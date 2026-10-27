# lib/config.sh -- configuration loading.
#
# This file is sourced, never executed directly. It must not alter the
# caller's shell options.
#
# config.env is parsed as DATA only (never sourced/evaluated) per §5/§7.1.
# shellcheck shell=bash

# Expand one pair of surrounding double quotes and a leading ~/ in a value,
# per §5.2 ($ and backticks are NOT expanded). Returns the value on stdout.
_spm_expand_value() {
	local v="$1"
	if [ "${#v}" -ge 2 ] && [ "${v:0:1}" = '"' ] && [ "${v: -1}" = '"' ]; then
		v="${v:1:${#v}-2}"
	fi
	# Expand a leading ~/ to $HOME/. Compare characters (not a quoted "~/")
	# so shellcheck does not flag a tilde in quotes, and bash case patterns do
	# not tilde-expand.
	if [ "${v:0:1}" = '~' ] && [ "${v:1:1}" = '/' ]; then
		v="$HOME${v:1}"
	fi
	printf '%s' "$v"
}

# Read a single KEY from a config-style (KEY=VALUE) file using the same parsing
# rules as config.env (§5.2/§7.1). Prints the expanded value (to stdout) and
# returns 0 on the first match, or returns 1 if KEY is absent. Parsed as data
# only -- never sourced.
spm_get_kv() {
	local file="$1" key="$2" line k v
	local re_key='^[A-Z][A-Z0-9_]*$'
	[ -f "$file" ] || return 1
	while IFS= read -r line || [ -n "$line" ]; do
		line="${line%$'\r'}"
		[ -z "$line" ] && continue
		case "$line" in '#'*) continue ;; esac
		case "$line" in *=*) ;; *) continue ;; esac
		k="${line%%=*}"
		if [[ $k =~ $re_key ]] && [ "$k" = "$key" ]; then
			v=$(_spm_expand_value "${line#*=}")
			printf '%s' "$v"
			return 0
		fi
	done < "$file"
	return 1
}

# Load configuration, setting these globals (and exporting SPM_CONFIG_DIR,
# APPS_DIR, BIN_DIR, GITHUB_TOKEN for subprocesses):
#   SPM_CONFIG_DIR  config/state root (env var or default)
#   APPS_DIR        where apps are installed (config.env or default)
#   BIN_DIR         where links are created (config.env or default)
#   SAFE_UPGRADE    0 or 1 (config.env or default 0)
#   LOG_KEEP        integer >= 1 (config.env or default 20)
#   GITHUB_TOKEN    string (env var takes precedence over config.env, §5)
#   BASELINE_REPO   git URL for `sync` (config.env or default empty; §5/§12)
spm_load_config() {
	# SPM_CONFIG_DIR comes from the environment, or the built-in default.
	if [ -z "${SPM_CONFIG_DIR:-}" ]; then
		SPM_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/static-pkgmgr"
	fi
	export SPM_CONFIG_DIR

	# Built-in defaults (exported: subprocesses such as recipes need them).
	# APPS_DIR/BIN_DIR are NOT read from the environment; only GITHUB_TOKEN and
	# SPM_CONFIG_DIR are, per §5/§149.
	export APPS_DIR="$HOME/.local/opt"
	export BIN_DIR="$HOME/.local/bin"
	export SAFE_UPGRADE="0"
	export LOG_KEEP="20"
	# shellcheck disable=SC2034  # non-exported global; read by sync (lib/sync.sh), §12.
	BASELINE_REPO=""

	# GITHUB_TOKEN: the environment variable takes precedence over config.env.
	# Remember whether it was set in the environment, and capture any value
	# coming from the file, before resolving precedence after parsing.
	local _gh_env_set=0 _gh_env_val="" _gh_file=""
	if [ -n "${GITHUB_TOKEN+set}" ]; then
		_gh_env_set=1
		_gh_env_val="$GITHUB_TOKEN"
	fi

	local cfg="$SPM_CONFIG_DIR/config.env"
	if [ ! -f "$cfg" ]; then
		if [ "$_gh_env_set" = 1 ]; then GITHUB_TOKEN="$_gh_env_val"; else GITHUB_TOKEN=""; fi
		export GITHUB_TOKEN
		return 0
	fi

	local line key value
	local re_key='^[A-Z][A-Z0-9_]*$'
	local re_uint='^[0-9]+$'
	while IFS= read -r line || [ -n "$line" ]; do
		# Tolerate CRLF line endings.
		line="${line%$'\r'}"
		# Skip blank lines and comments.
		[ -z "$line" ] && continue
		case "$line" in '#'*) continue ;; esac
		# Must be KEY=VALUE.
		case "$line" in
			*=*) ;;
			*) spm_die "config: invalid line (expected KEY=VALUE): $line" ;;
		esac
		key="${line%%=*}"
		value=$(_spm_expand_value "${line#*=}")
		# Validate KEY format.
		if ! [[ $key =~ $re_key ]]; then
			spm_die "config: invalid key: '$key'"
		fi
		case "$key" in
			APPS_DIR)
				case "$value" in /*) ;; *) spm_die "config: APPS_DIR must be an absolute path: $value" ;; esac
				APPS_DIR="$value"
				;;
			BIN_DIR)
				case "$value" in /*) ;; *) spm_die "config: BIN_DIR must be an absolute path: $value" ;; esac
				BIN_DIR="$value"
				;;
			SAFE_UPGRADE)
				case "$value" in 0|1) ;; *) spm_die "config: SAFE_UPGRADE must be 0 or 1" ;; esac
				SAFE_UPGRADE="$value"
				;;
			LOG_KEEP)
				if [[ ! $value =~ $re_uint ]]; then
					spm_die "config: LOG_KEEP must be an integer"
				fi
				if [ "$value" -lt 1 ]; then
					spm_die "config: LOG_KEEP must be >= 1"
				fi
				LOG_KEEP="$value"
				;;
			GITHUB_TOKEN)
				_gh_file="$value"
				;;
			BASELINE_REPO)
				# shellcheck disable=SC2034  # non-exported global; read by sync (lib/sync.sh), §12.
				case "$value" in
					"" ) BASELINE_REPO="" ;;
					https://*|git@*|ssh://*|git://*) BASELINE_REPO="$value" ;;
					file://*) [ "${SPM_TEST_MODE:-0}" = "1" ] || spm_die "config: BASELINE_REPO file:// requires SPM_TEST_MODE=1"; BASELINE_REPO="$value" ;;
					*) spm_die "config: BASELINE_REPO must be a git URL (https://, git@, ssh://, git://)" ;;
				esac
				;;
			*)
				# Unknown key: warn and ignore per §5.2.
				spm_warn "config: unknown key '$key' (ignored)"
				continue
				;;
		esac
	done < "$cfg"

	# Environment GITHUB_TOKEN wins over the value from config.env.
	if [ "$_gh_env_set" = 1 ]; then
		GITHUB_TOKEN="$_gh_env_val"
	else
		GITHUB_TOKEN="$_gh_file"
	fi

	export GITHUB_TOKEN
}

# Load config when this file is sourced.
spm_load_config
