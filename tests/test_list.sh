#!/usr/bin/env bash
# tests/test_list.sh -- Phase 3: `list` (name, version, path of installed pkgs).
# (§12 command: list); read-only (no lock, no mutation).
set -Eeuo pipefail
: "${SPM_ROOT:=$(readlink -f "$(dirname "${BASH_SOURCE[0]}")/..")}"
export SPM_ROOT
. "$SPM_ROOT/tests/lib.sh"
spm_setup_test_env

BIN="$SPM_TEST_BIN"

reset_helloapp() {
	bash "$BIN" uninstall helloapp >/dev/null 2>&1 || true
	rm -f "$SPM_CONFIG_DIR/locks/helloapp.json" "$BIN_DIR/hello"
	rm -rf "$APPS_DIR/helloapp" "$APPS_DIR/.staging/helloapp"
}

# --- empty install dir -> empty list, exit 0 --------------------------------
reset_helloapp
spm_run bash "$BIN" list
spm_eq_int "$SPM_CODE" 0
spm_eq "$SPM_OUT" ""

# --- installed package appears with version and path ------------------------
reset_helloapp
spm_run bash "$BIN" lock update helloapp
spm_run bash "$BIN" install helloapp
spm_eq_int "$SPM_CODE" 0
spm_run bash "$BIN" list
spm_eq_int "$SPM_CODE" 0
spm_contains "$SPM_OUT" "helloapp"
spm_contains "$SPM_OUT" "1.0.0"
spm_contains "$SPM_OUT" "$APPS_DIR/helloapp"
# One entry per installed package, name first field.
spm_eq "$(printf '%s\n' "$SPM_OUT" | cut -f1 | sort | tr '\n' ',')" "helloapp,"

# --- multiple packages ------------------------------------------------------
reset_helloapp
spm_run bash "$BIN" lock update helloapp withuninstall 2>/dev/null || true
spm_run bash "$BIN" install helloapp withuninstall
spm_eq_int "$SPM_CODE" 0
spm_run bash "$BIN" list
spm_eq_int "$SPM_CODE" 0
spm_contains "$SPM_OUT" "helloapp"
spm_contains "$SPM_OUT" "withuninstall"
# Two distinct app dirs listed.
spm_eq "$(printf '%s\n' "$SPM_OUT" | cut -f1 | sort | tr '\n' ',')" \
	"helloapp,withuninstall,"

spm_end
