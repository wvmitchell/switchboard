# Explanation: distribution

Switchboard started life as a git clone you symlink onto your PATH. Shipping it
through Homebrew sounds like a packaging chore (write a formula, done), but two
things about switchboard make it more than that: it **writes its own install path
into other programs' config**, and a release pipeline that publishes to every brew
user has to be **impossible to fool** into shipping the wrong thing. This page
explains both. The facts live in [Reference: the release pipeline](reference-release.md).

## Part 1: paths that survive `brew upgrade`

### The problem

`switchboard install` and the agent hooks don't just run switchboard; they
*record where it is*:

- a line in your `tmux.conf` that sources `<install>/switchboard.tmux`;
- tmux hooks and key bindings that run `<install>/bin/switchboard`;
- each worktree's `.claude/settings.local.json` hook commands;
- the global `[hooks]` block in `~/.codex/config.toml`.

For a clone, `<install>` is your checkout, and it doesn't move. For Homebrew it's
the **keg**, a versioned folder:

```
/opt/homebrew/Cellar/switchboard/0.50.0/libexec/bin/switchboard
```

`brew upgrade` installs 0.51.0 into a new keg, and `brew cleanup` deletes the old
one. Every path above would then point at a folder that no longer exists: the
sidebar key stops working, the hooks fail quietly, and the agent dots stop moving.

Codex makes it worse. It approves hook commands by **hashing their text**, so any
change to the path, even a working one, makes every codex hook untrusted again until
you re-approve it in `/hooks`. A path that changes on every release means
re-approving on every release.

### The approach

Homebrew keeps one stable link per formula that always points at the current
keg: `/opt/homebrew/opt/switchboard`. `StablePath.resolve` (`lib/switchboard/stable_path.rb`)
rewrites any path inside a switchboard keg to the same path under `opt/`:

```
<prefix>/Cellar/switchboard/<version>/<rest>   →   <prefix>/opt/switchboard/<rest>
                                  (only if <prefix>/opt/switchboard exists)
```

Both places the install path comes from go through it: `SWITCHBOARD_BIN` (set by
`bin/switchboard`) and `Installer.repo_root`. Everything downstream (the tmux.conf
line, hooks, bindings, the codex block) inherits the stable path. After an upgrade
the same bytes point at the new keg, so nothing needs rewriting and codex's trust
survives.

A clone path doesn't match the keg pattern and passes through unchanged, so clone
installs behave exactly as before.

### Trade-offs

- **It recognizes Homebrew by path shape.** A keg with no `opt/` link (only
  possible in a hand-broken prefix; brew creates it on install and keeps it
  through `brew unlink`) falls back to the real path and is treated like a clone.
- **An upgrade still has to touch the running setup.** The paths stay valid, but
  a running tmux server keeps the bindings and hooks it loaded, and each worktree's
  Claude hooks keep the set the release that wrote them had. `switchboard upgrade`
  does both after fetching the new version (tmux from any shell, hooks only from the
  installed binary); `switchboard doctor` tells you when either is stale.
- **Under brew, PATH belongs to brew.** `install` skips the `~/.local/bin`
  symlinks and `uninstall` leaves PATH to `brew uninstall`; `doctor` checks that
  `switchboard` and `sb` on your PATH are this install, and says how to fix
  whatever shadows them.

## Part 2: a release pipeline that can't ship the wrong thing

### The problem

Releasing means four things: a tag, a GitHub Release with notes, a tarball, and a
formula in the tap that points at the tarball with the right checksum. Done by
hand that's error-prone. Done by a naive workflow it's worse, because the failure
modes are quiet:

- **Out-of-order runs.** CI runs finish in any order, and GitHub keeps only one
  *pending* run per concurrency group, cancelling older ones. A workflow that
  releases "the commit that triggered me" can tag an old commit, skip a version,
  or point the tap at an older formula.
- **Untested commits.** Unit tests passing doesn't mean `brew install` works.
- **Drift between formula and tarball.** If the formula is built from today's
  template but downloads last release's tarball, an edit to the formula ships
  instructions that don't match the code.
- **Silent no-ops.** An error read as "not ready yet" looks exactly like a
  healthy run that had nothing to do.

### The approach

```
 push to main ──► test (Linux) ───────┐
             └──► formula (macOS) ────┤  each completion triggers release.yml
                                      ▼
                       ┌─────────────────────────────┐
                       │ checkout main's CURRENT tip │
                       │ gather facts (fail loudly)  │
                       │ Release.plan(...)           │──► nothing to do: notice, exit 0
                       └──────────────┬──────────────┘
                     release?         │ tap?
                 ┌────────────────────┴───────────────────┐
                 ▼                                        ▼
     tag + GitHub Release                  render formula FROM THE TAG,
     (notes from CHANGELOG)                hash the downloaded tarball,
                                           push to wvmitchell/homebrew-switchboard
```

