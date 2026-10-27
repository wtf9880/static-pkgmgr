#!/usr/bin/env bash
# Fixture recipe: installs helloapp by streaming+verifying the tarball into
# $SPM_STAGE, then recording a link via spm_link. Used by Phase 1 tests.
set -Eeuo pipefail

# SPM_HELPERS is a runtime path, so shellcheck cannot follow these sources.
# shellcheck disable=SC1091
. "$SPM_HELPERS/http.sh"
# shellcheck disable=SC1091
. "$SPM_HELPERS/link.sh"

# Stream the archive, verify sha256, and extract into the staging dir.
# tar args include -f - so tar reads curl's stream from stdin.
spm_stream_extract "$SPM_URL" "$SPM_SHA256" "$SPM_STAGE" -xzf -

# Record the links we want the core to create (after the tree is moved).
spm_link bin/hello hello
