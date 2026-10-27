#!/usr/bin/env bash
# tests/test_uninstall.sh -- tests for lib/uninstall.sh (Phase 1) (§7.4, §9, §10).
set -Eeuo pipefail
: "${SPM_ROOT:=$(readlink -f "$(dirname "${BASH_SOURCE[0]}")/..")}"
export SPM_ROOT
. "$SPM_ROOT/tests/lib.sh"
spm_setup_test_env

BIN="$SPM_TEST_BIN"

reset_wu() {
	bash "$BIN" uninstall withuninstall >/dev/null 2>&1 || true
	rm -f "$SPM_CONFIG_DIR/locks/withuninstall.json" "$BIN_DIR/hello" \
		"$BIN_DIR/.uninstalled-withuninstall"
	rm -rf "$APPS_DIR/withuninstall" "$APPS_DIR/.staging/withuninstall"
}

# --- install then uninstall; recipe uninstall.sh runs first (§7.4) -------
reset_wu
spm_run bash "$BIN" install withuninstall
spm_eq_int "$SPM_CODE" 0
spm_run bash "$BIN" uninstall withuninstall
spm_eq_int "$SPM_CODE" 0
spm_contains "$SPM_ERR" "withuninstall removed"
# The recipe's uninstall.sh ran while SPM_FINAL_DIR still existed.
spm_true "recipe uninstall.sh did not run" \
	test -f "$BIN_DIR/.uninstalled-withuninstall"
spm_false "link remained after uninstall" test -L "$BIN_DIR/hello"
spm_false "app dir remained after uninstall" test -e "$APPS_DIR/withuninstall"

# --- uninstall not installed -> error --------------------------------------
reset_wu
spm_run bash "$BIN" uninstall withuninstall
spm_eq_int "$SPM_CODE" 1
spm_contains "$SPM_ERR" "is not installed"

# --- fallback: links removed even without .spm/links (§9/§10) -------------
reset_wu
spm_run bash "$BIN" install withuninstall
spm_eq_int "$SPM_CODE" 0
# Delete the recorded links file so uninstall must rely on a BIN_DIR scan.
rm -f "$APPS_DIR/withuninstall/.spm/links"
spm_run bash "$BIN" uninstall withuninstall
spm_eq_int "$SPM_CODE" 0
spm_false "fallback scan did not remove the link" test -L "$BIN_DIR/hello"
spm_false "app dir remained (fallback)" test -e "$APPS_DIR/withuninstall"

spm_end
