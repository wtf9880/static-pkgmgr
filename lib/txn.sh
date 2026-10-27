# lib/txn.sh -- transactions: global flock, pending markers, recovery,
# and cleanup on failure / signals. (§10, §14 exit code 3, Phase 2)
#
# Sourced by the entrypoint; defines functions only. Must not alter the
# caller's shell options (see AGENTS.md). The entrypoint (which runs under
# `set -Eeuo pipefail`) installs the traps; this file only provides the
# primitives and trap handlers.
# shellcheck shell=bash

# Globals describing the in-progress per-package operation. These are read by
# the ERR/INT/TERM trap handlers (spm_on_err, spm_cleanup_failed). They are
# manipulated only through spm_write_marker / spm_txn_track / spm_txn_done so
# that shellcheck (which analyzes this file in isolation) sees both the
# assignments and the reads and does not flag SC2034.
spm_txn_pkg=""
spm_txn_stage=""
spm_txn_plan=""
spm_cleanup_running=0   # re-entrancy guard for the cleanup path.

# --- global mutex ----------------------------------------------------------

# Take the global mutex on $SPM_CONFIG_DIR/spm.flock with flock -n. If it is
# busy, exit 3 with a clear message. (§10.1, §12 exit code 3)
spm_acquire_lock() {
	local f="$SPM_CONFIG_DIR/spm.flock"
	# Open fd 9 on the lock file. Do NOT redirect fd 2 here: `exec` with no
	# command applies redirections persistently to the shell, which would
	# silence stderr for every later spm_log/spm_die.
	exec 9>"$f" || spm_die "txn: cannot open lock file: $f" 1
	if ! flock -n 9; then
		exec 9>&- || true
		spm_die "another static-pkgmgr operation is running" 3
	fi
}

# Release the global mutex.
spm_release_lock() {
	exec 9>&- || true
}

# --- staging sweep ---------------------------------------------------------

