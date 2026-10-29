# Ansible integration for `static-pkgmgr`

A reference **custom Ansible module** (`static_pkgmgr`) plus an example playbook
that ties the package manager's CLI to Ansible's declarative, idempotent model.

## What it does

`static-pkgmgr` already has an idempotency-friendly CLI (see `STRUCTURE.md`
§12):

| Command | When installed | Exit code |
| --- | --- | --- |
| `install <pkg>` | already installed | `1` ("... is already installed; use upgrade") |
| `upgrade <pkg>` | already up-to-date (pin matches install) | `0` ("... already up-to-date") |
| `uninstall <pkg>` | not installed | `1` ("... is not installed") |
| `lock show <pkg>` | always | `0`, tab-separated `<pkg>\t<desired>\t<installed>\t<status>` |

The catch: `upgrade` is a *no-op that still exits 0*, so the plain `command`
module always reports `changed=True`. The custom module fixes this by using the
tool's own read-only commands (`list`, `lock show`, and `lock update --dry-run`)
to decide whether a change is actually needed, and only then invoking the
mutating command. It also implements `check_mode`.

## Module arguments

| Argument | Type | Default | Notes |
| --- | --- | --- | --- |
| `name` | list[str] | required | Package name(s) to manage. Aliases: `pkg`, `package`. |
| `state` | present\|absent\|latest | `present` | `latest` refreshes the pin then upgrades/installs. |
| `version` | str | `null` | Only for `state=present`. Pins to `pkg@<version>` before installing. Ignored (with a warning) for other states. |
| `spm_path` | str | `static-pkgmgr` | Override the entrypoint path. |
| `config_dir` | str | `$SPM_CONFIG_DIR` | Overrides `$SPM_CONFIG_DIR` (lock/state root). |
| `github_token` | str | from environment | Passed as `$GITHUB_TOKEN` (no_log). |
| `test_mode` | bool | `false` | Sets `SPM_TEST_MODE=1` (allows `file://` fixture URLs). |

## How idempotency is detected

- **`present`** — `static-pkgmgr list` (read-only) tells us whether the package is
  installed. Not installed → `install` (changed). Installed → no change.
- **`absent`** — same `list` lookup; installed → `uninstall` (changed).
- **`latest`** — `lock update <pkg>` refreshes the pin (the tool's own
  "resolve latest" step), then `lock show <pkg>` reports the status:
  - `up-to-date` → no change
  - `upgrade` → `upgrade` (changed)
  - `not installed` → `install` (changed)
  - `no pin` → fail
  - `check_mode` uses `lock update --dry-run` + a version comparison as a
    fast, side-effect-free approximation (it cannot see SHA-256-only pin
    changes, since the dry run writes no pin file).

## Important: where things get installed

`static-pkgmgr` does **not** read `APPS_DIR` or `BIN_DIR` from the environment
(`STRUCTURE.md` §5: only `SPM_CONFIG_DIR` and `GITHUB_TOKEN` are read from env).
It defaults to `$HOME/.local/opt` and `$HOME/.local/bin`.

So either:

1. **Run as the target user** (the common case). With `become: true` +
   `become_user: alice`, the module runs `static-pkgmgr` and it installs into
   `alice`'s `~/.local/...`. No `config_dir`/`spm_path` needed.
2. **Isolate the state** by setting `config_dir` to a custom directory that
   contains a `config.env` overriding `APPS_DIR`/`BIN_DIR`:

   ```ini
   # $SPM_CONFIG_DIR/config.env
   APPS_DIR=/srv/apps
   BIN_DIR=/srv/bin
   ```

The environment section of the example playbook shows the `SPM_CONFIG_DIR` +
`SPM_TEST_MODE` usage. Note we deliberately do **not** put `APPS_DIR`/`BIN_DIR`
in the `environment` block — they would be silently ignored.

## Installing the module

Three options; pick one.

**Option A — per-playbook via `ANSIBLE_LIBRARY`:**
```sh
ANSIBLE_LIBRARY=integrations/ansible/library \
  ansible-playbook -i inventory manage_packages.yml
```

**Option B — inside a role** (auto-discovered): copy the file to
`roles/<role>/library/static_pkgmgr.py` and call it as `myorg.nginx.static_pkgmgr`
… or just `static_pkgmgr` after `collections/roles` are on the path.

**Option C — globally on the controller:**
```sh
mkdir -p ~/.ansible/plugins/modules
cp integrations/ansible/library/static_pkgmgr.py ~/.ansible/plugins/modules/
```

Then `ansible-doc -t module static_pkgmgr` shows the help.

## Validation

The module is exercised end-to-end through real `ansible-playbook` against
`static-pkgmgr`'s own test fixtures. The harness
(`tests/run_validation.sh`) builds an isolated sandbox whose `packages/`
serves the `helloapp` fixture (a `file://` archive, valid under
`SPM_TEST_MODE=1`), wires a temp `static-pkgmgr` onto `PATH`, and runs two
playbooks:

- `tests/playbook_check.yml` — `--check` mode; asserts the module predicts
  `changed` for a missing package and `changed=false` when already absent.
- `tests/playbook_apply.yml` — real run; asserts `changed` across the full
  lifecycle: install → idempotent reinstall → latest (no-op) → uninstall →
  idempotent absent.

```sh
# from the repo root:
nix-shell -p ansible --run \
  'bash integrations/ansible/tests/run_validation.sh'
```

(The harness rewrites the module's `python3` shebang to an absolute path inside
a temp copy — a workaround for a quirk in the Nix-packaged Ansible where
`#!/usr/bin/env python3` is mis-tokenized. The repository module keeps its
portable shebang.) See `playbooks/manage_packages.yml` for the real-world
shape (multi-package, `become_user`, `BASELINE_REPO`).

## Limitations / notes

- `version` is honored only for `state=present`. It pins via `lock update
  <pkg>@<version>` before installing; an unresolvable version fails the task.
- `state=latest` in `check_mode` approximates "would change" via the resolved
  *version*; a same-version artifact whose SHA-256 changed is reported as
  "up-to-date" in check mode (correct in real mode, where `lock show` sees the
  full SHA-256 comparison).
- The module shells out to the CLI rather than importing internals; this keeps
  it decoupled from Bash internals and works over SSH exactly like a user
  would invoke the tool.
