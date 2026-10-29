#!/usr/bin/env bash
# Recipe: tmux (pythops/tmux-linux-binary), a terminal multiplexer. Resolves
# the latest release from GitHub releases, taking the SHA256 from each asset's
# `digest` field (pythops publishes digests as "sha256:<hex>" for v3.6 and
# later, so the "sha256:" prefix is stripped) and the size from a HEAD request.
# Releases before v3.6 carry a null digest, so the recipe falls back to
# spm_http_sha256 (trust on first use, §14) in that case.
#
# The tag regex matches pythops' tag scheme -- "v<major>.<minor>[a-z]?", e.g.
# v3.6b, v3.6a, v3.6 -- and is anchored at the end so any future hyphenated
# pre-release tags (e.g. v3.7-rc1) or dotted patch tags (e.g. v3.6.1) are
# excluded. Releases come back newest-first, so the first match is the latest.
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

repo="pythops/tmux-linux-binary"
# Match pythops' tag scheme (v3.6b, v3.6a, v3.6 ...) and reject anything with a
# trailing pre-release/patch suffix by anchoring at end of the tag.
tag_re='v[0-9]+\.[0-9]+[a-z]?$'

# Resolve x86_64 first; its tag becomes the package version.
res=$(spm_github_find_asset "$repo" "$tag_re" \
	'tmux-linux-x86_64$' "$SPM_REQUESTED_VERSION")
version=$(printf '%s' "$res" | jq -r '.version')
url_x=$(printf '%s' "$res" | jq -r '.url')
digest_x=$(printf '%s' "$res" | jq -r '.digest')
# pythops publishes digests as "sha256:<hex>" (v3.6+); strip the algorithm
# prefix to get a raw 64-hex sha256 for the pin. When no digest is present
# (older releases), fall back to trust-on-first-use via spm_http_sha256 (§14).
if [ "$digest_x" = "null" ] || [ -z "$digest_x" ]; then
	sha_x=$(spm_http_sha256 "$url_x")
else
	sha_x="${digest_x#sha256:}"
fi
size_x=$(spm_http_size "$url_x" 2>/dev/null || true)

# aarch64 uses the same release (the tag matches [requested] identically).
res_a=$(spm_github_find_asset "$repo" "$tag_re" \
	'tmux-linux-arm64$' "$SPM_REQUESTED_VERSION")
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
