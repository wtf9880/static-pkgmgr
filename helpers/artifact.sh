# helpers/artifact.sh -- spm_artifact (§8).
#
# This file is sourced by recipes (into the recipe subprocess). It must not
# alter the caller's shell options.
# shellcheck shell=bash

# Build a JSON fragment for one architecture's artifact.
#   spm_artifact <arch> <url> <sha256> <size>
# Prints: {"<arch>":{"url":...,"sha256":...,"size":<size|null>}}
# <size> empty -> JSON null.
# shellcheck disable=SC2312 # return value of jq is the command's success
spm_artifact() {
	local arch="$1" url="$2" sha="$3" size="$4"
	local size_json
	if [ -z "$size" ]; then
		size_json="null"
	else
		size_json="$size"
	fi
	jq -nc --arg arch "$arch" --arg url "$url" --arg sha "$sha" \
		--argjson size "$size_json" \
		'{($arch): {url: $url, sha256: $sha, size: $size}}'
}
