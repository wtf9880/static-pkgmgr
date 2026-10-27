#!/usr/bin/env bash
# Fixture recipe: runs as the package's own uninstall hook (§7.4). Emits a
# marker file so tests can prove it executed, while SPM_FINAL_DIR still exists.
set -Eeuo pipefail

# §7.4 env: SPM_PKG, SPM_FINAL_DIR, SPM_BIN_DIR. Leave a marker the core will
# not touch (it only removes symlinks).
printf 'uninstalled %s at %s\n' "$SPM_PKG" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
	> "$SPM_BIN_DIR/.uninstalled-$SPM_PKG"
