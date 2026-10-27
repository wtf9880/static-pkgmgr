# helpers/checksums.sh -- spm_sha256_from_checksums (§8).
#
# This file is sourced by recipes (into the recipe subprocess). It must not
# alter the caller's shell options.
# shellcheck shell=bash

# spm_sha256_from_checksums <checksums_url> <filename>
# Download a SHASUMS-style checksums file and print the SHA256 hex for
# <filename>. These files list one record per line as
# "<sha>  <filename>" (BSD `checksum -p file` style) or "<sha> *<filename>"
# (GNU coreutils `sha256sum` text/binary marker is tolerated). Returns
# non-zero if the download fails or the filename is not listed. (§8, §14:
# upstream checksums are preferred over trust on first use.)
spm_sha256_from_checksums() {
	local url="$1" file="$2" sha=""
	if ! sha=$(curl -fsSL "$url" 2>/dev/null | awk -v f="$file" '
		NF >= 2 { fn = $2; sub(/^\*/, "", fn) }
		fn == f { print $1; exit }
	'); then
		printf 'spm_sha256_from_checksums: download failed: %s\n' "$url" >&2
		return 1
	fi
	if [ -z "$sha" ]; then
		printf 'spm_sha256_from_checksums: no entry for %s in %s\n' "$file" "$url" >&2
		return 1
	fi
	printf '%s\n' "$sha"
}
