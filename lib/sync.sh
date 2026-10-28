# lib/sync.sh -- Phase 5: sync desired pins from a baseline lock repo.
#
# `sync` fetches a (shallow, --depth 1) git checkout of $BASELINE_REPO into
# $SPM_CONFIG_DIR/baseline, then copies every baseline pin that the local
# $SPM_CONFIG_DIR/locks/ is missing. It never overwrites an existing local
# pin (use `lock update` to refresh one), never runs a recipe, and writes no
# pending marker (so a few skipped pins do not abort the rest) -- it reuses
# the soft-rc pattern of `lock update`; the global mutex (taken by the
# entrypoint when BASELINE_REPO is set and --dry-run is not) is released on
# exit via fd-close. (§4.1, §5, §10.1, §12, §15)
#
# Sourced by the entrypoint; defines functions only.
# shellcheck shell=bash

# Remove every entry inside <dir> (but not <dir> itself) via spm_safe_rm,
# leaving the directory empty so `git clone` can populate it. Mirrors the
# staging sweep in lib/txn.sh (spm_cleanup_staging) and deliberately avoids
# `find -exec spm_safe_rm` (spm_safe_rm is a shell function, not on PATH, so
# `find -exec` cannot call it). (§14)
_spm_clear_dir() {
	local dir="$1" s
	while IFS= read -r -d '' s; do
		[ -n "$s" ] || continue
		spm_safe_rm "$s"
	done < <(find "$dir" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
	return 0
}

# sync [pkg...] -- §12, Phase 5. (§4.1 baseline/, §5 BASELINE_REPO, §10, §15)
#
# Fetch the baseline: clone fresh if the checkout is absent, refresh in place
# via `fetch --depth 1 origin` + `reset --hard origin/HEAD` if present. Then,
# for each baseline pin (locks/<pkg>.json at the repo root): validate it (§6);
# skip if a local pin already exists; skip + warn if the package has no
# recipe in $SPM_ROOT/packages; otherwise copy it atomically with
# spm_write_pin. With package args, only those are synced and an unknown
# package is a hard error (die before writing anything). --dry-run still
# fetches and prints the planned writes but writes nothing.
spm_cmd_sync() {
	if [ -z "${BASELINE_REPO:-}" ]; then
		spm_die "sync: BASELINE_REPO is not set (config.env §5)"
	fi

	local baseline="$SPM_CONFIG_DIR/baseline"
	local rc=0 pkg pin ver want found p
	local -a pkgs=()

	# --- fetch: clone fresh or refresh the shallow checkout ---------------
	if [ -d "$baseline/.git" ]; then
		# Refresh an existing shallow checkout to origin/HEAD. (§15)
		if ! git -C "$baseline" fetch --depth 1 origin; then
			spm_die "sync: failed to refresh baseline (git fetch)"
		fi
		if ! git -C "$baseline" reset --hard "origin/HEAD"; then
			spm_die "sync: failed to refresh baseline (git reset --hard)"
		fi
	else
		# No git checkout yet (or a stale non-git leftover): clear any stale
		# contents of an existing baseline dir so the clone can populate it.
		# spm_safe_rm refuses the baseline root itself, so we clear its
		# contents rather than the directory. (§14)
		if [ -e "$baseline" ]; then
			_spm_clear_dir "$baseline"
		fi
		if ! git clone --depth 1 "$BASELINE_REPO" "$baseline"; then
			# Git's diagnostics already reached the terminal; tidy any
			# partial tree so the next run can retry, then abort without
			# writing any pins. (§15: fetch/clone failure => nothing written.)
			if [ -e "$baseline" ]; then
				_spm_clear_dir "$baseline" || true
			fi
			spm_die "sync: failed to clone baseline: $BASELINE_REPO"
		fi
	fi

	# --- enumerate baseline pins (locks/<pkg>.json at the repo root) ------
	local locksdir="$baseline/locks"
	if [ -d "$locksdir" ]; then
		mapfile -t pkgs < <(find "$locksdir" -mindepth 1 -maxdepth 1 -name '*.json' \
			-printf '%f\n' 2>/dev/null | sed 's/\.json$//' | sort)
	fi

	# --- requested subset: unknown packages are a hard error --------------
	if [ $# -gt 0 ]; then
		local -a requested=("$@")
		for want in "${requested[@]}"; do
			found=0
			for p in "${pkgs[@]}"; do
				[ "$p" = "$want" ] && { found=1; break; }
			done
			# Die BEFORE writing any pin. (§15)
			[ "$found" -eq 1 ] || spm_die "sync: unknown package '$want' not in baseline"
		done
		pkgs=("${requested[@]}")
	fi

	# --- copy missing pins -----------------------------------------------
	for pkg in "${pkgs[@]}"; do
		pin="$locksdir/$pkg.json"
		# Validate schema (§6). Invalid -> warn, skip, rc=1.
		if ! spm_validate_pin "$pin" "$pkg"; then
			spm_warn "sync: '$pkg': invalid baseline pin; skipping"
			rc=1
			continue
		fi
		# Never overwrite an existing local pin; use `lock update` to refresh.
		if [ -e "$SPM_CONFIG_DIR/locks/$pkg.json" ]; then
			spm_log "sync: '$pkg': already exists (use 'lock update' to refresh)"
			continue
		fi
		# No recipe here -> not managed by us -> warn + skip (not an error).
		if [ ! -f "$SPM_ROOT/packages/$pkg/meta" ]; then
			spm_warn "sync: '$pkg': no recipe in $SPM_ROOT/packages; skipping"
			continue
		fi
		# Version for the log/plan line (the pin was already validated).
		ver=$(jq -r '.version' "$pin" 2>/dev/null) || ver="?"
		if [ "${SPM_DRY_RUN:-0}" = "1" ]; then
			spm_log "sync: '$pkg': would write pin (version $ver) (dry-run)"
		elif spm_write_pin "$pkg" < "$pin"; then
			spm_log "sync: '$pkg': wrote pin (version $ver)"
		else
			spm_warn "sync: '$pkg': failed to write pin; skipping"
			rc=1
		fi
	done

	return "$rc"
}
