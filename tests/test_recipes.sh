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

# --- cross-check: lock update (dry-run) changes nothing ----------------------
spm_run bash "$BIN" -n lock update nodejs
spm_eq_int "$SPM_CODE" 0
spm_contains "$SPM_ERR" "would update pin for nodejs" \
	|| spm_fail "lock update dry-run should print the plan"

# --- cleanup ---------------------------------------------------------------
rm -rf "$SBX"

spm_end
