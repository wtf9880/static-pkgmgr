# static-pkgmgr: structure and design

Status: proposal v1. This document is the specification. If code and this document disagree, the document wins. Change this document first when a decision changes.

## 1. Goals and non-goals

Goals:

- Install user-level apps distributed as archives or plain downloads, without root.
- Two stages: `lock` resolves URL, SHA256, and size per architecture. `install` downloads and extracts using the lock.
- Anyone can add a recipe under `packages/` without maintainer approval.
- Keep disk usage low. Archives are never stored on disk unless a recipe explicitly needs a seekable file.
- Plain Bash, small code, `getopt` for argument parsing.

Non-goals:

- System packages, root, services, dependency resolution between packages, building from source.
- Signature verification (v1 uses SHA256 only).

## 2. Requirements

- Bash 5.1 or newer.
- GNU coreutils, findutils, util-linux (`getopt`, `flock`), GNU `tar`, `sed`, `grep`.
- `jq` and `curl`.
- `wget` and `busybox` are optional, used only by recipes that need them.

## 3. Source repository layout

```text
static-pkgmgr/
├── bin/
│   └── static-pkgmgr          # entrypoint: global getopt, subcommand dispatch
├── lib/                       # sourced only, never executed directly
│   ├── common.sh              # log/warn/die, arch detection, spm_safe_rm
│   ├── config.sh              # parse config.env (no sourcing), defaults, precedence
│   ├── lock.sh                # validate, read, atomically write pins; `lock update`
│   ├── txn.sh                 # global flock, pending markers, recovery, cleanup
│   ├── install.sh             # install, upgrade (in-place and safe), uninstall
│   ├── manifest.sh            # .spm/ read/write, link checks
│   ├── recipe.sh              # load meta, run lock.sh/install.sh/uninstall.sh with env
│   └── sync.sh                # Phase 5: sync baseline lock repo, fill missing pins
├── helpers/                   # packager-facing API, stable
│   ├── github.sh              # spm_github_find_asset
│   ├── git.sh                 # spm_git_latest_tag
│   ├── http.sh                # spm_http_size, spm_http_sha256, spm_stream_extract,
│   │                          # spm_download_verified
│   ├── checksums.sh           # spm_sha256_from_checksums
│   ├── artifact.sh            # spm_artifact
│   └── link.sh                # spm_link
├── packages/                  # recipes (packagers' domain)
│   ├── nodejs/
│   │   ├── meta
│   │   ├── lock.sh
│   │   ├── install.sh
│   │   └── uninstall.sh       # optional
│   └── ripgrep/
│       └── ...
├── tests/
│   ├── run.sh                 # plain Bash test runner, no bats
│   ├── fixtures/              # tiny local archives and recipes, used via file:// URLs
│   └── test_*.sh
├── scripts/
│   └── bootstrap-deps.sh      # optional: installs jq, curl, etc.
├── .github/workflows/ci.yml   # shellcheck -x and tests/run.sh
├── AGENTS.md                  # rules for coding agents
├── CONTRIBUTING.md            # packager guide: recipe contracts and helper API
├── STRUCTURE.md              # this file
└── README.md
```

Helpers and `lib/` files are sourced, never executed directly.

The entrypoint resolves itself with `readlink -f`, sets `SPM_ROOT`, and reads `packages/` from there. Install the tool by symlinking it:

```text
~/.local/bin/static-pkgmgr -> ~/src/static-pkgmgr/bin/static-pkgmgr
```

Updating recipes means running `git pull` in the clone.

## 4. Data locations

### 4.1 Config and state: `$SPM_CONFIG_DIR`

`SPM_CONFIG_DIR` defaults to `${XDG_CONFIG_HOME:-$HOME/.config}/static-pkgmgr`.

```text
~/.config/static-pkgmgr/
├── baseline/            # Phase 5: shallow git checkout of BASELINE_REPO (§4.1)
├── config.env          # user settings (section 5), optional
├── locks/              # desired pins, one JSON file per package (section 6)
│   ├── nodejs.json
│   └── ripgrep.json
├── pending/            # transaction markers, present only during an operation
├── logs/               # <UTC-timestamp>-<command>.log, newest LOG_KEEP kept
└── spm.flock           # global mutex for mutating commands
```

