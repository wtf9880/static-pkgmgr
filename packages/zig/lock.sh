#!/usr/bin/env bash
# Recipe: Zig (ziglang.org). Resolves the latest (or requested) stable version
# from the zig download index (https://ziglang.org/download/index.json), an
# object keyed by version with per-version objects holding per-platform entries.
# Each platform entry carries the tarball URL, a bare 64-hex "shasum", and a
# "size" string. The latest stable is the highest version key -- the "master"
# dev-build key is excluded by the numeric filter and a version sort (sort -V)
# orders the keys correctly (e.g. 0.17.0 ranks above 0.9.0). The index supplies
# the upstream SHA256 for every artifact, so no trust-on-first-use fallback is
# needed (§14). (§7.2, §8)
#
# Run by the core with a fresh CWD and SPM_HELPERS/SPM_REQUESTED_VERSION set.
set -Eeuo pipefail

# shellcheck disable=SC1091
. "$SPM_HELPERS/http.sh"
# shellcheck disable=SC1091
. "$SPM_HELPERS/artifact.sh"

index_url="https://ziglang.org/download/index.json"
meta=$(curl -fsSL "$index_url")

# Resolve the version: a requested version, or the newest stable key (the index
# is keyed by version plus a "master" dev-build key; sort -V orders version
# numbers correctly and the numeric filter drops "master"). (§7.2)
if [ -n "$SPM_REQUESTED_VERSION" ]; then
	version="$SPM_REQUESTED_VERSION"
else
	version=$(printf '%s' "$meta" | jq -r 'keys[] | select(test("^[0-9]"))' \
		| sort -V | tail -n 1)
fi
[ -n "$version" ] || { printf 'zig: could not resolve version\n' >&2; exit 1; }
printf '%s' "$meta" | jq -e --arg v "$version" 'has($v)' >/dev/null \
	|| { printf 'zig: version %s not found in index\n' "$version" >&2; exit 1; }

arts=()
# zig tarballs are zig-<plat>-<ver>.tar.xz (e.g. zig-x86_64-linux-0.17.0.tar.xz).
# The index platform keys "x86_64-linux"/"aarch64-linux" map straight to the
# install arch, and the index shasum is already a bare 64-hex string (no prefix
# to strip, unlike the "sha256:<hex>" digests some GitHub releases publish).
for pair in "x86_64:x86_64-linux" "aarch64:aarch64-linux"; do
	arch="${pair%%:*}"
	plat="${pair#*:}"
	entry=$(printf '%s' "$meta" | jq -r --arg v "$version" --arg p "$plat" \
		'.[$v][$p] // empty')
	[ -n "$entry" ] || { printf 'zig: no artifact for %s on %s\n' "$plat" "$version" >&2; exit 1; }
	url=$(printf '%s' "$entry" | jq -r '.tarball')
	sha=$(printf '%s' "$entry" | jq -r '.shasum')
	size=$(printf '%s' "$entry" | jq -r '.size // empty')
	# Fall back to a HEAD request if the index omits the size.
	[ -n "$size" ] || size=$(spm_http_size "$url" 2>/dev/null || true)
	art=$(spm_artifact "$arch" "$url" "$sha" "$size")
	arts+=("$art")
done

artifacts=$(printf '%s\n' "${arts[@]}" | jq -s 'add')
printf '%s' "$(jq -nc --arg version "$version" --argjson artifacts "$artifacts" \
	'{version: $version, artifacts: $artifacts}')"
