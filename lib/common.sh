# lib/common.sh -- common helpers.
#
# This file is sourced, never executed directly. It must not alter the
# caller's shell options (see AGENTS.md: "Sourced files in lib/ and helpers/
# must not change shell options").
# shellcheck shell=bash

# --- logging ---------------------------------------------------------------

# Log an informational line. Diagnostics go to stderr; the log file
# ($SPM_LOG, if set and writable) gets a copy.
spm_log() {
	printf '%s\n' "$*" >&2
	if [ -n "${SPM_LOG:-}" ]; then
		printf '%s\n' "$*" >>"$SPM_LOG" 2>/dev/null || true
	fi
}

# Log a warning line.
spm_warn() {
	printf 'warning: %s\n' "$*" >&2
}

# Log an error line (no exit).
spm_err() {
	printf '%s\n' "$*" >&2
}

# Print an error and exit. Usage: spm_die "message" [code]
spm_die() {
	local msg="$1"
	local code="${2-1}"
	printf 'error: %s\n' "$msg" >&2
	exit "$code"
}

# --- architecture ----------------------------------------------------------

# Print the normalized architecture name (arm64 -> aarch64).
spm_arch() {
	local m
	m=$(uname -m)
	case "$m" in
		arm64) printf 'aarch64\n' ;;
		*) printf '%s\n' "$m" ;;
	esac
}

# Cache the current architecture once, exporting it for subprocesses.
: "${SPM_ARCH:=$(spm_arch)}"
export SPM_ARCH

# --- safe removal ----------------------------------------------------------

# Remove a path only if its real location is strictly inside one of the
# allowed roots: $APPS_DIR, $BIN_DIR, $SPM_CONFIG_DIR/pending, or
# $SPM_CONFIG_DIR/baseline (Phase 5, for stale baseline cleanup).
# Refuses anything else (and refuses the roots themselves) per §14/D6.
#
# The target path is removed as given (so a symlink is unlinked, not its
# target), but the safety check uses the resolved real path so a symlink that
# points outside the allowed roots is refused.
spm_safe_rm() {
	local target="$1"
	[ -n "$target" ] || spm_die "spm_safe_rm: empty path" 2

	# A non-existent path (not even a dangling symlink) is a no-op, so cleanup
	# code can call this on paths that may already be gone.
	if [ ! -e "$target" ] && [ ! -L "$target" ]; then
		spm_warn "spm_safe_rm: path does not exist: $target"
		return 0
	fi

	# Resolve to a canonical absolute path (following symlinks) for the safety
	# check, so a symlink that points outside the allowed roots is refused.
	local real
	real=$(readlink -f -- "$target") || spm_die "spm_safe_rm: cannot resolve: $target" 2

	local allowed=0 r rreal i
	local -a roots=()
	[ -n "${APPS_DIR:-}" ] && roots+=("$APPS_DIR")
	[ -n "${BIN_DIR:-}" ] && roots+=("$BIN_DIR")
	[ -n "${SPM_CONFIG_DIR:-}" ] && roots+=("$SPM_CONFIG_DIR/pending" "$SPM_CONFIG_DIR/baseline")

	for ((i = 0; i < ${#roots[@]}; i++)); do
		r="${roots[$i]}"
		rreal=$(readlink -f -- "$r" 2>/dev/null) || continue
		[ -n "$rreal" ] || continue
		# strictly inside rreal: equal to root? no. starts with root + "/" ?
		if [ "$real" != "$rreal" ] && [ "${real#"$rreal"/}" != "$real" ]; then
			allowed=1
			break
		fi
	done

	if [ "$allowed" -ne 1 ]; then
		spm_die "spm_safe_rm: refused (outside allowed roots): $target" 2
	fi

	rm -rf -- "$target"
}