Phase 5 adds `baseline/` for synced baseline locks: a shallow git checkout of `BASELINE_REPO` whose `locks/<pkg>.json` files are schema-1 pins with `requested: null`. `index.json` is intentionally not part of the design (git already tracks what changed).

### 4.2 Installed apps: `$APPS_DIR` (default `~/.local/opt`)

```text
~/.local/opt/
├── .staging/               # extraction area, same filesystem as APPS_DIR
│   ├── nodejs/             # install in progress
│   └── nodejs.old/         # safe upgrade only: previous tree, deleted after success
├── nodejs/                 # directory name has no version
│   ├── bin/node
│   └── .spm/
│       ├── lock.json       # copy of the pin that was installed
│       └── links           # absolute paths of links created in BIN_DIR, one per line
└── ripgrep/
    └── ...
```

### 4.3 Links: `$BIN_DIR` (default `~/.local/bin`)

Only symlinks created by `spm_link`. Each link points into `$APPS_DIR/<name>/`, so the target path doesn't change when the app is upgraded.

## 5. Configuration

File: `$SPM_CONFIG_DIR/config.env`. It is optional.

```text
# comments start with #
APPS_DIR=/home/you/.local/opt
SAFE_UPGRADE=1
```

Parsing rules:

- The file is read line by line. It is never `source`d or evaluated.
- Each line is blank, a `# comment`, or `KEY=VALUE`. `KEY` must match `^[A-Z][A-Z0-9_]*$`.
- The value is taken literally to the end of the line. One pair of surrounding double quotes is removed. `$`, backticks, and `\` are not expanded.
- A leading `~/` in a path value is replaced with `$HOME`. No other expansion happens.
- Unknown keys produce a warning and are ignored.
- An invalid value for a known key is an error (exit 1).

Keys:

| Key | Default | Allowed values | Meaning |
|---|---|---|---|
| `APPS_DIR` | `~/.local/opt` | absolute path | where apps are installed |
| `BIN_DIR` | `~/.local/bin` | absolute path | where links are created |
| `SAFE_UPGRADE` | `0` | `0`, `1` | upgrade mode (section 11) |
| `LOG_KEEP` | `20` | integer ≥ 1 | number of log files kept |
| `GITHUB_TOKEN` | empty | string | used by `helpers/github.sh`. The environment variable `GITHUB_TOKEN` takes precedence. |
| `BASELINE_REPO` | empty | git URL: `https://`, `git@`, `ssh://`, `git://`; `file://` only with `SPM_TEST_MODE=1` | git repository providing baseline pins for `sync`; an empty value disables `sync` (exits 1) |

Precedence, highest first: command-line flag, then `config.env`, then built-in default. The only environment variables read are `GITHUB_TOKEN` and `SPM_CONFIG_DIR`.

## 6. Pins (lock files)

Location: `$SPM_CONFIG_DIR/locks/<package>.json`, one file per package.

Written only by `lock update`, and by `install` when no pin exists yet. Never written into the source repository.

Schema 1:

```json
{
  "schema": 1,
  "package": "nodejs",
  "version": "22.11.0",
  "requested": null,
  "resolved_at": "2026-10-22T08:00:00Z",
  "artifacts": {
    "x86_64": {
      "url": "https://nodejs.org/dist/v22.11.0/node-v22.11.0-linux-x64.tar.xz",
      "sha256": "9f2c...64 lowercase hex characters",
      "size": 31234567
    },
    "aarch64": {
      "url": "https://nodejs.org/dist/v22.11.0/node-v22.11.0-linux-arm64.tar.xz",
      "sha256": "...",
      "size": 30123456
    }
  }
}
```

Field rules:

- `schema`: must be `1`. Any other value is refused with a clear message.
- `package`: must equal the recipe directory name.
- `requested`: `null` means track the latest version. A string is a pinned version.
- `version`: written by `lock.sh`. Used for display and comparison. Never parsed.
- `artifacts`: object keyed by architecture name (`uname -m` output, with `arm64` normalized to `aarch64`). Must contain at least one key.
- `url`: must start with `https://`. `file://` is allowed only when `SPM_TEST_MODE=1`.
- `sha256`: 64 lowercase hex characters.
- `size`: integer bytes, or `null` if unknown.
- `resolved_at`: UTC ISO 8601, written by the core.

Writing: the core writes to a temporary file in the same directory, validates it with `jq`, then `mv -f` to the final name. A failed `lock update` keeps the previous pin.

