#!/usr/bin/env bash
# Recipe: ripgrep (rg) from GitHub releases. Uses spm_github_find_asset to
# locate the release by tag and the asset by architecture-specific regex; the
# asset's `digest` supplies the SHA256 when present, otherwise the recipe falls
# back to spm_http_sha256 (trust on first use, §14). (§7.2, §8)
#
# Run by the core with a fresh CWD and SPM_HELPERS/SPM_REQUESTED_VERSION set.
set -Eeuo pipefail

# shellcheck disable=SC1091
. "$SPM_HELPERS/github.sh"
# shellcheck disable=SC1091
. "$SPM_HELPERS/http.sh"
# shellcheck disable=SC1091
. "$SPM_HELPERS/artifact.sh"

repo="sharkdp/ripgrep"
tag_re='v[0-9]+\.[0-9]+\.[0-9]+'

# Resolve x86_64 first; its tag becomes the package version.
res=$(spm_github_find_asset "$repo" "$tag_re" \
	'.*x86_64-unknown-linux-musl.*\.tar\.gz' "$SPM_REQUESTED_VERSION")
version=$(printf '%s' "$res" | jq -r '.version')
url_x=$(printf '%s' "$res" | jq -r '.url')
digest_x=$(printf '%s' "$res" | jq -r '.digest')
if [ "$digest_x" = "null" ]; then
	sha_x=$(spm_http_sha256 "$url_x")
else
	sha_x="$digest_x"
fi
size_x=$(spm_http_size "$url_x" 2>/dev/null || true)

# aarch64 uses the same release (the tag matches [requested] identically).
res_a=$(spm_github_find_asset "$repo" "$tag_re" \
	'.*aarch64-unknown-linux-musl.*\.tar\.gz' "$SPM_REQUESTED_VERSION")
url_a=$(printf '%s' "$res_a" | jq -r '.url')
digest_a=$(printf '%s' "$res_a" | jq -r '.digest')
if [ "$digest_a" = "null" ]; then
	sha_a=$(spm_http_sha256 "$url_a")
else
	sha_a="$digest_a"
fi
size_a=$(spm_http_size "$url_a" 2>/dev/null || true)

art_x=$(spm_artifact x86_64 "$url_x" "$sha_x" "$size_x")
art_a=$(spm_artifact aarch64 "$url_a" "$sha_a" "$size_a")
artifacts=$(printf '%s\n%s\n' "$art_x" "$art_a" | jq -s 'add')
printf '%s' "$(jq -nc --arg version "$version" --argjson artifacts "$artifacts" \
	'{version: $version, artifacts: $artifacts}')"
