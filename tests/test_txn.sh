#!/usr/bin/env bash
# tests/test_txn.sh -- Phase 2: global flock, pending markers, recovery,
# cleanup on failure and on signals. (§10, §15 phase 2)
set -Eeuo pipefail

# Capture the real repository root before spm_setup_test_env replaces SPM_ROOT
# with the throwaway test root.
: "${SPM_ROOT:=$(readlink -f "$(dirname "${BASH_SOURCE[0]}")/..")}"
export SPM_ROOT
REPO_ROOT="$SPM_ROOT"

. "$SPM_ROOT/tests/lib.sh"
spm_setup_test_env

BIN="$SPM_TEST_BIN"
STAGING="$APPS_DIR/.staging"

# Build a hangapp recipe (real dir, not symlinked into tests/fixtures so it
# does not pollute the served package set) plus symlinks to the real fixtures.
# install.sh hangs on its first run (by replacing itself with `sleep`, so there
# is no orphaned child to clean up), then succeeds once the sentinel exists.
# uninstall.sh is fast (a normal hook) so recovery/uninstall do not stall.
spm_setup_repo_with_hangapp() {
	rm -f "$SPM_ROOT/packages"            # drop the fixtures symlink
	mkdir -p "$SPM_ROOT/packages"
	ln -s "$REPO_ROOT/tests/fixtures/helloapp" "$SPM_ROOT/packages/helloapp"
	ln -s "$REPO_ROOT/tests/fixtures/withuninstall" "$SPM_ROOT/packages/withuninstall"

	local h="$SPM_ROOT/packages/hangapp"
	mkdir -p "$h"
	cp "$REPO_ROOT/tests/fixtures/helloapp/app.tar.gz" "$h/app.tar.gz"
	cp "$REPO_ROOT/tests/fixtures/helloapp/lock.sh" "$h/lock.sh"
	printf 'NAME=hangapp\nDESCRIPTION=hang fixture\nHOMEPAGE=https://x.invalid\n' > "$h/meta"
	cat > "$h/install.sh" <<'EOF'
#!/usr/bin/env bash
# Hangs on first run so tests can kill the core mid-install, then succeeds.
set -Eeuo pipefail
# shellcheck disable=SC1091
. "$SPM_HELPERS/http.sh"
# shellcheck disable=SC1091
. "$SPM_HELPERS/link.sh"
if [ -f "$HOME/.spm-hang-install-skip" ]; then
	spm_stream_extract "$SPM_URL" "$SPM_SHA256" "$SPM_STAGE" -xzf -
	spm_link bin/hello hello
	exit 0
fi
# Record our PID *before* exec replaces this shell, so the test can kill the
# sleep (no orphaned children).
printf 'pid=%s\nprogress: hanging\n' "$$" > "$SPM_STAGE/progress"
: > "$HOME/.spm-hang-install-skip"
exec sleep 30
EOF
	cat > "$h/uninstall.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'uninstalled %s\n' "$SPM_PKG" > "$SPM_BIN_DIR/.uninstalled-$SPM_PKG"
EOF
	chmod +x "$h/install.sh" "$h/uninstall.sh" "$h/lock.sh"
}

spm_setup_repo_with_hangapp

# Helper: wait up to ~10s for a file to appear; return 0 if it did.
spm_wait_file() {
	local f="$1" i=0
	while [ "$i" -lt 100 ]; do
		[ -e "$f" ] && return 0
		sleep 0.1
		i=$((i + 1))
	done
	return 1
}

hangapp_marker() { cat "$SPM_CONFIG_DIR/pending/hangapp"; }
hangapp_pid() { sed -n 's/^pid=//p' "$STAGING/hangapp/progress" 2>/dev/null | head -n1; }

