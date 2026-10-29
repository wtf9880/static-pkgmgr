#!/usr/bin/env bash
# tests/test_recipes.sh -- Phase-4 recipe tests.
#
# Exercises the real packages/nodejs and packages/ripgrep recipes end-to-end
# against an offline fake curl (tests/fixtures/fakebin/curl) that serves canned
# index/SHASUMS/GitHub-JSON data and the canned archive bytes. The archive
# fixtures are built in a temp dir here so the SHA256 values are always
# self-consistent. No real network is used. (§7, §8, §14)
set -Eeuo pipefail

# SPM_TEST_MODE=1 is set by tests/run.sh; file:// is allowed but the recipes
# use https:// URLs that the fake curl intercepts, so this is just a safety net.
: "${SPM_ROOT:=$(readlink -f "$(dirname "${BASH_SOURCE[0]}")/..")}"
export SPM_ROOT
# Remember the real repository root; spm_setup_test_env re-points SPM_ROOT at
# the throwaway test repo, and we link the real recipes from here.
_REAL_ROOT="$SPM_ROOT"
. "$SPM_ROOT/tests/lib.sh"

# --- build offline fixtures -------------------------------------------------
# Archives with the real top-level directory layout the recipes expect.
SBX=$(mktemp -dt p4.XXXXXX)
export SPM_FAKE_FIXTURES="$SBX"

# nodejs fixture: node-v1.2.3-linux-x64/bin/{node,npm}
mkdir -p "$SBX/node/node-v1.2.3-linux-x64/bin"
printf '#!/usr/bin/env bash\necho "phase4 node v1.2.3 from static-pkgmgr fixture"\n' \
	> "$SBX/node/node-v1.2.3-linux-x64/bin/node"
printf '#!/usr/bin/env bash\necho "phase4 npm from static-pkgmgr fixture"\n' \
	> "$SBX/node/node-v1.2.3-linux-x64/bin/npm"
chmod +x "$SBX/node/node-v1.2.3-linux-x64/bin/node" "$SBX/node/node-v1.2.3-linux-x64/bin/npm"
tar -C "$SBX/node" -cJf "$SBX/phase4node.tar.xz" node-v1.2.3-linux-x64
node_sha=$(sha256sum "$SBX/phase4node.tar.xz" | cut -d' ' -f1)
node_size=$(wc -c < "$SBX/phase4node.tar.xz" | tr -d ' ')

# ripgrep fixture: ripgrep-1.2.3-1-x86_64-unknown-linux-musl/rg
mkdir -p "$SBX/rg/ripgrep-1.2.3-1-x86_64-unknown-linux-musl"
printf '#!/usr/bin/env bash\necho "phase4 ripgrep rg v1.2.3 from static-pkgmgr fixture"\n' \
	> "$SBX/rg/ripgrep-1.2.3-1-x86_64-unknown-linux-musl/rg"
chmod +x "$SBX/rg/ripgrep-1.2.3-1-x86_64-unknown-linux-musl/rg"
tar -C "$SBX/rg" -czf "$SBX/phase4rg.tar.gz" ripgrep-1.2.3-1-x86_64-unknown-linux-musl
rg_sha=$(sha256sum "$SBX/phase4rg.tar.gz" | cut -d' ' -f1)

# Canned index.json: latest is v1.2.3.
cat > "$SBX/nodejs-index.json" <<JSON
[
  {"version":"v1.2.3","date":"2026-01-02","files":["linux-x64","linux-arm64"]},
  {"version":"v1.0.0","date":"2025-01-01","files":["linux-x64"]}
]
JSON
# Canned SHASUMS256.txt: the entry name the recipe looks up, with the fixture
# archive's real sha. The arm64 entry reuses the same sha (the fake curl serves
# the same bytes for both arches; only x86_64 is installed on this host).
cat > "$SBX/nodejs-SHASUMS256.txt" <<SHAS
$node_sha  node-v1.2.3-linux-x64.tar.xz
$node_sha  node-v1.2.3-linux-arm64.tar.xz
SHAS
# Canned GitHub releases for ripgrep. The asset's digest = the fixture sha, so
# the recipe uses it (no spm_http_sha256 fallback needed).
cat > "$SBX/ripgrep-releases.json" <<JSON
[
  {"tag_name":"v1.2.3","name":"1.2.3","assets":[
    {"name":"ripgrep-1.2.3-1-x86_64-unknown-linux-musl.tar.gz","browser_download_url":"https://github.com/sharkdp/ripgrep/releases/download/v1.2.3/ripgrep-1.2.3-1-x86_64-unknown-linux-musl.tar.gz","digest":"$rg_sha"},
    {"name":"ripgrep-1.2.3-1-aarch64-unknown-linux-musl.tar.gz","browser_download_url":"https://github.com/sharkdp/ripgrep/releases/download/v1.2.3/ripgrep-1.2.3-1-aarch64-unknown-linux-musl.tar.gz","digest":"$rg_sha"}]},
  {"tag_name":"v1.0.0","name":"1.0.0","assets":[]}
]
JSON

