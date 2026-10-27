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
	local tmp hash fifo sha_pid
	tmp=$(mktemp)
	hash=$(mktemp)
	# Hash the download in a tracked background job reading from a FIFO. A plain
	# `>(sha256sum)` process substitution is NOT waited on by `wait`, which races
	# `read $hash` and yields an empty digest (flaky sha mismatch). A FIFO plus
	# an explicit `wait $sha_pid` closes the loop. The archive is never stored.
	fifo=$(mktemp -u)
	mkfifo "$fifo"
	sha256sum <"$fifo" >"$hash" &
	sha_pid=$!
	# curl -> tee (split: hash sink via FIFO + stdout -> tar). -f makes curl fail
	# on HTTP errors; pipefail (caller's option) surfaces a failing stage.
	if ! curl -fLs "$url" | tee "$fifo" | tar "$@" -C "$dest"; then
		kill "$sha_pid" 2>/dev/null || true
		wait "$sha_pid" 2>/dev/null || true
		rm -f "$tmp" "$hash" "$fifo"
		printf 'spm_stream_extract: download or extraction failed: %s\n' "$url" >&2
		return 1
	fi
	# Reap the hasher so the hash file is complete before reading it.
	wait "$sha_pid" 2>/dev/null || true
	local got=""
	if [ -s "$hash" ]; then
		read -r got _ < "$hash" || true
	fi
	rm -f "$tmp" "$hash" "$fifo"
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

# spm_http_size <url>
# Print the size in bytes: the last Content-Length seen during a HEAD request
# (following redirects with -L), or nothing when the header is absent. Returns
# non-zero when the request fails or the size cannot be determined. (§8)
spm_http_size() {
	local url="$1" size=""
	# -I sends HEAD, -L follows redirects, -s silences progress. awk keeps the
	# last Content-Length across redirect hops and strips a trailing CR.
	size=$(curl -sIL "$url" 2>/dev/null \
		| awk 'tolower($1) == "content-length:" { v=$2 } END { sub(/\r/, "", v); if (v != "") print v }')
	if [ -n "$size" ]; then
		printf '%s\n' "$size"
		return 0
	fi
	printf 'spm_http_size: no Content-Length: %s\n' "$url" >&2
	return 1
}

# spm_http_sha256 <url>
# Stream the download through the SHA256 hasher and print the hex digest.
# Nothing is written to disk (trust on first use) -- prefer an upstream
# checksum (see spm_sha256_from_checksums) when a recipe publishes one. (§8, §14)
spm_http_sha256() {
	local url="$1" digest=""
	if ! digest=$(curl -fsSL "$url" 2>/dev/null | sha256sum 2>/dev/null); then
		printf 'spm_http_sha256: download failed: %s\n' "$url" >&2
		return 1
	fi
	# sha256sum prints "<hash>  -"; take the first field.
	printf '%s\n' "$digest" | cut -d' ' -f1
}
