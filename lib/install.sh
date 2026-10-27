# lib/install.sh -- install command (§7.3, §9, §11.1 in-place).
#
# Sourced by the entrypoint; defines functions only.
# shellcheck shell=bash

# install <pkg>... -- §12.
spm_cmd_install() {
	[ $# -gt 0 ] || { spm_err "usage: static-pkgmgr install <pkg>..."; exit 2; }
	local pkg
	for pkg in "$@"; do
		spm_install_one "$pkg"
	done
}

# Resolve the artifact for $SPM_ARCH out of a pin file, printing url sha size
# on separate lines (size may be empty). Dies on missing architecture.
spm_pin_artifact() {
	local pin="$1"
	local url sha size
	url=$(jq -r --arg arch "$SPM_ARCH" '.artifacts[$arch].url // empty' "$pin")
	[ -n "$url" ] || spm_die "install: no artifact for arch $SPM_ARCH" 1
	sha=$(jq -r --arg arch "$SPM_ARCH" '.artifacts[$arch].sha256' "$pin")
	size=$(jq -r --arg arch "$SPM_ARCH" '.artifacts[$arch].size // empty' "$pin")
	printf '%s\n%s\n%s\n' "$url" "$sha" "$size"
}

spm_install_one() {
	local pkg="$1"
	[[ "$pkg" =~ ^[a-z0-9][a-z0-9._-]*$ ]] \
		|| spm_die "install: invalid package name: $pkg" 1

	local recipe="$SPM_ROOT/packages/$pkg"
	if [ ! -d "$recipe" ] || [ ! -f "$recipe/install.sh" ] || [ ! -f "$recipe/meta" ]; then
		spm_die "install: no recipe for package: $pkg" 1
	fi

	# §9.2: error if already installed.
	if [ -e "$APPS_DIR/$pkg" ] || [ -L "$APPS_DIR/$pkg" ]; then
		spm_die "install: $pkg is already installed; use upgrade" 1
	fi

	# §12: ensure a pin exists (resolve first if missing).
	local pin="$SPM_CONFIG_DIR/locks/$pkg.json"
	if [ ! -f "$pin" ]; then
		spm_log "install: no pin for $pkg; resolving first"
		spm_lock_one "$pkg" || spm_die "install: failed to resolve $pkg" 1
	fi
	[ -f "$pin" ] || spm_die "install: no pin for $pkg" 1
	spm_validate_pin "$pin" "$pkg" || spm_die "install: invalid pin for $pkg" 1

	local version url sha size
	IFS=$'\n' read -r -d '' url sha size _ < <(spm_pin_artifact "$pin"; printf '\0') || true
	version=$(jq -r '.version' "$pin")

	# Stage under $APPS_DIR/.staging/<pkg> (same filesystem -> atomic rename). (§4.2, §11)
	local stage="$APPS_DIR/.staging/$pkg"
	mkdir -p "$APPS_DIR/.staging"
	spm_safe_rm "$stage" 2>/dev/null || true
	mkdir -p "$stage"

	# Link plan: a temp file the recipe appends to via spm_link. (§7.3, §9)
	local plan; plan=$(mktemp)
	: > "$plan"

	# Run the recipe. (§7.3 env)
	if ! SPM_MODE=install SPM_PKG="$pkg" SPM_VERSION="$version" \
		SPM_ARCH="$SPM_ARCH" SPM_URL="$url" SPM_SHA256="$sha" \
		SPM_SIZE="$size" SPM_LOCK="$pin" SPM_STAGE="$stage" \
		SPM_FINAL_DIR="$APPS_DIR/$pkg" SPM_BIN_DIR="$BIN_DIR" \
		SPM_LINK_PLAN="$plan" SPM_HELPERS="$SPM_ROOT/helpers" \
		GITHUB_TOKEN="${GITHUB_TOKEN:-}" \
		bash "$recipe/install.sh"; then
		rm -f "$plan"
		spm_safe_rm "$stage" 2>/dev/null || true
		spm_die "install: recipe failed for $pkg" 1
	fi

	# §9: detect link conflicts before committing the app directory.
	if ! spm_check_link_plan "$plan"; then
		rm -f "$plan"
		spm_safe_rm "$stage" 2>/dev/null || true
		spm_die "install: link conflict for $pkg (use upgrade)" 1
	fi

	# §11.1 step 4: move staging tree into place atomically.
	if ! mv "$stage" "$APPS_DIR/$pkg"; then
		rm -f "$plan"
		spm_safe_rm "$stage" 2>/dev/null || true
		spm_die "install: could not move $pkg into place" 1
	fi

	# §11.1 step 5: ensure BIN_DIR exists, then create the symlinks.
	mkdir -p "$BIN_DIR"
	local links
	links=$(spm_create_links "$APPS_DIR/$pkg" "$plan")
	rm -f "$plan"

	# §11.1 step 6: persist .spm/lock.json and .spm/links atomically. (§6, §9)
	spm_write_app_lock "$APPS_DIR/$pkg" "$pin"
	printf '%s' "$links" | spm_write_app_links "$APPS_DIR/$pkg"

	spm_log "install: $pkg installed (version $version)"
}
