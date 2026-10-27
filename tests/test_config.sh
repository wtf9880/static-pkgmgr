#!/usr/bin/env bash
# tests/test_config.sh -- tests for lib/config.sh (Phase 0: config parsing).
#
# config.sh is designed to load once at source time (production model: the
# entrypoint sources it once). To test each scenario cleanly we spawn a fresh
# child process per scenario with a controlled GITHUB_TOKEN environment and a
# temp SPM_CONFIG_DIR, mirroring real usage and avoiding in-process reload
# artifacts.
set -Eeuo pipefail
: "${SPM_ROOT:=$(readlink -f "$(dirname "${BASH_SOURCE[0]}")/..")}"
export SPM_ROOT
. "$SPM_ROOT/tests/lib.sh"

# spm_run_config <config.env content> <gh: "__unset__" or an env value>
# Spawns a child that sources common.sh + config.sh under a temp SPM_CONFIG_DIR
# (with GITHUB_TOKEN controlled) and prints the resolved config vars.
# Sets SPM_OUT (var dump), SPM_ERR, SPM_CODE.
spm_run_config() {
	local content="$1"
	local gh="$2"
	local cfg script
	cfg=$(mktemp -dt spm-cfg.XXXXXX)
	if [ -n "$content" ]; then
		printf '%s\n' "$content" > "$cfg/config.env"
	fi
	# The child script body uses $SPM_ROOT/$APPS_DIR/... which MUST expand in the
	# child shell, not here; hence single quotes.
	# shellcheck disable=SC2016
	script='
		. "$SPM_ROOT/lib/common.sh"
		. "$SPM_ROOT/lib/config.sh"
		printf "APPS_DIR=%s\nBIN_DIR=%s\nSAFE_UPGRADE=%s\nLOG_KEEP=%s\nGITHUB_TOKEN=%s\n" \
			"$APPS_DIR" "$BIN_DIR" "$SAFE_UPGRADE" "$LOG_KEEP" "$GITHUB_TOKEN"
	'
	if [ "$gh" = "__unset__" ]; then
		spm_run env -u GITHUB_TOKEN SPM_CONFIG_DIR="$cfg" bash -c "$script"
	else
		spm_run env GITHUB_TOKEN="$gh" SPM_CONFIG_DIR="$cfg" bash -c "$script"
	fi
}

# Extract a var line ("KEY=value") from SPM_OUT.
cfg_var() { printf '%s\n' "$SPM_OUT" | sed -n "s/^$1=//p" | head -n1; }

# --- defaults (no config.env present) --------------------------------------
spm_run_config "" "__unset__"
spm_eq_int "$SPM_CODE" 0
spm_eq "$(cfg_var APPS_DIR)" "$HOME/.local/opt"
spm_eq "$(cfg_var BIN_DIR)" "$HOME/.local/bin"
spm_eq_int "$(cfg_var SAFE_UPGRADE)" 0
spm_eq_int "$(cfg_var LOG_KEEP)" 20
spm_eq "$(cfg_var GITHUB_TOKEN)" ""

# --- all known keys set ----------------------------------------------------
spm_run_config 'APPS_DIR=/opt/apps
BIN_DIR=/opt/bin
SAFE_UPGRADE=1
LOG_KEEP=5
GITHUB_TOKEN=sometoken' "__unset__"
spm_eq_int "$SPM_CODE" 0
spm_eq "$(cfg_var APPS_DIR)" "/opt/apps"
spm_eq "$(cfg_var BIN_DIR)" "/opt/bin"
spm_eq_int "$(cfg_var SAFE_UPGRADE)" 1
spm_eq_int "$(cfg_var LOG_KEEP)" 5
spm_eq "$(cfg_var GITHUB_TOKEN)" "sometoken"

# --- one pair of surrounding double quotes is removed ---------------------
spm_run_config 'APPS_DIR="/opt/apps"
SAFE_UPGRADE="1"
LOG_KEEP="7"
GITHUB_TOKEN="tok"' "__unset__"
spm_eq "$(cfg_var APPS_DIR)" "/opt/apps"
spm_eq_int "$(cfg_var SAFE_UPGRADE)" 1
spm_eq_int "$(cfg_var LOG_KEEP)" 7
spm_eq "$(cfg_var GITHUB_TOKEN)" "tok"

