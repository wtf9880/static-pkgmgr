# helpers/http.sh -- streaming download/extract and verified download (§8).
#
# This file is sourced by recipes (into the recipe subprocess). It must not
# alter the caller's shell options.
# shellcheck shell=bash

# spm_stream_extract <url> <sha256> <dest> [tar args...]
# Streams the download through sha256 and extracts into <dest>. Fails on
# download, extract, or hash mismatch. The archive is never stored on disk —
# only the computed hash is written to a temporary file (deleted here).
spm_stream_extract() {
	local url="$1" sha="$2" dest="$3"
	shift 3
	local tmp hash
	tmp=$(mktemp)
	hash=$(mktemp)
	# curl -> tee (split: hash sink + stdout) -> tar. -f makes curl fail on HTTP
	# errors; pipefail (caller's option) surfaces a failing stage.
	if ! curl -fLs "$url" | tee >(sha256sum >"$hash") | tar "$@" -C "$dest"; then
		rm -f "$tmp" "$hash"
		printf 'spm_stream_extract: download or extraction failed: %s\n' "$url" >&2
		return 1
	fi
	# Reap the hash process so the file is complete.
	wait 2>/dev/null || true
	local got=""
	if [ -s "$hash" ]; then
		read -r got _ < "$hash" || true
	fi
	rm -f "$tmp" "$hash"
	if [ "$got" != "$sha" ]; then
		printf 'spm_stream_extract: sha256 mismatch for %s: expected %s, got %s\n' \
			"$url" "$sha" "$got" >&2
		return 1
	fi
	return 0
}

# spm_download_verified <url> <sha256> <file>
# Downloads <url> to <file> (a path in $SPM_STAGE's parent), then verifies the
# sha256. For formats that need a seekable file (e.g. zip). The recipe must
# delete <file> after it has extracted from it.
spm_download_verified() {
	local url="$1" sha="$2" file="$3"
	if ! curl -fLs "$url" -o "$file"; then
		rm -f "$file"
		printf 'spm_download_verified: download failed: %s\n' "$url" >&2
		return 1
	fi
	local got
	got=$(sha256sum "$file" | cut -d' ' -f1)
	if [ "$got" != "$sha" ]; then
		rm -f "$file"
		printf 'spm_download_verified: sha256 mismatch for %s: expected %s, got %s\n' \
			"$url" "$sha" "$got" >&2
		return 1
	fi
	return 0
}
