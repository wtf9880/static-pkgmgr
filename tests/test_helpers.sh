#!/usr/bin/env bash
# tests/test_helpers.sh -- tests for helpers/artifact.sh, http.sh, link.sh (§8).
set -Eeuo pipefail
: "${SPM_ROOT:=$(readlink -f "$(dirname "${BASH_SOURCE[0]}")/..")}"
export SPM_ROOT
. "$SPM_ROOT/tests/lib.sh"
. "$SPM_ROOT/helpers/artifact.sh"
. "$SPM_ROOT/helpers/http.sh"
. "$SPM_ROOT/helpers/link.sh"

FX="$SPM_ROOT/tests/fixtures/helloapp/app.tar.gz"
sha=$(sha256sum "$FX" | cut -d' ' -f1)
url="file://$FX"

# --- spm_artifact ----------------------------------------------------------
# With an integer size.
out=$(spm_artifact x86_64 "https://example.invalid/a.tar.gz" "$sha" "123")
spm_eq "$(printf '%s' "$out" | jq -r '.x86_64.url')" "https://example.invalid/a.tar.gz" \
	|| spm_fail "spm_artifact url wrong"
spm_eq "$(printf '%s' "$out" | jq -r '.x86_64.sha256')" "$sha" \
	|| spm_fail "spm_artifact sha wrong"
spm_eq "$(printf '%s' "$out" | jq -r '.x86_64.size')" "123" \
	|| spm_fail "spm_artifact size wrong"
spm_eq "$(printf '%s' "$out" | jq -r 'keys | join(",")')" "x86_64" \
	|| spm_fail "spm_artifact should have exactly one arch key"
# Empty size -> JSON null.
out=$(spm_artifact aarch64 "https://example.invalid/a.tar.gz" "$sha" "")
spm_eq "$(printf '%s' "$out" | jq -r '.aarch64.size')" "null" \
	|| spm_fail "spm_artifact size=null wrong"

# --- spm_stream_extract ----------------------------------------------------
# Success: streams + verifies + extracts.
dest=$(mktemp -dt stream-ok.XXXXXX)
spm_true "spm_stream_extract succeeded" \
	spm_stream_extract "$url" "$sha" "$dest" -xzf -
spm_true "extracted bin/hello missing" test -f "$dest/bin/hello"
spm_eq "$("$dest/bin/hello")" "hello from static-pkgmgr fixture" \
	|| spm_fail "extracted hello produced wrong output"
rm -rf "$dest"

# Mismatch: wrong sha256 -> failure. (spm_stream_extract does not clean the
# destination itself; the caller is responsible for that, e.g. the core
# removes $SPM_STAGE on recipe failure.)
dest=$(mktemp -dt stream-bad.XXXXXX)
spm_false "spm_stream_extract should fail on sha mismatch" \
	spm_stream_extract "$url" \
	"0000000000000000000000000000000000000000000000000000000000000000" \
	"$dest" -xzf -
rm -rf "$dest"

# Bad URL -> failure.
dest=$(mktemp -dt stream-404.XXXXXX)
spm_false "spm_stream_extract should fail on bad url" \
	spm_stream_extract "file:///nonexistent/archive.tar.gz" "$sha" "$dest" -xzf -
rm -rf "$dest"

# --- spm_download_verified -------------------------------------------------
dl=$(mktemp -p "${TMPDIR:-/tmp}" dl.XXXXXX)
spm_true "spm_download_verified succeeded" spm_download_verified "$url" "$sha" "$dl"
spm_eq "$(wc -c < "$dl")" "$(wc -c < "$FX")" \
	|| spm_fail "spm_download_verified: file size mismatch"
rm -f "$dl"

# Mismatch -> failure and the file is removed.
dl=$(mktemp -p "${TMPDIR:-/tmp}" dl.XXXXXX)
spm_false "spm_download_verified should fail on sha mismatch" \
	spm_download_verified "$url" \
	"0000000000000000000000000000000000000000000000000000000000000000" "$dl"
spm_false "spm_download_verified left the file on mismatch" test -e "$dl"
rm -f "$dl"

# --- spm_link --------------------------------------------------------------
plan=$(mktemp)
: > "$plan"
SPM_LINK_PLAN="$plan" spm_link bin/hello hello
spm_eq "$(cat "$plan")" $'hello\tbin/hello' \
	|| spm_fail "spm_link plan wrong: [$(cat "$plan")]"
# Appends a second link.
SPM_LINK_PLAN="$plan" spm_link sbin/hi hi
spm_eq "$(cat "$plan")" $'hello\tbin/hello\nhi\tsbin/hi' \
	|| spm_fail "spm_link plan append wrong: [$(cat "$plan")]"
rm -f "$plan"

spm_end
