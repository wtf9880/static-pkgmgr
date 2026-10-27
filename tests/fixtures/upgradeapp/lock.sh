#!/usr/bin/env bash
# Fixture recipe: resolves lock metadata for the upgradeapp package.
# Produces v1.0.0 when SPM_REQUESTED_VERSION=1.0.0, otherwise v2.0.0, so tests
# can install v1 and then resolve/upgrade to v2. Used by Phase 3 tests.
set -Eeuo pipefail

# SPM_HELPERS is a runtime path, so shellcheck cannot follow the source.
# shellcheck disable=SC1091
. "$SPM_HELPERS/artifact.sh"

mydir=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
if [ "$SPM_REQUESTED_VERSION" = "1.0.0" ]; then
	archive="$mydir/app_v1.tar.gz"
	version="1.0.0"
else
	archive="$mydir/app_v2.tar.gz"
	version="2.0.0"
fi
url="file://$archive"

sha=$(sha256sum "$archive" | cut -d' ' -f1)
size=$(wc -c < "$archive")

art_x86=$(spm_artifact x86_64 "$url" "$sha" "$size")
art_arm=$(spm_artifact aarch64 "$url" "$sha" "$size")
artifacts=$(printf '%s\n%s\n' "$art_x86" "$art_arm" | jq -s 'add')

printf '%s' "$(jq -n --arg version "$version" --argjson artifacts "$artifacts" \
	'{version: $version, artifacts: $artifacts}')"