# Remove leftover .staging/* entries. Called at the start of every mutating
# command, while the global mutex is held. (§10.8)
spm_cleanup_staging() {
	[ -d "$APPS_DIR/.staging" ] || return 0
	local s
	while IFS= read -r -d '' s; do
		[ -n "$s" ] || continue
		if ! spm_safe_rm "$s" 2>/dev/null; then
			spm_warn "txn: could not remove leftover staging entry: $s"
		fi
	done < <(find "$APPS_DIR/.staging" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
	return 0
}

# --- pending marker --------------------------------------------------------

# Pending-marker file path for <pkg>. (§4.1, §10.2)
spm_marker_file() {
	printf '%s/pending/%s\n' "$SPM_CONFIG_DIR" "$1"
}

# Write pending/<pkg> atomically with op=, mode=, started=. (§10.2)
#   $1 = package, $2 = op (install/uninstall/upgrade), $3 = mode (inplace/safe/empty)
# Also begins tracking this package for cleanup-on-failure.
spm_write_marker() {
	local pkg="$1" op="$2" mode="${3-}" ts tmp
	mkdir -p "$SPM_CONFIG_DIR/pending"
	ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	tmp=$(mktemp "$SPM_CONFIG_DIR/pending/.marker.XXXXXX")
	{
		printf 'op=%s\n' "$op"
		printf 'mode=%s\n' "$mode"
		printf 'started=%s\n' "$ts"
	} >"$tmp"
	mv -f "$tmp" "$(spm_marker_file "$pkg")"
	spm_txn_pkg="$pkg"
}

# Remove the pending marker for <pkg>.
spm_remove_marker() {
	rm -f "$(spm_marker_file "$1")"
}

# Record the staging tree and link plan for an in-progress operation so the
# trap handlers can clean them up. (§10.10)
spm_txn_track() {
	spm_txn_stage="$1"
	spm_txn_plan="$2"
}

# Clear the in-progress transaction state and drop the marker. Call only on
# the success path (after $APPS_DIR / links are fully consistent).
spm_txn_done() {
	local pkg="$1"
	spm_remove_marker "$pkg" 2>/dev/null || true
	spm_txn_pkg=""
	spm_txn_stage=""
	spm_txn_plan=""
}

# --- recovery --------------------------------------------------------------

# If a pending marker for <pkg> exists, recover from the previous (crashed)
# operation. (§10.3) Returns 0 either way (a missing marker means nothing to
# recover). The caller then proceeds with a fresh operation.
spm_recovery() {
	local pkg="$1"
	local marker; marker=$(spm_marker_file "$pkg")
	[ -f "$marker" ] || return 0
	spm_warn "txn: recovering from a previous crash for $pkg"
	local recipe="$SPM_ROOT/packages/$pkg"
	local pkgdir="$APPS_DIR/$pkg"

	# 1. Run uninstall.sh if present, ignoring its failure.
	if [ -f "$recipe/uninstall.sh" ]; then
		SPM_PKG="$pkg" SPM_FINAL_DIR="$pkgdir" SPM_BIN_DIR="$BIN_DIR" \
			bash "$recipe/uninstall.sh" 2>/dev/null || true
	fi

	# 2. Remove links: from .spm/links, plus the fallback scan.
	spm_remove_links "$pkg" "$pkgdir" 2>/dev/null || true

	# 3. Remove the app dir and any staging trees for this package.
	spm_safe_rm "$pkgdir" 2>/dev/null || true
	spm_safe_rm "$APPS_DIR/.staging/$pkg" 2>/dev/null || true
	spm_safe_rm "$APPS_DIR/.staging/$pkg.old" 2>/dev/null || true

	# 4. Remove the marker.
	spm_remove_marker "$pkg"
}

# --- cleanup on failure ----------------------------------------------------

# Remove the staging tree and any links the core created for the in-progress
# package, then drop the marker. If any step fails, the marker is left in
# place so the next run recovers. (§10.10)
# Uses the spm_txn_* globals populated by spm_write_marker / spm_txn_track.
spm_cleanup_failed() {
	# Guard against re-entry from nested traps.
	[ "$spm_cleanup_running" = 1 ] && return 0
	spm_cleanup_running=1
	local pkg="$spm_txn_pkg" stage="$spm_txn_stage" plan="$spm_txn_plan"
	local ok=1 name linkpath target

	if [ -n "$pkg" ]; then
		# Remove links the core created from the plan (only symlinks that still
		# point into this package's install dir).
		if [ -n "$plan" ] && [ -f "$plan" ]; then
			while IFS=$'\t' read -r name linkpath || [ -n "$name" ]; do
				[ -z "$name" ] && continue
				linkpath="$BIN_DIR/$name"
				if [ -L "$linkpath" ]; then
					target=$(readlink -f "$linkpath" 2>/dev/null || true)
					case "$target" in
						"$APPS_DIR/$pkg"/*) rm -f -- "$linkpath" || ok=0 ;;
					esac
				fi
			done < "$plan"
		fi
		# Remove the staged tree.
		if [ -n "$stage" ] && [ -e "$stage" ]; then
			if ! spm_safe_rm "$stage" 2>/dev/null; then
				spm_warn "txn: could not remove staging tree: $stage"
				ok=0
			fi
		fi
		# Drop the marker only if cleanup fully succeeded; otherwise leave it
		# so the next run recovers. (§10.10)
		if [ "$ok" = 1 ]; then
			spm_remove_marker "$pkg" 2>/dev/null || true
		fi
	fi
	spm_cleanup_running=0
	return 0
}

# --- trap handlers ---------------------------------------------------------

# ERR trap handler. Runs inside functions (set -E). Cleans up the current
# package and lets set -e propagate the original exit code.
spm_on_err() {
	local rc=$?
	[ "$spm_cleanup_running" = 1 ] && return 0
	if [ -n "${spm_txn_pkg:-}" ]; then
		spm_warn "txn: aborting $spm_txn_pkg (exit $rc); cleaning up"
		spm_cleanup_failed
	fi
	return 0
}

# INT/TERM handler: run cleanup, release the lock, exit with 128+sig. (§10.12)
spm_on_signal() {
	local sig=$1
	spm_warn "txn: interrupted by signal $sig; cleaning up"
	spm_cleanup_failed
	spm_release_lock
	exit $((128 + sig))
}

# --- txn lifecycle ---------------------------------------------------------

# Acquire the lock, sweep leftover staging, and install traps. Call at the
# start of every mutating command (lock/update, install, uninstall, upgrade).
spm_begin_txn() {
	mkdir -p "$SPM_CONFIG_DIR/pending" "$APPS_DIR/.staging"
	spm_acquire_lock || return $?
	# §10.8: leftover .staging/* is deleted now that we hold the lock.
	spm_cleanup_staging
	trap 'spm_on_signal 2' INT
	trap 'spm_on_signal 15' TERM
	trap spm_on_err ERR
}

# Tear down the lock and restore default traps. Call on the success path.
spm_end_txn() {
	trap - INT TERM ERR
	spm_txn_pkg=""
	spm_txn_stage=""
	spm_txn_plan=""
	spm_release_lock
}
