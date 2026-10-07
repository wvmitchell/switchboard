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
- **New tmux bindings still need a reload after an upgrade.** The paths stay
  valid, but a running tmux server keeps the bindings and hooks it loaded. That's
  the same as a `git pull` upgrade; `switchboard doctor` tells you when.
- **Under brew, PATH belongs to brew.** `install` skips the `~/.local/bin`
  symlinks and `uninstall` leaves PATH to `brew uninstall`; `doctor` checks that
  `switchboard` on your PATH is this install.

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
- **Render from the tag.** The formula is built from the template *at the release
  tag* and hashed against that tag's tarball, so it always describes the code it
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
  the same next version (issue #105 tracks assigning versions after merge).
- **A superseded version isn't tagged.** If two bumps land before the first one's
  gates finish, only the newer version gets a tag.
- **macOS CI minutes.** The formula job runs on every push to main and on PRs
  that touch packaging or install code.
- **Private repos release without updating the tap.** Brew can't download a
  private tarball, so the tap step skips until the repo is public and
  `HOMEBREW_TAP_TOKEN` is set.

## Related

- [Reference: the release pipeline](reference-release.md)
- [How to cut a release and enable the Homebrew tap](howto-release.md)
- [How to install, upgrade, or move to Homebrew](howto-install-and-upgrade.md)
- [Explanation: architecture](explanation-architecture.md)
