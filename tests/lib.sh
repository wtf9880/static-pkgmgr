# tests/lib.sh -- tiny assertion helpers for the plain-Bash test runner.
# Sourced by tests/test_*.sh. This is test infrastructure, not a package helper.
# shellcheck shell=bash

# Per-run counters (sourced once per test process).
_SPM_P=0
_SPM_F=0

spm_pass() { _SPM_P=$((_SPM_P + 1)); }
spm_fail() { _SPM_F=$((_SPM_F + 1)); printf '  FAIL: %s\n' "$*" >&2; }

# spm_eq <actual> <expected> [message]
spm_eq() {
	if [ "$1" = "$2" ]; then
		spm_pass
	else
		spm_fail "spm_eq: expected [${2}] got [${1}]${3:+: $3}"
	fi
}

# spm_eq_int <actual> <expected>
spm_eq_int() {
	if [ "$1" -eq "$2" ]; then
		spm_pass
	else
		spm_fail "spm_eq_int: expected [$2] got [$1]"
	fi
}

spm_ne() {
	if [ "$1" != "$2" ]; then spm_pass; else spm_fail "spm_ne: both [$1]"; fi
}

# spm_contains <haystack> <needle>
spm_contains() {
	case "$1" in
		*"$2"*) spm_pass ;;
		"") spm_fail "spm_contains: haystack empty, needle [$2]" ;;
		*) spm_fail "spm_contains: [$2] not found in [$1]" ;;
	esac
}

# spm_not_contains <haystack> <needle>
spm_not_contains() {
	case "$1" in
		*"$2"*) spm_fail "spm_not_contains: found [$2] in [$1]" ;;
		*) spm_pass ;;
	esac
}

# spm_match <string> <regex>  -- POSIX ERE, anchored (use ^...$ as needed)
spm_match() {
	if printf '%s' "$1" | grep -Eq "$2"; then spm_pass; else spm_fail "spm_match: [$1] !~ /$2/"; fi
}

# spm_run <command...> -- run in a subshell, capturing stdout/stderr/exit code.
# Sets SPM_OUT, SPM_ERR, SPM_CODE, which callers read (hence the SC2034
# suppression: they are intentionally not consumed within this file).
# Safe under `set -e` (uses an if-condition).
# shellcheck disable=SC2034
spm_run() {
	local _out _err
	_out=$(mktemp)
	_err=$(mktemp)
	if ( "$@" ) >"$_out" 2>"$_err"; then
		SPM_CODE=0
	else
		SPM_CODE=$?
	fi
	SPM_OUT=$(cat "$_out")
	SPM_ERR=$(cat "$_err")
	rm -f -- "$_out" "$_err"
}

# Write a config.env into a fresh temp dir, point SPM_CONFIG_DIR at it, and
# (re)load config. Restores the original SPM_CONFIG_DIR afterwards.
# Usage: spm_with_config "KEY=VALUE
# line2"
spm_with_config() {
	_SPM_CFG_PREV="${SPM_CONFIG_DIR:-}"
	SPM_CONFIG_DIR=$(mktemp -dt spm-cfg.XXXXXX)
	printf '%s\n' "$1" > "$SPM_CONFIG_DIR/config.env"
	spm_load_config
}

spm_restore_config() {
	SPM_CONFIG_DIR="$_SPM_CFG_PREV"
	spm_load_config
}

spm_end() {
	printf '  passed: %d failed: %d\n' "$_SPM_P" "$_SPM_F"
	if [ "$_SPM_F" -ne 0 ]; then
		return 1
	fi
	return 0
}

# Build an isolated throwaway SPM_ROOT whose packages/ serves tests/fixtures/
# (so the real repo's packages/ is never written to). The entrypoint is COPIED
# (not symlinked) so readlink -f inside it resolves SPM_ROOT to the temp dir.
# lib/ and helpers/ are symlinked so the real libraries are used. Exports
# SPM_ROOT=<temp> and sets SPM_TEST_BIN + SPM_TEST_ROOT (for teardown).
spm_setup_test_repo() {
	SPM_TEST_ROOT=$(mktemp -dt spm-root.XXXXXX)
	mkdir -p "$SPM_TEST_ROOT/bin"
	cp "$SPM_ROOT/bin/static-pkgmgr" "$SPM_TEST_ROOT/bin/"
	chmod +x "$SPM_TEST_ROOT/bin/static-pkgmgr"
	ln -s "$SPM_ROOT/lib" "$SPM_TEST_ROOT/lib"
	ln -s "$SPM_ROOT/helpers" "$SPM_TEST_ROOT/helpers"
	ln -s "$SPM_ROOT/tests/fixtures" "$SPM_TEST_ROOT/packages"
	export SPM_ROOT="$SPM_TEST_ROOT"
	# Intentionally read by individual test files (shellcheck SC2034).
	# shellcheck disable=SC2034
	SPM_TEST_BIN="$SPM_TEST_ROOT/bin/static-pkgmgr"
}

# spm_true <message> <command...> : pass if the command succeeds, else fail.
# (Intentional if/else avoids the shellcheck SC2015 warning that the
# `condition && spm_pass || spm_fail` idiom triggers.)
spm_true() {
	local msg="$1"
	shift
	if "$@" >/dev/null 2>&1; then spm_pass; else spm_fail "$msg"; fi
}

# spm_false <message> <command...> : pass if the command fails, else fail.
spm_false() {
	local msg="$1"
	shift
	if "$@" >/dev/null 2>&1; then spm_fail "$msg"; else spm_pass; fi
}

spm_teardown_test_repo() {
	[ -n "${SPM_TEST_ROOT:-}" ] || return 0
	rm -rf -- "$SPM_TEST_ROOT"
	SPM_TEST_ROOT=""
}

# Set up a fully isolated sandbox (own HOME / SPM_CONFIG_DIR / APPS_DIR /
# BIN_DIR from config defaults) plus a throwaway test repo whose packages/
# serves tests/fixtures/. Sources common.sh + config.sh so the helper globals
# match what the entrypoint subprocess will compute. Registers cleanup on EXIT.
# This is test infrastructure; it may write to its own temp base.
spm_setup_test_env() {
	SPM_SANDBOX=$(mktemp -dt spm-sbx.XXXXXX)
	export HOME="$SPM_SANDBOX/home"
	export SPM_CONFIG_DIR="$SPM_SANDBOX/config"
	mkdir -p "$HOME" "$SPM_CONFIG_DIR"
	. "$SPM_ROOT/lib/common.sh"
	. "$SPM_ROOT/lib/config.sh"
	mkdir -p "$APPS_DIR" "$BIN_DIR" "$SPM_CONFIG_DIR/pending" "$SPM_CONFIG_DIR/locks"
	spm_setup_test_repo
	trap spm_teardown_test_env EXIT
}

spm_teardown_test_env() {
	spm_teardown_test_repo
	if [ -n "${SPM_SANDBOX:-}" ]; then
		rm -rf -- "$SPM_SANDBOX"
		SPM_SANDBOX=""
	fi
}
