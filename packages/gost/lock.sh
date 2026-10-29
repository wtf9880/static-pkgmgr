#!/usr/bin/env bash
# Recipe: gost (GO Simple Tunnel), a Go-based proxy tool. Resolves the latest
# (or requested) release from GitHub releases, takes the SHA256 from the
# upstream checksums.txt published per release (preferred over trust on first
# use, §14), and the size from a HEAD request. The release assets carry no
# GitHub `digest`, so the upstream checksums file is the checksum source.
# (§7.2, §8)
#
# Run by the core with a fresh CWD and SPM_HELPERS/SPM_REQUESTED_VERSION set.
set -Eeuo pipefail

# shellcheck disable=SC1091
. "$SPM_HELPERS/github.sh"
# shellcheck disable=SC1091
. "$SPM_HELPERS/http.sh"
# shellcheck disable=SC1091
. "$SPM_HELPERS/checksums.sh"
# shellcheck disable=SC1091
. "$SPM_HELPERS/artifact.sh"

repo="ginuerzh/gost"
tag_re='v[0-9]+\.[0-9]+\.[0-9]+'

# Resolve x86_64 first; its tag becomes the package version. gost publishes both
# linux_amd64 and linux_amd64v3 archives; anchor the extension so the v3
# variant is never selected.
res=$(spm_github_find_asset "$repo" "$tag_re" \
	'.*linux_amd64\.tar\.gz' "$SPM_REQUESTED_VERSION")
version=$(printf '%s' "$res" | jq -r '.version')
tag=$(printf '%s' "$res" | jq -r '.tag')
url_x=$(printf '%s' "$res" | jq -r '.url')
# gost signs no assets on GitHub; checksums.txt ( "<sha>  <file>", §8) is the
# upstream SHA256 source. One file covers every architecture.
sums="https://github.com/$repo/releases/download/$tag/checksums.txt"
sha_x=$(spm_sha256_from_checksums "$sums" "$(basename "$url_x")")
size_x=$(spm_http_size "$url_x" 2>/dev/null || true)

# aarch64 uses the same release (the tag matches [requested] identically).
res_a=$(spm_github_find_asset "$repo" "$tag_re" \
	'.*linux_arm64\.tar\.gz' "$SPM_REQUESTED_VERSION")
url_a=$(printf '%s' "$res_a" | jq -r '.url')
sha_a=$(spm_sha256_from_checksums "$sums" "$(basename "$url_a")")
size_a=$(spm_http_size "$url_a" 2>/dev/null || true)

art_x=$(spm_artifact x86_64 "$url_x" "$sha_x" "$size_x")
art_a=$(spm_artifact aarch64 "$url_a" "$sha_a" "$size_a")
artifacts=$(printf '%s\n%s\n' "$art_x" "$art_a" | jq -s 'add')
printf '%s' "$(jq -nc --arg version "$version" --argjson artifacts "$artifacts" \
	'{version: $version, artifacts: $artifacts}')"
