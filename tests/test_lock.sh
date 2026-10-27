#!/usr/bin/env bash
# tests/test_lock.sh -- tests for lib/lock.sh (Phase 1: lock update) (§6, §7.2, §12).
set -Eeuo pipefail
: "${SPM_ROOT:=$(readlink -f "$(dirname "${BASH_SOURCE[0]}")/..")}"
export SPM_ROOT
. "$SPM_ROOT/tests/lib.sh"
spm_setup_test_env
. "$SPM_ROOT/lib/lock.sh"   # for spm_validate_pin

BIN="$SPM_TEST_BIN"
pin="$SPM_CONFIG_DIR/locks/helloapp.json"

# --- lock update <pkg> writes a schema-1 pin ------------------------------
spm_run bash "$BIN" lock update helloapp
spm_eq_int "$SPM_CODE" 0
spm_contains "$SPM_ERR" "updated helloapp"
spm_true "pin file not written" test -f "$pin"
spm_true "pin schema/content invalid" \
	jq -e '.schema == 1 and .package == "helloapp" and .version == "1.0.0"
	       and .requested == null and (.artifacts | length >= 1)' "$pin"
# The pin must carry an artifact for the running architecture (x86_64 in this
# env; the fixture emits both x86_64 and aarch64).
spm_true "no artifact for x86_64" \
	jq -e '.artifacts["x86_64"] | (.url | type == "string") and (.sha256 | type == "string") and (.size | type == "number")' "$pin"
# Atomic write: no leftover temp files in locks/.
left=$(find "$SPM_CONFIG_DIR/locks" -name '.pin.*' -print 2>/dev/null)
spm_eq "$left" "" || spm_fail "leftover pin temp files: [$left]"

# --- lock update <pkg>@<ver> sets requested ------------------------------
rm -f "$pin"
spm_run bash "$BIN" lock update helloapp@1.2.3
spm_eq_int "$SPM_CODE" 0
spm_true "requested not set to 1.2.3" jq -e '.requested == "1.2.3" and .version == "1.0.0"' "$pin"

# --- lock update <pkg>@latest -> requested null --------------------------
spm_run bash "$BIN" lock update helloapp@latest
spm_eq_int "$SPM_CODE" 0
spm_true "requested not null for @latest" jq -e '.requested == null' "$pin"

# --- lock update <pkg> (keep) preserves requested ------------------------
spm_run bash "$BIN" lock update helloapp@9.9.9
spm_eq_int "$SPM_CODE" 0
spm_true "requested not set to 9.9.9" jq -e '.requested == "9.9.9"' "$pin"
# Re-run with no version -> keep -> requested preserved as 9.9.9.
spm_run bash "$BIN" lock update helloapp
spm_eq_int "$SPM_CODE" 0
spm_true "keep did not preserve requested" jq -e '.requested == "9.9.9"' "$pin"

# --- lock update with no args locks all recipes --------------------------
rm -f "$SPM_CONFIG_DIR/locks"/*.json
spm_run bash "$BIN" lock update
spm_eq_int "$SPM_CODE" 0
spm_contains "$SPM_ERR" "updated helloapp"
spm_true "lock update (all) did not write helloapp pin" test -f "$pin"

# --- invalid requested version is rejected --------------------------------
spm_run bash "$BIN" lock update helloapp@v/invalid
spm_eq_int "$SPM_CODE" 1
spm_contains "$SPM_ERR" "invalid requested version"
# The previous (valid) pin must be untouched on this failure.
spm_true "pin lost after rejected requested" test -f "$pin"

# --- missing recipe -> error ---------------------------------------------
spm_run bash "$BIN" lock update nope
spm_eq_int "$SPM_CODE" 1
spm_contains "$SPM_ERR" "no recipe for package"

# --- a failing recipe keeps the previous pin ------------------------------
# Build a throwaway broken recipe in a temp repo (NOT in tests/fixtures, which
# is served as the "all" set). spm_lock_one is called directly so we can point
# SPM_ROOT at the temp repo.
broot=$(mktemp -dt spm-broken.XXXXXX)
mkdir -p "$broot/packages/brokenapp"
printf 'NAME=brokenapp\nDESCRIPTION=b\nHOMEPAGE=https://x.invalid\n' \
	> "$broot/packages/brokenapp/meta"
printf '#!/usr/bin/env bash\necho "simulated lock failure" >&2\nexit 1\n' \
	> "$broot/packages/brokenapp/lock.sh"
chmod +x "$broot/packages/brokenapp/lock.sh"
# Seed a previous pin for brokenapp (so a recipe failure keeps it).
jq '.package = "brokenapp"' "$pin" > "$SPM_CONFIG_DIR/locks/brokenapp.json"
before=$(sha256sum "$SPM_CONFIG_DIR/locks/brokenapp.json" | cut -d' ' -f1)
saved_root="$SPM_ROOT"
SPM_ROOT="$broot"
spm_run spm_lock_one brokenapp
spm_eq_int "$SPM_CODE" 1
spm_contains "$SPM_ERR" "keeping previous pin"
after=$(sha256sum "$SPM_CONFIG_DIR/locks/brokenapp.json" | cut -d' ' -f1)
spm_eq "$before" "$after" || spm_fail "previous pin not retained after failure"

# --- no previous pin + failing recipe -> hard failure --------------------
rm -f "$SPM_CONFIG_DIR/locks/brokenapp.json"
spm_run spm_lock_one brokenapp
spm_eq_int "$SPM_CODE" 1
spm_contains "$SPM_ERR" "no previous pin"
SPM_ROOT="$saved_root"
rm -rf "$broot"

# --- file:// pins are only valid in SPM_TEST_MODE (§6) -------------------
pin2=$(mktemp)
jq '.artifacts.x86_64.url = "file:///tmp/x.tar.gz"' "$pin" > "$pin2" || true
if SPM_TEST_MODE=1 spm_validate_pin "$pin2" helloapp; then spm_pass
else spm_fail "file:// pin should validate in test mode"; fi
if SPM_TEST_MODE=0 spm_validate_pin "$pin2" helloapp; then
	spm_fail "file:// pin must NOT validate outside test mode"
else
	spm_pass
fi
rm -f "$pin2"

# --- a malformed pin fails validation ------------------------------------
bad=$(mktemp)
printf '%s\n' '{"schema":1,"package":"helloapp"}' > "$bad"
spm_false "malformed pin should not validate" spm_validate_pin "$bad" helloapp
rm -f "$bad"

spm_end
