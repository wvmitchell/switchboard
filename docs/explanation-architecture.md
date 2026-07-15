# Explanation: architecture

This explains *why* switchboard is shaped the way it is — the decisions a
contributor (or a future you) needs to hold in mind before changing anything. For
the *what*, see the [reference docs](reference-cli.md); for the agent-facing map,
see [CLAUDE.md](../CLAUDE.md).

## The problem

Conductor and emdash give a great glanceable view of parallel agent workspaces,
but they own a database, run an Electron app, and want the mouse. Switching
between worktrees means reaching for a trackpad or a command palette. The goal
was the same overview, driven entirely from the keyboard, with no daemon, no
database, and no build step — something that stands up on a fresh machine in one
command and gets out of the way.

That goal forces a few decisions.

## Git is the source of truth at runtime

Switchboard does not maintain a database of worktrees. It runs `git worktree
list` and renders what it finds. The config (`~/.config/switchboard/config.yml`)
is *only a registry* of which repos to scan — names and paths, plus a few
optional knobs.

This is the single most important design choice, and most of the others follow
from it:

- **No sync problem.** A worktree you create with plain `git`, or that emdash or
  Conductor creates, shows up the instant git knows about it. There's nothing to
  reconcile, no import step, no stale rows. emdash and Conductor are peers, not
  dependencies — their worktrees appear because git finds them.
- **No coupling.** The old emdash SQLite seed import was removed (issue #3).
  `install`/`init` write an empty config; the add-project flow grows it.
- **PR badges are the one thing git doesn't know,** so they come from `gh` —
  cached on disk (`~/.cache/switchboard/prs`) so the UI never blocks on the
  network. That cache is the only piece of external state, and it self-refreshes
  (see [agent presence](explanation-agent-presence.md) for the triggers).

The trade-off: every render shells out to `git`. That's cheap (worktree list is
fast, and the per-worktree reflog parse is cached by mtime), and it buys
correctness for free — the map is never out of date with the territory, because
the territory *is* the map.

## One data model, one front-end

```
Config ─┐
Git ────┼──▶ Model ──▶ Tree.nodes ──▶ Sidebar (the only front-end)
Pr  ────┘   (project    (ordered      (hand-rolled ANSI TUI in a
            → worktree   Node structs)  narrow tmux pane)
            tree)
```

- **`Model`** (`model.rb`) assembles the `project → worktree` tree from `Config`
  + `Git` + cached `Pr` data. A `Worktree` knows its branch (live HEAD, from git),
  its PR badge, and whether it's the project's primary checkout. (The struct also
  carries a dirty flag, but the sidebar builds the model `with_dirty: false` — 16
  per-worktree `git status` calls would be too slow on the synchronous paint, so
  dirty is left unread.)
- **`Tree.nodes`** (`tree.rb`) flattens that into an ordered list of `Node`
  structs: a project header, its workspaces, and — for a workspace that has held
  more than one branch — inline branch rows. The branch history comes from the
  worktree's own HEAD reflog (`Git.branch_history`), a signal neither GUI uses.
  This is the multiple-PRs-per-workspace case made visible.
- **`Sidebar`** (`sidebar.rb` — the run-loop core, plus the `sidebar/` concern
  files the #57 split carved out: `edges`, a collaborator owning the agent-edge
  fanout state, and the `render`/`input`/`actions`/`prompt`/`rows` concern
  mixins — one class in several files) draws the nodes as a 3-level tree in a
  fixed-width tmux pane. No fzf, no curses — a hand-rolled ANSI renderer. It is the *only*
  navigator.

The primary trunk checkout is always filtered out as a switch target (you never
switch *to* `main`).

> There used to be a second front-end — an `fzf` popup picker (`picker.rb`,
> `Tree.lines`, fzf-callback subcommands). It was removed so the sidebar is the
> single source of truth. References to it in old commits are stale.

## The binary re-invokes itself to spawn the sidebar