# golang fixture: go/bin/{go,gofmt} + go/VERSION, wrapped in a single "go/"
# tree (the real Go tarball layout). The fake curl serves golang-dl.json
# (go1.27.3 as the newest manifest entry) plus this archive for both arches.
mkdir -p "$SBX/go/go/bin"
printf '#!/usr/bin/env bash\necho "phase4 go 1.27.3 from static-pkgmgr fixture"\n' \
	> "$SBX/go/go/bin/go"
printf '#!/usr/bin/env bash\necho "phase4 gofmt 1.27.3 from static-pkgmgr fixture"\n' \
	> "$SBX/go/go/bin/gofmt"
printf 'go1.27.3\n' > "$SBX/go/go/VERSION"
chmod +x "$SBX/go/go/bin/go" "$SBX/go/go/bin/gofmt"
tar -C "$SBX/go" -czf "$SBX/phase4golang.tar.gz" go
golang_sha=$(sha256sum "$SBX/phase4golang.tar.gz" | cut -d' ' -f1)
golang_size=$(wc -c < "$SBX/phase4golang.tar.gz" | tr -d ' ')
# Canned go.dev manifest (?mode=json): go1.27.3 with the fixture archive's real
# sha + size for both linux arches (the fake curl serves the same bytes for
# both, exercising the recipe's upstream-checksum path rather than TOFU).
cat > "$SBX/golang-dl.json" <<JSON
[
  {"version":"go1.27.3","stable":true,"files":[
    {"filename":"go1.27.3.linux-amd64.tar.gz","os":"linux","arch":"amd64","version":"go1.27.3","sha256":"$golang_sha","size":$golang_size,"kind":"archive"},
    {"filename":"go1.27.3.linux-arm64.tar.gz","os":"linux","arch":"arm64","version":"go1.27.3","sha256":"$golang_sha","size":$golang_size,"kind":"archive"},
    {"filename":"go1.27.3.src.tar.gz","os":"","arch":"","version":"go1.27.3","sha256":"0000000000000000000000000000000000000000000000000000000000000000","size":1,"kind":"source"}
  ]}
]
JSON

# gost fixture: a single "gost" binary at the top level (the real tarball
# extracts its files directly — LICENSE, README*, gost — with no wrapper
# directory to flatten).
mkdir -p "$SBX/gost"
printf '#!/usr/bin/env bash\necho "phase4 gost v2.12.0 from static-pkgmgr fixture"\n' \
	> "$SBX/gost/gost"
