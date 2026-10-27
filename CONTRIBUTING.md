# Contributing to static-pkgmgr

static-pkgmgr is a user-level package manager for static (prebuilt) apps
distributed as archives or plain downloads. Recipes live in the repository's
`packages/` directory and are reviewed as code — anyone can add one. This
document is the packager's reference. The authoritative spec is `STRUCTURE.md`.

## Layout

```
static-pkgmgr/
├── bin/static-pkgmgr     # entrypoint: global getopt, subcommand dispatch
├── lib/*.sh              # core (sourced, never executed directly)
├── helpers/*.sh          # packager-facing API (§8)
├── packages/<name>/      # recipes (packager's domain)
│   ├── meta             # NAME/DESCRIPTION/HOMEPAGE (KEY=VALUE, §7.1)
│   ├── lock.sh           # resolve version, URL, SHA256, size (§7.2)
│   ├── install.sh        # extract + link plan (§7.3)
│   └── uninstall.sh      # optional external cleanup (§7.4)
└── tests/                # fixtures + plain-Bash tests (§D11)
```

The entrypoint resolves itself with `readlink -f`, so install it by symlinking
`bin/static-pkgmgr` (e.g. `~/.local/bin/static-pkgmgr -> ~/src/.../bin/static-pkgmgr`)
and update recipes with `git pull` in the clone.

## Recipe contract

A package is a directory `packages/<name>/` containing `meta` and `lock.sh`,
and usually `install.sh` and optionally `uninstall.sh`.

### `meta` (§7.1)

A `KEY=VALUE` file parsed as data (never sourced), same rules as `config.env`
(§5). `KEY` matches `^[A-Z][A-Z0-9_]*$`; surrounding double quotes are removed;
a leading `~/` expands to `$HOME`.

- `NAME` (required): must equal the directory name and match
  `^[a-z0-9][a-z0-9._-]*$`. The install directory name. Never contains a
  version.
- `DESCRIPTION` (required).
- `HOMEPAGE` (optional).

### `lock.sh` (§7.2)

The core runs `lock.sh` in a fresh empty directory, with these environment
variables set:

| Variable | Meaning |
|---|---|
| `SPM_REQUESTED_VERSION` | empty = latest; otherwise the pinned version |
| `SPM_HELPERS` | path to `helpers/`, to be sourced |
| `GITHUB_TOKEN` | passed through if set |

Behavior:

- Prints **exactly one JSON object** to stdout: `{"version": "...", "artifacts": {...}}`.
  Diagnostics go to stderr.
- Emits one artifact per supported architecture, built with `spm_artifact`.
- Exits non-zero on failure; the core then keeps the previous pin (§6).
- May write only under its temporary working directory. Must not store archives.

The core validates the resulting pin (§6) and writes it atomically; a failure
leaves the previous pin in place.

### `install.sh` (§7.3)

Run for both fresh installs and upgrades (`SPM_MODE` is `install` or `upgrade`).
Environment set by the core:

| Variable | Meaning |
|---|---|
| `SPM_MODE` | `install` or `upgrade` |
| `SPM_PKG`, `SPM_VERSION` | package name, version from the pin |
| `SPM_ARCH` | current architecture (`arm64` normalized to `aarch64`) |
| `SPM_URL`, `SPM_SHA256`, `SPM_SIZE` | artifact for `$SPM_ARCH` (`SPM_SIZE` may be empty) |
| `SPM_LOCK` | path to the pin file |
| `SPM_STAGE` | empty directory; write the app tree here |
| `SPM_FINAL_DIR` | `$APPS_DIR/<name>` — do not write here, use only for paths stored in files |
| `SPM_BIN_DIR` | link directory; do not create links directly |
| `SPM_LINK_PLAN` | file; append links here via `spm_link` |
| `SPM_HELPERS` | path to `helpers/`, to be sourced |

Rules:

- Write only under `$SPM_STAGE`. Never write absolute paths into `$SPM_STAGE`
  (they break after the rename) — use `$SPM_FINAL_DIR` for stored paths.
- Download/extract with `spm_stream_extract` (streamed + verified); for zip or
  other non-seekable formats, use `spm_download_verified` and delete the file
  afterward (the one case an archive touches disk).
- Create links only with `spm_link`.
- Do not depend on `.spm/` or any state from a previous install.

### `uninstall.sh` (§7.4, optional)

Runs before the core removes anything, while `$SPM_FINAL_DIR` still exists.
Env: `SPM_PKG`, `SPM_FINAL_DIR`, `SPM_BIN_DIR`. Must work without the pin file.
Use it only for external cleanup (shell completions, desktop entries). The core
removes links and the app directory itself.

## Helper API (§8)

Helpers are sourced by recipes; they must not change shell options and must not
parse `ls`. All print results to stdout, diagnostics to stderr, return non-zero
on failure.

| Helper | Signature | Output |
|---|---|---|
| `spm_github_find_asset` | `<owner/repo> <tag_regex> <asset_regex> [requested]` | `{"version","tag","name","url","digest"}` |
| `spm_git_latest_tag` | `<repo_url> <tag_regex> [requested]` | latest matching tag (uses `git ls-remote`, never clones) |
| `spm_http_size` | `<url>` | size in bytes (last Content-Length from a HEAD), or empty |
| `spm_http_sha256` | `<url>` | SHA256 hex of the streamed download (nothing stored) |
| `spm_sha256_from_checksums` | `<checksums_url> <filename>` | SHA256 hex from a SHASUMS-style file |
| `spm_artifact` | `<arch> <url> <sha256> <size>` | JSON fragment for `artifacts` |
| `spm_stream_extract` | `<url> <sha256> <dest> [tar args...]` | streamed download + verify + extract |
| `spm_download_verified` | `<url> <sha256> <file>` | download to a file, verify, return (recipe deletes after) |
| `spm_link` | `<path_in_app> <link_name>` | records a link in `$SPM_LINK_PLAN` |

`spm_github_find_asset` selects the latest tag matching `tag_regex` (or the
matching `requested`), then the asset matching `asset_regex`. It takes the
SHA256 from the asset's `digest` field when present; otherwise the recipe must
supply one (e.g. `spm_http_sha256` — trust on first use). It sends
`Authorization` only when `GITHUB_TOKEN` is set, only to `api.github.com` and
`github.com`.

## Security and hygiene (§14)

- URLs must be `https://`. `file://` is allowed only with `SPM_TEST_MODE=1`.
- Prefer upstream checksums (`spm_sha256_from_checksums`); use `spm_http_sha256`
  (trust on first use) only as a fallback, and document which a recipe uses.
- Never `eval` config, pins, recipes, or network data. Read JSON with `jq`.
- Recipes run with the user's privileges and are code — review them like code.
- Don't store archives on disk unless a format needs a seekable file (then use
  `spm_download_verified` and delete it).

## Testing (§D11)

Tests are plain Bash (no bats) in `tests/test_*.sh`, run by `tests/run.sh`.
They use a temporary `HOME` / `SPM_CONFIG_DIR` / `APPS_DIR` / `BIN_DIR` and
`SPM_TEST_MODE=1` so recipes can use `file://` fixtures. New recipes should
keep their network-dependent bits in `lock.sh`/`install.sh` (delegated to the
helpers above) so the helpers can be unit-tested offline.

## Commits

- `shellcheck -x` must stay clean across `bin`, `lib`, `helpers`, `tests`, and
  the fixture `lock.sh`/`install.sh`/`uninstall.sh` scripts.
- `tests/run.sh` must pass with `0 failed`.
- One operation at a time: mutating commands take the global `flock`; exit 3
  when busy (§12).
