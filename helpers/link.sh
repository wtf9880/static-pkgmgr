# helpers/link.sh -- spm_link (§8).
#
# This file is sourced by recipes (into the recipe subprocess). It must not
# alter the caller's shell options.
# shellcheck shell=bash

# spm_link <path_in_app> <link_name>
# Records an intended link in $SPM_LINK_PLAN as "<link_name>\t<path_in_app>".
# The core creates the actual symlinks after the install tree is in place.
# <path_in_app> is relative to the app directory; <link_name> is the name to
# create in $SPM_BIN_DIR.
spm_link() {
	local path_in_app="$1" link_name="$2"
	printf '%s\t%s\n' "$link_name" "$path_in_app" >>"$SPM_LINK_PLAN"
}
