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
keg: `/opt/homebrew/opt/switchboard` (issue #9). `StablePath.resolve` (`lib/switchboard/stable_path.rb`)
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
- **Under brew, PATH belongs to brew.** When `Installer.homebrew?`, `install` skips the `~/.local/bin`
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

The PR still picks the version: it bumps `version.rb`, adds a CHANGELOG entry, and is
titled `vX.Y.Z`. Everything after merge is automated by `.github/workflows/release.yml`
(issue #9), a `workflow_run` job that tags the commit, creates the GitHub Release from the
CHANGELOG entry, and pushes the formula to the tap.

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
- **Two gates, both required.** A release needs `test` *and* `formula` (on macOS: the
  formula installed from a local tap, then `brew audit --strict` and `brew test`) to
  have passed on main for the tip.
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
  `contents: write`, which silently dropped `actions: read`, the permission to read
  Actions results, and every run reported nothing to do.
- **Decisions in tested Ruby.** The workflow only gathers facts. What to do with
  them is `Release.plan` (`packaging/release.rb`), a pure function with table-driven tests in
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

## Part 3: telling you about a release, and installing it

### The update line

A Homebrew install's sidebars show `↑ 0.58.0 available · switchboard upgrade` just under
the wordmark, on every session, while a newer release is out (issue #47; `UpdateCheck`,
`update_check.rb`). There's no dismiss: the line shows until you upgrade.

**Checking is rare and cheap.** A visible sidebar's `reload` spawns
`switchboard check-update` only when the cached answer (`latest.json`, in
`$XDG_CACHE_HOME/switchboard`) is older than 4 hours and the last attempt is older than
1 hour. The sidebar touches the attempt file itself before spawning, so twenty panes
start one child, and the child's non-blocking flock keeps one lookup running at a time.

**The check can't bother you.** The child daemonizes *first*, so it has no controlling
terminal and nothing it runs can prompt into a pane. It reads the newest tag through
`LatestRelease` (time-limited, with git config stripped; see
[below](#upgrading-switchboard-upgrade)) and writes only a real answer, so being offline
keeps the last one.

**It compares against what's installed, not what's running.** `rebuild` compares the
cached tag with the *installed* `version.rb` (`Installer.repo_root` follows the opt link
to the new keg), never the `VERSION` this process loaded. After `switchboard upgrade`, a
running sidebar still has the old code, and comparing against that would leave the line
up after you'd upgraded.

**Hidden panes still pick it up.** Both files are part of `warm_fingerprint`, and
`reload` records them with the mtimes `rebuild` actually *read* (`@update_seen`), not a
fresh stat. Otherwise a write landing between the two would be marked as drawn, and a
hidden pane would skip the warm reload that shows it.

**Who checks:**

- **Only the installed Homebrew binary** checks or draws the line (`applies?`). Clone and
  `--HEAD` installs don't, and a dogfood checkout would be comparing against its own
  branch.
- **`update_check: false`** turns off both.
- **`SWITCHBOARD_NO_UPDATE_CHECK`** turns off the check.
- **The sandbox** draws a seeded line (`Sandbox.seed_update`) without the Homebrew match,
  and never fetches.

### Upgrading (`switchboard upgrade`)

`Upgrade` (`upgrade.rb`, issue #10) fetches the newest version the same way switchboard
was installed. The install method *is* the channel:

- **Homebrew:** `brew update`, then `brew upgrade`.
- **A `--HEAD` keg:** `brew upgrade --fetch-HEAD`.
- **A clone:** `Upgrade.clone_pull`. It refuses if there are changes to tracked files,
  then runs `git fetch` and `git merge --no-overwrite-ignore --ff-only @{upstream}`, so git
  itself refuses an update that would overwrite an untracked *or* ignored local file. A
  plain pull silently overwrites ignored ones.

A failed `brew update` is only a note, unless nothing moved. Then `update_blocked` exits 1
instead of claiming there's nothing newer, since switchboard's own tap may be the one that
failed.

**"Up to date" depends on the method.**

- **For brew,** it means the newest release tag. `LatestRelease` (`latest_release.rb`)
  runs one `git ls-remote`, limited to 5 seconds, with your global, system *and* repo git
  config kept out (`GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CONFIG_NOSYSTEM`, run from the
  tmpdir), so an `insteadOf` rule can't redirect it.
- **For a clone,** it means HEAD against its upstream, using the time-limited
  `Git.fetch_base`, with ssh in BatchMode.

A stamp taken before and after (the keg's realpath, or the HEAD commit) decides whether
anything moved.

**Then it hands off to the new code.** The old process still has the old code loaded, so
it *execs the new binary* with `upgrade --finish <old>`. It clears `SB_REEXEC` first, so a
clone's new binary can still re-exec itself under a modern Ruby. The finish step:

1. `Installer.refresh_wiring`: the hook reporter, plus every hooked worktree of every
   configured project, primaries included, via `HookFile.refresh`;
2. the codex block, if it's installed;
3. the tmux fragment, run in the live server from any shell (`reload_fragment`), but only
   when tmux.conf sources *this* install.

A hand-off (new code arrived) ends by reloading every running sidebar
(`Upgrade.reload_sidebars` → `CodeReload.reload_all`, installed binary only; see
[the code reload](explanation-sidebar-lifecycle.md)) and prints the counts. The old "press
prefix-s twice" hint is gone.

**Running it again repairs a broken upgrade.** An up-to-date run still finishes any
leftover setup (`leftovers?`, which includes tmux key drift), so re-running finishes an
interrupted upgrade. If `config.yml` won't parse, it finishes what doesn't need the config,
then exits 1 naming the parse error instead of saying "up to date."

### Two guards on shared wiring

Hook commands, the reporter and the codex block all call back into whichever binary wrote
them. Two rules keep an upgrade, or a stray checkout, from breaking them.

**Only the installed binary rewrites anything shared.** `Installer.installed_bin?` checks
that the running `SWITCHBOARD_BIN` is the `switchboard` on your PATH. Without that, running
a dogfood checkout would repoint every worktree at a path that later vanishes.

**`HookFile.refresh` only updates; it never adds or clobbers.**

- It skips a file that doesn't have our hooks.
- It compares regardless of order (`same_hooks?` / `canonical`).
- It re-reads just before the atomic write, and returns `:conflict` if Claude saved the
  file in the meantime.
- It treats an unparseable file as ours (`:corrupt`) only when it carries one of our marks.
  It reports the specific cause from `HookFile.corrupt_reason`, as `doctor` does: invalid
  JSON or UTF-8, a malformed hooks section, unreadable, or not a regular file under 4 MiB.
- An unreadable or foreign file is never touched.

`install` runs the same `refresh_wiring`, so installing by hand ends up in the same place.

## Related

- [Reference: the release pipeline](reference-release.md)
- [How to cut a release and enable the Homebrew tap](howto-release.md)
- [How to install, upgrade, or move to Homebrew](howto-install-and-upgrade.md)
- [Explanation: architecture](explanation-architecture.md)