## 7. Recipes (`packages/<name>/`)

### 7.1 `meta`

A `KEY=VALUE` file, parsed with the same rules as `config.env`. Never sourced.

- `NAME` (required): install directory name. Must equal the recipe directory name and match `^[a-z0-9][a-z0-9._-]*$`. Never contains a version.
- `DESCRIPTION` (required).
- `HOMEPAGE` (optional).

### 7.2 `lock.sh`

Run by the core with the current directory set to a fresh temporary directory, which is deleted afterward.

Environment:

| Variable | Meaning |
|---|---|
| `SPM_REQUESTED_VERSION` | empty means latest, otherwise the user's requested version |
| `SPM_HELPERS` | path to the `helpers/` directory, to be sourced |
| `GITHUB_TOKEN` | passed through if set |

Output and behavior:

- Prints exactly one JSON object to stdout: `{"version": "...", "artifacts": {...}}`. Diagnostics go to stderr.
- Emits an artifact for every architecture the package supports. Use `spm_artifact` to build them.
- Exits non-zero on failure. The core then keeps the previous pin.
- Must not write files outside its temporary directory. It must not store archives on disk.

### 7.3 `install.sh`

Run for both fresh installs and upgrades.

Environment set by the core:

| Variable | Meaning |
|---|---|
| `SPM_MODE` | `install` or `upgrade` |
| `SPM_PKG` | package name |
| `SPM_VERSION` | version from the pin |
| `SPM_ARCH` | current architecture |
| `SPM_URL`, `SPM_SHA256`, `SPM_SIZE` | artifact for `SPM_ARCH` (`SPM_SIZE` may be empty) |
| `SPM_LOCK` | path to the pin file, for any extra fields |
| `SPM_STAGE` | empty directory. Write the app tree here. |
| `SPM_FINAL_DIR` | where the tree will be after success (`$APPS_DIR/<name>`). Do not write here. Use only for absolute paths written into files. |
| `SPM_BIN_DIR` | link directory. Do not create links directly. |
| `SPM_LINK_PLAN` | file where `spm_link` records intended links |
| `SPM_HELPERS` | path to the `helpers/` directory, to be sourced |

Rules:

- Write only under `$SPM_STAGE`.
- Never write absolute paths that point into `$SPM_STAGE` into any file, because they break after the rename. Use `$SPM_FINAL_DIR` instead.
- Download and extract with `spm_stream_extract`, or with `spm_download_verified` for formats that need a seekable file (for example zip). Both verify SHA256.
- Create links only with `spm_link`.
- Must not require `.spm/` or any other state from a previous install.

### 7.4 `uninstall.sh` (optional)

- Runs before the core removes anything, while `SPM_FINAL_DIR` still exists.
- Environment: `SPM_PKG`, `SPM_FINAL_DIR`, `SPM_BIN_DIR`.
- Must work without the pin file.
- Use it only for cleanup the core can't do: files outside the app directory, such as shell completions or desktop entries. The core removes links and the app directory itself.

## 8. Helper API (`helpers/`)

All helpers print results to stdout, diagnostics to stderr, and return non-zero on failure. Helpers write temporary files only with `mktemp`.

| Helper | Used in | Signature | Output |
|---|---|---|---|
| `spm_github_find_asset` | `lock.sh` | `<owner/repo> <tag_regex> <asset_regex> [requested]` | JSON: `{"version","tag","name","url","digest"}` |
| `spm_git_latest_tag` | `lock.sh` | `<repo_url> <tag_regex> [requested]` | tag string. Uses `git ls-remote --tags --refs --sort=-v:refname`. Never clones. |
| `spm_http_size` | `lock.sh` | `<url>` | size in bytes, or empty. Sends `HEAD` with `-L` and reads the last `Content-Length`. |
| `spm_http_sha256` | `lock.sh` | `<url>` | SHA256 hex. Streams the download through the hash. Nothing is stored. Trust on first use, so prefer upstream checksums. |
| `spm_sha256_from_checksums` | `lock.sh` | `<checksums_url> <filename>` | SHA256 hex from a `SHASUMS`-style file |
| `spm_artifact` | `lock.sh` | `<arch> <url> <sha256> <size>` | JSON fragment for `artifacts` |
| `spm_stream_extract` | `install.sh` | `<url> <sha256> <dest> [tar args...]` | none. Fails on download, extract, or hash mismatch. |
| `spm_download_verified` | `install.sh` | `<url> <sha256> <file>` | none. Downloads to a file in `$SPM_STAGE`'s parent, verifies, and returns. The recipe must delete the file after extraction. |
| `spm_link` | `install.sh` | `<path_in_app> <link_name>` | none. Appends `<link_name><TAB><path_in_app>` to `$SPM_LINK_PLAN`. The core creates the link after the move. |

