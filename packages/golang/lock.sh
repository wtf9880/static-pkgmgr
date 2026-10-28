#!/usr/bin/env bash
# Recipe: Go toolchain. Resolves the version, SHA256, and size from the go.dev
# release manifest (https://go.dev/dl/?mode=json) in a single fetch. The
# manifest lists stable releases newest-first, and every file entry carries its
# sha256 and size, so the latest version is .[0].version (with the leading "go"
# stripped, e.g. go1.27.3 -> 1.27.3, the same convention Node uses without its
# "v"). A bare requested version (e.g. "1.27.3", without the "go" prefix) pins a
# release. Downloads live on
# https://go.dev/dl/go<version>.linux-{amd64,arm64}.tar.gz.
#
# The manifest only lists the newest releases, so a requested version that is
# absent from it falls back to spm_http_sha256 / spm_http_size (trust on first
# use, §14). Upstream checksums are otherwise preferred over TOFU (§14).
#
# Run by the core with a fresh CWD and SPM_HELPERS/SPM_REQUESTED_VERSION set.
# (§7.2, §8)
set -Eeuo pipefail

# shellcheck disable=SC1091
. "$SPM_HELPERS/http.sh"
# shellcheck disable=SC1091
. "$SPM_HELPERS/artifact.sh"

# One manifest fetch gives the version + checksums for every architecture.
meta=$(curl -fsSL "https://go.dev/dl/?mode=json")

if [ -n "$SPM_REQUESTED_VERSION" ]; then
	version="$SPM_REQUESTED_VERSION"
else
	# Newest stable entry first (the manifest is sorted newest-first); strip
	# the leading "go" so the pin stores a bare version like nodejs does.
	version=$(printf '%s' "$meta" | jq -r '.[0].version' | sed 's/^go//')
fi
[ -n "$version" ] || { printf 'golang: could not resolve version\n' >&2; exit 1; }

# go.dev/dl/go<version>.linux-{amd64,arm64}.tar.gz
dl_tag="go$version"

arts=()
# The archive filename embeds the GOOS/GOARCH, e.g. go1.27.3.linux-amd64.tar.gz.
for pair in "x86_64:amd64" "aarch64:arm64"; do
	arch="${pair%%:*}"
	lnx="${pair#*:}"
	fname="$dl_tag.linux-$lnx.tar.gz"
	url="https://go.dev/dl/$fname"
	sha=$(printf '%s' "$meta" | jq -r --arg v "$dl_tag" --arg f "$fname" \
		'.[] | select(.version == $v) | .files[] | select(.filename == $f) | .sha256' 2>/dev/null || true)
	size=$(printf '%s' "$meta" | jq -r --arg v "$dl_tag" --arg f "$fname" \
		'.[] | select(.version == $v) | .files[] | select(.filename == $f) | .size // empty' 2>/dev/null || true)
	# Fall back to trust-on-first-use when the manifest lacks this version.
	if [ -z "$sha" ] || [ "$sha" = "null" ]; then
		sha=$(spm_http_sha256 "$url")
	fi
	[ -n "$size" ] || size=$(spm_http_size "$url" 2>/dev/null || true)
	art=$(spm_artifact "$arch" "$url" "$sha" "$size")
	arts+=("$art")
done

artifacts=$(printf '%s\n' "${arts[@]}" | jq -s 'add')
printf '%s' "$(jq -nc --arg version "$version" --argjson artifacts "$artifacts" \
	'{version: $version, artifacts: $artifacts}')"
