# lib/manifest.sh -- .spm/ read/write and link checks (§3, §9, §10).
#
# Sourced by the entrypoint; must not alter shell options.
# shellcheck shell=bash

# --- atomic writes ---------------------------------------------------------

# Atomically write <srcfile> to <dest>: copy into a temp file in the same
# directory, then mv -f. (§6: pins and .spm/ files written atomically.)
spm_atomic_write_file() {
	local dest="$1" src="$2"
	local dir; dir=$(dirname "$dest")
	mkdir -p "$dir"
	local tmp; tmp=$(mktemp "$dir/.tmp.XXXXXX")
	cp -f "$src" "$tmp"
	mv -f "$tmp" "$dest"
}

# Atomically write stdin to <dest> via a temp file in the same directory.
spm_atomic_write() {
	local dest="$1"
	local dir; dir=$(dirname "$dest")
	mkdir -p "$dir"
	local tmp; tmp=$(mktemp "$dir/.tmp.XXXXXX")
	cat > "$tmp"
	mv -f "$tmp" "$dest"
}

# --- .spm read/write -------------------------------------------------------

# Copy the pin (<pinfile>) into <pkgdir>/.spm/lock.json atomically.
spm_write_app_lock() {
	local pkgdir="$1" pinfile="$2"
	spm_atomic_write_file "$pkgdir/.spm/lock.json" "$pinfile"
}

# Write <pkgdir>/.spm/links (absolute link paths, one per line) from stdin.
spm_write_app_links() {
	local pkgdir="$1"
	spm_atomic_write "$pkgdir/.spm/links"
}

# Print the absolute link paths for <pkg>: from .spm/links if present, else a
# fallback scan of $BIN_DIR for symlinks into $APPS_DIR/<pkg>/ (§9).
spm_read_links() {
	local pkg="$1"
	local pkgdir="$APPS_DIR/$pkg"
	local f="$pkgdir/.spm/links"
	if [ -f "$f" ]; then
		cat "$f"
		return 0
	fi
	# Fallback scan.
	local l tgt
	while IFS= read -r -d '' l; do
		if tgt=$(readlink -f "$l" 2>/dev/null); then
			case "$tgt" in "$pkgdir"/*) printf '%s\n' "$l" ;; esac
		fi
	done < <(find "$BIN_DIR" -maxdepth 1 -type l -print0 2>/dev/null)
}

# --- link creation ---------------------------------------------------------

# Check whether a link slot is creatable: empty, or an existing symlink that
# already points into $APPS_DIR. Returns 0 (ok) or 1 (conflict). (§9)
spm_link_acceptable() {
	local linkpath="$1"
	if [ -e "$linkpath" ] || [ -L "$linkpath" ]; then
		[ -L "$linkpath" ] || return 1
		local tgt; tgt=$(readlink -f "$linkpath" 2>/dev/null) || return 1
		case "$tgt" in "$APPS_DIR"/*) return 0 ;; esac
		return 1
	fi
	return 0
}

# Validate every link in the plan (conflict check). Returns 1 on conflict.
# Plan lines: <link_name>\t<path_in_app>.
spm_check_link_plan() {
	local plan="$1" link_name path_in_app
	[ -f "$plan" ] || return 0
	while IFS=$'\t' read -r link_name path_in_app || [ -n "$link_name" ]; do
		[ -z "$link_name" ] && continue
		spm_link_acceptable "$BIN_DIR/$link_name" || return 1
	done < "$plan"
	return 0
}

# Create symlinks from the plan into <pkgdir>. Prints the absolute link paths
# created (one per line) on stdout. (§9, §11.1 step 4-5)
spm_create_links() {
	local pkgdir="$1" plan="$2"
	local link_name path_in_app target linkpath
	local created=""
	[ -f "$plan" ] || { printf '%s' "$created"; return 0; }
	while IFS=$'\t' read -r link_name path_in_app || [ -n "$link_name" ]; do
		[ -z "$link_name" ] && continue
		target="$pkgdir/$path_in_app"
		linkpath="$BIN_DIR/$link_name"
		ln -sfn "$target" "$linkpath"
		created+="${linkpath}"$'\n'
	done < "$plan"
	printf '%s' "$created"
}

# Remove links for <pkg>: those listed in .spm/links, plus a fallback scan of
# $BIN_DIR for symlinks into $APPS_DIR/<pkg>/ (§9, §10 recovery).
spm_remove_links() {
	local pkg="$1"
	local pkgdir="$APPS_DIR/$pkg"
	local link_path
	local f="$pkgdir/.spm/links"
	if [ -f "$f" ]; then
		while IFS= read -r link_path || [ -n "$link_path" ]; do
			[ -z "$link_path" ] && continue
			if [ -e "$link_path" ] || [ -L "$link_path" ]; then
				rm -f -- "$link_path"
			fi
		done < "$f"
	fi
	# Fallback scan (covers the case where .spm/links is missing).
	local l tgt
	while IFS= read -r -d '' l; do
		if tgt=$(readlink -f "$l" 2>/dev/null); then
			case "$tgt" in "$pkgdir"/*) rm -f -- "$l" ;; esac
		fi
	done < <(find "$BIN_DIR" -maxdepth 1 -type l -print0 2>/dev/null)
}

# Return 0 if the installed copy of <pkg> matches the desired pin <pinfile>:
# both the version string and the per-architecture sha256 must be equal. A
# missing app dir or .spm/lock.json, or a missing pin, is "not matching" (1).
# (§12 upgrade comparison, reused by `lock show`.)
spm_installed_matches_pin() {
	local pkg="$1" pin="$2"
	[ -f "$pin" ] || return 1
	local pkgdir="$APPS_DIR/$pkg"
	local inst="$pkgdir/.spm/lock.json"
	[ -f "$inst" ] || return 1
	local iv dv isha dsha
	iv=$(jq -r '.version' "$inst")
	dv=$(jq -r '.version' "$pin")
	[ "$iv" = "$dv" ] || return 1
	isha=$(jq -r --arg a "$SPM_ARCH" '.artifacts[$a].sha256 // ""' "$inst")
	dsha=$(jq -r --arg a "$SPM_ARCH" '.artifacts[$a].sha256 // ""' "$pin")
	[ "$isha" = "$dsha" ]
}

# list -- §12. Read-only: prints installed packages as
# "<name>\t<version>\t<path>". (§9 installed state.)
spm_cmd_list() {
	local pkgdir pkg ver inst
	if [ ! -d "$APPS_DIR" ]; then
		return 0
	fi
	# Skip hidden infrastructure dirs such as .staging (package names never
	# start with ".", §7.1); they are not installed applications.
	while IFS= read -r -d '' pkgdir; do
		pkg=$(basename "$pkgdir")
		inst="$pkgdir/.spm/lock.json"
		if [ -f "$inst" ]; then
			ver=$(jq -r '.version // "-" ' "$inst" 2>/dev/null)
			[ -n "$ver" ] && [ "$ver" != "null" ] || ver="-"
		else
			ver="-"
		fi
		printf '%s\t%s\t%s\n' "$pkg" "$ver" "$pkgdir"
	done < <(find "$APPS_DIR" -mindepth 1 -maxdepth 1 -type d -not -name '.*' \
		-print0 2>/dev/null | sort -z)
	return 0
}