chmod +x "$SBX/gost/gost"
tar -C "$SBX/gost" -czf "$SBX/phase4gost.tar.gz" gost
gost_sha=$(sha256sum "$SBX/phase4gost.tar.gz" | cut -d' ' -f1)
gost_size=$(wc -c < "$SBX/phase4gost.tar.gz" | tr -d ' ')
# Canned GitHub releases for gost. Assets carry no digest, so the recipe reads
# the SHA256 from the upstream checksums.txt fixture (the same real sha for
# both arches; the fake curl serves identical archive bytes). The amd64v3
# asset is included to confirm the recipe's asset regex does not pick it up.
cat > "$SBX/gost-releases.json" <<JSON
[
  {"tag_name":"v2.12.0","name":"v2.12.0","assets":[
    {"name":"checksums.txt","browser_download_url":"https://github.com/ginuerzh/gost/releases/download/v2.12.0/checksums.txt","digest":null},
    {"name":"gost_2.12.0_linux_amd64.tar.gz","browser_download_url":"https://github.com/ginuerzh/gost/releases/download/v2.12.0/gost_2.12.0_linux_amd64.tar.gz","digest":null},
    {"name":"gost_2.12.0_linux_amd64v3.tar.gz","browser_download_url":"https://github.com/ginuerzh/gost/releases/download/v2.12.0/gost_2.12.0_linux_amd64v3.tar.gz","digest":null},
    {"name":"gost_2.12.0_linux_arm64.tar.gz","browser_download_url":"https://github.com/ginuerzh/gost/releases/download/v2.12.0/gost_2.12.0_linux_arm64.tar.gz","digest":null}]}
]
JSON
# Canned gost checksums.txt: the fixture archive's real sha for both linux
# arches (BSD `sha256 -p` style: "<sha>  <file>").
cat > "$SBX/gost-checksums.txt" <<SHAS
$gost_sha  gost_2.12.0_linux_amd64.tar.gz
$gost_sha  gost_2.12.0_linux_arm64.tar.gz
SHAS

# websocat fixture: a standalone executable BINARY (not a tarball). websocat
# publishes plain statically-linked binaries (application/octet-stream) named
# websocat.<triple>, so the recipe uses spm_download_verified (the seekable-file
# case) rather than spm_stream_extract. The fake curl serves this file for both
# arches and for HEAD (size) requests.
mkdir -p "$SBX/wc"
printf '#!/usr/bin/env bash\necho "phase4 websocat v1.14.1 from static-pkgmgr fixture"\n' \
	> "$SBX/wc/websocat.x86_64-unknown-linux-musl"
chmod +x "$SBX/wc/websocat.x86_64-unknown-linux-musl"
cp "$SBX/wc/websocat.x86_64-unknown-linux-musl" "$SBX/phase4websocat"
wc_sha=$(sha256sum "$SBX/phase4websocat" | cut -d' ' -f1)
wc_size=$(wc -c < "$SBX/phase4websocat" | tr -d ' ')
# Canned GitHub releases for websocat. v4.0.0-alpha3 is listed first
# (newest-first, like the live API) to confirm the recipe's anchored tag regex
# skips pre-release/alpha tags and lands on the latest stable (v1.14.1). Asset
# digests are published as "sha256:<hex>" (the real websocat format), so the
# recipe strips the "sha256:" prefix; both arches reuse the same fixture sha,
# which the fake curl serves as identical bytes.
cat > "$SBX/websocat-releases.json" <<JSON
[
  {"tag_name":"v4.0.0-alpha3","name":"v4.0.0-alpha3","assets":[]},
  {"tag_name":"v1.14.1","name":"v1.14.1","assets":[
    {"name":"websocat.x86_64-unknown-linux-musl","browser_download_url":"https://github.com/vi/websocat/releases/download/v1.14.1/websocat.x86_64-unknown-linux-musl","digest":"sha256:$wc_sha"},
    {"name":"websocat.aarch64-unknown-linux-musl","browser_download_url":"https://github.com/vi/websocat/releases/download/v1.14.1/websocat.aarch64-unknown-linux-musl","digest":"sha256:$wc_sha"}]},
  {"tag_name":"v1.14.0","name":"v1.14.0","assets":[]}
]
JSON

# tmux fixture: a standalone executable BINARY (not a tarball), like websocat.
# pythops distributes plain statically-linked binaries named tmux-linux-<triple>.
# The recipe uses spm_download_verified; the fake curl serves this file for both
# arches and for HEAD (size) requests.
printf '#!/usr/bin/env bash\necho "phase4 tmux 3.6b from static-pkgmgr fixture"\n' \
	> "$SBX/phase4tmux"
