# Reference: the release pipeline

Everything that turns a merged version bump into a tagged GitHub Release and an
updated Homebrew formula. Three pieces: the `release` workflow, the `formula` CI
workflow it waits on, and `packaging/release.rb`, which holds every decision and
renderer as plain, unit-tested Ruby. For the step-by-step, see
[How to cut a release and enable the Homebrew tap](howto-release.md); for the
reasoning, [Explanation: distribution](explanation-distribution.md).

## Files

| File | Role |
|------|------|
| `lib/switchboard/version.rb` | `Switchboard::VERSION`, the version a release is cut from. |
| `CHANGELOG.md` | Release notes. Each version needs a `## [X.Y.Z] — title (YYYY-MM-DD)` entry. |
| `packaging/homebrew/switchboard.rb` | The formula template. The pipeline rewrites its `url` to the release tag and its `sha256` (a placeholder in the repo) to the tarball's hash; the in-repo `url` is not kept current. |
| `packaging/release.rb` | Pure decision + rendering logic, plus a small CLI the workflow calls. Tests: `test/release_test.rb`. |
| `.github/workflows/test.yml` | The offline suite (Ruby 3.0 + 3.3) and the real-tmux smoke job. A release gate. |
| `.github/workflows/formula.yml` | Installs the formula from a local tap on macOS and runs `brew audit --strict` + `brew test`. A release gate. |
| `.github/workflows/release.yml` | Tags, creates the GitHub Release, and updates the tap. |

## `release.yml`

### Triggers

| Trigger | When it runs the job |
|---------|----------------------|
| `workflow_run` on `[test, formula]`, `types: [completed]`, `branches: [main]` | Whenever either gate finishes on main **and** that gate run was a `push` (PR runs never start a release). The gate's own pass/fail doesn't filter the job; Plan checks both gates itself. |
| `workflow_dispatch` | A manual run, only when dispatched on `refs/heads/main`. Same checks as an automatic run. |

The trigger list must match the job's `GATES` env (`test formula`).

### Permissions and concurrency

- `permissions: contents: write, actions: read`. Listing any permission zeroes
  the rest; `actions: read` is what lets Plan read the gates' run results.
- Job-level `concurrency: { group: release, cancel-in-progress: false }`: one
  release job at a time; a newer queued run replaces an older queued one.

### Steps

1. **Checkout `main`** (its tip at job start, not the commit that triggered the
   run) and set up Ruby 3.3.
2. **Plan** gathers facts and calls `release.rb plan`:

   | Fact | How |
   |------|-----|
   | `is_tip` | The checked-out sha equals `gh api repos/:repo/commits/main` (false if main moved mid-run). |
   | `version` | `release.rb version` (from `version.rb`). |
   | `tagged` | `git ls-remote --exit-code --tags origin refs/tags/vX.Y.Z`: exit 0 = tagged, 2 = not; anything else fails the step. |
   | `latest` | The highest `vX.Y.Z` tag on origin (`sort -V`), or empty. |
   | `released` | When tagged: `gh api …/releases/tags/vX.Y.Z` succeeds = true; `HTTP 404` = false; any other error fails the step. |
   | `tag_green` | When tagged: the tag's commit (the peeled `^{}` commit for an annotated tag) passes the same gate check as `green`. |
   | `green` | Every gate in `GATES` has a `success` conclusion for this sha on main, event `push` (`gh run list -w <gate> -c <sha> -e push -b main -L 1`). Pending or missing reads as not green; a failed lookup fails the step. |

   It writes `version`, `release`, `tag_exists`, `tap`, `reason` to the step's
   outputs and prints `reason` as a notice.
3. **Tag + GitHub Release** (when `release == true`): builds the title and body
   from the CHANGELOG entry, then `gh release create`: with `--target <tip sha>`
   for a new tag, or `--verify-tag` to attach a missing Release to an existing tag.
