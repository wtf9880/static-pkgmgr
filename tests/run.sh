#!/usr/bin/env bash
# tests/run.sh -- plain Bash test runner (§D11: no bats).
#
# Creates an isolated sandbox (temporary HOME, SPM_CONFIG_DIR, APPS_DIR,
# BIN_DIR) so tests never touch the real $HOME, then runs each
# tests/test_*.sh in turn and reports pass/fail.
set -Eeuo pipefail

: "${SPM_ROOT:=$(readlink -f "$(dirname "${BASH_SOURCE[0]}")/..")}"
export SPM_ROOT

# SPM_TEST_MODE=1 allows file:// fixtures (§6/§14) for the install tests.
export SPM_TEST_MODE=1
# Do not inherit the host's XDG layout.
unset XDG_CONFIG_HOME 2>/dev/null || true

# One temporary base holds every sandbox directory we create, so cleanup is a
# single guarded rm -rf of a directory we made ourselves.
SPM_TEST_BASE=$(mktemp -dt spm-run.XXXXXX)
TEST_HOME="$SPM_TEST_BASE/home"
SPM_CONFIG_DIR="$SPM_TEST_BASE/config"
APPS_DIR="$SPM_TEST_BASE/apps"
BIN_DIR="$SPM_TEST_BASE/bin"
mkdir -p "$TEST_HOME" "$SPM_CONFIG_DIR" "$APPS_DIR" "$BIN_DIR"
export HOME="$TEST_HOME" SPM_CONFIG_DIR APPS_DIR BIN_DIR

cleanup() {
	# Remove only the exact temp base we created (test-harness housekeeping;
	# it lives outside the app roots, where spm_safe_rm must refuse it).
	local base="$SPM_TEST_BASE"
	case "$base" in
		"${TMPDIR:-/tmp}"/*) rm -rf -- "$base" ;;
	esac
}
trap cleanup EXIT

# Make the entrypoint runnable as `static-pkgmgr` for end-to-end checks.
export PATH="$SPM_ROOT/bin:$PATH"

pass=0
fail=0
shopt -s nullglob
for tf in "$SPM_ROOT"/tests/test_*.sh; do
	name=$(basename "$tf")
	if bash "$tf"; then
		printf 'PASS %s\n' "$name"
		pass=$((pass + 1))
	else
		printf 'FAIL %s\n' "$name"
		fail=$((fail + 1))
	fi
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
