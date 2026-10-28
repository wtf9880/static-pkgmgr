# lib/lock.sh -- lock (pin) management (§6, §7.2, §12).
#
# Sourced by the entrypoint; defines functions only.
# shellcheck shell=bash

# Validate a pin file against the §6 rules. $1 = pin file, $2 = package name.
# Returns 0 if valid, 1 otherwise.
spm_validate_pin() {
	local pin="$1" pkg="${2-}"
	local testmode="${SPM_TEST_MODE:-0}"
	[ -f "$pin" ] || return 1
	jq -e --arg pkg "$pkg" --arg testmode "$testmode" '
		if type == "object" then . else null end
		| .schema == 1
		  and (.package | type == "string"
		       and test("^[a-z0-9][a-z0-9._-]*$")
		       and . == $pkg)
		  and (.version | type == "string" and length > 0)
		  and (.requested == null
		       or (.requested | type == "string"
		           and test("^[A-Za-z0-9._+-]+$")))
		  and (.resolved_at | type == "string" and length > 0)
		  and (.artifacts | type == "object" and length >= 1)
		  and ([.artifacts | keys[] | test("^[A-Za-z0-9_+-]+$")] | all)
		  and ([.artifacts[] | (.url | type == "string"
		       and (startswith("https://")
		            or ($testmode == "1" and startswith("file://"))))]
		       | all)
		  and ([.artifacts[] | (.sha256 | type == "string"
		                        and test("^[0-9a-f]{64}$"))] | all)
		  and ([.artifacts[] | (.size == null
		       or (.size | type == "number" and (. == floor)))] | all)
	' "$pin" >/dev/null 2>&1
}

# Atomically write pin JSON (read from stdin) for <pkg>: validate with jq,
# then mv into $SPM_CONFIG_DIR/locks. A failure keeps the previous pin. (§6)
spm_write_pin() {
	local pkg="$1"
	local locksdir="$SPM_CONFIG_DIR/locks"
	mkdir -p "$locksdir"
	local tmp; tmp=$(mktemp "$locksdir/.pin.XXXXXX")
	if ! jq . > "$tmp"; then
		rm -f "$tmp"
		return 1
	fi
	if ! spm_validate_pin "$tmp" "$pkg"; then
		rm -f "$tmp"
		return 1
	fi
	mv -f "$tmp" "$locksdir/$pkg.json"
}

