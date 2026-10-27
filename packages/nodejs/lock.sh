#!/usr/bin/env bash
# Recipe: Node.js. Resolves the latest (or requested) version from the
# nodejs.org dist index, reads the SHA256 from the upstream SHASUMS256.txt, and
# the size from a HEAD request. Uses spm_sha256_from_checksums (upstream
# checksum is preferred over trust on first use, §14). (§7.2, §8)
#
# Run by the core with a fresh CWD and SPM_HELPERS/SPM_REQUESTED_VERSION set.
set -Eeuo pipefail

# shellcheck disable=SC1091
. "$SPM_HELPERS/http.sh"
# shellcheck disable=SC1091
. "$SPM_HELPERS/checksums.sh"
# shellcheck disable=SC1091
. "$SPM_HELPERS/artifact.sh"

dist="https://nodejs.org/dist"

# Resolve the version: a requested version, or the newest from the index.
if [ -n "$SPM_REQUESTED_VERSION" ]; then
	ver="$SPM_REQUESTED_VERSION"
else
	ver=$(curl -fsSL "$dist/index.json" | jq -r '.[0].version' | sed 's/^v//')
fi
[ -n "$ver" ] || { echo "nodejs: could not resolve version" >&2; exit 1; }

# nodejs.org publishes one SHASUMS256.txt per version.
sums="$dist/v$ver/SHASUMS256.txt"

# Build one artifact entry per supported architecture.
arts=()
# nodesjs.org names archives node-v<ver>-linux-x64.tar.xz / -linux-arm64.tar.xz
# (the "linux-" is already in the name, so the suffix is just x64/arm64).
for pair in "x86_64:x64" "aarch64:arm64"; do
	arch="${pair%%:*}"
	lnx="${pair#*:}"
	fname="node-v$ver-linux-$lnx.tar.xz"
	url="$dist/v$ver/$fname"
	sha=$(spm_sha256_from_checksums "$sums" "$fname")
	size=$(spm_http_size "$url" 2>/dev/null || true)
	art=$(spm_artifact "$arch" "$url" "$sha" "$size")
	arts+=("$art")
done

artifacts=$(printf '%s\n' "${arts[@]}" | jq -s 'add')
printf '%s' "$(jq -nc --arg version "$ver" --argjson artifacts "$artifacts" \
	'{version: $version, artifacts: $artifacts}')"
