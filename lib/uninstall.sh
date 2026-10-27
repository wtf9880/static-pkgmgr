# lib/uninstall.sh -- uninstall command (§7.4, §9, §10).
#
# Sourced by the entrypoint; defines functions only.
# shellcheck shell=bash

# uninstall <pkg>... -- §12.
spm_cmd_uninstall() {
	[ $# -gt 0 ] || { spm_err "usage: static-pkgmgr uninstall <pkg>..."; exit 2; }
	local pkg
	for pkg in "$@"; do
		spm_uninstall_one "$pkg"
	done
}

spm_uninstall_one() {
	local pkg="$1"
	[[ "$pkg" =~ ^[a-z0-9][a-z0-9._-]*$ ]] \
		|| spm_die "uninstall: invalid package name: $pkg" 1

	local recipe="$SPM_ROOT/packages/$pkg"
	local pkgdir="$APPS_DIR/$pkg"

	# §9.3: error if not installed.
	if [ ! -e "$pkgdir" ] && [ ! -L "$pkgdir" ]; then
		spm_die "uninstall: $pkg is not installed" 1
	fi

	# §12: --dry-run prints the plan and changes nothing.
	if [ "$SPM_DRY_RUN" = 1 ]; then
		spm_log "uninstall: would remove $pkg"
		return 0
	fi

	# §10.3: recover from a crashed previous uninstall attempt.
	spm_recovery "$pkg"

	# §10.2: write the pending marker before any change under $APPS_DIR/$BIN_DIR.
	spm_write_marker "$pkg" uninstall ""
	spm_txn_track "" ""   # uninstall has no staging tree / link plan of its own.

	# §7.4: run uninstall.sh if present (while SPM_FINAL_DIR still exists).
	# Ignore failures -- this hook is for external cleanup only.
	if [ -f "$recipe/uninstall.sh" ]; then
		if ! SPM_PKG="$pkg" SPM_FINAL_DIR="$pkgdir" SPM_BIN_DIR="$BIN_DIR" \
			bash "$recipe/uninstall.sh"; then
			spm_warn "uninstall: recipe uninstall.sh failed for $pkg (ignored)"
		fi
	fi

	# §9 / §10 recovery: remove links (from .spm/links, fallback scan included).
	spm_remove_links "$pkg" "$pkgdir"

	# §7.4 / §10: remove the app directory.
	if ! spm_safe_rm "$pkgdir"; then
		# §10.10: cleanup-on-failure drops the marker; re-run retries.
		spm_cleanup_failed
		spm_die "uninstall: could not remove $pkg" 1
	fi

	# §10.2: success -- clear the pending marker.
	spm_txn_done "$pkg"
	spm_log "uninstall: $pkg removed"
}
