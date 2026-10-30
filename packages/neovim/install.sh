#!/usr/bin/env bash
# Recipe: install Neovim from its linux-<arch> tarball into $SPM_STAGE. (§7.3)
# The archive is streamed and SHA256-verified with spm_stream_extract, so nothing
# is stored on disk (§8, §14). The tarball wraps its contents in a single
# "nvim-linux-<arch>/" directory, which is flattened so links resolve against the
# app root: the "nvim" binary at bin/ finds its runtime at ../share/nvim and its
# lib at ../lib/nvim relative to itself, so the flattened layout (bin/, lib/,
# share/ under $SPM_STAGE) is what the binary expects. (§7.3: write only under
# $SPM_STAGE, link with spm_link, never write absolute paths into $SPM_STAGE.)
set -Eeuo pipefail

# shellcheck disable=SC1091
. "$SPM_HELPERS/http.sh"
# shellcheck disable=SC1091
. "$SPM_HELPERS/link.sh"

spm_stream_extract "$SPM_URL" "$SPM_SHA256" "$SPM_STAGE" -xzf -

# Flatten the top-level wrapper directory (e.g. nvim-linux-x86_64/). Moving
# every entry out leaves the directory empty; rmdir removes only that empty,
# recipe-scoped staging path (no recursive deletion of arbitrary trees).
for d in "$SPM_STAGE"/nvim-linux-*/; do
	[ -d "$d" ] || continue
	find "$d" -mindepth 1 -maxdepth 1 -exec mv -t "$SPM_STAGE" {} +
	rmdir "$d"
done

spm_link bin/nvim nvim