`bin/switchboard` exports its own absolute path as `$SWITCHBOARD_BIN`. `tmux.rb`
uses that to `split-window` a pane running `switchboard sidebar` beside each
session. So the sidebar is just the same binary in a different mode, and tmux —
not a daemon — owns its lifecycle. The same trick lets the tmux hooks call back
into the binary (`poke-sidebar`, `sidebar-sync`, `tmux-bind`).

## tmux is the window manager

Each worktree maps to exactly one tmux session named `sb/<project>/<leaf>`.

- **Switching** (`↵`) creates the session on demand and attaches a fixed-width
  sidebar pane. On *creation only* (never a re-switch), switchboard types the
  project's resolved `session_command` into the window — the "how the agent
  starts" knob. A live session is never disturbed.
- **Creating** (`n`) types more than that: a new worktree also gets its
  `worktree_creation_command` (the setup a fresh checkout needs — `.env`,
  `bundle install`), composed *ahead* of the agent as
  `sh -ec '<script>' && <session_command>`. The script goes to `sh -ec` as one
  argument so a multi-line script survives intact, and only the wrapper joins the
  `&&` — so a failed setup short-circuits the chain and the agent never opens on a
  half-built tree. Setup rides the create path alone; a later switch back carries
  the bare `session_command`, so it runs once per *worktree*, not per session.
- **The `sb/` prefix is the ownership signal.** There's no separate session
  registry; a session named `sb/…` is switchboard's, anything else isn't. This is
  what lets `prune` reconcile sessions against worktrees (`reconcile.rb`) without
  tracking state — it diffs the live `sb/` sessions against the worktrees git
  reports.
- **`sb/home`** maps to no worktree (it lives in `$HOME`), so it never matches a
  project prefix and is never pruned. It's the safe fallback (deleting the
  workspace you're *in* switches you here first, then kills it) and the stable
  launch base (bare `switchboard` from a shell lands here).

## Everything degrades, nothing crashes

The house rule, enforced everywhere: every shell-out escapes its args with
`Shellwords` and swallows stderr, and every failure returns `[]`/`{}`/`nil`
rather than raising into the UI. A lapsed `gh` token freezes the badges (it
doesn't blank them — see `Pr.refresh`); a malformed config degrades to empty and
is reported by `doctor` (`Config#load_data`); a missing audio player just stays
silent. The TUI is a long-lived loop with a person watching it, so a crash is the
worst outcome — worse than briefly-stale data. `doctor` exists precisely because
the UI degrades *quietly*: it's the honest surface where silent degradation
becomes visible.

## Trade-offs, named

- **Shelling out vs. a library.** Pure stdlib + `git`/`tmux`/`gh` subprocesses
  means zero gems and zero build step, but it means parsing porcelain output and
  paying process-spawn cost. Worth it: the install story is `git clone &&
  bin/switchboard install`, and the code stays readable.
- **Git as truth vs. a cache.** Re-deriving from git every render costs
  subprocesses but eliminates an entire class of staleness bugs. Caches are added
  only where the network is involved (PRs) or the parse is expensive (the reflog,
  memoized by mtime).
- **tmux as the substrate.** Leaning on tmux for sessions, panes, and hooks means
  switchboard does no window management itself, but it inherits tmux's quirks —
  most sharply, [recycled pane ids](explanation-sidebar-lifecycle.md), which drove
  a real duplicate-sound bug.

## Conventions

- Every file starts with `# frozen_string_literal: true`.
- Stateless helpers are `module_function` modules (`ClaudeHook`, `Tmux`, `Installer`,
  `Git`, `Pr`, …). Only `Model`, `Config`, `Sidebar` (plus its `Sidebar::Edges`
  collaborator — see above), and `AgentState` are classes — they hold state.
- Comments explain *why* a non-obvious thing is done, not *what* the code does.
  Match that density.

See [CONTRIBUTING](../CONTRIBUTING.md) for how this maps to the test suite.

## Related

- [Explanation: agent presence](explanation-agent-presence.md) — the dots, sounds, and bold.
- [Explanation: sidebar lifecycle](explanation-sidebar-lifecycle.md) — per-session visibility and the orphan bug.
- [Reference: config](reference-config.md) — the registry this all reads.