`spm_github_find_asset`:

- Lists releases with the GitHub API and selects the first (or the requested) tag matching `tag_regex`.
- Selects the asset whose name matches `asset_regex`.
- Takes the SHA256 from the asset's `digest` field when present. Otherwise the recipe must provide a checksum source.
- Sends `Authorization` only when a token is set. Never sends it to hosts other than `api.github.com` and `github.com`.

Zip and other non-streamable formats use `spm_download_verified`. The temporary file is deleted after extraction. This is the one accepted case where an archive touches disk, and the recipe must document it.

## 9. Installed state

Each installed app has `$APPS_DIR/<name>/.spm/`:

- `lock.json`: copy of the pin used for the install. Used by `list`, `lock show`, and `upgrade`.
- `links`: one absolute link path per line. Written by the core only.

Link ownership: the core creates a link only if the path is empty or is already a symlink pointing into `$APPS_DIR/`. Anything else at that path is a conflict and fails the install.

Fallback for uninstall when `.spm/links` is missing: scan `$BIN_DIR` for symlinks whose target starts with `$APPS_DIR/<name>/`, and remove those.

## 10. Transactions and crash safety

Global mutex: each mutating command (`install`, `upgrade`, `uninstall`, `lock update`, `sync`) takes `flock -n` on `$SPM_CONFIG_DIR/spm.flock`. If it's busy, exit 3 with "another static-pkgmgr operation is running".

Pending marker: `pending/<pkg>`, created before the first change under `$APPS_DIR` or `$BIN_DIR` for that package. It contains `op=`, `mode=`, and `started=`. It is removed only after the operation succeeds, or after cleanup on failure succeeds. A command that does not touch `$APPS_DIR` or `$BIN_DIR` (such as `sync`) takes the lock but writes no marker.

Recovery: if `pending/<pkg>` exists when an operation on `<pkg>` starts, the core recovers first:

1. Run `uninstall.sh` if present, ignoring its failure.
2. Remove the links listed in `.spm/links`, plus the fallback scan.
3. Remove `$APPS_DIR/<pkg>`, `.staging/<pkg>`, and `.staging/<pkg>.old`.
4. Remove the marker.
5. Continue with the requested operation as a fresh install.

Leftover `.staging/*` entries are deleted at the start of every mutating command. The global mutex makes this safe.

Failure during an operation: the core runs cleanup, which deletes staging and removes links it created, then removes the marker. If cleanup itself fails, the marker stays, and the next run recovers.

Signals: `INT` and `TERM` run the same cleanup. `set -E` ensures the `ERR` trap fires inside functions.

## 11. Upgrade modes

`SAFE_UPGRADE=0` (default) means in-place. `SAFE_UPGRADE=1` means safe.

Override per run: `upgrade --safe-upgrade` or `upgrade --no-safe-upgrade`. These flags are valid only for `upgrade`. `install` always stages into `.staging/` and never keeps an old copy, so it has no mode.

Recovery always reinstalls from the pin, regardless of mode.

### 11.1 In-place (`SAFE_UPGRADE=0`)

1. Write marker `pending/<pkg>` (`op=upgrade mode=inplace`).
2. Run the old `uninstall.sh` if present. Remove the links in `.spm/links`. Delete `$APPS_DIR/<pkg>`.
3. Run `install.sh` with `SPM_MODE=upgrade` and `SPM_STAGE=.staging/<pkg>`. This downloads, verifies, and extracts.
4. Rename `.staging/<pkg>` to `$APPS_DIR/<pkg>`.
5. Create links from the plan. Write `.spm/lock.json` and `.spm/links`.
6. Remove the marker.

Peak disk use: one tree plus nothing else, because archives are streamed.
The app is unavailable from step 2 until step 5.
If step 3 fails, cleanup runs, the app stays removed, and the command exits 1. Running `upgrade` again retries.

### 11.2 Safe (`SAFE_UPGRADE=1`)

