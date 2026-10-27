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

	# §9.3 / §10: error if not installed.
	if [ ! -e "$pkgdir" ] && [ ! -L "$pkgdir" ]; then
		spm_die "uninstall: $pkg is not installed" 1
	fi

	# §7.4: if the recipe has uninstall.sh, run it first (while SPM_FINAL_DIR
	# still exists). Ignore failures.
	if [ -f "$recipe/uninstall.sh" ]; then
		if ! SPM_PKG="$pkg" SPM_FINAL_DIR="$pkgdir" SPM_BIN_DIR="$BIN_DIR" \
			bash "$recipe/uninstall.sh"; then
			spm_warn "uninstall: recipe uninstall.sh failed for $pkg (ignored)"
		fi
	fi

	# §9 / §10 recovery: remove links (from .spm/links, fallback scan included).
	spm_remove_links "$pkg" "$pkgdir"

	# §7.4 / §10: remove the app directory.
	spm_safe_rm "$pkgdir"
	spm_log "uninstall: $pkg removed"
}
