#!/usr/bin/env bash
# tests/test_sync.sh -- Phase 5 tests for `sync` (§15).
#
# Offline only: each baseline is a tiny throwaway git repo served via file://
# (allowed because run.sh exports SPM_TEST_MODE=1). `sync` never runs a
# recipe -- it consults only packages/<pkg>/meta. Fixtures ship meta for
# helloapp and brokenapp; nodejs/ripgrep are deliberately absent from the
# fixtures so the "no recipe -> skip" path is exercised.
set -Eeuo pipefail
: "${SPM_ROOT:=$(readlink -f "$(dirname "${BASH_SOURCE[0]}")/..")}"
export SPM_ROOT
. "$SPM_ROOT/tests/lib.sh"

spm_setup_test_env

# 64 hex 'a's: a valid §6 sha256. "invalid" -> a too-short bogus sha that
# fails spm_validate_pin's ^[0-9a-f]{64}$ check.
SHA64="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

# --- fixture helpers ---------------------------------------------------------

# bl_pin <repodir> <pkg> <ver> <sha|invalid> -- write a schema-1 baseline pin
# at locks/<pkg>.json. The pin's artifact URL is https://... (never fetched),
# so no archive fixture or fake curl is needed (sync never downloads). (§15)
bl_pin() {
	local r="$1" pkg="$2" ver="$3" sha="$4"
	if [ "$sha" = "invalid" ]; then sha="deadbeef"; fi
	mkdir -p "$r/locks"
	jq -n --arg pkg "$pkg" --arg ver "$ver" --arg sha "$sha" '{
		schema: 1,
		package: $pkg,
		version: $ver,
		requested: null,
		resolved_at: "2024-01-01T00:00:00Z",
		artifacts: {
			x86_64: {
				url: ("https://example.com/" + $pkg + "-" + $ver + ".tar.gz"),
				sha256: $sha,
				size: 100
			}
		}
	}' > "$r/locks/$pkg.json"
}

# new_baseline <repodir> <pkg:ver:sha>... -- git-init a `main` branch, write
# each pin, and commit them as the baseline's first commit.
new_baseline() {
	local r="$1"; shift
	[ -d "$r" ] || mkdir -p "$r"
	git init -q -b main "$r"
	git -C "$r" config user.email "spm-test@example.com"
	git -C "$r" config user.name "spm-test"
	local spec pkg ver sha
	for spec in "$@"; do
		pkg="${spec%%:*}"; spec="${spec#*:}"
		ver="${spec%%:*}"; sha="${spec#*:}"
		bl_pin "$r" "$pkg" "$ver" "$sha"
	done
	git -C "$r" add -A
	git -C "$r" commit -qm "baseline"
}

# bl_commit <repodir> -- commit any pending changes (for refresh tests).
bl_commit() {
	local r="$1"
	git -C "$r" add -A
	git -C "$r" commit -qm "update" || true
}

# Read the version of a local pin, or "" if absent/invalid (safe under set -e).
pin_ver() { jq -r '.version // empty' "$SPM_CONFIG_DIR/locks/$1.json" 2>/dev/null || printf ''; }

# --- (A) BASELINE_REPO unset -> rc1 "not set" (Phase 5 is opt-in) -----------
spm_run bash "$SPM_TEST_BIN" sync
spm_eq_int "$SPM_CODE" 1
spm_contains "$SPM_ERR" "BASELINE_REPO"
spm_contains "$SPM_ERR" "not set"

# --- (B) sync all: write the valid pin, skip the invalid + no-recipe one -----
{
	repodir=$(mktemp -dt sync-repo.XXXXXX)
	new_baseline "$repodir" \
		"helloapp:1.0.0:$SHA64" "brokenapp:0.1.0:invalid" "nodejs:20.0.0:$SHA64"
	spm_with_config "BASELINE_REPO=file://$repodir"
	spm_run bash "$SPM_TEST_BIN" sync
	spm_eq_int "$SPM_CODE" 1                       # brokenapp pin invalid -> rc1
	if [ -f "$SPM_CONFIG_DIR/locks/helloapp.json" ]; then
		spm_pass
		spm_eq "$(pin_ver helloapp)" "1.0.0"
	else
		spm_fail "sync B: helloapp pin not written"
	fi
	if [ -f "$SPM_CONFIG_DIR/locks/brokenapp.json" ]; then
		spm_fail "sync B: brokenapp pin written"
	else
		spm_pass
	fi
	if [ -f "$SPM_CONFIG_DIR/locks/nodejs.json" ]; then
		spm_fail "sync B: nodejs pin written"
	else
		spm_pass
	fi
	spm_contains "$SPM_ERR" "brokenapp"
	spm_contains "$SPM_ERR" "nodejs"
}

