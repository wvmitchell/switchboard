# How to keep sessions tidy and diagnose problems

Switchboard maps every worktree to its own tmux session. A worktree deleted,
moved, or renamed *outside* switchboard (or a crash) can leave a stray session
behind. This covers cleaning those up, tearing everything down, and using
`doctor` to find what's wrong.

## Prerequisites

- switchboard installed. These commands also work from a plain shell (they talk
  to the tmux server), so they're your recovery tools after a crash.

## See what's orphaned, then clean it

Preview first — `prune` with a dry run only reports:

```sh
switchboard prune --dry-run     # -n works too
```

```
would kill 2 orphaned session(s):
  sb/app/old-feature
  sb/api/spike
run `switchboard prune` to remove these
```

Then remove them:

```sh
switchboard prune
```

`prune` reconciles live `sb/` sessions against `git worktree list`. It only
touches projects it can **verify** — the project is in your config and git can
read it — so a project whose repo you *moved* or unregistered is left alone (its
sessions survive; use `quit` below for a full teardown). A session younger than a
short grace window is also spared, so a just-created session is never killed mid
launch.

**Auto-prune on launch (on by default).** Landing on the home session prunes
orphans for you. Turn it off in `config.yml`:

```yaml
prune_on_launch: false
```

## Tear everything down

```sh
switchboard quit
```

Closes *all* `sb/` sessions — the one you're in last, so nothing is orphaned —
and clears every agent-state file (so a torn-down agent doesn't read as still
working). Your config, projects, and durable view preferences (folded projects,
the full-header toggle, and the pane width) survive; `switchboard` brings it all
back.

The sidebar's `q` does the same with a confirm prompt.

### If switchboard isn't on your PATH

The raw equivalent of `quit`, safe to run from a plain terminal:

```sh
here=$(tmux display-message -p '#{session_name}' 2>/dev/null)
tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^sb/' | grep -vxF "$here" \
  | while read -r s; do tmux kill-session -t "=$s"; done
case "$here" in sb/*) tmux kill-session -t "=$here";; esac
```

This sweeps `sb/home` too — fine, it's recreated lazily next time.

## Run the doctor

`switchboard doctor` is read-only and the first place to look when something's
off. It checks, with the fix inline for anything red:

- `tmux` / `git` / `gh` on PATH, and tmux ≥ 3.0.
- Config present and parseable (reports a parse error and the file to fix).
- PATH symlinks (`switchboard` required; `sb` optional). Under Homebrew it checks
  instead that `switchboard` on PATH is this install, and names a clone link that
  shadows it.
- Which install your tmux.conf is wired to: this one (✓), another that still
  exists (a note; `switchboard install` re-wires it), or one that's gone (✗).
- tmux wiring: the fragment is sourced, the keys are bound, and the hooks are
  **live in the running server** — not just present in config. These diverge
  after a `git pull` until tmux reloads; `doctor` tells you when a reload is
  needed.
- `gh` authenticated, and how stale each project's cached PR badges are (so
  "why are my badges old?" has an answer).
- An audio player on PATH, and whether each sound spec resolves.
- Orphaned `sb/` sessions (points you at `prune`).
- Orphaned sidebar *processes* — a `switchboard sidebar` that outlived its pane.
  Harmless to the UI, but because tmux recycles pane ids a straggler can
  double-ring completion sounds, so it's worth seeing. See
  [Explanation: sidebar lifecycle](explanation-sidebar-lifecycle.md).

## Troubleshooting

- **Moved from a clone to Homebrew and things half-work.** See
  [How to install, upgrade, or move to Homebrew](howto-install-and-upgrade.md#move-from-a-git-clone-to-homebrew).
- **`prefix-s` stopped working after a `git pull`.** The running tmux has the old
  bindings. `switchboard install` (idempotent) or `tmux source-file <your conf>`
  reloads them. `doctor` confirms with "NOT bound — running tmux is stale".
- **A session won't go away with `prune`.** Its project is unverifiable (moved or
  unregistered repo), so `prune` deliberately spares it. Use `quit` for a full
  teardown, or re-register/fix the repo path and prune again.
- **Badges are frozen.** `gh` auth likely lapsed; `doctor` reports it. Run
  `gh auth login`. A PR you closed *on GitHub* needs a manual `R` in the sidebar.
- **Completion sounds fire twice.** Check `doctor` for orphaned sidebar
  processes; they self-reap within a few seconds, but a persistent one means a
  pane closed uncleanly.
- **Deleting the workspace you're in.** Safe — switchboard switches you to home
  first, then kills it, so you land on the full tree, not a bare shell.

## Related

- [Reference: CLI](reference-cli.md) — `prune`, `quit`, `doctor`.
- [Reference: config](reference-config.md) — `prune_on_launch`.
- [Explanation: architecture](explanation-architecture.md) — why `sb/` is the ownership signal.
