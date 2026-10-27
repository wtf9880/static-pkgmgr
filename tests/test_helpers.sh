#!/usr/bin/env bash
# tests/test_helpers.sh -- tests for helpers/artifact.sh, http.sh, link.sh (§8).
set -Eeuo pipefail
: "${SPM_ROOT:=$(readlink -f "$(dirname "${BASH_SOURCE[0]}")/..")}"
export SPM_ROOT
. "$SPM_ROOT/tests/lib.sh"
. "$SPM_ROOT/helpers/artifact.sh"
. "$SPM_ROOT/helpers/http.sh"
. "$SPM_ROOT/helpers/link.sh"
. "$SPM_ROOT/helpers/checksums.sh"
. "$SPM_ROOT/helpers/git.sh"
. "$SPM_ROOT/helpers/github.sh"

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

# --- spm_http_size / spm_http_sha256 (file://, §8) ---------------------------
# Real curl + file:// fixtures; no network.
sha=$(sha256sum "$FX" | cut -d' ' -f1)
size=$(wc -c < "$FX" | tr -d ' ')
spm_eq "$(spm_http_size "$url")" "$size" \
	|| spm_fail "spm_http_size should report the file size"
size_rc=0
spm_http_size "file:///nonexistent/no-such.tar.gz" >/dev/null 2>&1 || size_rc=$?
spm_ne "$size_rc" 0 || spm_fail "spm_http_size should fail on a missing file"
spm_eq "$(spm_http_sha256 "$url")" "$sha" \
	|| spm_fail "spm_http_sha256 should match sha256sum"
sha_rc=0
spm_http_sha256 "file:///nonexistent/no-such.tar.gz" >/dev/null 2>&1 || sha_rc=$?
spm_ne "$sha_rc" 0 || spm_fail "spm_http_sha256 should fail on a missing file"

# --- spm_sha256_from_checksums (file:// SHASUMS, §8) -------------------------
SBX=$(mktemp -dt sums.XXXXXX)
printf '%s  %s\n' "$sha" "$(basename "$FX")" > "$SBX/SHASUMS256.txt"
sum_url="file://$SBX/SHASUMS256.txt"
spm_eq "$(spm_sha256_from_checksums "$sum_url" "$(basename "$FX")")" "$sha" \
	|| spm_fail "sha256_from_checksums should find the local entry"
sbx_rc=0
spm_sha256_from_checksums "$sum_url" "no-such-entry" >/dev/null 2>&1 || sbx_rc=$?
spm_ne "$sbx_rc" 0 || spm_fail "sha256_from_checksums should fail on missing entry"
rm -rf "$SBX"

# --- spm_git_latest_tag (local git repo, §8) ---------------------------------
# git ls-remote works against a local repository path, so this is fully offline.
SBX=$(mktemp -dt git.XXXXXX)
git init -q "$SBX" >/dev/null 2>&1
git -C "$SBX" config user.email test@example.com
git -C "$SBX" config user.name test
printf 'x\n' > "$SBX/f"
git -C "$SBX" add f
git -C "$SBX" commit -qm init >/dev/null 2>&1
git -C "$SBX" tag -a v1.0.0 -m1
git -C "$SBX" tag v1.10.0
git -C "$SBX" tag v2.0.0
# Latest (newest-first sort) match.
spm_eq "$(spm_git_latest_tag "$SBX" 'v[0-9.]+')" "v2.0.0" \
	|| spm_fail "git_latest_tag should return the newest matching tag"
# Version order is numeric (v1.10.0 > v1.2.0 > v1.0.0).
git -C "$SBX" tag v1.2.0
spm_eq "$(spm_git_latest_tag "$SBX" 'v[0-9.]+')" "v2.0.0" \
	|| spm_fail "git_latest_tag should pick v2.0.0 over v1.10.0"
# A specific requested version pins the tag (v-prefixed or bare).
spm_eq "$(spm_git_latest_tag "$SBX" 'v[0-9.]+' '1.10.0')" "v1.10.0" \
	|| spm_fail "git_latest_tag should honour a requested version"