# --- leading ~/ expands to $HOME -----------------------------------------
spm_run_config 'APPS_DIR=~/apps
BIN_DIR=~/bin' "__unset__"
spm_eq "$(cfg_var APPS_DIR)" "$HOME/apps"
spm_eq "$(cfg_var BIN_DIR)" "$HOME/bin"

# --- $ and backticks are NOT expanded (literal to end of line) ------------
# Single-quoted content so "$HOME" is literal in config.env; this verifies
# §5.2 that $ is not expanded.
# shellcheck disable=SC2016
spm_run_config 'GITHUB_TOKEN="$HOME"
APPS_DIR=/tmp/literal-#-value' "__unset__"
# shellcheck disable=SC2016
spm_eq "$(cfg_var GITHUB_TOKEN)" '$HOME'
spm_eq "$(cfg_var APPS_DIR)" '/tmp/literal-#-value'

# --- comments (#) and blank lines are skipped -----------------------------
spm_run_config '# this is a comment
APPS_DIR=/opt/apps

# mid-file comment
SAFE_UPGRADE=1' "__unset__"
spm_eq "$(cfg_var APPS_DIR)" "/opt/apps"
spm_eq_int "$(cfg_var SAFE_UPGRADE)" 1

# --- unknown key warns and is ignored; known keys still applied -----------
spm_run_config 'WEIRDKEY=1
APPS_DIR=/opt/apps' "__unset__"
spm_eq_int "$SPM_CODE" 0
spm_contains "$SPM_ERR" "WEIRDKEY"
spm_contains "$SPM_ERR" "ignored"
spm_eq "$(cfg_var APPS_DIR)" "/opt/apps"

# --- invalid KEY format is an error (exit 1) ------------------------------
spm_run_config 'lowercase=1' "__unset__"
spm_eq_int "$SPM_CODE" 1

spm_run_config '1KEY=1' "__unset__"
spm_eq_int "$SPM_CODE" 1

# --- line without = is an error -------------------------------------------
spm_run_config 'NOEQUALSSIGN' "__unset__"
spm_eq_int "$SPM_CODE" 1

# --- invalid APPS_DIR (not absolute) is an error --------------------------
spm_run_config 'APPS_DIR=relative/path' "__unset__"
spm_eq_int "$SPM_CODE" 1

spm_run_config 'BIN_DIR=relative' "__unset__"
spm_eq_int "$SPM_CODE" 1

# --- invalid SAFE_UPGRADE is an error -------------------------------------
spm_run_config 'SAFE_UPGRADE=2' "__unset__"
spm_eq_int "$SPM_CODE" 1

spm_run_config 'SAFE_UPGRADE=yes' "__unset__"
spm_eq_int "$SPM_CODE" 1

# --- invalid LOG_KEEP (non-integer / < 1) is an error ---------------------
spm_run_config 'LOG_KEEP=abc' "__unset__"
spm_eq_int "$SPM_CODE" 1

spm_run_config 'LOG_KEEP=0' "__unset__"
spm_eq_int "$SPM_CODE" 1

# --- GITHUB_TOKEN: environment variable takes precedence over config.env --
spm_run_config 'GITHUB_TOKEN=fromfile' "fromenv"
spm_eq_int "$SPM_CODE" 0
spm_eq "$(cfg_var GITHUB_TOKEN)" "fromenv"

# --- GITHUB_TOKEN from config.env when env is unset -----------------------
spm_run_config 'GITHUB_TOKEN=fromfile' "__unset__"
spm_eq "$(cfg_var GITHUB_TOKEN)" "fromfile"

# --- empty config file yields defaults ------------------------------------
spm_run_config "" "__unset__"
spm_eq "$(cfg_var APPS_DIR)" "$HOME/.local/opt"
spm_eq_int "$(cfg_var SAFE_UPGRADE)" 0
spm_eq_int "$(cfg_var LOG_KEEP)" 20

spm_end
