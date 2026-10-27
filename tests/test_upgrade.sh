#!/usr/bin/env bash
# tests/test_upgrade.sh -- Phase 3: `upgrade` (in-place and safe modes),
# --safe-upgrade/--no-safe-upgrade, SAFE_UPGRADE config, --dry-run, and the
# (version + sha256) up-to-date comparison. (§11, §12)
set -Eeuo pipefail
: "${SPM_ROOT:=$(readlink -f "$(dirname "${BASH_SOURCE[0]}")/..")}"
export SPM_ROOT
. "$SPM_ROOT/tests/lib.sh"
spm_setup_test_env

BIN="$SPM_TEST_BIN"
upg_pin="$SPM_CONFIG_DIR/locks/upgradeapp.json"

# Install upgradeapp at v1.0.0 then resolve the v2.0.0 pin, leaving a fresh
# "would upgrade" state. Returns without asserting.
setup_v1_then_v2pin() {
	bash "$BIN" uninstall upgradeapp >/dev/null 2>&1 || true
	rm -f "$upg_pin" "$BIN_DIR/upg"
	rm -rf "$APPS_DIR/upgradeapp" "$APPS_DIR/.staging/upgradeapp"
	spm_run bash "$BIN" lock update upgradeapp@1.0.0
	[ "$SPM_CODE" = 0 ] || { echo "setup lock v1 failed"; return 1; }
	spm_run bash "$BIN" install upgradeapp
	[ "$SPM_CODE" = 0 ] || { echo "setup install v1 failed"; return 1; }
	spm_run bash "$BIN" lock update upgradeapp@latest   # -> v2 pin
	[ "$SPM_CODE" = 0 ] || { echo "setup lock v2 failed"; return 1; }
}

upg_ver() { jq -r '.version' "$APPS_DIR/upgradeapp/.spm/lock.json" 2>/dev/null || true; }

# --- up-to-date: upgrade is a no-op when the installed pin matches ----------
setup_v1_then_v2pin
# Back the pin down to v1 so the install matches -> up-to-date.
spm_run bash "$BIN" lock update upgradeapp@1.0.0
spm_eq_int "$SPM_CODE" 0
spm_run bash "$BIN" upgrade upgradeapp
spm_eq_int "$SPM_CODE" 0
spm_contains "$SPM_ERR" "already up-to-date"
spm_eq "$("$BIN_DIR/upg" 2>&1)" "upgrade v1 from static-pkgmgr fixture" \
	|| spm_fail "content changed on an up-to-date upgrade"

# --- in-place upgrade: v1 -> v2 (default mode) ------------------------------
setup_v1_then_v2pin
spm_run bash "$BIN" upgrade upgradeapp
spm_eq_int "$SPM_CODE" 0
spm_contains "$SPM_ERR" "upgrade: upgradeapp upgraded to 2.0.0 (mode=inplace)"
spm_eq "$("$BIN_DIR/upg" 2>&1)" "upgrade v2 from static-pkgmgr fixture" \
	|| spm_fail "content not v2 after in-place upgrade"
spm_eq "$(upg_ver)" "2.0.0" || spm_fail "installed lock.json not v2"
spm_false "staging tree left after upgrade" test -d "$APPS_DIR/.staging/upgradeapp"

# --- safe upgrade: old tree preserved during extraction, then removed -------
setup_v1_then_v2pin
spm_run bash "$BIN" --safe-upgrade upgrade upgradeapp
spm_eq_int "$SPM_CODE" 0
spm_contains "$SPM_ERR" "upgrade: upgradeapp upgraded to 2.0.0 (mode=safe)"
spm_eq "$("$BIN_DIR/upg" 2>&1)" "upgrade v2 from static-pkgmgr fixture" \
	|| spm_fail "content not v2 after safe upgrade"
spm_eq "$(upg_ver)" "2.0.0" || spm_fail "installed lock.json not v2 (safe)"
spm_false "old tree left after safe upgrade" test -d "$APPS_DIR/.staging/upgradeapp.old"
spm_true "app dir still present after safe upgrade" test -d "$APPS_DIR/upgradeapp"

# --- SAFE_UPGRADE config key drives the mode --------------------------------
setup_v1_then_v2pin
printf 'SAFE_UPGRADE=1\n' > "$SPM_CONFIG_DIR/config.env"
spm_run bash "$BIN" upgrade upgradeapp
spm_eq_int "$SPM_CODE" 0
spm_contains "$SPM_ERR" "mode=safe"
rm -f "$SPM_CONFIG_DIR/config.env"
# --no-safe-upgrade overrides the config back to in-place.
setup_v1_then_v2pin
printf 'SAFE_UPGRADE=1\n' > "$SPM_CONFIG_DIR/config.env"
spm_run bash "$BIN" --no-safe-upgrade upgrade upgradeapp
spm_eq_int "$SPM_CODE" 0
spm_contains "$SPM_ERR" "mode=inplace"
rm -f "$SPM_CONFIG_DIR/config.env"

# --- --dry-run prints the plan, changes nothing ----------------------------
setup_v1_then_v2pin
spm_run bash "$BIN" -n upgrade upgradeapp
spm_eq_int "$SPM_CODE" 0
spm_contains "$SPM_ERR" "would upgrade upgradeapp"
# No mutation: still v1.
spm_eq "$("$BIN_DIR/upg" 2>&1)" "upgrade v1 from static-pkgmgr fixture" \
	|| spm_fail "dry-run changed the installed app"
spm_eq "$(upg_ver)" "1.0.0" || spm_fail "dry-run wrote a new .spm/lock.json"
spm_false "dry-run must not leave a pending marker" \
	test -f "$SPM_CONFIG_DIR/pending/upgradeapp"

# --- error: not installed ---------------------------------------------------
bash "$BIN" uninstall upgradeapp >/dev/null 2>&1 || true
rm -f "$upg_pin" "$BIN_DIR/upg"
rm -rf "$APPS_DIR/upgradeapp" "$APPS_DIR/.staging/upgradeapp"
spm_run bash "$BIN" upgrade upgradeapp
spm_eq_int "$SPM_CODE" 1
spm_contains "$SPM_ERR" "is not installed"

# --- error: explicit name with no pin ---------------------------------------
spm_run bash "$BIN" lock update upgradeapp@1.0.0
spm_eq_int "$SPM_CODE" 0
spm_run bash "$BIN" install upgradeapp
spm_eq_int "$SPM_CODE" 0
rm -f "$upg_pin"
spm_run bash "$BIN" upgrade upgradeapp
spm_eq_int "$SPM_CODE" 1
spm_contains "$SPM_ERR" "no pin for upgradeapp"
bash "$BIN" uninstall upgradeapp >/dev/null 2>&1 || true

# --- no-arg upgrade: skip installed-but-pinless packages with a warning ------
spm_run bash "$BIN" lock update upgradeapp@1.0.0
spm_run bash "$BIN" install upgradeapp
rm -f "$upg_pin"
spm_run bash "$BIN" upgrade
spm_eq_int "$SPM_CODE" 0
spm_contains "$SPM_ERR" "no pin for upgradeapp; skipping"
bash "$BIN" uninstall upgradeapp >/dev/null 2>&1 || true

# --- no-arg upgrade: nothing installed --------------------------------------
spm_run bash "$BIN" upgrade
spm_eq_int "$SPM_CODE" 0
spm_contains "$SPM_ERR" "no installed packages"

spm_end
