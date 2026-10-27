# AGENTS.md

## Read first

Read `STRUCTURE.md` completely before changing anything. It is the specification for layout, names, formats, flags, and behavior. If the code and `STRUCTURE.md` disagree, or the spec is unclear, stop and ask. Do not guess.

## Hard rules

- Bash only. Every executable starts with `#!/usr/bin/env bash` and `set -Eeuo pipefail`. Sourced files in `lib/` and `helpers/` must not change shell options.
- Use Bash 5.1 features at most. Do not use newer features.
- Dependencies are limited to: Bash, GNU coreutils, findutils, util-linux (`getopt`, `flock`), GNU `tar`, `sed`, `grep`, `jq`, `curl`. Do not add others (Python, Node, bats, yq, and so on). Ask first.
- Parse options with `getopt`. Never write manual `while`/`case` loops over `"$@"` for options.
- Never `eval` anything that comes from config, pins, recipes, or the network.
- Never `source` `config.env`, and never `source` pins or `meta`. Parse them as data as described in `STRUCTURE.md`.
- Never store a full archive on disk unless the recipe uses `spm_download_verified` for a format that needs it.
- Write only to `$SPM_CONFIG_DIR`, `$APPS_DIR`, `$BIN_DIR`, and directories created with `mktemp`.
- Do not `rm -rf` any path unless it goes through `spm_safe_rm`, which validates the path.
- Write pins and `.spm/` files atomically: write a temporary file in the same directory, then `mv -f`.
- Never replace a file in `$BIN_DIR` unless it is a symlink into `$APPS_DIR/`.
- Installed directory names never contain a version.
- Never write lock or pin files into the source repository.
- Never use `sudo`.
- Quote every expansion. Do not parse `ls` output. Use `find -print0` with `read -r -d ''`.
- Do not add CLI flags, config keys, JSON fields, helper names, or directories that `STRUCTURE.md` does not define. To add one, propose a change to `STRUCTURE.md` first.
- Do not refactor or reformat code unrelated to the task.
- Do not disable a shellcheck warning unless you add a comment explaining why.

## Pitfalls that agents commonly hit

- `local x=$(cmd)` hides the exit status. Declare first, then assign: `local x; x=$(cmd)`.
- Under `set -e`, `((i++))` exits when `i` is 0. Use `i=$((i + 1))`.
- Under `set -o pipefail`, `grep` with no match fails the pipeline. Handle that case on purpose.
- `curl` without `-f` saves an HTTP error page as the archive. Always use `-f`.
- `wait` after a process substitution needs Bash 5.1 or newer.
- A relative symlink is fine after a rename. An absolute symlink into `$SPM_STAGE` is not. Use `$SPM_FINAL_DIR`.
- `mv` across filesystems copies instead of renaming. Keep `.staging/` inside `$APPS_DIR`.
- `[[ $x =~ $re ]]` works only when `$re` is in a variable and unquoted on the right side.
- Heredocs without quoted delimiters expand variables. Use `<<'EOF'` unless expansion is wanted.
- `readlink -f` resolves the real path of the entrypoint. Use it to find `SPM_ROOT`.
- Traps: `set -E` is required for the `ERR` trap to run in functions. Clean up on `EXIT`, `INT`, and `TERM`.

## Process

- Implement one phase from `STRUCTURE.md` section 15 at a time. Stop and report when it is done.
- Before claiming a task is done, run `shellcheck -x` on all scripts and `tests/run.sh`. Show the output.
- Do not skip, delete, or weaken a test to make it pass.
- Tests must not touch the real `$HOME`. Use a temporary `SPM_CONFIG_DIR`, `APPS_DIR`, and `BIN_DIR`.
- If you are unsure about a decision, ask instead of choosing silently.