# --- A. pending marker is written during install; concurrent cmd exits 3 ----
rm -f "$HOME/.spm-hang-install-skip"
"$BIN" install hangapp &
ha_pid=$!
if spm_wait_file "$STAGING/hangapp/progress"; then spm_pass; else spm_fail "hangapp recipe never started"; fi
m=$(hangapp_marker)
spm_contains "$m" "op=install"
spm_contains "$m" "started="        # timestamp present
spm_contains "$m" "mode="           # mode key present (empty for install)
spm_true "staging tree created during install" test -d "$STAGING/hangapp"
# While the install holds the lock, a second mutating command must exit 3.
spm_run bash "$BIN" lock update helloapp
spm_eq_int "$SPM_CODE" 3
spm_contains "$SPM_ERR" "another static-pkgmgr operation is running"
# SIGKILL mid-install simulates a crash: the marker + staging must survive.
recipe_pid=$(hangapp_pid)
kill -9 "$ha_pid" 2>/dev/null || true
[ -n "$recipe_pid" ] && kill -9 "$recipe_pid" 2>/dev/null || true
wait "$ha_pid" 2>/dev/null || true
spm_true "marker must survive SIGKILL crash" test -f "$SPM_CONFIG_DIR/pending/hangapp"
spm_true "staging must survive SIGKILL crash" test -d "$STAGING/hangapp"
spm_false "app dir must not exist after crash" test -e "$APPS_DIR/hangapp"

# --- A2. recovery: re-installing after a crash succeeds (fresh install) ----
spm_run bash "$BIN" install hangapp
spm_eq_int "$SPM_CODE" 0
spm_contains "$SPM_ERR" "hangapp installed"
spm_false "marker removed on success" test -f "$SPM_CONFIG_DIR/pending/hangapp"
spm_true "app installed after recovery" test -d "$APPS_DIR/hangapp"
spm_contains "$("$BIN_DIR/hello" 2>&1)" "hello from static-pkgmgr fixture"

# --- B. SIGTERM mid-install runs cleanup, then re-install succeeds ---------
# hangapp is now installed; uninstall it so we can re-install, and reset the
# hang sentinel so install.sh hangs again on this run.
spm_run bash "$BIN" uninstall hangapp
spm_eq_int "$SPM_CODE" 0
rm -f "$HOME/.spm-hang-install-skip"
"$BIN" install hangapp &
hb_pid=$!
if spm_wait_file "$STAGING/hangapp/progress"; then spm_pass; else spm_fail "hangapp recipe never started (SIGTERM test)"; fi
hb_recipe=$(hangapp_pid)
kill -TERM "$hb_pid" 2>/dev/null || true
term_rc=0
wait "$hb_pid" 2>/dev/null || term_rc=$?
# §10.12: signals run cleanup -> marker + staging + app all cleaned up.
spm_false "marker removed by SIGTERM cleanup" test -f "$SPM_CONFIG_DIR/pending/hangapp"
spm_false "staging removed by SIGTERM cleanup" test -d "$STAGING/hangapp"
spm_false "app absent after SIGTERM cleanup" test -e "$APPS_DIR/hangapp"
spm_eq_int "$term_rc" 143      # 128 + SIGTERM(15)
[ -n "$hb_recipe" ] && kill -9 "$hb_recipe" 2>/dev/null || true
# Re-install succeeds now that the sentinel exists.
spm_run bash "$BIN" install hangapp
spm_eq_int "$SPM_CODE" 0
spm_contains "$SPM_ERR" "hangapp installed"
spm_false "marker removed on success" test -f "$SPM_CONFIG_DIR/pending/hangapp"

# --- C. leftover .staging/* is swept at the start of a mutating command ----
mkdir -p "$STAGING/orphan"
: > "$STAGING/orphan/junk"
spm_true "stale staging entry created" test -d "$STAGING/orphan"
spm_run bash "$BIN" lock update helloapp
spm_eq_int "$SPM_CODE" 0
spm_false "stale staging entry swept" test -d "$STAGING/orphan"

# --- D. uninstall succeeds and leaves no marker behind --------------------
# hangapp is installed from test B; uninstall it and confirm no marker lingers.
spm_run bash "$BIN" uninstall hangapp
spm_eq_int "$SPM_CODE" 0
spm_false "uninstall must not leave a pending marker" test -f "$SPM_CONFIG_DIR/pending/hangapp"

# --- E. lock update never writes a pending marker --------------------------
rm -f "$SPM_CONFIG_DIR/pending/helloapp"
spm_run bash "$BIN" lock update helloapp
spm_eq_int "$SPM_CODE" 0
spm_false "lock update must not create a pending marker" test -f "$SPM_CONFIG_DIR/pending/helloapp"

spm_end
