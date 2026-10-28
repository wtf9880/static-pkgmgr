#!/usr/bin/env bash
# Recipe: install the Go toolchain from its linux-amd64/arm64 tarball into
# $SPM_STAGE. (§7.3) The archive is streamed and SHA256-verified with
# spm_stream_extract, so nothing is stored on disk (§14). The tarball wraps its
# contents in a single "go/" directory, which is flattened so links resolve
# against the app root. (§7.3: write only under $SPM_STAGE, link with spm_link,
# never write absolute paths into $SPM_STAGE.)
set -Eeuo pipefail

# shellcheck disable=SC1091
. "$SPM_HELPERS/http.sh"
# shellcheck disable=SC1091
. "$SPM_HELPERS/link.sh"

spm_stream_extract "$SPM_URL" "$SPM_SHA256" "$SPM_STAGE" -xzf -

# Flatten the single top-level "go/" directory. Its name never carries a
# version (unlike Node's "node-v<ver>-linux-<arch>"), so this is a direct check
# rather than a versioned glob. After moving every entry out, the directory is
# empty and removed with rmdir (not rm -rf), keeping destructive removal
# scoped to a guaranteed-empty, core-managed staging path.
if [ -d "$SPM_STAGE/go" ]; then
	find "$SPM_STAGE/go" -mindepth 1 -maxdepth 1 -exec mv -t "$SPM_STAGE" {} +
	rmdir "$SPM_STAGE/go"
fi

# Go's bin/ holds the toolchain entry points.
spm_link bin/go go
spm_link bin/gofmt gofmt
