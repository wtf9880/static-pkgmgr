#!/usr/bin/env python3
# -*- coding: utf-8 -*-

# Copyright (c) static-pkgmgr contributors.
# SPDX-License-Identifier: MIT
#
# Ansible module: manage user-level apps installed by `static-pkgmgr`.
#
# This is a thin, idempotency-aware wrapper around the `static-pkgmgr` CLI.
# It does NOT re-implement the package manager; it treats the CLI as the
# source of truth and uses the tool's own read-only commands
# (`list`, `lock show`, and `lock update --dry-run`) to decide whether a
# change is needed, then invokes the mutating command only when required.
#
# Why a custom module instead of the `command` module?
#   * Correct `changed` reporting: the CLI's `upgrade` is a no-op that still
#     exits 0, so a naive `command` call always reports "changed".
#   * Ansible `check_mode` support: the module predicts the outcome without
#     writing pins, app dirs, or links.
#   * Structured return values a playbook can `register` against.
#
# Requirements on the target:
#   * The `static-pkgmgr` entrypoint must be on PATH (or give `spm_path`).
#   * `jq`, `curl`, `git`, and Bash 5.1+ (static-pkgmgr's own deps).
#   * If using GitHub-based recipes, `GITHUB_TOKEN` (via `github_token`).

from __future__ import annotations

import re

from ansible.module_utils.basic import AnsibleModule


# ---------------------------------------------------------------------------
# Process / environment plumbing
# ---------------------------------------------------------------------------

def build_env(module):
    """Environment fragment for `static-pkgmgr` subprocesses.

    Only SPM_CONFIG_DIR, GITHUB_TOKEN and SPM_TEST_MODE are honored from the
    environment (STRUCTURE.md §5: APPS_DIR/BIN_DIR are NOT read from the
    environment -- they come from config.env or $HOME defaults). We therefore
    deliberately do NOT forward APPS_DIR/BIN_DIR; see the module docs.
    """
    env = {}
    if module.params["config_dir"]:
        env["SPM_CONFIG_DIR"] = module.params["config_dir"]
    if module.params["github_token"]:
        env["GITHUB_TOKEN"] = module.params["github_token"]
    if module.params["test_mode"]:
        env["SPM_TEST_MODE"] = "1"
    # Ansible's run_command merges this onto the controller's os.environ via
    # environ_update, so PATH and HOME still reach the subprocess.
    return env


def spm_prefix(module):
    """Return the static-pkgmgr invocation as a list prefix."""
    path = module.params.get("spm_path")
    return [path] if path else ["static-pkgmgr"]


def run_spm(module, args, check=True):
    """Run static-pkgmgr with `args` (a list). Returns (rc, out, err)."""
    cmd = spm_prefix(module) + list(args)
    rc, out, err = module.run_command(
        cmd, environ_update=build_env(module)
    )
    if check and rc != 0:
        module.fail_json(
            msg="static-pkgmgr command failed: " + " ".join(cmd),
            cmd=cmd,
            rc=rc,
            stdout=out,
            stderr=err,
        )
    return rc, out, err


# ---------------------------------------------------------------------------
# Read-only queries (safe in check_mode; never take the global lock)
# ---------------------------------------------------------------------------

def list_packages(module):
    """Return {name: (version, install_path)} from `static-pkgmgr list`.

    `list` is read-only and takes no lock (STRUCTURE.md §10/§12).
    """
    rc, out, _ = run_spm(module, ["list"], check=False)
    pkgs = {}
    if rc != 0 or not out:
        return pkgs
    for line in out.splitlines():
        parts = line.split("\t")
        # layout: name \t version \t path
        if len(parts) >= 3 and parts[0]:
            pkgs[parts[0]] = (parts[1], parts[2])
    return pkgs


def lock_show(module, name):
    """Return dict(desired, installed, status) for one package via `lock show`.

    status is one of: up-to-date | upgrade | not installed | no pin | unknown.
    `lock show` is read-only (§12).
    """
    rc, out, err = run_spm(module, ["lock", "show", name], check=False)
    if rc != 0:
        return {"status": "unknown", "stderr": err}
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) >= 4 and parts[0] == name:
            return {"desired": parts[1], "installed": parts[2], "status": parts[3]}
    return {"status": "unknown"}


def dryrun_latest_version(module, name):
    """Resolve the latest version *without writing a pin* (check_mode helper).

    Uses `lock update --dry-run`, whose output is:
        'lock: would update pin for <pkg> to <VER> (requested=latest) (dry-run)'
    Returns the resolved version string, or None if it could not be parsed.
    """
    rc, out, _ = run_spm(module, ["lock", "update", "-n", name], check=False)
    if rc != 0 or not out:
        return None
    m = re.search(re.escape(name) + r"\b.*?to (\S+)", out)
    return m.group(1) if m else None


# ---------------------------------------------------------------------------
# State handlers
# ---------------------------------------------------------------------------

def install_one(module, name):
    """Run `install`; treat 'already installed' as non-fatal (race-safe).

    `install` resolves the pin itself if none exists (§12), so callers do not
    need to pre-resolve for the unversioned case.
    """
    rc, out, err = run_spm(module, ["install", name], check=False)
    if rc == 1 and "already installed" in (err or ""):
        return  # idempotency: it landed between our check and now
    if rc != 0:
        module.fail_json(msg="install failed for " + name, rc=rc, stdout=out, stderr=err)