1. Write marker `pending/<pkg>` (`op=upgrade mode=safe`).
2. Run `install.sh` with `SPM_MODE=upgrade` and `SPM_STAGE=.staging/<pkg>`. The old version stays in place and keeps working.
3. On success, rename `$APPS_DIR/<pkg>` to `.staging/<pkg>.old`. Then rename `.staging/<pkg>` to `$APPS_DIR/<pkg>`.
4. Create links from the plan. Remove links from the old `.spm/links` that are not in the new plan. Write the new `.spm/`.
5. Delete `.staging/<pkg>.old`.
6. Remove the marker.

Peak disk use: old tree plus new tree, so the disk must have room for both.
If step 2 fails, the old version is untouched.
A crash after step 3 triggers recovery, which reinstalls from the pin. Recovery needs the network.

### 11.3 Comparison

| | In-place | Safe |
|---|---|---|
| Extra disk during upgrade | none beyond the new tree | old tree plus new tree |
| App usable during download | no | yes |
| Download fails | app is removed, retry needed | old version keeps working |
| Crash recovery | reinstall from pin | reinstall from pin |

## 12. Commands

```text
static-pkgmgr [global options] <command> [args]

Global options:
  -h, --help              show help
  -V, --version           show version
  -n, --dry-run           print the plan, change nothing
      --safe-upgrade      upgrade with staged swap (overrides config)
      --no-safe-upgrade   upgrade in place (overrides config)

Commands:
  lock update [--all|--installed] [pkg[@ver]] resolve or refresh pins
  lock show [pkg...]      desired vs installed version, with status
  install <pkg>...        fresh install; error if already installed
  upgrade [pkg...]        upgrade installed packages whose pin differs
  uninstall <pkg>...      remove links, uninstall.sh if present, app dir
  list                    installed packages: name, version, path
  sync [pkg...]           fill missing pins from the baseline lock repo (§4.1)
```

Argument parsing:

- Global options use `getopt -o hVn -l help,version,dry-run,safe-upgrade,no-safe-upgrade -n static-pkgmgr -- "$@"`, with a leading `+` in the short option string so parsing stops at the first non-option (the subcommand).
- Each subcommand with options parses its own arguments with `getopt`.
- `lock update` parses `--all`/`--installed` with its own `getopt -l 'all,installed' -o ''` (long options only, no short options). The two flags are mutually exclusive with each other and with named package arguments.
- `lock` takes a subcommand (`update` or `show`) as its first positional argument.

Argument semantics:

- `lock update pkg`: resolve and keep the existing `requested` value.
- `lock update pkg@ver`: resolve and set `requested` to `ver`.
- `lock update pkg@latest`: resolve and set `requested` to `null`.
- `lock update` with no arguments: every package with an existing local pin (`locks/<pkg>.json`).
- `lock update --all`: every recipe in `packages/` (with `lock.sh` + `meta`).
- `lock update --installed`: every package present under `$APPS_DIR/<pkg>` that already has a local pin.
- `--all` and `--installed` are mutually exclusive with each other and with named packages; combining them is a usage error (exit 2). For scope-based selection (`--installed` and the no-argument default), a package with no recipe is skipped with a non-fatal warning; for explicitly named packages, a missing recipe is a hard error (exit 1).
- `install pkg`: if no pin exists, run the resolve step first, then install. If the package is already installed, exit 1 with "already installed, use upgrade".
- `upgrade`: does not run `lock.sh`. For each installed package, compare the pin with the installed state. Compare both `version` and `artifacts[<arch>].sha256`, so a re-published artifact with the same version also counts as an upgrade. Packages with no pin are skipped with a warning. Naming a package with no pin is an error.
- `sync`: refreshes the baseline lock repo (`git fetch` + check out `HEAD`) into `$SPM_CONFIG_DIR/baseline/`, then writes `locks/<pkg>.json` for every package `pkg` in `baseline/locks/` (or each `pkg` named on the command line) that has no existing local pin, has a matching recipe in `packages/<pkg>/`, and whose baseline pin validates (§6). A named package not present in the baseline is an error. A baseline pin whose package has no recipe is skipped with a warning. `sync` takes the global `flock` but writes no pending marker (it does not touch `$APPS_DIR` or `$BIN_DIR`) and never runs `lock.sh`. A per-package pin-validation failure does not stop the remaining packages; the command exits 1 if any package failed. `--dry-run` fetches the baseline and prints the plan without writing any pin. If the fetch fails, `sync` exits 1 and writes nothing.
- `lock show` status values: `up-to-date`, `upgrade`, `not installed`, `no pin`.

