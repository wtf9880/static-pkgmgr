#!/usr/bin/env bash
# Recipe: install Node.js from its linux-x64/arm64 tarball into $SPM_STAGE.
# (§7.3) The archive is streamed and SHA256-verified with spm_stream_extract,
# so nothing is stored on disk (§14). The tarball wraps its contents in a
# single "node-v<ver>-linux-<arch>/" directory, which is flattened so links
# resolve against the app root. (§7.3: write only under $SPM_STAGE, link with
# spm_link, never write absolute paths into $SPM_STAGE.)
set -Eeuo pipefail

# shellcheck disable=SC1091
. "$SPM_HELPERS/http.sh"
# shellcheck disable=SC1091
. "$SPM_HELPERS/link.sh"

spm_stream_extract "$SPM_URL" "$SPM_SHA256" "$SPM_STAGE" -xJf -

# Flatten the versioned top-level directory.
for d in "$SPM_STAGE"/node-v*/; do
	[ -d "$d" ] || continue
	find "$d" -mindepth 1 -maxdepth 1 -exec mv -t "$SPM_STAGE" {} +
	rm -rf "$d"
done

spm_link bin/node node
spm_link bin/npm npm
