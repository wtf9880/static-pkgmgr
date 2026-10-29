#!/usr/bin/env bash
# Validation harness for the static_pkgmgr Ansible module.
#
# Sets up an isolated static-pkgmgr repo (packages/ -> tests/fixtures) so the
# module can drive the real CLI without touching $HOME or the real repo state,
# then runs the check-mode and apply playbooks through ansible-playbook.
#
# This script is meant to be run INSIDE `nix-shell -p ansible`:
#   nix-shell -p ansible --run 'bash integrations/ansible/tests/run_validation.sh'
set -Eeuo pipefail

# Locate the repository root from this script's path.
SCRIPT_DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)

# --- isolated static-pkgmgr sandbox ----------------------------------------
SANDBOX=$(mktemp -dt spm-ansible.XXXXXX)
export HOME="$SANDBOX/home"
mkdir -p "$HOME"

SPM_CONFIG_DIR="$SANDBOX/config"
APPS_DIR="$SANDBOX/apps"
BIN_DIR="$SANDBOX/bin"
mkdir -p "$SPM_CONFIG_DIR" "$APPS_DIR" "$BIN_DIR"

# APPS_DIR / BIN_DIR are NOT read from the environment by static-pkgmgr (§5),
# so they must live in config.env inside SPM_CONFIG_DIR.
printf 'APPS_DIR=%s\nBIN_DIR=%s\n' "$APPS_DIR" "$BIN_DIR" > "$SPM_CONFIG_DIR/config.env"
export SPM_CONFIG_DIR

# A throwaway SPM_ROOT whose packages/ serves the test fixtures (file:// URLs),
# so no network is needed. The entrypoint resolves SPM_ROOT from its own real
# path, so we copy it into the temp repo.
TMP_REPO="$SANDBOX/repo"
mkdir -p "$TMP_REPO/bin"
cp "$REPO_ROOT/bin/static-pkgmgr" "$TMP_REPO/bin/static-pkgmgr"
chmod +x "$TMP_REPO/bin/static-pkgmgr"
ln -s "$REPO_ROOT/lib" "$TMP_REPO/lib"
ln -s "$REPO_ROOT/helpers" "$TMP_REPO/helpers"
ln -s "$REPO_ROOT/tests/fixtures" "$TMP_REPO/packages"

# Put the temp-repo entrypoint on PATH as `static-pkgmgr`.
mkdir -p "$SANDBOX/wrappers"
ln -sf "$TMP_REPO/bin/static-pkgmgr" "$SANDBOX/wrappers/static-pkgmgr"
export PATH="$SANDBOX/wrappers:$PATH"

# --- locate the module + playbooks -----------------------------------------
MODULE_DIR="$REPO_ROOT/integrations/ansible/library"

# In this Nix-managed sandbox, Ansible 2.21 executes the module via its
# shebang but refuses to substitute `ansible_python_interpreter` for a
# `#!/usr/bin/env python3` shebang (it single-quotes the whole string as one
# argv0, so `/bin/sh -c '/usr/bin/env python3 ...'` fails). On any normal
# Linux/macOS manager this is a non-issue. As a test-only workaround we copy
# the module into a temp dir and rewrite ONLY the shebang to the absolute
# interpreter. The repository module is left untouched (portable shebang).
PY_BIN=$(command -v python3)
MOD_LIB="$SANDBOX/ansible_lib"
mkdir -p "$MOD_LIB"
{ printf '#!%s\n' "$PY_BIN"; tail -n +2 "$MODULE_DIR/static_pkgmgr.py"; } > "$MOD_LIB/static_pkgmgr.py"
export ANSIBLE_LIBRARY="$MOD_LIB"

PLAY_APPLY="$SCRIPT_DIR/playbook_apply.yml"
PLAY_CHECK="$SCRIPT_DIR/playbook_check.yml"

echo "ansible-playbook binary: $(command -v ansible-playbook || echo MISSING)"
echo "python on target:        $(python3 --version 2>&1)"
echo "module lib (patched):    $MOD_LIB/static_pkgmgr.py"

echo
echo "========================================================================"
echo "RUN 1/2: check_mode (--check) against fresh state -- no writes expected"
echo "========================================================================"
# --check still runs the module; the module must NOT mutate state. We use a
# fresh config dir so helloapp is absent.
# (SPM_CONFIG_DIR is already fresh.)
ansible-playbook -i localhost, -c local --check "$PLAY_CHECK"

echo
echo "========================================================================"
echo "RUN 2/2: real apply against fresh state -- install/idempotent/latest/absent"
echo "========================================================================"
ansible-playbook -i localhost, -c local "$PLAY_APPLY"

echo
echo "VALIDATION PASSED"