chmod +x "$SBX/phase4tmux"
tmux_sha=$(sha256sum "$SBX/phase4tmux" | cut -d' ' -f1)
tmux_size=$(wc -c < "$SBX/phase4tmux" | tr -d ' ')
# Canned GitHub releases for tmux. v3.6b is listed first (newest-first, like
# the live API); v3.6a is an older release that must NOT be picked. Asset
# digests are "sha256:<hex>" (the real pythops format for v3.6+), so the recipe
# strips the prefix; both arches reuse the same fixture sha, which the fake curl
# serves as identical bytes.
cat > "$SBX/tmux-linux-binary-releases.json" <<JSON
[
  {"tag_name":"v3.6b","name":"v3.6b","assets":[
    {"name":"tmux-linux-x86_64","browser_download_url":"https://github.com/pythops/tmux-linux-binary/releases/download/v3.6b/tmux-linux-x86_64","digest":"sha256:$tmux_sha"},
    {"name":"tmux-linux-arm64","browser_download_url":"https://github.com/pythops/tmux-linux-binary/releases/download/v3.6b/tmux-linux-arm64","digest":"sha256:$tmux_sha"}]},
  {"tag_name":"v3.6a","name":"v3.6a","assets":[
    {"name":"tmux-linux-x86_64","browser_download_url":"https://github.com/pythops/tmux-linux-binary/releases/download/v3.6a/tmux-linux-x86_64","digest":"sha256:0000000000000000000000000000000000000000000000000000000000000000"},
    {"name":"tmux-linux-arm64","browser_download_url":"https://github.com/pythops/tmux-linux-binary/releases/download/v3.6a/tmux-linux-arm64","digest":"sha256:0000000000000000000000000000000000000000000000000000000000000000"}]}
]
JSON