- **Judge main's tip, not the trigger.** Every run checks out main's current tip
  and asks "is *this* commit ready?". Whichever run survives the concurrency queue
  releases the newest commit, and no run ever releases an older one.
- **Two gates, both required.** A release needs `test` *and* `formula` (a real
  `brew install` + `brew test` on macOS) to have passed on main for the tip.
  Whichever gate finishes second triggers the run that acts.
- **Never backwards.** If `version.rb` is behind the newest tag (a reverted bump,
  or a version collision settled lower), nothing is tagged and the tap isn't touched.
- **Trust a tag only if its commit was gated and carries the version.** When the
  version's tag already exists, the commit it points at (matched by exact tag
  name) must also have passed both gates on main, and its `version.rb` must say
  that version, so a hand-pushed or moved tag can't publish untested or older code.
  Plan pins that exact commit, and the Release and tap steps fail if the tag no
  longer resolves to it, so a tag moved mid-run can't slip through either.
- **Render from the tag.** The formula is built from the template *at the verified
  tag commit* and hashed against that tag's tarball, so it always describes the code it
  downloads. A failed download can't turn into a checksum either: the empty-file
  hash is rejected.
- **Idempotent and self-healing.** The tap update runs on every acting run and
  only commits when something changed. A failed push, or a token added after the
  release, is fixed by the next green push to main. A tag left without its
  Release gets the Release on the next run.
- **Loud failures.** Every fact-gathering lookup fails the step when it errors.
  "Not green" means the gate genuinely isn't green, not that the question
  couldn't be asked. This matters: an early version listed only
  `contents: write`, which silently removed permission to read Actions results,
  and every run reported nothing to do.
- **Decisions in tested Ruby.** The workflow only gathers facts. What to do with
  them is `Release.plan`, a pure function with table-driven tests in
  `test/release_test.rb`, alongside the CHANGELOG parser and formula renderer.

### Trade-offs