gt_rc=0
spm_git_latest_tag "$SBX" 'v[0-9]+\.[0-9]+\.[0-9]+' >/dev/null 2>&1 || gt_rc=$?
spm_eq "$gt_rc" 0 || spm_fail "git_latest_tag: none of the tags is 3-part"
# No matching tag -> non-zero.
nomatch=0
spm_git_latest_tag "$SBX" 'zzz' >/dev/null 2>&1 || nomatch=$?
spm_ne "$nomatch" 0 || spm_fail "git_latest_tag should fail when no tag matches"
rm -rf "$SBX"

# --- spm_github_find_asset (fake curl serving canned releases, §8) -----------
# Uses tests/fixtures/fakebin/curl plus a canned releases JSON.
_SPM_PATH_PRE="$PATH"
_SPM_GH_FIX=$(mktemp -dt ghfix.XXXXXX)
cat > "$_SPM_GH_FIX/ripgrep-releases.json" <<'JSON'
[
  {"tag_name":"v2.0.0","name":"2.0.0","assets":[
    {"name":"ripgrep-2.0.0-x86_64-unknown-linux-musl.tar.gz","browser_download_url":"https://github.com/sharkdp/ripgrep/releases/download/v2.0.0/rg-x86_64.tgz","digest":"deadbeef"},
    {"name":"ripgrep-2.0.0-aarch64-unknown-linux-musl.tar.gz","browser_download_url":"https://github.com/sharkdp/ripgrep/releases/download/v2.0.0/rg-aarch64.tgz","digest":"deadbeef"}]},
  {"tag_name":"v1.2.3","name":"1.2.3","assets":[
    {"name":"ripgrep-1.2.3-x86_64-unknown-linux-musl.tar.gz","browser_download_url":"https://github.com/sharkdp/ripgrep/releases/download/v1.2.3/rg-x86_64.tgz","digest":"cafef00d"}]},
  {"tag_name":"notag","name":"notag","assets":[]}
]
JSON
SPM_FAKE_FIXTURES="$_SPM_GH_FIX"
export SPM_FAKE_FIXTURES
PATH="$SPM_ROOT/tests/fixtures/fakebin:$PATH"
export PATH
# Latest matching tag -> newest release (v2.0.0).
out=$(spm_github_find_asset sharkdp/ripgrep 'v[0-9]+\.[0-9]+\.[0-9]+' '.*x86_64.*\.tar\.gz')
spm_eq "$(printf '%s' "$out" | jq -r '.version')" "2.0.0" \
	|| spm_fail "github_find_asset latest version wrong"
spm_eq "$(printf '%s' "$out" | jq -r '.digest')" "deadbeef" \
	|| spm_fail "github_find_asset latest digest wrong"
spm_eq "$(printf '%s' "$out" | jq -r '.tag')" "v2.0.0" \
	|| spm_fail "github_find_asset latest tag wrong"
spm_eq "$(printf '%s' "$out" | jq -r '.name')" "ripgrep-2.0.0-x86_64-unknown-linux-musl.tar.gz" \
	|| spm_fail "github_find_asset latest asset name wrong"
# Requested version pins to a specific release.
out=$(spm_github_find_asset sharkdp/ripgrep 'v[0-9]+\.[0-9]+\.[0-9]+' '.*x86_64.*\.tar\.gz' '1.2.3')
spm_eq "$(printf '%s' "$out" | jq -r '.version')" "1.2.3" \
	|| spm_fail "github_find_asset requested version wrong"
spm_eq "$(printf '%s' "$out" | jq -r '.digest')" "cafef00d" \
	|| spm_fail "github_find_asset requested digest wrong"
# No matching tag regex -> non-zero.
gh_tag_rc=0
spm_github_find_asset sharkdp/ripgrep 'zzz' '.*' >/dev/null 2>&1 || gh_tag_rc=$?
spm_ne "$gh_tag_rc" 0 || spm_fail "github_find_asset should fail on a tag regex with no match"
# No matching asset -> non-zero.
gh_asset_rc=0
spm_github_find_asset sharkdp/ripgrep 'v[0-9.]+' 'no-such-asset' >/dev/null 2>&1 || gh_asset_rc=$?
spm_ne "$gh_asset_rc" 0 || spm_fail "github_find_asset should fail on an asset regex with no match"
PATH="$_SPM_PATH_PRE"
unset SPM_FAKE_FIXTURES
rm -rf "$_SPM_GH_FIX"

spm_end
