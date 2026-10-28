# static-pkgmgr

A user-level, static (reproducible) application package manager written in
pure Bash. It downloads a pinned archive for a package, verifies it, and
symlinks its binaries into `~/.local/bin` — without touching system
directories, without a database, and without root.

`static-pkgmgr` manages **app** packages (like `nodejs`, `ripgrep`) the same
way Nix/ Homebrew-style shims work: a version-pinned archive is unpacked into
`$APPS_DIR/<pkg>` and `$BIN_DIR/<pkg>` links into it. The desired version
lives in a pin file (`locks/<pkg>.json`, see the [Pinning model](#pinning-model))
so installs are reproducible and auditable.

> **Specification.** `STRUCTURE.md` is the authoritative spec for layout,
> names, formats, flags, and behavior. This file is a user-facing summary.

---

## Features

- Declarative pins: a `locks/<pkg>.json` file pins one version + verified
  artifact per architecture.
- Offline-safe: pins and archives are checksummed (SHA-256); downloads use
  `curl` with error checking and are never trusted without verification.
- Atomic installs: a staged swap puts the app into place only after a
  successful download+verify; a failure leaves links untouched.
- Safe upgrades: in-place or staged-swap (`--safe-upgrade`), never clobbering
  a half-installed upgrade.
- Single-user, no root: everything lives under `$HOME` (`APPS_DIR`,
  `BIN_DIR`, `SPM_CONFIG_DIR`).
- Concurrency: a `flock` mutex serializes mutating operations, with cleanup
  on signals/`ERR`.
- Optional baseline sync: pre-populate missing pins from a trusted git repo
  (`sync`, Phase 5).

---

## Requirements

- Bash 4.4+ (uses associative arrays, `mapfile`, `read -d ''`).
- GNU coreutils, `find` (findutils), `sed`, `grep`, `jq`, `curl`.
- `flock` (util-linux), GNU `tar`.
- `git` (used by recipes for fetching sources, and by `sync`).
- (`nix` is required only for the development shell, not for running the tool.)

---

## Install

`static-pkgmgr` is a single Bash script (`bin/static-pkgmgr`) with libraries
under `lib/`. To use it:

```sh
# Make the entrypoint runnable. The script resolves $SPM_ROOT via its own
# real path, so it can live anywhere.
ln -s "$PWD/bin/static-pkgmgr" "$HOME/.local/bin/static-pkgmgr"
```

Ensure `git`, `jq`, and `curl` are on `PATH`. No build step is required.

### Development environment

A Nix devShell provides the test/lint dependencies:

```sh
nix develop            # shell with shellcheck, git, jq, unzip
```

---

## Quick start

```sh
# Resolve pins for everything shipped under packages/ (writes locks/*.json).
SPM_TEST_MODE=1 static-pkgmgr lock update

# Install a package.
static-pkgmgr install ripgrep

# See what is installed.
static-pkgmgr list

# Check for updates (compares pins against installed).
static-pkgmgr lock show
static-pkgmgr upgrade

# Remove a package.
static-pkgmgr uninstall ripgrep
```

---

## Commands

| command | description |
| --- | --- |
| `lock update [pkg[@ver]]` | Resolve and write pins for all packages, or for one (`pkg`, `pkg@1.2.3`, or `pkg@latest`). |
| `lock show [pkg...]` | Show desired vs. installed version with status: `up-to-date`, `upgrade`, `not installed`, `no pin`. |
| `install <pkg...>` | Fresh install; errors if a package is already installed. |
| `upgrade [pkg...]` | Upgrade installed packages whose pin differs from what is installed. |
| `uninstall <pkg...>` | Remove symlinks, run `uninstall.sh` if present, remove the app directory. |
| `list` | List installed packages: name, version, path. |
| `sync [pkg...]` | *(Phase 5, optional)* Fill missing local pins from the baseline lock repo. |

### Global options

| option | description |
| --- | --- |
| `-h`, `--help` | Show help. |
| `-V`, `--version` | Show version. |
| `-n`, `--dry-run` | Print the plan, change nothing. |
| `--safe-upgrade` | Upgrade with a staged swap (overrides config). |
| `--no-safe-upgrade` | Upgrade in place (overrides config). |

Only mutating commands (`install`, `upgrade`, `uninstall`, `lock update`, and
`sync` when `BASELINE_REPO` is set) take the global mutex. `lock show`, `list`,
and `sync` with no `BASELINE_REPO` are read-only/no-ops that exit 1. A
`--dry-run` is never mutating (even for otherwise-mutating commands) and
skips the lock.

---

## Configuration

The optional file `$SPM_CONFIG_DIR/config.env` is parsed as data (never
sourced). Configuration keys and their defaults:

| key | default | source | meaning |
| --- | --- | --- | --- |
| `SPM_CONFIG_DIR` | `~/.config/static-pkgmgr` | env var | Config/state root. |
| `APPS_DIR` | `~/.local/opt` | `config.env` / default | Where apps are installed. |
| `BIN_DIR` | `~/.local/bin` | `config.env` / default | Where symlinks are created. |
| `SAFE_UPGRADE` | `0` | `config.env` / default | `1` = staged swap by default. |
| `LOG_KEEP` | `20` | `config.env` / default | Newest log files to retain. |
| `GITHUB_TOKEN` | empty | env var (wins) / `config.env` | Used by `helpers/github.sh`. |
| `BASELINE_REPO` | empty | `config.env` | Git repo for `sync`; empty disables `sync`. |

Precedence (highest first): command-line flag, then `config.env`, then built-in
default. The only environment variables read by the core are `GITHUB_TOKEN`
and `SPM_CONFIG_DIR` (plus `SPM_TEST_MODE`, see below).

Example `config.env`:

```ini
APPS_DIR=$HOME/.local/opt
BIN_DIR=$HOME/.local/bin
SAFE_UPGRADE=1
LOG_KEEP=30
BASELINE_REPO=https://git.example.com/my-baseline-locks
```

### `BASELINE_REPO`

`sync` fetches a shallow git checkout of this repo and offers its
`locks/<pkg>.json` files as baseline pins. An **empty value disables
`sync`** (it exits 1 with `BASELINE_REPO is not set`). Accepted URL schemes:
`https://`, `git@`, `ssh://`, `git://`. `file://` is allowed **only** when
`SPM_TEST_MODE=1` (to prevent relying on local paths in production).

---

## Directory layout

`$SPM_CONFIG_DIR` (default `~/.config/static-pkgmgr/`):

```
~/.config/static-pkgmgr/
├── config.env          # user settings (section 5), optional
├── locks/              # desired pins, one JSON file per package (section 6)
│   ├── nodejs.json
│   └── ripgrep.json
├── pending/            # transaction markers, only during an operation
├── logs/               # <UTC-timestamp>-<command>.log, newest LOG_KEEP kept
├── baseline/           # Phase 5: shallow git checkout of BASELINE_REPO
└── spm.flock           # global mutex for mutating commands
```

Installed apps live in `$APPS_DIR/<pkg>` (directory names never contain a
version), and `$BIN_DIR/<name>` holds symlinks into an app's `bin/` tree.
Pin and `.spm/` writes are atomic (write to a temp file in the same
directory, then `mv -f`).

---

## Pinning model

Each pin is a schema-1 JSON document (see `STRUCTURE.md` §6):

```jsonc
{
  "schema": 1,
  "package": "nodejs",
  "version": "20.11.1",
  "requested": null,          // null, or a string like "20" / "latest"
  "resolved_at": "2024-01-01T00:00:00Z",
  "artifacts": {
    "x86_64": { "url": "https://nodejs.org/dist/v20.11.1/node-v20.11.1-linux-x64.tar.xz",
                "sha256": "0123456789abcdef…64 hex chars", "size": 30113684 },
    "aarch64": { "url": "https://nodejs.org/dist/v20.11.1/node-v20.11.1-linux-arm64.tar.xz",
                 "sha256": "…64 hex…", "size": 22988892 }
  }
}
```

`install`/`upgrade` download the artifact for the current architecture,
verify its SHA-256, and stage-install it. `size` may be `null` (then the
archive is streamed for hashing) or an integer byte count.

---

## Recipes

Packages live under `packages/<pkg>/`:

```
packages/nodejs/
├── meta                 # name, description, license, homepage
├── lock.sh              # resolves the latest/ requested version -> prints a pin JSON on stdout
├── install.sh           # unpacks $SPM_ARCHIVE into $SPM_FINAL_DIR and links $SPM_BIN_DIR
└── uninstall.sh         # optional: remove extra files/links on uninstall
```

`meta` is read but never executed. `lock.sh`/`install.sh`/`uninstall.sh` are
run by the core with a controlled environment (`SPM_PKG`, `SPM_ARCHIVE`,
`SPM_FINAL_DIR`, `SPM_BIN_DIR`, `SPM_VERSION`, etc.); the core never sources
them and never `eval`s their output.

---

## Sync & the baseline lock repo (Phase 5)

`sync` is **opt-in** (enabled only when `BASELINE_REPO` is set):

```sh
static-pkgmgr sync            # fill every missing pin from the baseline
static-pkgmgr sync nodejs     # only for named packages
static-pkgmgr -n sync         # dry run: fetch + show the plan, write nothing
```

1. **Fetch.** If `$SPM_CONFIG_DIR/baseline` is absent, `git clone --depth 1`
   `BASELINE_REPO` into it; otherwise `git fetch --depth 1 origin` +
   `git reset --hard origin/HEAD`.
2. **For each** `baseline/locks/<pkg>.json`:
   - validate it (§6); an invalid pin is **warned + skipped** (and the run
     exits non-zero);
   - if a local `locks/<pkg>.json` already exists, **skip** it (run
     `lock update` to refresh);
   - if `packages/<pkg>/meta` is missing, **warn + skip** (not an error);
   - otherwise copy the pin atomically into `locks/`.
3. With **package args**, only those are synced; an unknown package **dies
   before any pin is written**.

`sync` never runs a recipe, never overwrites an existing pin, and writes no
pending transaction marker (it mirrors `lock update`'s soft-rc pattern: a few
skipped pins do not abort the rest; the global mutex is still taken for a real
(non-dry-run) sync and is released on exit).

---

## Dry run

`-n` / `--dry-run` is accepted by every command and is always non-mutating: it
prints the plan to stderr and writes nothing — it still fetches the baseline
for `sync`, but performs no pin writes, installs, or removals. A dry run
skips the global mutex and the staging sweep.

---

## Development & testing

```sh
nix develop
shellcheck -x bin lib helpers tests packages       # plus: shellcheck -x bin/static-pkgmgr
SPM_TEST_MODE=1 bash tests/run.sh
```

`tests/run.sh` runs every `tests/test_*.sh` in an isolated sandbox (temporary
`HOME`, `SPM_CONFIG_DIR`, `APPS_DIR`, `BIN_DIR`) and never touches the real
`$HOME`. `SPM_TEST_MODE=1` allows `file://` fixture URLs. Add a new
`tests/test_*.sh` and `run.sh` picks it up automatically.

### Project status (by phase)

`STRUCTURE.md` §15 defines incremental phases. All are implemented:

| Phase | scope | status |
| --- | --- | --- |
| 0 | core: log/warn/die, arch, safe removal, global mutex, txn markers | done |
| 1 | entrypoint: getopt globals + subcommand dispatch | done |
| 2 | transactions: flock, staging, recovery, signal/ERR traps | done |
| 3 | layout: directory tree + naming | done |
| 4 | recipes + packager helpers (`git`, `github`, `checksums`, `http`, `artifact`, `link`) | done |
| 5 | `sync` + baseline lock repo (`BASELINE_REPO`, `baseline/`) — opt-in | done |

---

## License

See the repository. `static-pkgmgr` is a small Bash project; contributions
are guided by `CONTRIBUTING.md`.