# Resolve one package spec and write its pin. <spec> is pkg, pkg@ver, or
# pkg@latest; otherwise the existing requested value is preserved. (§12)
spm_lock_one() {
	local spec="$1"
	local pkg raw
	if [[ "$spec" == *@* ]]; then
		pkg="${spec%%@*}"
		raw="${spec#*@}"
	else
		pkg="$spec"
		raw=""
	fi
	[[ "$pkg" =~ ^[a-z0-9][a-z0-9._-]*$ ]] \
		|| spm_die "lock: invalid package name: $pkg" 1
	local recipe="$SPM_ROOT/packages/$pkg"
	[ -d "$recipe" ] && [ -f "$recipe/lock.sh" ] && [ -f "$recipe/meta" ] \
		|| spm_die "lock: no recipe for package: $pkg" 1
	local name
	name=$(spm_get_kv "$recipe/meta" NAME) || name=""
	[ "$name" = "$pkg" ] \
		|| spm_die "lock: recipe NAME ($name) does not match package name ($pkg)" 1

	local pin="$SPM_CONFIG_DIR/locks/$pkg.json"
	local req_env="" req_is_null=0 req_val=""
	if [ -n "$raw" ]; then
		if [ "$raw" = "latest" ]; then
			req_is_null=1
		else
			req_is_null=0
			req_val="$raw"
		fi
	else
		# Preserve the existing requested value, or null if no pin.
		if [ -f "$pin" ]; then
			local existing; existing=$(jq -r '.requested // "null"' "$pin")
			if [ "$existing" = "null" ]; then
				req_is_null=1
			else
				req_is_null=0
				req_val="$existing"
			fi
		else
			req_is_null=1
		fi
	fi
	if [ "$req_is_null" = 0 ]; then
		[[ "$req_val" =~ ^[A-Za-z0-9._+-]+$ ]] \
			|| spm_die "lock: invalid requested version: $req_val" 1
		req_env="$req_val"
	fi

	# Run the recipe in a fresh temp dir (§7.2). Captures stdout (recipe JSON).
	local tmp; tmp=$(mktemp -d)
	local out
	if ! out=$( SPM_REQUESTED_VERSION="$req_env" SPM_HELPERS="$SPM_ROOT/helpers" \
		GITHUB_TOKEN="${GITHUB_TOKEN:-}" bash "$recipe/lock.sh" ); then
		rm -rf "$tmp"
		spm_warn "lock: recipe failed for $pkg; keeping previous pin"
		[ -f "$pin" ] || spm_die "lock: no previous pin for $pkg" 1
		return 1
	fi
	rm -rf "$tmp"

	# §7.2: recipe must print exactly one JSON object with version + artifacts.
	if ! printf '%s' "$out" | jq -e \
		'(.version | type == "string" and length > 0) and (.artifacts | type == "object" and length >= 1)' \
		>/dev/null 2>&1; then
		spm_warn "lock: recipe output for $pkg is not valid {version,artifacts}"
		[ -f "$pin" ] || spm_die "lock: no previous pin for $pkg" 1
		return 1
	fi

	local version; version=$(printf '%s' "$out" | jq -r '.version')
	local requested_json
	if [ "$req_is_null" = 1 ]; then
		requested_json="null"
	else
		requested_json=$(jq -nc --arg v "$req_val" '$v')
	fi
	local resolved_at; resolved_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	local pinjson
	if ! pinjson=$(jq -n \
		--arg pkg "$pkg" \
		--arg version "$version" \
		--argjson requested "$requested_json" \
		--arg resolved "$resolved_at" \
		--slurpfile rec <(printf '%s' "$out") \
		'{schema:1, package:$pkg, version:$version, requested:$requested,
		  resolved_at:$resolved, artifacts:($rec[0].artifacts)}'); then
		spm_die "lock: failed to build pin for $pkg" 1
	fi
	# §12: dry-run resolves the pin (read-only) but writes nothing.
	if [ "$SPM_DRY_RUN" = 1 ]; then
		local shown
		if [ "$req_is_null" = 1 ]; then shown="latest"; else shown="$req_val"; fi
		spm_log "lock: would update pin for $pkg to $version (requested=$shown) (dry-run)"
		return 0
	fi
	if ! printf '%s\n' "$pinjson" | spm_write_pin "$pkg"; then
		# Validation/write failed: the previous pin (if any) is retained. (§6)
		spm_die "lock: invalid pin produced for $pkg" 1
	fi
	local shown
	if [ "$req_is_null" = 1 ]; then shown="latest"; else shown="$req_val"; fi
	spm_log "lock: updated $pkg to $version (requested=$shown)"
	return 0
}