# --- isolated sandbox + test repo with nodejs + ripgrep recipes -------------
spm_setup_test_env
# spm_setup_test_repo makes the test repo's packages/ a symlink to
# tests/fixtures. Replace it with a real directory (in the temp tree) that also
# holds the real nodejs/ripgrep recipes, so the committed tests/fixtures/ is
# never written to.
rm -f "$SPM_TEST_ROOT/packages"
mkdir -p "$SPM_TEST_ROOT/packages"
for d in "$_REAL_ROOT/tests/fixtures"/*/; do
	[ -f "$d/lock.sh" ] || continue
	ln -s "$_REAL_ROOT/tests/fixtures/$(basename "$d")" "$SPM_TEST_ROOT/packages/$(basename "$d")"
done
ln -s "$_REAL_ROOT/packages/nodejs" "$SPM_TEST_ROOT/packages/nodejs"
ln -s "$_REAL_ROOT/packages/ripgrep" "$SPM_TEST_ROOT/packages/ripgrep"
ln -s "$_REAL_ROOT/packages/golang" "$SPM_TEST_ROOT/packages/golang"
ln -s "$_REAL_ROOT/packages/gost" "$SPM_TEST_ROOT/packages/gost"
ln -s "$_REAL_ROOT/packages/websocat" "$SPM_TEST_ROOT/packages/websocat"
ln -s "$_REAL_ROOT/packages/tmux-linux-binary" "$SPM_TEST_ROOT/packages/tmux-linux-binary"

# Intercept curl calls with the fake curl test double.
PATH="$_REAL_ROOT/tests/fixtures/fakebin:$PATH"
export PATH

BIN="$SPM_TEST_BIN"
SPM_ARCH=$(uname -m)
[ "$SPM_ARCH" = "arm64" ] && SPM_ARCH="aarch64"
export SPM_ARCH
echo "host arch: $SPM_ARCH"

# --- nodejs: lock update -> resolve to v1.2.3 via index + SHASUMS -----------
spm_run bash "$BIN" lock update nodejs
spm_eq_int "$SPM_CODE" 0
spm_eq "$(jq -r '.version' "$SPM_CONFIG_DIR/locks/nodejs.json")" "1.2.3" \
	|| spm_fail "nodejs lock version should be 1.2.3"
spm_eq "$(jq -r --arg a "$SPM_ARCH" '.artifacts[$a].sha256' "$SPM_CONFIG_DIR/locks/nodejs.json")" "$node_sha" \
	|| spm_fail "nodejs lock sha should match the fixture archive"
spm_eq "$(jq -r --arg a "$SPM_ARCH" '.artifacts[$a].size' "$SPM_CONFIG_DIR/locks/nodejs.json")" "$node_size" \
	|| spm_fail "nodejs lock size should match the fixture archive"
spm_eq "$(jq -r --arg a "$SPM_ARCH" '.artifacts[$a].url' "$SPM_CONFIG_DIR/locks/nodejs.json")" \
	"https://nodejs.org/dist/v1.2.3/node-v1.2.3-linux-$([ "$SPM_ARCH" = "x86_64" ] && echo x64 || echo arm64).tar.xz" \
	|| spm_fail "nodejs lock url wrong"

# --- nodejs: install (stream extract + flatten + link) ---------------------
spm_run bash "$BIN" install nodejs
spm_eq_int "$SPM_CODE" 0
# bin/node and bin/npm were linked, and bin/node reports the fixture content.
spm_eq "$("$BIN_DIR/node" 2>/dev/null)" "phase4 node v1.2.3 from static-pkgmgr fixture" \
	|| spm_fail "nodejs install: bin/node produced wrong output"
spm_eq "$("$BIN_DIR/npm" 2>/dev/null)" "phase4 npm from static-pkgmgr fixture" \
	|| spm_fail "nodejs install: bin/npm produced wrong output"
# Installed version is recorded and lock show is up-to-date.
spm_eq "$(jq -r '.version' "$APPS_DIR/nodejs/.spm/lock.json")" "1.2.3" \
	|| spm_fail "nodejs install: .spm/lock.json version wrong"
spm_run bash "$BIN" lock show nodejs
spm_eq_int "$SPM_CODE" 0
spm_contains "$SPM_OUT" "up-to-date" \
	|| spm_fail "nodejs lock show should be up-to-date after install"
spm_false "staging tree left after install" test -e "$APPS_DIR/.staging/nodejs"

# --- nodejs: upgrade (v1.2.3 -> v2.0.0 via SHASUMS with new sha) -----------
# Re-stamp the SHASUMS with a different sha/size so the pin differs, then
# resolve a v2.0.0 (the recipe resolves latest from index.json; we swap the
# index so latest becomes v2.0.0 with a fresh fixture archive).
mkdir -p "$SBX/node2/node-v2.0.0-linux-x64/bin"
printf '#!/usr/bin/env bash\necho "phase4 node v2.0.0 from static-pkgmgr fixture"\n' \
	> "$SBX/node2/node-v2.0.0-linux-x64/bin/node"
printf '#!/usr/bin/env bash\necho "phase4 npm v2"\n' \
	> "$SBX/node2/node-v2.0.0-linux-x64/bin/npm"
chmod +x "$SBX/node2/node-v2.0.0-linux-x64/bin/node" "$SBX/node2/node-v2.0.0-linux-x64/bin/npm"
tar -C "$SBX/node2" -cJf "$SBX/phase4node.tar.xz" node-v2.0.0-linux-x64
node2_sha=$(sha256sum "$SBX/phase4node.tar.xz" | cut -d' ' -f1)
node2_size=$(wc -c < "$SBX/phase4node.tar.xz" | tr -d ' ')
cat > "$SBX/nodejs-index.json" <<JSON
[
  {"version":"v2.0.0","date":"2026-06-01","files":["linux-x64","linux-arm64"]},
  {"version":"v1.2.3","date":"2026-01-02","files":["linux-x64","linux-arm64"]}
]
JSON
cat > "$SBX/nodejs-SHASUMS256.txt" <<SHAS
$node2_sha  node-v2.0.0-linux-x64.tar.xz
$node2_sha  node-v2.0.0-linux-arm64.tar.xz
SHAS
# lock update preserves requested=null -> latest = v2.0.0.
spm_run bash "$BIN" lock update nodejs
spm_eq_int "$SPM_CODE" 0
spm_eq "$(jq -r '.version' "$SPM_CONFIG_DIR/locks/nodejs.json")" "2.0.0" \
	|| spm_fail "nodejs lock should now resolve to v2.0.0"
spm_eq "$(jq -r --arg a "$SPM_ARCH" '.artifacts[$a].size' "$SPM_CONFIG_DIR/locks/nodejs.json")" "$node2_size" \
	|| spm_fail "nodejs lock v2 size should match the fixture archive"
spm_run bash "$BIN" upgrade nodejs
spm_eq_int "$SPM_CODE" 0
spm_eq "$("$BIN_DIR/node" 2>/dev/null)" "phase4 node v2.0.0 from static-pkgmgr fixture" \
	|| spm_fail "nodejs upgrade: bin/node should report v2"
spm_false "staging tree left after upgrade" test -e "$APPS_DIR/.staging/nodejs"
# Dry-run upgrade of an up-to-date package is a no-op that changes nothing.
spm_run bash "$BIN" -n upgrade nodejs
spm_eq_int "$SPM_CODE" 0
spm_contains "$SPM_ERR" "already up-to-date" \
	|| spm_fail "nodejs dry-run upgrade should be a no-op"

# --- ripgrep: lock update -> resolve via GitHub releases (fake curl) ----------
spm_run bash "$BIN" lock update ripgrep
spm_eq_int "$SPM_CODE" 0
spm_eq "$(jq -r '.version' "$SPM_CONFIG_DIR/locks/ripgrep.json")" "1.2.3" \
	|| spm_fail "ripgrep lock version should be 1.2.3"
spm_eq "$(jq -r --arg a "$SPM_ARCH" '.artifacts[$a].sha256' "$SPM_CONFIG_DIR/locks/ripgrep.json")" "$rg_sha" \
	|| spm_fail "ripgrep lock sha should match the fixture archive"
spm_eq "$(jq -r --arg a "$SPM_ARCH" '.artifacts[$a].url' "$SPM_CONFIG_DIR/locks/ripgrep.json")" \
	"https://github.com/sharkdp/ripgrep/releases/download/v1.2.3/ripgrep-1.2.3-1-$([ "$SPM_ARCH" = "x86_64" ] && echo x86_64 || echo aarch64)-unknown-linux-musl.tar.gz" \
	|| spm_fail "ripgrep lock url wrong"

# --- ripgrep: install (stream extract + flatten + link) ----------------------
spm_run bash "$BIN" install ripgrep
spm_eq_int "$SPM_CODE" 0
spm_eq "$("$BIN_DIR/rg" 2>/dev/null)" "phase4 ripgrep rg v1.2.3 from static-pkgmgr fixture" \
	|| spm_fail "ripgrep install: bin/rg produced wrong output"
spm_run bash "$BIN" lock show ripgrep
spm_eq_int "$SPM_CODE" 0
spm_contains "$SPM_OUT" "up-to-date" \
	|| spm_fail "ripgrep lock show should be up-to-date after install"
spm_false "staging tree left after ripgrep install" test -e "$APPS_DIR/.staging/ripgrep"

# --- golang: lock update -> go1.27.3 via git tags + go.dev manifest ------------
spm_run bash "$BIN" lock update golang
spm_eq_int "$SPM_CODE" 0
spm_eq "$(jq -r '.version' "$SPM_CONFIG_DIR/locks/golang.json")" "1.27.3" \
	|| spm_fail "golang lock version should be 1.27.3"
spm_eq "$(jq -r --arg a "$SPM_ARCH" '.artifacts[$a].sha256' "$SPM_CONFIG_DIR/locks/golang.json")" "$golang_sha" \
	|| spm_fail "golang lock sha should match the fixture archive"
spm_eq "$(jq -r --arg a "$SPM_ARCH" '.artifacts[$a].size' "$SPM_CONFIG_DIR/locks/golang.json")" "$golang_size" \
	|| spm_fail "golang lock size should match the fixture archive"
spm_eq "$(jq -r --arg a "$SPM_ARCH" '.artifacts[$a].url' "$SPM_CONFIG_DIR/locks/golang.json")" \
	"https://go.dev/dl/go1.27.3.linux-$([ "$SPM_ARCH" = "x86_64" ] && echo amd64 || echo arm64).tar.gz" \
	|| spm_fail "golang lock url wrong"

# --- golang: install (stream extract + flatten + link) -----------------------
spm_run bash "$BIN" install golang
spm_eq_int "$SPM_CODE" 0
spm_eq "$("$BIN_DIR/go" 2>/dev/null)" "phase4 go 1.27.3 from static-pkgmgr fixture" \
	|| spm_fail "golang install: bin/go produced wrong output"
spm_eq "$("$BIN_DIR/gofmt" 2>/dev/null)" "phase4 gofmt 1.27.3 from static-pkgmgr fixture" \
	|| spm_fail "golang install: bin/gofmt produced wrong output"
spm_eq "$(jq -r '.version' "$APPS_DIR/golang/.spm/lock.json")" "1.27.3" \
	|| spm_fail "golang install: .spm/lock.json version wrong"
spm_run bash "$BIN" lock show golang
spm_eq_int "$SPM_CODE" 0
spm_contains "$SPM_OUT" "up-to-date" \
	|| spm_fail "golang lock show should be up-to-date after install"
spm_false "staging tree left after golang install" test -e "$APPS_DIR/.staging/golang"

# --- gost: lock update -> resolve v2.12.0 via GitHub releases + checksums.txt --
# gost assets carry no digest, so the recipe reads the SHA256 from the upstream
# checksums.txt (the asset regex anchors linux_amd64 so the amd64v3 variant is
# not selected). (§7.2)
spm_run bash "$BIN" lock update gost
spm_eq_int "$SPM_CODE" 0
spm_eq "$(jq -r '.version' "$SPM_CONFIG_DIR/locks/gost.json")" "2.12.0" \
	|| spm_fail "gost lock version should be 2.12.0"
spm_eq "$(jq -r --arg a "$SPM_ARCH" '.artifacts[$a].sha256' "$SPM_CONFIG_DIR/locks/gost.json")" "$gost_sha" \
	|| spm_fail "gost lock sha should match the fixture archive"
spm_eq "$(jq -r --arg a "$SPM_ARCH" '.artifacts[$a].size' "$SPM_CONFIG_DIR/locks/gost.json")" "$gost_size" \
	|| spm_fail "gost lock size should match the fixture archive"
spm_eq "$(jq -r --arg a "$SPM_ARCH" '.artifacts[$a].url' "$SPM_CONFIG_DIR/locks/gost.json")" \
	"https://github.com/ginuerzh/gost/releases/download/v2.12.0/gost_2.12.0_linux_$([ "$SPM_ARCH" = "x86_64" ] && echo amd64 || echo arm64).tar.gz" \
	|| spm_fail "gost lock url wrong"

# --- gost: install (stream extract + link, no wrapper to flatten) ------------
spm_run bash "$BIN" install gost
spm_eq_int "$SPM_CODE" 0
spm_eq "$("$BIN_DIR/gost" 2>/dev/null)" "phase4 gost v2.12.0 from static-pkgmgr fixture" \
	|| spm_fail "gost install: bin/gost produced wrong output"
spm_eq "$(jq -r '.version' "$APPS_DIR/gost/.spm/lock.json")" "2.12.0" \
	|| spm_fail "gost install: .spm/lock.json version wrong"
spm_run bash "$BIN" lock show gost
spm_eq_int "$SPM_CODE" 0
spm_contains "$SPM_OUT" "up-to-date" \
	|| spm_fail "gost lock show should be up-to-date after install"
spm_false "staging tree left after gost install" test -e "$APPS_DIR/.staging/gost"

# --- websocat: lock update -> resolve v1.14.1 via GitHub releases ------------
# websocat interleaves alpha/pre-release tags newest-first; the recipe's
# anchored tag regex must skip them and land on the latest stable (v1.14.1).
# Asset digests are "sha256:<hex>" (the real websocat format), so the recipe
# strips the "sha256:" prefix to get the raw pin sha256. (§7.2, §8)
spm_run bash "$BIN" lock update websocat
spm_eq_int "$SPM_CODE" 0
spm_eq "$(jq -r '.version' "$SPM_CONFIG_DIR/locks/websocat.json")" "1.14.1" \
	|| spm_fail "websocat lock version should be 1.14.1"
spm_eq "$(jq -r --arg a "$SPM_ARCH" '.artifacts[$a].sha256' "$SPM_CONFIG_DIR/locks/websocat.json")" "$wc_sha" \
	|| spm_fail "websocat lock sha should match the fixture binary"
spm_eq "$(jq -r --arg a "$SPM_ARCH" '.artifacts[$a].size' "$SPM_CONFIG_DIR/locks/websocat.json")" "$wc_size" \
	|| spm_fail "websocat lock size should match the fixture binary"
spm_eq "$(jq -r --arg a "$SPM_ARCH" '.artifacts[$a].url' "$SPM_CONFIG_DIR/locks/websocat.json")" \
	"https://github.com/vi/websocat/releases/download/v1.14.1/websocat.$([ "$SPM_ARCH" = "x86_64" ] && echo x86_64 || echo aarch64)-unknown-linux-musl" \
	|| spm_fail "websocat lock url wrong"

# --- websocat: install (download verified binary + link, no tarball) ---------
# The asset is a plain executable binary, so spm_download_verified is used
# instead of spm_stream_extract; no wrapper directory to flatten. (§7.3, §8)
spm_run bash "$BIN" install websocat
spm_eq_int "$SPM_CODE" 0
spm_eq "$("$BIN_DIR/websocat" 2>/dev/null)" "phase4 websocat v1.14.1 from static-pkgmgr fixture" \
	|| spm_fail "websocat install: bin/websocat produced wrong output"
spm_eq "$(jq -r '.version' "$APPS_DIR/websocat/.spm/lock.json")" "1.14.1" \
	|| spm_fail "websocat install: .spm/lock.json version wrong"
spm_run bash "$BIN" lock show websocat
spm_eq_int "$SPM_CODE" 0
spm_contains "$SPM_OUT" "up-to-date" \
	|| spm_fail "websocat lock show should be up-to-date after install"
spm_false "staging tree left after websocat install" test -e "$APPS_DIR/.staging/websocat"

# --- tmux-linux-binary: lock update -> resolve v3.6b via GitHub releases -------
# The recipe's tag regex matches pythops' tag scheme (v3.6b, v3.6a, v3.6 ...);
# the canned JSON lists v3.6b first (newest-first) and v3.6a after, so the
# first match is the latest (v3.6b). Asset digests are "sha256:<hex>", so the
# recipe strips the prefix. (§7.2, §8)
spm_run bash "$BIN" lock update tmux-linux-binary
spm_eq_int "$SPM_CODE" 0
spm_eq "$(jq -r '.version' "$SPM_CONFIG_DIR/locks/tmux-linux-binary.json")" "3.6b" \
	|| spm_fail "tmux lock version should be 3.6b"
spm_eq "$(jq -r --arg a "$SPM_ARCH" '.artifacts[$a].sha256' "$SPM_CONFIG_DIR/locks/tmux-linux-binary.json")" "$tmux_sha" \
	|| spm_fail "tmux lock sha should match the fixture binary"
spm_eq "$(jq -r --arg a "$SPM_ARCH" '.artifacts[$a].size' "$SPM_CONFIG_DIR/locks/tmux-linux-binary.json")" "$tmux_size" \
	|| spm_fail "tmux lock size should match the fixture binary"
spm_eq "$(jq -r --arg a "$SPM_ARCH" '.artifacts[$a].url' "$SPM_CONFIG_DIR/locks/tmux-linux-binary.json")" \
	"https://github.com/pythops/tmux-linux-binary/releases/download/v3.6b/tmux-linux-$([ "$SPM_ARCH" = "x86_64" ] && echo x86_64 || echo arm64)" \
	|| spm_fail "tmux lock url wrong"

# --- tmux-linux-binary: install (download verified binary + link, no tarball) --
# The asset is a plain executable binary named tmux-linux-<triple>; the recipe
# downloads it with spm_download_verified, renames it to bin/tmux, and links
# "tmux" into $BIN_DIR. No archive to extract, no wrapper directory to flatten.
# (§7.3, §8)
spm_run bash "$BIN" install tmux-linux-binary
spm_eq_int "$SPM_CODE" 0
spm_eq "$("$BIN_DIR/tmux" 2>/dev/null)" "phase4 tmux 3.6b from static-pkgmgr fixture" \
	|| spm_fail "tmux install: bin/tmux produced wrong output"
spm_eq "$(jq -r '.version' "$APPS_DIR/tmux-linux-binary/.spm/lock.json")" "3.6b" \
	|| spm_fail "tmux install: .spm/lock.json version wrong"
spm_run bash "$BIN" lock show tmux-linux-binary
spm_eq_int "$SPM_CODE" 0
spm_contains "$SPM_OUT" "up-to-date" \
	|| spm_fail "tmux lock show should be up-to-date after install"
spm_false "staging tree left after tmux install" test -e "$APPS_DIR/.staging/tmux-linux-binary"

# --- cross-check: lock update (dry-run) changes nothing ----------------------
spm_run bash "$BIN" -n lock update nodejs
spm_eq_int "$SPM_CODE" 0
spm_contains "$SPM_ERR" "would update pin for nodejs" \
	|| spm_fail "lock update dry-run should print the plan"

# --- cleanup ---------------------------------------------------------------
rm -rf "$SBX"

spm_end
