#!/usr/bin/env bash
# tests/test_entrypoint.sh -- tests for bin/static-pkgmgr global parsing and
# subcommand dispatch. Phase 0 (pure parsing) + Phase 1 (real dispatch).
set -Eeuo pipefail
: "${SPM_ROOT:=$(readlink -f "$(dirname "${BASH_SOURCE[0]}")/..")}"
export SPM_ROOT
. "$SPM_ROOT/tests/lib.sh"

BIN="$SPM_ROOT/bin/static-pkgmgr"

# --- version ---------------------------------------------------------------
spm_run bash "$BIN" -V
spm_eq_int "$SPM_CODE" 0
spm_contains "$SPM_OUT" "static-pkgmgr"

spm_run bash "$BIN" --version
spm_eq_int "$SPM_CODE" 0

# --- help ------------------------------------------------------------------
spm_run bash "$BIN" -h
spm_eq_int "$SPM_CODE" 0
spm_contains "$SPM_OUT" "usage"

spm_run bash "$BIN" --help
spm_eq_int "$SPM_CODE" 0
spm_contains "$SPM_OUT" "install"

# --- no command -> usage error --------------------------------------------
spm_run bash "$BIN"
spm_eq_int "$SPM_CODE" 2
spm_contains "$SPM_ERR" "no command"

# --- unknown option -> usage error ---------------------------------------
spm_run bash "$BIN" --bogus-command
spm_eq_int "$SPM_CODE" 2

# --- unknown subcommand -> error -----------------------------------------
spm_run bash "$BIN" frobnicate
spm_eq_int "$SPM_CODE" 2
spm_contains "$SPM_ERR" "unknown command"

# --- Phase 1: real commands require their arguments (usage error) ----------
spm_run bash "$BIN" install
spm_eq_int "$SPM_CODE" 2
spm_run bash "$BIN" uninstall
spm_eq_int "$SPM_CODE" 2
spm_run bash "$BIN" lock
spm_eq_int "$SPM_CODE" 2
spm_contains "$SPM_ERR" "usage"

# --- Phase 1: real commands dispatch (against the bare repo: no recipes) -
# These confirm install/lock/uninstall reach their handlers rather than the
# skeleton "not implemented" path.
spm_run bash "$BIN" install frobnicate
spm_eq_int "$SPM_CODE" 1
spm_contains "$SPM_ERR" "no recipe for package"

spm_run bash "$BIN" lock update frobnicate
spm_eq_int "$SPM_CODE" 1
spm_contains "$SPM_ERR" "no recipe for package"

spm_run bash "$BIN" uninstall frobnicate
spm_eq_int "$SPM_CODE" 1
spm_contains "$SPM_ERR" "is not installed"

# --- still-unimplemented subcommands (Phase 3) exit 1 ----------------------
for cmd in upgrade list sync; do
	spm_run bash "$BIN" "$cmd"
	spm_eq_int "$SPM_CODE" 1
	spm_contains "$SPM_ERR" "not implemented"
done

# lock show is Phase 3.
spm_run bash "$BIN" lock show
spm_eq_int "$SPM_CODE" 1
spm_contains "$SPM_ERR" "not implemented"

# --- global flags are accepted (parsed) before the subcommand --------------
# -n/--dry-run are parsed as globals; the subcommand then runs (Phase 1 does
# not yet act on --dry-run, so install still tries and errors on no recipe).
spm_run bash "$BIN" -n install frobnicate
spm_eq_int "$SPM_CODE" 1
spm_run bash "$BIN" --dry-run install frobnicate
spm_eq_int "$SPM_CODE" 1
spm_run bash "$BIN" --safe-upgrade install frobnicate
spm_eq_int "$SPM_CODE" 1
spm_run bash "$BIN" --no-safe-upgrade install frobnicate
spm_eq_int "$SPM_CODE" 1

# --- subcommand args are not parsed as globals (+ prefix stops at 1st non-option)
spm_run bash "$BIN" install --dry-run pkgname
spm_eq_int "$SPM_CODE" 1   # '--dry-run' reaches the subcommand as an arg

spm_end