# lock update [--all|--installed] [pkg[@ver]...] -- §12.
# Scope selection (mutually exclusive): named packages; --all (every recipe in
# packages/); --installed (apps under $APPS_DIR/<pkg> with an existing pin);
# or, with no arguments, every package with an existing local pin (locks/<pkg>.json).
spm_lock_update() {
	local parsed
	if ! parsed=$(getopt -o '' -l 'all,installed' -n static-pkgmgr -- "$@"); then
		spm_err "usage: static-pkgmgr lock update [--all|--installed] [pkg[@ver]]" >&2
		return 2
	fi
	# shellcheck disable=SC2086  # getopt shell-quoted output; standard idiom (§14 D7).
	eval "set -- $parsed"
	local -a pkgs=()
	local all=0 installed=0 explicit=0
	while [ $# -gt 0 ]; do
		case "$1" in
			--all) all=1 ;;
			--installed) installed=1 ;;
			--) ;;
			*) pkgs+=("$1") ;;
		esac
		shift
	done
	if [ "$all" -eq 1 ] && [ "$installed" -eq 1 ]; then
		spm_err "lock update: --all and --installed are mutually exclusive" >&2
		return 2
	fi
	if { [ "$all" -eq 1 ] || [ "$installed" -eq 1 ]; } && [ "${#pkgs[@]}" -gt 0 ]; then
		spm_err "lock update: --all/--installed cannot be combined with package names" >&2
		return 2
	fi
	if [ "${#pkgs[@]}" -gt 0 ]; then explicit=1; fi
	local -a targets=()
	if [ "$explicit" -eq 1 ]; then
		# Named packages: resolve exactly those (existing behavior).
		targets=("${pkgs[@]}")
	elif [ "$all" -eq 1 ]; then
		if [ -d "$SPM_ROOT/packages" ]; then
			# §12 "all" set: a directory without lock.sh+meta is not a package.
			mapfile -t targets < <(find -L "$SPM_ROOT/packages" -mindepth 1 -maxdepth 1 -type d \
				-exec test -f '{}/lock.sh' \; -exec test -f '{}/meta' \; \
				-printf '%f\n' 2>/dev/null | sort)
		fi
		if [ "${#targets[@]}" -eq 0 ]; then
			spm_warn "lock update: no recipes found in $SPM_ROOT/packages"
			return 0
		fi
	elif [ "$installed" -eq 1 ]; then
		# Installed apps that already have a local pin (Option B: --installed).
		if [ -d "$APPS_DIR" ]; then
			local p
			while IFS= read -r -d '' d; do
				p="${d##*/}"
				[ -n "$p" ] || continue
				[ -f "$SPM_CONFIG_DIR/locks/$p.json" ] && targets+=("$p")
			done < <(find "$APPS_DIR" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
		fi
	else
		# Default (no flags, no packages): every package with an existing pin.
		if [ -d "$SPM_CONFIG_DIR/locks" ]; then
			mapfile -t targets < <(find "$SPM_CONFIG_DIR/locks" -mindepth 1 -maxdepth 1 \
				-name '*.json' -printf '%f\n' 2>/dev/null | sed 's/\.json$//' | sort)
		fi
	fi
	if [ "${#targets[@]}" -eq 0 ]; then
		spm_warn "lock update: nothing to resolve"
		return 0
	fi
	local rc=0 p recipe
	for p in "${targets[@]}"; do
		# Scope-based selection: a missing recipe is a non-fatal skip. Named
		# packages get the hard "no recipe" error from spm_lock_one (§12).
		if [ "$explicit" -eq 0 ]; then
			recipe="$SPM_ROOT/packages/$p"
			if [ ! -d "$recipe" ] || [ ! -f "$recipe/lock.sh" ] || [ ! -f "$recipe/meta" ]; then
				spm_warn "lock: no recipe for $p (skipped)"
				continue
			fi
		fi
		spm_lock_one "$p" || rc=1
	done
	return "$rc"
}

# lock show [pkg...] -- §12. Read-only: prints "<pkg>\t<desired>\t<installed>\t<status>"
# for each named package, or for every pinned package when none are named.
# Status: up-to-date | upgrade | not installed | no pin.
spm_lock_show() {
	local -a pkgs=()
	if [ $# -gt 0 ]; then
		pkgs=("$@")
	else
		if [ -d "$SPM_CONFIG_DIR/locks" ]; then
			mapfile -t pkgs < <(find "$SPM_CONFIG_DIR/locks" -mindepth 1 -maxdepth 1 \
				-name '*.json' -printf '%f\n' 2>/dev/null | sed 's/\.json$//' | sort)
		fi
	fi
	local pkg pin pkgdir inst desired installed status
	for pkg in "${pkgs[@]}"; do
		if ! [[ "$pkg" =~ ^[a-z0-9][a-z0-9._-]*$ ]]; then
			spm_warn "lock show: invalid package name: $pkg"
			continue
		fi
		pin="$SPM_CONFIG_DIR/locks/$pkg.json"
		pkgdir="$APPS_DIR/$pkg"
		inst="$pkgdir/.spm/lock.json"
		if [ ! -f "$pin" ]; then
			desired="-"; installed="-"; status="no pin"
		elif ! [ -e "$pkgdir" ] && [ ! -L "$pkgdir" ]; then
			desired=$(jq -r '.version' "$pin")
			installed="-"; status="not installed"
		else
			desired=$(jq -r '.version' "$pin")
			if [ -f "$inst" ]; then
				installed=$(jq -r '.version' "$inst")
			else
				installed="-"
			fi
			if spm_installed_matches_pin "$pkg" "$pin"; then
				status="up-to-date"
			else
				status="upgrade"
			fi
		fi
		printf '%s\t%s\t%s\t%s\n' "$pkg" "$desired" "$installed" "$status"
	done
	return 0
}

spm_lock_main() {
	local subcmd="${1-}"
	[ $# -gt 0 ] || { spm_err "usage: static-pkgmgr lock update [--all|--installed] [pkg[@ver]] | lock show [pkg...]"; exit 2; }
	shift
	case "$subcmd" in
		update) spm_lock_update "$@" ;;
		show) spm_lock_show "$@" ;;
		*) spm_err "usage: static-pkgmgr lock update [--all|--installed] [pkg[@ver]] | lock show [pkg...]"; exit 2 ;;
	esac
}