Exit codes: `0` success, `1` error, `2` usage error, `3` busy (the global mutex is held).

## 13. Architecture decisions

| # | Decision | Reason |
|---|---|---|
| D1 | Recipes live in the repo's `packages/` | Recipes can be reviewed as code. Version bumps don't need approval. |
| D2 | Pins live in the user's config dir, one file per package | No commit per version. Per-user. Easy to diff. |
| D3 | Installed directory has no version. A copy of the pin is in `.spm/lock.json`. | Link targets stay stable across upgrades. |
| D4 | One pin holds artifacts keyed by architecture | Multi-arch support without a schema change. |
| D5 | `uninstall.sh` is optional. The core removes links and the directory. | Removal works without a pin, which crash recovery depends on. |
| D6 | Stream download and extract. Verify SHA256 after extraction, inside staging. | No archive is stored on disk. |
| D7 | `config.env` is parsed as data, never sourced | Config can't execute code. |
| D8 | Global `flock` and pending markers | One operation at a time. Crashes are recoverable. |
| D9 | Default upgrade is in-place. Safe upgrade is opt-in. | Disk is scarce. Safety is available when wanted. |
| D10 | `install.sh` records a link plan, and the core creates links | Enables dry-run and conflict checks. Keeps link creation atomic. |
| D11 | Tests in plain Bash, no bats | Fewer dependencies. |
| D12 | Baseline lock repo is phase 5, optional | Not needed for v1. |

## 14. Security

- Artifact URLs must be `https://`. `file://` is allowed only when `SPM_TEST_MODE=1`.
- SHA256 is checked before anything reaches `$APPS_DIR`. With no upstream checksum, `spm_http_sha256` is trust on first use. Prefer upstream checksums and document which kind a recipe uses.
- Recipes run with the user's privileges and are code. Review them like code. A recipe can do whatever the user can do.
- Never `eval` anything from config, pins, recipes, or the network. Read JSON with `jq`.
- Validate names and values. `requested` must match `^[A-Za-z0-9._+-]+$`. Package names must match the rule in section 7.1.
- Never use `sudo`.
- `spm_safe_rm` refuses any path outside `$APPS_DIR`, `$BIN_DIR`, `$SPM_CONFIG_DIR/pending`, `$SPM_CONFIG_DIR/baseline`, or `.staging`.

## 15. Implementation phases

Each phase is a separate session with its own review. Do not start a phase before the previous one passes.

- **Phase 0, skeleton.** Entrypoint with `getopt`. `common.sh`. `config.sh`. CI running `shellcheck -x` and `tests/run.sh`. Test runner that uses a temporary `SPM_CONFIG_DIR`.
- **Phase 1, core install path.** `lock update` and `install` using a fixture recipe served over `file://`. In-place only. `uninstall`. Pins written atomically. Links created from the plan. Link conflict checks.
- **Phase 2, transactions.** Global `flock`. Pending markers. Recovery. Cleanup on failure and on signals. Tests that simulate a crash by killing the process mid-install.
- **Phase 3, upgrades.** `upgrade` (in-place and safe), `--safe-upgrade` and `--no-safe-upgrade`, `SAFE_UPGRADE` in config, `lock show`, `list`, `--dry-run`.
- **Phase 4, helpers and real recipes.** `helpers/github.sh`, `git.sh`, `http.sh`, `checksums.sh`, `artifact.sh`, `link.sh`. Recipes for `nodejs` and `ripgrep`. `CONTRIBUTING.md`.
- **Phase 5, optional.** `sync` and the baseline lock repo (`baseline/`, `BASELINE_REPO` in §5): `sync` fetches a shallow checkout and fills missing local pins from `baseline/locks/<pkg>.json`. `index.json` is intentionally not part of the design (git already tracks what changed).

## 16. Open questions

- Safe mode recovery: should a crash after the swap roll back to the old tree when it is still intact, instead of reinstalling? Proposed for v1: no, keep recovery simple.
- Disk checks: should the core compare `size` from the pin with free space in `$APPS_DIR` before installing? Proposed for v1: warn only.
- Should `uninstall.sh` be run before or after the core removes links? Proposed: before, so it can still see its files.
