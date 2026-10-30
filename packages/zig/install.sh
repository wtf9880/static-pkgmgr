#!/usr/bin/env bash
# Recipe: install Zig from its linux-<arch> tarball into $SPM_STAGE. (§7.3)
# The archive is streamed and SHA256-verified with spm_stream_extract, so nothing
# is stored on disk (§8, §14). zig ships xz-compressed tarballs that wrap their
# contents in a single "zig-*-linux-<ver>/" directory -- the arch/word order in
# the name has varied across releases (e.g. zig-linux-x86_64-0.14.0 vs
# zig-x86_64-linux-0.17.0), but the "zig-" prefix is constant -- so the glob
# "zig-*/" matches every release's wrapper. Flattening puts the "zig" binary at
# the app root next to lib/ (compiler stdlib), which is the layout the binary
# expects. (§7.3: write only under $SPM_STAGE, link with spm_link, never write
# absolute paths into $SPM_STAGE.)
set -Eeuo pipefail

# shellcheck disable=SC1091
. "$SPM_HELPERS/http.sh"
# shellcheck disable=SC1091
. "$SPM_HELPERS/link.sh"

spm_stream_extract "$SPM_URL" "$SPM_SHA256" "$SPM_STAGE" -xJf -

# Flatten the top-level wrapper directory (e.g. zig-x86_64-linux-0.17.0/). The
# glob "zig-*/" (trailing slash = directories only) matches the wrapper but not
# the flattened "zig" binary, which is a file and lacks the "zig-" prefix.
# Moving every entry out leaves the directory empty, so rmdir removes only that
# empty, recipe-scoped staging path (no recursive deletion of arbitrary trees).
for d in "$SPM_STAGE"/zig-*/; do
	[ -d "$d" ] || continue
	find "$d" -mindepth 1 -maxdepth 1 -exec mv -t "$SPM_STAGE" {} +
	rmdir "$d"
done

spm_link zig zig