- **Versions are still chosen in the PR.** The workflow releases whatever
  `version.rb` says; it doesn't pick numbers. Parallel branches can still race for
  the same next version (issue #8 tracks assigning versions after merge).
- **A superseded version isn't tagged.** If two bumps land before the first one's
  gates finish, only the newer version gets a tag.
- **macOS CI minutes.** The formula job runs on every push to main and on PRs
  that touch packaging or install code.
- **Private repos release without updating the tap.** Brew can't download a
  private tarball, so the tap step skips until the repo is public and
  `HOMEBREW_TAP_TOKEN` is set.

## Baked paths, in detail

This is the full implementation detail [CLAUDE.md](../CLAUDE.md) points to; keep it current with the code.

**Baked paths must survive `brew upgrade`** (issue #9). The install path gets
written into long-lived wiring — the tmux.conf marker line, the tmux hooks/bindings,
per-worktree Claude hooks, the global codex block. A clone's realpath is stable; a
Homebrew keg's (`<prefix>/Cellar/switchboard/<ver>/…`) is deleted by upgrade+cleanup,
and a changed path also re-hashes the codex commands, voiding their `/hooks` trust.
So both sources of that path — `SWITCHBOARD_BIN` (`bin/switchboard`) and
`Installer.repo_root` — run through `StablePath.resolve` (`stable_path.rb`), which
rewrites a switchboard keg path to its `opt/switchboard` twin (fails safe to the
realpath when no opt link exists). Under brew (`Installer.homebrew?`) install/uninstall
skip the `~/.local/bin` symlinks and `doctor` checks the brew PATH entry instead.

## The release job, in detail

This is the full implementation detail [CLAUDE.md](../CLAUDE.md) points to; keep it current with the code.

**Releases are automated after merge** (`.github/workflows/release.yml`; issue #9 —
#8, assigning the version after merge, is still open). The PR still picks the version (`version.rb` + CHANGELOG entry, `vX.Y.Z` title);
once `test` AND `formula` (macOS: formula installed from a local tap, `brew audit
--strict` + `brew test`) are green on main, a `workflow_run` job tags it, creates the
GitHub Release from the CHANGELOG entry, and pushes the formula to
`wvmitchell/homebrew-switchboard`. Every run judges main's CURRENT tip (GitHub keeps one
pending run per group, and gates finish out of order), never moves the tap backwards,
trusts an existing tag only if its exact ref's commit passed the gates and carries the version, pins that commit so later steps fail if the tag moves, renders the formula from it, and fails loudly on any lookup error (a
missing `actions: read` once made every run a silent no-op). All decisions live in the
pure, table-tested `Release.plan` (`packaging/release.rb`); the YAML only gathers facts.
The tap step skips while the repo is private or `HOMEBREW_TAP_TOKEN` is unset. Full
detail: `docs/reference-release.md`, `docs/howto-release.md`.

## The update line and upgrade, in detail

This is the full implementation detail [CLAUDE.md](../CLAUDE.md) points to; keep it current with the code.

### The update line (#47 — Homebrew only)

A Homebrew install's sidebars show `↑ 0.58.0 available · switchboard upgrade` right
under the wordmark, on every session, while a newer release is out (`UpdateCheck`,
`update_check.rb`). A visible sidebar's `reload` spawns `switchboard check-update`
when the cache (`latest.json`, `$XDG_CACHE_HOME/switchboard`) is older than 4h and the
last attempt older than 1h; the sidebar touches the attempt file itself before
spawning, so twenty panes start one child, and the child's non-blocking flock keeps one
lookup at a time. The child daemonizes FIRST (no controlling terminal, so nothing it
runs can prompt into a pane), reads the newest tag through `LatestRelease` (bounded,
config-stripped) and writes only a real answer, so offline keeps the last one.
`rebuild` compares the cached tag against the INSTALLED `version.rb`
(`Installer.repo_root` follows the opt link to the new keg), never the `VERSION` this
process loaded: after `switchboard upgrade` a running sidebar still has the old code,
and comparing against that would keep the line up after you upgraded. Both files ride
`warm_fingerprint`, and `reload` baselines them with the mtimes `rebuild` READ
(`@update_seen`), not a fresh stat — a write between the two would otherwise be
marked drawn and a hidden pane would skip the warm that shows it. Gates: only the
installed Homebrew binary checks or draws (`applies?`: clone and `--HEAD` installs
don't; a dogfood checkout would compare against its own branch); `update_check:
false` stops both; `SWITCHBOARD_NO_UPDATE_CHECK` stops the check. The sandbox draws a
seeded line (`Sandbox.seed_update`) without the Homebrew match and never fetches.
There's no dismiss: the line shows until you upgrade.

### Upgrading (`switchboard upgrade`, #10)

`Upgrade` (`upgrade.rb`) fetches the newest version the way switchboard was installed —
the install method IS the channel: Homebrew (`brew update` + `brew upgrade`), a `--HEAD`
keg (`brew upgrade --fetch-HEAD`), or a clone (`Upgrade.clone_pull`: refused over tracked
changes, then `git fetch` + `git merge --no-overwrite-ignore --ff-only @{upstream}`, so
git itself refuses an update that would overwrite an untracked OR ignored local file —
a plain pull silently overwrites ignored ones). A failed `brew update` is only a note,
unless nothing moved: then `update_blocked` exits 1 instead of claiming "nothing newer"
(switchboard's own tap may be the one that failed). "Up to date" is per method: the
newest release tag for brew (`LatestRelease`, `latest_release.rb`: one `git ls-remote`
bounded to 5s, with the user's global/system git config AND any repo config kept OUT —
`GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CONFIG_NOSYSTEM`, run from the tmpdir — so an
`insteadOf` can't hijack it), HEAD vs its upstream
for a clone (bounded `Git.fetch_base`, ssh in BatchMode). A stamp (keg realpath / HEAD
commit) taken before and after decides whether anything moved. Then it **execs the new
binary** with `upgrade --finish <old>` — the old process has the old code loaded — and
clears `SB_REEXEC` so a clone's new binary can still re-exec under a modern Ruby. Finish
= `Installer.refresh_wiring` (the reporter + every hooked worktree of every configured
project, primaries too, via `HookFile.refresh`) + the codex block if installed + running
the tmux fragment in the live server from any shell (`reload_fragment`, only when
tmux.conf sources THIS install). An up-to-date run still finishes leftover setup
(`leftovers?`, which includes tmux key drift), so re-running repairs an interrupted
upgrade; with a config.yml that won't parse it finishes what doesn't need the config,
then exits 1 naming the parse error instead of saying "up to date". A hand-off (new code)
ends by reloading every running sidebar (`Upgrade.reload_sidebars` → `CodeReload.reload_all`,
installed binary only; see the hot-reload section) and prints the counts. The old "press
prefix-s twice" hint is gone.

Two guards carry the design. **Only the installed binary rewrites anything shared**
(`Installer.installed_bin?`: the running `SWITCHBOARD_BIN` is the `switchboard` on PATH):
hook commands, the reporter and the codex block all call back into whichever binary wrote
them, so a dogfood checkout would otherwise repoint every worktree at a path that
vanishes. **`HookFile.refresh` only updates, never adds or clobbers**: it skips a file
without our hooks, compares order-insensitively (`same_hooks?` / `canonical`), re-reads
before the atomic write and returns `:conflict` if Claude saved the file meanwhile, and
treats an unparseable file as ours (`:corrupt`, reported with `HookFile.corrupt_reason`'s
specific cause — invalid JSON/UTF-8, a malformed hooks section, unreadable, not a regular
file under 4 MiB — as `doctor` does) only when it carries one of our
marks — an unreadable or foreign file is never touched. `install` runs the same
`refresh_wiring`, so the manual route converges too.


## Related

- [Reference: the release pipeline](reference-release.md)
- [How to cut a release and enable the Homebrew tap](howto-release.md)
- [How to install, upgrade, or move to Homebrew](howto-install-and-upgrade.md)
- [Explanation: architecture](explanation-architecture.md)