def upgrade_one(module, name):
    """Run `upgrade`; idempotent -- a no-op returns 0 when already current."""
    rc, out, err = run_spm(module, ["upgrade", name], check=False)
    if rc == 1 and "not installed" in (err or ""):
        # lock show said "not installed" but upgrade disagrees -> install.
        install_one(module, name)
        return
    if rc != 0:
        module.fail_json(msg="upgrade failed for " + name, rc=rc, stdout=out, stderr=err)


def ensure_present(module, name, version):
    """state=present: ensure the package is installed (at `version` if given)."""
    check = module.check_mode
    pkgs = list_packages(module)
    installed_ver = pkgs.get(name, (None, None))[0]

    if version:
        spec = name + ("@latest" if version == "latest" else "@" + version)
        if check:
            rc, out, err = run_spm(module, ["lock", "update", "-n", spec], check=False)
            if rc != 0:
                module.fail_json(msg="lock update (dry-run) failed for " + spec, rc=rc, stdout=out, stderr=err)
        else:
            rc, out, err = run_spm(module, ["lock", "update", spec], check=False)
            if rc != 0:
                module.fail_json(msg="lock update failed for " + spec, rc=rc, stdout=out, stderr=err)
        # Presence + version match.
        if installed_ver is not None:
            if installed_ver == version:
                return False, "%s already installed at %s" % (name, version)
            if check:
                return True, "would reinstall %s from %s to %s" % (name, installed_ver, version)
            install_one(module, name)
            return True, "installed %s at %s" % (name, version)
        if check:
            return True, "would install %s at %s" % (name, version)
        install_one(module, name)
        return True, "installed %s at %s" % (name, version)

    # No version pin requested: presence is the only criterion.
    if installed_ver is not None:
        return False, "%s already installed (%s)" % (name, installed_ver)
    if check:
        return True, "would install %s" % name
    install_one(module, name)
    return True, "installed %s" % name


def ensure_absent(module, name):
    """state=absent: ensure the package is uninstalled."""
    pkgs = list_packages(module)
    if name not in pkgs:
        return False, "%s is not installed" % name
    if module.check_mode:
        return True, "would uninstall %s" % name
    rc, out, err = run_spm(module, ["uninstall", name], check=False)
    if rc == 1 and "is not installed" in (err or ""):
        return False, "%s is not installed" % name  # race: already gone
    if rc != 0:
        module.fail_json(msg="uninstall failed for " + name, rc=rc, stdout=out, stderr=err)
    return True, "uninstalled %s" % name


def ensure_latest(module, name):
    """state=latest: refresh the pin, then bring the install up to it."""
    if module.check_mode:
        latest = dryrun_latest_version(module, name)
        if latest is None:
            # Resolution failed in check mode: be conservative and assume a
            # change would happen (the real run surfaces the real error).
            return True, "would update %s to latest (resolution unconfirmed in check mode)" % name
        pkgs = list_packages(module)
        if name not in pkgs:
            return True, "would install %s (latest=%s)" % (name, latest)
        installed_ver = pkgs[name][0]
        if installed_ver == latest:
            return False, "%s already at latest (%s)" % (name, latest)
        return True, "would upgrade %s from %s to %s" % (name, installed_ver, latest)

    # Real run: refresh the pin to the latest (contacts upstream, writes pin).
    rc, out, err = run_spm(module, ["lock", "update", name], check=False)
    if rc != 0:
        module.fail_json(msg="lock update failed for " + name, rc=rc, stdout=out, stderr=err)

    status = lock_show(module, name)
    st = status.get("status")
    if st == "up-to-date":
        return False, "%s already at latest (%s)" % (name, status.get("desired", "?"))
    if st == "upgrade":
        upgrade_one(module, name)
        return True, "upgraded %s to %s" % (name, status.get("desired", "?"))
    if st == "not installed":
        install_one(module, name)
        return True, "installed %s (latest)" % name
    # "no pin" or "unknown" here is unexpected after a successful lock update.
    module.fail_json(
        msg="could not determine install status for " + name + " after lock update",
        status=st,
        lock_show=status,
    )


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    module = AnsibleModule(
        argument_spec={
            "name": {
                "type": "list",
                "elements": "str",
                "required": True,
                "aliases": ["pkg", "package"],
            },
            "state": {
                "type": "str",
                "choices": ["present", "absent", "latest"],
                "default": "present",
            },
            "version": {
                "type": "str",
                "default": None,
            },
            "spm_path": {
                "type": "str",
                "default": None,
                "description": "Path to the static-pkgmgr entrypoint.",
            },
            "config_dir": {
                "type": "str",
                "default": None,
                "description": "Overrides $SPM_CONFIG_DIR (the lock/state root).",
            },
            "github_token": {
                "type": "str",
                "default": None,
                "no_log": True,
                "description": "Passed as $GITHUB_TOKEN for GitHub recipes.",
            },
            "test_mode": {
                "type": "bool",
                "default": False,
                "description": "Set SPM_TEST_MODE=1 (allows file:// fixture URLs).",
            },
        },
        supports_check_mode=True,
    )

    state = module.params["state"]
    version = module.params["version"]
    if version and state != "present":
        module.warn("version is ignored for state=%s" % state)
        version = None

    changed = False
    results = []
    for name in module.params["name"]:
        if state == "present":
            c, msg = ensure_present(module, name, version)
        elif state == "absent":
            c, msg = ensure_absent(module, name)
        else:
            c, msg = ensure_latest(module, name)
        changed = changed or bool(c)
        results.append({"package": name, "changed": bool(c), "msg": msg})

    module.exit_json(changed=changed, packages=results)


if __name__ == "__main__":
    main()
