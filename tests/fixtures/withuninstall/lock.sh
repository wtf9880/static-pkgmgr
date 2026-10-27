#!/usr/bin/env bash
# Fixture recipe: resolves lock metadata for the helloapp package.
# Used by Phase 1 tests with SPM_TEST_MODE=1 (file:// URLs).
set -Eeuo pipefail

# SPM_HELPERS is a runtime path, so shellcheck cannot follow the source.
# shellcheck disable=SC1091
. "$SPM_HELPERS/artifact.sh"

# Locate this recipe's directory (the core runs us with a fresh CWD, so we
# resolve our own path) and build a file:// URL to the bundled archive.
mydir=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
archive="$mydir/app.tar.gz"
url="file://$archive"

sha=$(sha256sum "$archive" | cut -d' ' -f1)
size=$(wc -c < "$archive")

art_x86=$(spm_artifact x86_64 "$url" "$sha" "$size")
art_arm=$(spm_artifact aarch64 "$url" "$sha" "$size")
artifacts=$(printf '%s\n%s\n' "$art_x86" "$art_arm" | jq -s 'add')

printf '%s' "$(jq -n --arg version "1.0.0" --argjson artifacts "$artifacts" \
	'{version: $version, artifacts: $artifacts}')"
