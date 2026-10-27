#!/usr/bin/env bash
# tests/test_lock_show.sh -- Phase 3: `lock show` (desired vs installed + status).
# (§12); read-only (no lock, no mutation).
set -Eeuo pipefail
: "${SPM_ROOT:=$(readlink -f "$(dirname "${BASH_SOURCE[0]}")/..")}"
export SPM_ROOT
. "$SPM_ROOT/tests/lib.sh"
spm_setup_test_env

BIN="$SPM_TEST_BIN"

reset_helloapp() {
	bash "$BIN" uninstall helloapp >/dev/null 2>&1 || true
	rm -f "$SPM_CONFIG_DIR/locks/helloapp.json" "$BIN_DIR/hello"
	rm -rf "$APPS_DIR/helloapp" "$APPS_DIR/.staging/helloapp" "$SPM_CONFIG_DIR/pending/helloapp"
}
reset_upgradeapp() {
	bash "$BIN" uninstall upgradeapp >/dev/null 2>&1 || true
	rm -f "$SPM_CONFIG_DIR/locks/upgradeapp.json" "$BIN_DIR/upg"
	rm -rf "$APPS_DIR/upgradeapp" "$APPS_DIR/.staging/upgradeapp" "$SPM_CONFIG_DIR/pending/upgradeapp"
}

# --- up-to-date -------------------------------------------------------------
reset_helloapp
spm_run bash "$BIN" lock update helloapp
spm_eq_int "$SPM_CODE" 0
spm_run bash "$BIN" install helloapp
spm_eq_int "$SPM_CODE" 0
spm_run bash "$BIN" lock show helloapp
spm_eq_int "$SPM_CODE" 0
spm_contains "$SPM_OUT" "helloapp"
spm_contains "$SPM_OUT" "up-to-date"
# desired and installed both the pinned version.
spm_contains "$SPM_OUT" "1.0.0"

# --- upgrade (v1 installed, v2 pin) -----------------------------------------
reset_upgradeapp
spm_run bash "$BIN" lock update upgradeapp@1.0.0
spm_eq_int "$SPM_CODE" 0
spm_run bash "$BIN" install upgradeapp
spm_eq_int "$SPM_CODE" 0
spm_run bash "$BIN" lock update upgradeapp@latest   # -> v2 pin
spm_eq_int "$SPM_CODE" 0
spm_run bash "$BIN" lock show upgradeapp
spm_eq_int "$SPM_CODE" 0
spm_contains "$SPM_OUT" "upgradeapp"
spm_contains "$SPM_OUT" "upgrade"
spm_contains "$SPM_OUT" "2.0.0"   # desired (pin) version
spm_contains "$SPM_OUT" "1.0.0"   # installed version

# --- not installed (pin exists, app absent) ---------------------------------
spm_run bash "$BIN" uninstall upgradeapp >/dev/null 2>&1 || true
rm -rf "$APPS_DIR/upgradeapp" "$BIN_DIR/upg"
# Pin still present (v2).
spm_run bash "$BIN" lock show upgradeapp
spm_eq_int "$SPM_CODE" 0
spm_contains "$SPM_OUT" "not installed"
spm_contains "$SPM_OUT" "2.0.0"   # desired still shows the pin version

# --- no pin (named package has no pin) --------------------------------------
reset_helloapp
spm_run bash "$BIN" lock show helloapp
spm_eq_int "$SPM_CODE" 0
spm_contains "$SPM_OUT" "no pin"

# --- no-arg: lists every pinned package -------------------------------------
spm_run bash "$BIN" lock update helloapp >/dev/null 2>&1 || true
spm_run bash "$BIN" lock update upgradeapp@1.0.0 >/dev/null 2>&1 || true
spm_run bash "$BIN" lock show
spm_eq_int "$SPM_CODE" 0
spm_contains "$SPM_OUT" "helloapp"
spm_contains "$SPM_OUT" "upgradeapp"

spm_end
