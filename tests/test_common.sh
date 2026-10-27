#!/usr/bin/env bash
# tests/test_common.sh -- tests for lib/common.sh (Phase 0: logging, arch, safe_rm)
set -Eeuo pipefail
: "${SPM_ROOT:=$(readlink -f "$(dirname "${BASH_SOURCE[0]}")/..")}"
export SPM_ROOT
. "$SPM_ROOT/tests/lib.sh"
. "$SPM_ROOT/lib/common.sh"
. "$SPM_ROOT/lib/config.sh"  # sets APPS_DIR/BIN_DIR/SPM_CONFIG_DIR defaults

# The default config points APPS_DIR/BIN_DIR at $HOME/.local/...; ensure they
# exist so the safe_rm and staging tests can create entries inside them.
mkdir -p "$APPS_DIR" "$BIN_DIR" "$SPM_CONFIG_DIR/pending"

# --- spm_arch -------------------------------------------------------------
arch=$(spm_arch)
spm_ne "$arch" ""
um=$(uname -m)
case "$um" in arm64) um=aarch64 ;; esac
spm_eq "$arch" "$um"
spm_eq "$SPM_ARCH" "$arch"

# --- spm_warn / spm_log (stderr) -------------------------------------------
spm_run spm_warn "hello"
spm_eq_int "$SPM_CODE" 0
spm_contains "$SPM_ERR" "warning: hello"
spm_eq "$SPM_OUT" ""

spm_run spm_log "info line"
spm_eq_int "$SPM_CODE" 0
spm_contains "$SPM_ERR" "info line"

# --- spm_err (stderr, no exit) --------------------------------------------
spm_run spm_err "just stderr"
spm_eq_int "$SPM_CODE" 0
spm_contains "$SPM_ERR" "just stderr"

# --- spm_die --------------------------------------------------------------
spm_run spm_die "boom" 7
spm_eq_int "$SPM_CODE" 7
spm_contains "$SPM_ERR" "error: boom"

spm_run spm_die "default code"
spm_eq_int "$SPM_CODE" 1
spm_contains "$SPM_ERR" "error: default code"

# --- spm_safe_rm: allowed removals ----------------------------------------
# Inside APPS_DIR is allowed and removed.
sub=$(mktemp -d "$APPS_DIR/.spm-safe.XXXXXX")
: > "$sub/file"
spm_run spm_safe_rm "$sub"
spm_eq_int "$SPM_CODE" 0
if [ -e "$sub" ]; then spm_fail "safe_rm did not remove $sub"; else spm_pass; fi

# Inside BIN_DIR is allowed.
bfile=$(mktemp "$BIN_DIR/.spm-b.XXXXXX")
spm_run spm_safe_rm "$bfile"
spm_eq_int "$SPM_CODE" 0

# Inside SPM_CONFIG_DIR/pending is allowed.
mkdir -p "$SPM_CONFIG_DIR/pending"
m="$SPM_CONFIG_DIR/pending/marker"
: > "$m"
spm_run spm_safe_rm "$m"
spm_eq_int "$SPM_CODE" 0
if [ -e "$m" ]; then spm_fail "pending marker not removed"; else spm_pass; fi

# .staging under APPS_DIR is allowed.
mkdir -p "$APPS_DIR/.staging"
s="$APPS_DIR/.staging/pkg"
mkdir -p "$s"
spm_run spm_safe_rm "$s"
spm_eq_int "$SPM_CODE" 0

# --- spm_safe_rm: refusals ------------------------------------------------
# Root itself is refused.
spm_run spm_safe_rm "$APPS_DIR"
spm_eq_int "$SPM_CODE" 2
spm_contains "$SPM_ERR" "refused"

# A path outside all roots (under temp HOME but not under APPS_DIR) is refused.
evil="$HOME/.spm-should-not-be-removed"
: > "$evil"
spm_run spm_safe_rm "$evil"
spm_eq_int "$SPM_CODE" 2
spm_contains "$SPM_ERR" "refused"
if [ -e "$evil" ]; then spm_pass; else spm_fail "outside path was removed!"; fi
rm -f -- "$evil"

# /etc/passwd is refused.
spm_run spm_safe_rm "/etc/passwd"
spm_eq_int "$SPM_CODE" 2

# A symlink in BIN_DIR pointing outside is refused (don't follow & delete target).
mkdir -p "$BIN_DIR"
ln -sf "/etc/passwd" "$BIN_DIR/.spm-evil-link"
spm_run spm_safe_rm "$BIN_DIR/.spm-evil-link"
spm_eq_int "$SPM_CODE" 2
# The symlink and the target must both remain.
if [ -L "$BIN_DIR/.spm-evil-link" ]; then spm_pass; else spm_fail "evil link was removed"; fi
rm -f -- "$BIN_DIR/.spm-evil-link"

# --- spm_safe_rm: empty path / nonexistent ---------------------------------
spm_run spm_safe_rm ""
spm_eq_int "$SPM_CODE" 2

spm_run spm_safe_rm "$APPS_DIR/does-not-exist-12345"
spm_eq_int "$SPM_CODE" 0

spm_end
