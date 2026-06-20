# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Switchboard is a keyboard-only switcher/creator for git-worktree workspaces — a
terminal-native alternative to Conductor/emdash. It's pure Ruby with **zero gem
dependencies**: everything is stdlib plus shelling out to `fzf`, `tmux`, `git`,
`gh`, and (for a legacy one-time import only) `sqlite3`. There is no Gemfile, no
build step, and no test suite. See `README.md` for the user-facing feature tour.

## Commands

```sh
bin/switchboard            # open the switcher (run it to dev/test by hand)
bin/switchboard doctor     # check that fzf/tmux/git/gh/sqlite3 + config exist
bin/switchboard init       # create ~/.config/switchboard/config.yml (today: seeds from emdash if present — see #3)
bin/switchboard sidebar    # run the persistent sidebar standalone (normally tmux-spawned)
```

> **In flux (issue #3):** standing switchboard up is currently manual (symlink
> `bin/switchboard`, hand-add tmux bindings, hand-edit the config). A
> `switchboard install`/`uninstall` command and an emdash-optional `init` are
> planned. Verify the current command surface in `cli.rb` before documenting
> setup — this is the area most likely to have moved on.

Ruby **>= 2.7** is required (`filter_map` etc.). `bin/switchboard` re-execs
itself under a modern ruby if launched on macOS system Ruby 2.6 — relevant
because tmux popups run a non-interactive shell that skips rbenv.

Useful env overrides when running locally without disturbing real state:
`SWITCHBOARD_CONFIG` (config path), `SWITCHBOARD_STATE_DIR` (agent-state files),
`XDG_DATA_HOME`/`XDG_STATE_HOME` (reporter script + state dirs).

## Architecture

**Git is the source of truth at runtime; the config is just a project registry.**
Worktrees are discovered live via `git worktree list`; the config
(`~/.config/switchboard/config.yml`) only lists which repos to scan. emdash's
SQLite DB (`lib/switchboard/emdash.rb`) is a **legacy one-time import**, read
during `init` to seed that registry and never touched again at runtime — and
even that coupling is being decoupled (issue #3), so treat it as an optional
import path, not a core dependency. PR badges come from `gh`, cached on disk
(`~/.cache/switchboard/prs`) so the UI never blocks on the network.

**One data model, two front-ends.** `Model` (`model.rb`) assembles the
`project → worktree` tree from `Config` + `Git` + cached `Pr` data. `Tree`
(`tree.rb`) turns that model into an ordered list of rows, emitted two ways:

- `Tree.lines` → tab-delimited strings for the **fzf picker** (`picker.rb`,
  rendered by `view.rb`). Hidden fields after the visible column carry
  `path / branch / kind / project`.
- `Tree.nodes` → structured `Node` structs for the **persistent sidebar**
  (`sidebar.rb`), a hand-rolled ANSI TUI in a narrow tmux pane (no fzf).

Both expand a workspace that has multiple branches in its HEAD-reflog history
into inline child rows (`Git.branch_history`) — the multiple-PRs-per-workspace
case. The canonical trunk checkout (`primary`) is always filtered out as a
switch target.

**The binary calls back into itself.** fzf can't call Ruby methods, so
`bin/switchboard` exports its own absolute path as `SWITCHBOARD_BIN`, and
`picker.rb` builds fzf `--preview`/`--bind` commands that re-invoke that binary
with the `_`-prefixed internal subcommands (`_rowpreview`, `_pr`, `_new`,
`_refresh`). `cli.rb` dispatches both the user-facing and internal commands; the
`_`-prefixed ones are fzf callbacks, not public surface.

**tmux mapping** (`tmux.rb`): each worktree ⇆ one session named
`sb/<project>/<leaf>`. Switching creates the session on demand and attaches a
fixed-width sidebar pane. The sidebar reloads on session-change via a tmux hook
that "pokes" it with `C-l` (`poke-sidebar`).

### Agent-state dots (the subtle part)

The dot beside each workspace shows whether an agent (Claude/Codex/Aider) is
thinking / done / waiting. `AgentState.scan` (`agent_state.rb`) merges **two
presence signals** per worktree:

1. **Hook state (exact).** Claude Code reports state by running a tiny POSIX-sh
   reporter that writes `<state>\t<cwd>\t<epoch>` files into the state dir. A
   fresh file (within `PRESENCE_TTL`) *is* presence — no process check needed.
2. **Process/activity (coarse fallback).** For hook-less agents, `Agents.active`
   finds agent CLIs via tmux panes + `pgrep`/`lsof`, and busy-vs-idle is inferred
   by hashing `tmux capture-pane` between scans. This can't distinguish
   "waiting" from "done".

`Hook` (`hook.rb`) wires Claude up **per worktree, never globally**: it merges
into `<worktree>/.claude/settings.local.json` (and adds that path to the
worktree's local git excludes so it never dirties `git status`). The reporter
script is materialized into the XDG **data** dir — an install-independent path
that survives `brew upgrade` — and the hook command points there. New worktrees
get this automatically (`Creator.create` → `Hook.enable`, gated on
`agent_state_hooks?`); existing ones via `switchboard enable-hooks`.

### Conventions

- Every file starts with `# frozen_string_literal: true`.
- Stateless helpers are `module_function` modules; only `Model`, `Config`,
  `Sidebar`, `Emdash`, and `AgentState` are classes (they hold state).
- All shell-outs escape args with `Shellwords` and swallow stderr; failures
  degrade gracefully (return `[]`/`{}`/`nil`) rather than crash the UI.
- Code is meant to be self-documenting; the existing comments explain *why* a
  non-obvious thing is done (the re-exec, the TTL, the capture-hash). Match that
  density — terse, only where the reason isn't on the surface.
