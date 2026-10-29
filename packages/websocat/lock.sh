#!/usr/bin/env bash
# Recipe: websocat (vi/websocat), a WebSocket command-line client and debugging
# tool. Resolves the latest release from GitHub releases, taking the SHA256 from
# each asset's `digest` field (websocat publishes digests as "sha256:<hex>",
# so the "sha256:" prefix is stripped) and the size from a HEAD request.
#
# The tag regex is anchored to the end of the tag so pre-release and alpha tags
# (v4.0.0-alpha3, v4.0.0-alpha2, ..., v3.0.0-prealpha0, v2.0.0-alpha0) that are
# interleaved newest-first in the release list are skipped; releases come back
# newest-first, so the first stable match is the latest stable release.
# (§7.2, §8, §14)
#
# Run by the core with a fresh CWD and SPM_HELPERS/SPM_REQUESTED_VERSION set.
set -Eeuo pipefail

# shellcheck disable=SC1091
. "$SPM_HELPERS/github.sh"
# shellcheck disable=SC1091
. "$SPM_HELPERS/http.sh"
# shellcheck disable=SC1091
. "$SPM_HELPERS/artifact.sh"

repo="vi/websocat"
# Anchor the version to the end so only stable (non-pre-release) tags match.
tag_re='v[0-9]+\.[0-9]+\.[0-9]+$'

# Resolve x86_64 first; its tag becomes the package version.
res=$(spm_github_find_asset "$repo" "$tag_re" \
	'websocat\.x86_64-unknown-linux-musl' "$SPM_REQUESTED_VERSION")
version=$(printf '%s' "$res" | jq -r '.version')
url_x=$(printf '%s' "$res" | jq -r '.url')
digest_x=$(printf '%s' "$res" | jq -r '.digest')
# websocat publishes digests as "sha256:<hex>"; strip the algorithm prefix to
# get a raw 64-hex sha256 for the pin. When no digest is present, fall back to
# trust-on-first use via spm_http_sha256 (§14).
if [ "$digest_x" = "null" ] || [ -z "$digest_x" ]; then
	sha_x=$(spm_http_sha256 "$url_x")
else
	sha_x="${digest_x#sha256:}"
fi
size_x=$(spm_http_size "$url_x" 2>/dev/null || true)

# aarch64 uses the same release (the tag matches [requested] identically).
res_a=$(spm_github_find_asset "$repo" "$tag_re" \
	'websocat\.aarch64-unknown-linux-musl' "$SPM_REQUESTED_VERSION")
url_a=$(printf '%s' "$res_a" | jq -r '.url')
digest_a=$(printf '%s' "$res_a" | jq -r '.digest')
if [ "$digest_a" = "null" ] || [ -z "$digest_a" ]; then
	sha_a=$(spm_http_sha256 "$url_a")
else
	sha_a="${digest_a#sha256:}"
fi
size_a=$(spm_http_size "$url_a" 2>/dev/null || true)

art_x=$(spm_artifact x86_64 "$url_x" "$sha_x" "$size_x")
art_a=$(spm_artifact aarch64 "$url_a" "$sha_a" "$size_a")
artifacts=$(printf '%s\n%s\n' "$art_x" "$art_a" | jq -s 'add')
printf '%s' "$(jq -nc --arg version "$version" --argjson artifacts "$artifacts" \
	'{version: $version, artifacts: $artifacts}')"
