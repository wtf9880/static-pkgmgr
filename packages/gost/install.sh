#!/usr/bin/env bash
# Recipe: install gost from its GitHub release tarball into $SPM_STAGE.
# (§7.3) The archive is streamed and SHA256-verified with spm_stream_extract
# (§14). gost tarballs extract their files (LICENSE, README*, and the `gost`
# binary) directly at the top level with no wrapper directory, so no
# flattening is needed: the binary lands at $SPM_STAGE/gost and is linked into
# $BIN_DIR. (§7.3: write only under $SPM_STAGE, link with spm_link, never write
# absolute paths into $SPM_STAGE.)
set -Eeuo pipefail

# shellcheck disable=SC1091
. "$SPM_HELPERS/http.sh"
# shellcheck disable=SC1091
. "$SPM_HELPERS/link.sh"

spm_stream_extract "$SPM_URL" "$SPM_SHA256" "$SPM_STAGE" -xzf -

spm_link gost gost
