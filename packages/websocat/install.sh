#!/usr/bin/env bash
# Recipe: install websocat from its prebuilt GitHub release binary into
# $SPM_STAGE. (§7.3) The release asset is a plain executable binary (an
# "application/octet-stream" with no archive wrapper), so it cannot be streamed
# through tar the way tarball packages are (§8: spm_stream_extract is for tar
# archives). Instead, spm_download_verified fetches the binary to a mktemp'd
# file in $SPM_STAGE's parent (same filesystem, so the move is a rename),
# verifies its SHA256, and the recipe places the binary under bin/ with the
# link recorded via spm_link. The download file is consumed by the rename, so
# nothing is stored on disk after success. (§7.3, §8, §14)
set -Eeuo pipefail

# shellcheck disable=SC1091
. "$SPM_HELPERS/http.sh"
# shellcheck disable=SC1091
. "$SPM_HELPERS/link.sh"

# Fetch the binary to a temp file in $SPM_STAGE's parent so the move into the
# staging tree is a same-filesystem rename (§11). spm_download_verified removes
# the temp file on download or hash failure.
tmp_bin=$(mktemp -p "$(dirname "$SPM_STAGE")" websocat.XXXXXX)
spm_download_verified "$SPM_URL" "$SPM_SHA256" "$tmp_bin"

mkdir -p "$SPM_STAGE/bin"
mv -f -- "$tmp_bin" "$SPM_STAGE/bin/websocat"
chmod +x "$SPM_STAGE/bin/websocat"

spm_link bin/websocat websocat
