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
	# §12: --dry-run prints the plan and changes nothing (no resolve, stage,
	# recipe, links, or .spm). Runs after the already-installed check so that
	# an installed package still errors under install.
	if [ "$SPM_DRY_RUN" = 1 ]; then
		local dver
		dver=$(jq -r '.version // "-" ' "$pin" 2>/dev/null)
		[ -n "$dver" ] && [ "$dver" != "null" ] || dver="-"
		spm_log "install: would install $pkg (version $dver)"
		return 0
	fi
	if [ ! -f "$pin" ]; then
		spm_log "install: no pin for $pkg; resolving first"
		spm_lock_one "$pkg" || spm_die "install: failed to resolve $pkg" 1
	fi
	[ -f "$pin" ] || spm_die "install: no pin for $pkg" 1
	spm_validate_pin "$pin" "$pkg" || spm_die "install: invalid pin for $pkg" 1

	local version url sha size
	IFS=$'\n' read -r -d '' url sha size _ < <(spm_pin_artifact "$pin"; printf '\0') || true
	version=$(jq -r '.version' "$pin")

	# §10.3: recover from a crashed previous attempt for this package.
	spm_recovery "$pkg"

	# §10.2: write the pending marker before the first change under $APPS_DIR.
	spm_write_marker "$pkg" install ""

	# Stage under $APPS_DIR/.staging/<pkg> (same filesystem -> atomic rename). (§4.2, §11)
	local stage="$APPS_DIR/.staging/$pkg"
	mkdir -p "$APPS_DIR/.staging"
	spm_safe_rm "$stage" 2>/dev/null || true
	mkdir -p "$stage"

	# Link plan: a temp file the recipe appends to via spm_link. (§7.3, §9)
	local plan; plan=$(mktemp)
	: > "$plan"
	# Track stage+plan so the ERR/INT/TERM trap handlers can clean up. (§10.10)
	spm_txn_track "$stage" "$plan"

	# Run the recipe. (§7.3 env)
	if ! SPM_MODE=install SPM_PKG="$pkg" SPM_VERSION="$version" \
		SPM_ARCH="$SPM_ARCH" SPM_URL="$url" SPM_SHA256="$sha" \
		SPM_SIZE="$size" SPM_LOCK="$pin" SPM_STAGE="$stage" \
		SPM_FINAL_DIR="$APPS_DIR/$pkg" SPM_BIN_DIR="$BIN_DIR" \
		SPM_LINK_PLAN="$plan" SPM_HELPERS="$SPM_ROOT/helpers" \
		GITHUB_TOKEN="${GITHUB_TOKEN:-}" \
		bash "$recipe/install.sh"; then
		# §10.10: cleanup staging + links + marker, then fail.
		spm_cleanup_failed
		spm_die "install: recipe failed for $pkg" 1
	fi

	# §9: detect link conflicts before committing the app directory.
	if ! spm_check_link_plan "$plan"; then
		spm_cleanup_failed
		spm_die "install: link conflict for $pkg (use upgrade)" 1
	fi

	# §11.1 step 4: move staging tree into place atomically.
	if ! mv "$stage" "$APPS_DIR/$pkg"; then
		spm_cleanup_failed
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

	# §10.2: success -- clear the pending marker and txn state.
	spm_txn_done "$pkg"

	spm_log "install: $pkg installed (version $version)"
}

# --- upgrade (Phase 3, §11) ------------------------------------------------

