#!/usr/bin/env bash
# tests/test_install.sh -- tests for lib/install.sh (Phase 1: in-place install)
# (§7.3, §9, §11.1).
set -Eeuo pipefail
: "${SPM_ROOT:=$(readlink -f "$(dirname "${BASH_SOURCE[0]}")/..")}"
export SPM_ROOT
. "$SPM_ROOT/tests/lib.sh"
spm_setup_test_env

BIN="$SPM_TEST_BIN"
pin="$SPM_CONFIG_DIR/locks/helloapp.json"

# Remove helloapp state between scenarios (best-effort).
reset_helloapp() {
	bash "$BIN" uninstall helloapp >/dev/null 2>&1 || true
	rm -f "$pin" "$BIN_DIR/hello"
	rm -rf "$APPS_DIR/helloapp" "$APPS_DIR/.staging/helloapp"
}

# --- fresh install (lock + install) ---------------------------------------
reset_helloapp
spm_run bash "$BIN" lock update helloapp
spm_eq_int "$SPM_CODE" 0
spm_run bash "$BIN" install helloapp
spm_eq_int "$SPM_CODE" 0
spm_contains "$SPM_ERR" "helloapp installed"
# App tree in place (no version in dir name, §4.2).
spm_true "app dir missing" test -d "$APPS_DIR/helloapp"
spm_true "bin/hello missing" test -x "$APPS_DIR/helloapp/bin/hello"
spm_false "versioned dir present" test -d "$APPS_DIR/helloapp-1.0.0"
# Link created in BIN_DIR with the right target.
spm_true "link missing" test -L "$BIN_DIR/hello"
spm_eq "$(readlink -f "$BIN_DIR/hello")" "$APPS_DIR/helloapp/bin/hello" \
	|| spm_fail "link target wrong"
spm_eq "$("$BIN_DIR/hello")" "hello from static-pkgmgr fixture" \
	|| spm_fail "hello produced wrong output"
# .spm metadata written atomically.
spm_true ".spm/lock.json missing" test -f "$APPS_DIR/helloapp/.spm/lock.json"
spm_true ".spm/links missing" test -f "$APPS_DIR/helloapp/.spm/links"
spm_contains "$(cat "$APPS_DIR/helloapp/.spm/links")" "$BIN_DIR/hello" \
	|| spm_fail "links file does not record the link"
spm_true ".spm/lock.json is not a valid pin" \
	jq -e '.package == "helloapp" and .schema == 1' "$APPS_DIR/helloapp/.spm/lock.json"
# No leftover staging dir after a successful install.
spm_false "staging dir left behind" test -d "$APPS_DIR/.staging/helloapp"

# --- already installed -> error (no upgrade path in Phase 1) --------------
spm_run bash "$BIN" install helloapp
spm_eq_int "$SPM_CODE" 1
spm_contains "$SPM_ERR" "already installed"

# --- missing pin -> auto-resolve first ------------------------------------
reset_helloapp
spm_false "pin should be absent" test -f "$pin"
spm_run bash "$BIN" install helloapp
spm_eq_int "$SPM_CODE" 0
spm_contains "$SPM_ERR" "no pin for helloapp; resolving first"
spm_true "auto-resolved install failed" test -d "$APPS_DIR/helloapp"

# --- sha mismatch -> recipe failure, no app dir, no links ---------------
reset_helloapp
spm_run bash "$BIN" lock update helloapp
spm_eq_int "$SPM_CODE" 0
# Corrupt the sha256 (still well-formed hex so pin validation passes).
jq '.artifacts.x86_64.sha256 = "0000000000000000000000000000000000000000000000000000000000000000"
    | .artifacts.aarch64.sha256 = "0000000000000000000000000000000000000000000000000000000000000000"' \
	"$pin" > "$pin.bad" && mv "$pin.bad" "$pin"
spm_run bash "$BIN" install helloapp
spm_eq_int "$SPM_CODE" 1
spm_contains "$SPM_ERR" "recipe failed"
spm_false "app dir created on sha mismatch" test -e "$APPS_DIR/helloapp"
spm_false "link created on sha mismatch" test -L "$BIN_DIR/hello"
spm_false "staging left behind on sha mismatch" test -d "$APPS_DIR/.staging/helloapp"

# --- link conflict -> failure before app dir is committed -----------------
reset_helloapp
spm_run bash "$BIN" lock update helloapp
mkdir -p "$BIN_DIR"
printf 'blocker\n' > "$BIN_DIR/hello"   # a regular file blocks the link
spm_run bash "$BIN" install helloapp
spm_eq_int "$SPM_CODE" 1
spm_contains "$SPM_ERR" "link conflict"
spm_false "app dir created on conflict" test -e "$APPS_DIR/helloapp"
if [ -f "$BIN_DIR/hello" ]; then
	spm_contains "$(cat "$BIN_DIR/hello")" "blocker"
else
	spm_fail "blocker file was removed on conflict"
fi

# --- no recipe -> error ---------------------------------------------------
reset_helloapp
spm_run bash "$BIN" install nope
spm_eq_int "$SPM_CODE" 1
spm_contains "$SPM_ERR" "no recipe for package"

spm_end