4. **Update Homebrew tap** (when `tap == true`). Skips with a notice while the
   repo is private, and with a warning when `HOMEBREW_TAP_TOKEN` is unset.
   Otherwise:
   1. downloads the tag's archive tarball (`curl --retry 3`) and hashes the file;
   2. reads the formula template **from the tag** (`git show vX.Y.Z:packaging/homebrew/switchboard.rb`);
   3. renders it with `release.rb formula`;
   4. clones `wvmitchell/homebrew-switchboard`, writes `Formula/switchboard.rb`,
      and pushes to the tap's default branch (only if the file changed).

   The token is sent as a per-command `http.extraheader` (never written to the
   clone's `.git/config`), and its base64 form is masked in logs.

### Secrets

| Secret | Needed for | Scope |
|--------|-----------|-------|
| `GITHUB_TOKEN` (automatic) | gate lookups, tag/Release | `contents: write`, `actions: read` (from `permissions:`) |
| `HOMEBREW_TAP_TOKEN` | pushing the tap | A fine-grained personal access token with **Contents: Read and write** on `wvmitchell/homebrew-switchboard` only. Optional; the tap step skips without it. |

## `Release.plan` decision table

`plan(tip:, checks_green:, version:, latest_tag:, tagged:, released:, tag_green:)` returns
`{release:, tag_exists:, tap:, reason:}`. Rows are checked top to bottom.

| Condition | release | tap | reason |
|-----------|:-------:|:---:|--------|
| not main's tip | no | no | not main's tip; the tip's run acts instead |
| a gate isn't green | no | no | waiting on every CI gate to pass for main's tip |
| `version` < `latest_tag` (semver order) | no | no | version.rb … is behind the newest tag …; not moving the tap backwards |
| tagged, but the tag's commit didn't pass every gate on main | no | no | vX.Y.Z points at a commit that didn't pass every CI gate on main; … |
| not tagged | **yes** (new tag) | yes | new version |
| tagged, no Release | **yes** (`--verify-tag`) | yes | tag exists without a Release; creating it |
| tagged and released | no | yes | already released; refreshing the tap |

## `formula.yml`

| Trigger | Paths |
|---------|-------|
| `pull_request` | `packaging/**`, `bin/switchboard`, `switchboard.tmux`, `lib/switchboard.rb`, `lib/switchboard/{stable_path,installer,cli,config}.rb`, `.github/workflows/formula.yml` |
| `push` to `main` | all paths (every releasable commit gets a brew test) |

On `macos-latest` it builds a `git archive` tarball of the commit, renders the
formula against it (`file://` url), creates a local tap with `brew tap-new`, and
runs `brew audit --strict`, `brew install`, and `brew test`.

## `packaging/release.rb` CLI

Run as `ruby packaging/release.rb <subcommand>` from the repo root.

| Subcommand | Output | Notes |
|------------|--------|-------|
| `version` | `0.50.0` | Reads `lib/switchboard/version.rb`; raises if no `X.Y.Z` constant. |
| `notes VERSION TITLE_FILE NOTES_FILE` | writes both files | Title `vX.Y.Z — <heading>` (date stripped); body is the entry up to the next `## [`. Raises if the version has no CHANGELOG entry, or only a heading. |
| `tarball-url VERSION` | `https://github.com/wvmitchell/switchboard/archive/refs/tags/vVERSION.tar.gz` | |
| `plan TIP CHECKS_GREEN VERSION LATEST_TAG TAGGED RELEASED TAG_GREEN` | `release=…`, `tag_exists=…`, `tap=…`, `reason=…` lines | Booleans are the strings `true`/`false`; `LATEST_TAG` may be empty. |
| `formula VERSION SHA256 [TEMPLATE]` | rendered formula on stdout | `TEMPLATE` defaults to `packaging/homebrew/switchboard.rb`. Raises on a non-hex sha, the empty-file sha (`e3b0c442…b855`), or a template without exactly one `url` and one `sha256` line for this repo. |
| anything else | usage on stderr, exit 1 | |

```sh
$ ruby packaging/release.rb plan true true 0.50.0 "" false false false
release=true
tag_exists=false
tap=true
reason=new version
```

## The formula

`packaging/homebrew/switchboard.rb`:

- **Depends on** `gh`, `git`, `ruby` (macOS system Ruby is 2.6; switchboard needs ≥ 3.0), `tmux`.
- **Installs** `bin/`, `lib/`, `switchboard.tmux` into `libexec`, rewrites
  `bin/switchboard`'s shebang to Homebrew Ruby, and links `switchboard` and `sb`
  into Homebrew's `bin`.
- **Caveats** tell the user to run `switchboard install`, and how to move from a clone.
- **Test** checks `switchboard --version` (any `X.Y.Z` for `--HEAD` builds) and
  that `install --print-tmux` writes the `opt/` fragment path, never a `Cellar` one.

## Related

- [How to cut a release and enable the Homebrew tap](howto-release.md)
- [How to install, upgrade, or move to Homebrew](howto-install-and-upgrade.md)
- [Explanation: distribution](explanation-distribution.md)
- [CLI reference](reference-cli.md): `install`, `uninstall`, `doctor`
