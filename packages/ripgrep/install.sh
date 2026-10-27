#!/usr/bin/env bash
# Recipe: install ripgrep (rg) from its GitHub release tarball into $SPM_STAGE.
# (§7.3) The archive is streamed and SHA256-verified with spm_stream_extract
# (§14). ripgrep tarballs wrap their contents in a single
# "ripgrep-<ver>-<triple>/" directory, which is flattened so links resolve
# against the app root.
set -Eeuo pipefail

# shellcheck disable=SC1091
. "$SPM_HELPERS/http.sh"
# shellcheck disable=SC1091
. "$SPM_HELPERS/link.sh"

spm_stream_extract "$SPM_URL" "$SPM_SHA256" "$SPM_STAGE" -xzf -

# Flatten the versioned top-level directory.
for d in "$SPM_STAGE"/ripgrep-*/; do
	[ -d "$d" ] || continue
	find "$d" -mindepth 1 -maxdepth 1 -exec mv -t "$SPM_STAGE" {} +
	rm -rf "$d"
done

spm_link rg rg