# upgrade [pkg...] -- §12. With no package names, upgrade every installed
# package. Packages installed but with no pin are skipped with a warning; a
# named package with no pin is an error.
spm_cmd_upgrade() {
	local -a pkgs=() p rc=0
	local explicit=1
	if [ $# -gt 0 ]; then
		pkgs=("$@")
	else
		if [ -d "$APPS_DIR" ]; then
			mapfile -t pkgs < <(find "$APPS_DIR" -mindepth 1 -maxdepth 1 -type d \
				-not -name '.*' -printf '%f\n' 2>/dev/null | sort)
		fi
		if [ "${#pkgs[@]}" -eq 0 ]; then
			spm_warn "upgrade: no installed packages"
			return 0
		fi
		explicit=0
	fi
	for p in "${pkgs[@]}"; do
		spm_do_upgrade "$p" "$explicit" || rc=1
	done
	return "$rc"
}

# Upgrade a single installed package. <explicit>=1 when the user named it (a
# missing pin is then an error); =0 when it was discovered as installed (a
# missing pin is warned and skipped, §12).
spm_do_upgrade() {
	local pkg="$1" explicit="${2-1}"
	[[ "$pkg" =~ ^[a-z0-9][a-z0-9._-]*$ ]] \
		|| spm_die "upgrade: invalid package name: $pkg" 1

	local recipe="$SPM_ROOT/packages/$pkg"
	if [ ! -d "$recipe" ] || [ ! -f "$recipe/install.sh" ] || [ ! -f "$recipe/meta" ]; then
		spm_die "upgrade: no recipe for package: $pkg" 1
	fi

	local pkgdir="$APPS_DIR/$pkg"
	[ -e "$pkgdir" ] || [ -L "$pkgdir" ] \
		|| spm_die "upgrade: $pkg is not installed; use install" 1

	local pin="$SPM_CONFIG_DIR/locks/$pkg.json"
	if [ ! -f "$pin" ]; then
		if [ "$explicit" = 1 ]; then
			spm_die "upgrade: no pin for $pkg (run 'lock update $pkg' first)" 1
		else
			spm_warn "upgrade: no pin for $pkg; skipping"
			return 0
		fi
	fi
	spm_validate_pin "$pin" "$pkg" || spm_die "upgrade: invalid pin for $pkg" 1

	# §12: up-to-date when the installed version and arch sha256 match the pin.
	if spm_installed_matches_pin "$pkg" "$pin"; then
		spm_log "upgrade: $pkg already up-to-date (version $(jq -r '.version' "$pin"))"
		return 0
	fi

	# §12: dry-run prints the plan and changes nothing.
	if [ "$SPM_DRY_RUN" = 1 ]; then
		local umode
		if [ "$SAFE_UPGRADE" = 1 ]; then umode="safe"; else umode="inplace"; fi
		spm_log "upgrade: would upgrade $pkg to $(jq -r '.version' "$pin") (mode=$umode)"
		return 0
	fi

	# §10.3: recover from a crashed previous upgrade.
	spm_recovery "$pkg"

	local mode="inplace"
	[ "$SAFE_UPGRADE" = 1 ] && mode="safe"
	spm_write_marker "$pkg" upgrade "$mode"

	local url sha size version
	IFS=$'\n' read -r -d '' url sha size _ < <(spm_pin_artifact "$pin"; printf '\0') || true
	version=$(jq -r '.version' "$pin")

	# §11.1/§11.2: stage under $APPS_DIR/.staging/<pkg> (same filesystem).
	local stage="$APPS_DIR/.staging/$pkg"
	mkdir -p "$APPS_DIR/.staging"
	spm_safe_rm "$stage" 2>/dev/null || true
	mkdir -p "$stage"
	local plan; plan=$(mktemp)
	: > "$plan"
	spm_txn_track "$stage" "$plan"

	# In-place only: tear down the OLD install before re-running the recipe
	# (§11.1 step 2). Safe mode keeps the old version working (§11.2 step 2).
	local old="" old_links=""
	if [ "$mode" = "inplace" ]; then
		if [ -f "$recipe/uninstall.sh" ]; then
			if ! SPM_PKG="$pkg" SPM_FINAL_DIR="$pkgdir" SPM_BIN_DIR="$BIN_DIR" \
				bash "$recipe/uninstall.sh"; then
				spm_warn "upgrade: uninstall.sh failed for $pkg (ignored)"
			fi
		fi
		spm_remove_links "$pkg" "$pkgdir"
		spm_safe_rm "$pkgdir"
	fi

	# §11.1 step 3 / §11.2 step 2: run install.sh (SPM_MODE=upgrade, extract).
	if ! SPM_MODE=upgrade SPM_PKG="$pkg" SPM_VERSION="$version" \
		SPM_ARCH="$SPM_ARCH" SPM_URL="$url" SPM_SHA256="$sha" \
		SPM_SIZE="$size" SPM_LOCK="$pin" SPM_STAGE="$stage" \
		SPM_FINAL_DIR="$pkgdir" SPM_BIN_DIR="$BIN_DIR" \
		SPM_LINK_PLAN="$plan" SPM_HELPERS="$SPM_ROOT/helpers" \
		GITHUB_TOKEN="${GITHUB_TOKEN:-}" bash "$recipe/install.sh"; then
		spm_cleanup_failed
		spm_die "upgrade: recipe failed for $pkg" 1
	fi
	if ! spm_check_link_plan "$plan"; then
		spm_cleanup_failed
		spm_die "upgrade: link conflict for $pkg (retry with --safe-upgrade)" 1
	fi

	# §11.1 step 4 / §11.2 step 3: move the new tree into place.
	if [ "$mode" = "safe" ]; then
		old="$APPS_DIR/.staging/$pkg.old"
		spm_safe_rm "$old" 2>/dev/null || true
		mv "$pkgdir" "$old"
		mv "$stage" "$pkgdir"
		if [ -f "$old/.spm/links" ]; then
			old_links=$(cat "$old/.spm/links")
		fi
	else
		mv "$stage" "$pkgdir"
	fi

	# §11.1 step 5 / §11.2 step 4: links + .spm/ (+ drop stale old links, safe).
	mkdir -p "$BIN_DIR"
	local new_names; new_names=$(cut -f1 "$plan" | paste -sd ' ' -)
	local links
	links=$(spm_create_links "$pkgdir" "$plan")
	rm -f "$plan"
	if [ -n "$old_links" ]; then
		local name
		while IFS= read -r ln; do
			[ -z "$ln" ] && continue
			name=$(basename -- "$ln")
			case " $new_names " in
				*" $name "*) ;;               # still wanted, keep it
				*) rm -f -- "$ln" ;;           # no longer wanted
			esac
		done <<< "$old_links"
	fi
	spm_write_app_lock "$pkgdir" "$pin"
	printf '%s' "$links" | spm_write_app_links "$pkgdir"

	# §11.2 step 5: delete the old staged tree.
	if [ "$mode" = "safe" ] && [ -n "$old" ]; then
		spm_safe_rm "$old" 2>/dev/null || true
	fi

	# §10.2 / §11.1 step 6: success -- clear the pending marker.
	spm_txn_done "$pkg"
	spm_log "upgrade: $pkg upgraded to $version (mode=$mode)"
}