# --- (C) re-sync: existing pin skipped, helloapp unchanged ------------------
{
	repodir=$(mktemp -dt sync-repo.XXXXXX)
	new_baseline "$repodir" \
		"helloapp:1.0.0:$SHA64" "brokenapp:0.1.0:invalid" "nodejs:20.0.0:$SHA64"
	spm_with_config "BASELINE_REPO=file://$repodir"
	spm_run bash "$SPM_TEST_BIN" sync              # first sync: writes helloapp
	spm_run bash "$SPM_TEST_BIN" sync              # re-sync
	spm_eq_int "$SPM_CODE" 1                        # brokenapp still invalid
	spm_eq "$(pin_ver helloapp)" "1.0.0"           # unchanged
}

# --- (D) sync helloapp (already pinned) -> rc0 "already exists" ------------
{
	repodir=$(mktemp -dt sync-repo.XXXXXX)
	new_baseline "$repodir" \
		"helloapp:1.0.0:$SHA64" "brokenapp:0.1.0:invalid" "nodejs:20.0.0:$SHA64"
	spm_with_config "BASELINE_REPO=file://$repodir"
	spm_run bash "$SPM_TEST_BIN" sync               # first sync writes helloapp
	spm_run bash "$SPM_TEST_BIN" sync helloapp     # already pinned
	spm_eq_int "$SPM_CODE" 0
	spm_contains "$SPM_ERR" "already exists"
}

# --- (E) sync nodejs (no recipe) -> rc0, no pin -----------------------------
{
	repodir=$(mktemp -dt sync-repo.XXXXXX)
	new_baseline "$repodir" "nodejs:20.0.0:$SHA64" "helloapp:1.0.0:$SHA64"
	spm_with_config "BASELINE_REPO=file://$repodir"
	spm_run bash "$SPM_TEST_BIN" sync nodejs
	spm_eq_int "$SPM_CODE" 0
	spm_contains "$SPM_ERR" "no recipe"
	if [ -f "$SPM_CONFIG_DIR/locks/nodejs.json" ]; then
		spm_fail "sync E: nodejs pin written"
	else
		spm_pass
	fi
}

# --- (F) sync ghostpkg (not in baseline) -> rc1 "unknown package" -----------
{
	repodir=$(mktemp -dt sync-repo.XXXXXX)
	new_baseline "$repodir" "helloapp:1.0.0:$SHA64"
	spm_with_config "BASELINE_REPO=file://$repodir"
	spm_run bash "$SPM_TEST_BIN" sync ghostpkg
	spm_eq_int "$SPM_CODE" 1
	spm_contains "$SPM_ERR" "unknown package"
	spm_contains "$SPM_ERR" "ghostpkg"
}

# --- (G) -n sync: fetch, print plan, write nothing -------------------------
{
	repodir=$(mktemp -dt sync-repo.XXXXXX)
	new_baseline "$repodir" "helloapp:1.0.0:$SHA64"
	spm_with_config "BASELINE_REPO=file://$repodir"
	rm -f "$SPM_CONFIG_DIR/locks/helloapp.json"
	spm_run bash "$SPM_TEST_BIN" -n sync
	spm_eq_int "$SPM_CODE" 0
	spm_contains "$SPM_ERR" "would write"
	if [ -f "$SPM_CONFIG_DIR/locks/helloapp.json" ]; then
		spm_fail "sync G: pin written despite dry-run"
	else
		spm_pass
	fi
}

# --- (H) refresh: v1 -> commit2 v2 -> sync picks up v2 ----------------------
{
	repodir=$(mktemp -dt sync-repo.XXXXXX)
	new_baseline "$repodir" "helloapp:1.0.0:$SHA64"
	spm_with_config "BASELINE_REPO=file://$repodir"
	spm_run bash "$SPM_TEST_BIN" sync
	spm_eq_int "$SPM_CODE" 0
	spm_eq "$(pin_ver helloapp)" "1.0.0"
	rm -f "$SPM_CONFIG_DIR/locks/helloapp.json"
	bl_pin "$repodir" helloapp "2.0.0" "$SHA64"
	bl_commit "$repodir"
	spm_run bash "$SPM_TEST_BIN" sync              # refresh -> v2
	spm_eq_int "$SPM_CODE" 0
	spm_eq "$(pin_ver helloapp)" "2.0.0"
}

# --- (I) invalid BASELINE_REPO -> config rc1 "must be a git URL" -----------
# Written directly to config.env (not via spm_with_config) so the invalid
# value is validated in the bin subprocess, not in this test process.
{
	badcfg=$(mktemp -dt sync-badcfg.XXXXXX)
	printf 'BASELINE_REPO=not-a-url\n' > "$badcfg/config.env"
	spm_run env SPM_CONFIG_DIR="$badcfg" bash "$SPM_TEST_BIN" sync
	spm_eq_int "$SPM_CODE" 1
	spm_contains "$SPM_ERR" "must be a git URL"
}

# --- (J) nonexistent file:// repo -> rc1 "failed to clone" -----------------
{
	spm_with_config "BASELINE_REPO=file:///nonexistent/repo"
	spm_run bash "$SPM_TEST_BIN" sync
	spm_eq_int "$SPM_CODE" 1
	spm_contains "$SPM_ERR" "failed to clone"
}

spm_end
