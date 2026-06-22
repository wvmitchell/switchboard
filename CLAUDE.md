# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Switchboard is a keyboard-only switcher/creator for git-worktree workspaces — a
terminal-native alternative to Conductor/emdash. It's pure Ruby with **zero gem
dependencies**: everything is stdlib plus shelling out to `tmux`, `git`, and
`gh`. There is no Gemfile and no build step. The test suite is stdlib Minitest
(no gems) under `test/` — run the whole thing with `bin/test`, or one file with
`bin/test test/installer_test.rb`. Every test runs **offline**: `SandboxTest`
(`test/test_helper.rb`) walls off real state — config, XDG dirs, git global,
`HOME`, `TMUX` — into a tmpdir, and its `temp_git_repo` helper spins up throwaway
repos for the git-backed tests (tmux/gh shell-outs are stubbed). See `README.md`
for the user-facing feature tour.

## Commands

```sh
bin/switchboard            # toggle the sidebar in the current tmux window
bin/switchboard install    # symlink onto PATH + wire tmux bindings + empty config (--no-tmux/--print-tmux/--tmux-conf)
bin/switchboard uninstall  # reverse install (symlink + tmux marker block + live unbind)
bin/switchboard doctor     # check that tmux/git/gh + config + install wiring exist
bin/switchboard init       # create ~/.config/switchboard/config.yml (empty; grown by the add-project flow)
bin/switchboard config     # open config.yml in $EDITOR (sidebar `e` does the same)
bin/switchboard sidebar    # run the persistent sidebar standalone (normally tmux-spawned)
bin/switchboard prune      # kill orphaned sb/ sessions (reconcile vs git worktrees; --dry-run/-n previews)
bin/switchboard quit       # close ALL sb/ sessions (full teardown; current session last)
bin/test                   # run the stdlib-Minitest suite (offline; bin/test <file> for one)
```

Setup is one command: `git clone && bin/switchboard install` (`Installer`,
`installer.rb`). It symlinks `bin/switchboard` to `~/.local/bin`, adds a
marker-delimited line to the tmux.conf tmux actually loads (found via
`#{config_files}`) that sources the self-locating `switchboard.tmux` fragment,
and scaffolds an empty config. The fragment binds `prefix-s` (toggle) and an
indexed `client-session-changed[99]` poke hook; `home` is intentionally not
bound (configurable keys are issue #15). All steps are idempotent and reversed
by `uninstall`.

Ruby **>= 3.0** is required (`Config` uses `YAML.safe_load_file`, added in Psych
3.3 / Ruby 3.0). `bin/switchboard` re-execs itself under a modern ruby if launched
on macOS system Ruby 2.6 — relevant because tmux panes run a non-interactive shell
that skips rbenv.

Useful env overrides when running locally without disturbing real state:
`SWITCHBOARD_CONFIG` (config path), `SWITCHBOARD_STATE_DIR` (agent-state files),
`XDG_DATA_HOME`/`XDG_STATE_HOME` (reporter script + state dirs).

## Architecture

**Git is the source of truth at runtime; the config is just a project registry.**
Worktrees are discovered live via `git worktree list`; the config
(`~/.config/switchboard/config.yml`) only lists which repos to scan. emdash and
Conductor are peer tools whose worktrees still show up (git finds them), but
there's **no database coupling** — `install`/`init` write an empty config and
the add-project flow grows it (the old emdash SQLite seed import was removed in
issue #3). PR badges come from `gh`, cached on disk (`~/.cache/switchboard/prs`)
so the UI never blocks on the network.

**One data model, one front-end.** `Model` (`model.rb`) assembles the
`project → worktree` tree from `Config` + `Git` + cached `Pr` data. `Tree.nodes`
(`tree.rb`) turns that into ordered `Node` structs, which the **persistent
sidebar** (`sidebar.rb`) draws as a hand-rolled ANSI TUI in a narrow tmux pane
(no fzf). It's the only navigator — the bare `bin/switchboard` command and the
bound tmux key both just toggle this sidebar. `view.rb` is now reduced to the
compact PR-badge helpers the sidebar uses (`pr_identifier` / `pr_tag`: state via
color, just the `#number` to fit the ~40-col pane).

> Until recently there was a second front-end — an `fzf` popup picker
> (`picker.rb`, `Tree.lines`, the `view.rb` preview functions, and `_`-prefixed
> fzf-callback subcommands in `cli.rb`). It was removed so the sidebar is the
> single source of truth; if you see references to it in old commits or issues,
> that's why it's gone.

The sidebar expands a workspace that has multiple branches in its HEAD-reflog
history into inline child rows (`Git.branch_history`) — the
multiple-PRs-per-workspace case. The canonical trunk checkout (`primary`) is
always filtered out as a switch target.

**The binary re-invokes itself to spawn the sidebar.** `bin/switchboard` exports
its own absolute path as `SWITCHBOARD_BIN`; `tmux.rb` uses it to `split-window`
a pane running `switchboard sidebar` beside each session. `cli.rb` dispatches the
user-facing commands plus the tmux-internal `toggle-sidebar` / `poke-sidebar`.

**tmux mapping** (`tmux.rb`): each worktree ⇆ one session named
`sb/<project>/<leaf>`. Switching creates the session on demand and attaches a
fixed-width sidebar pane. The sidebar reloads on session-change via a tmux hook
that "pokes" it with `C-l` (`poke-sidebar`). On the *creation* of a session
(only — never a re-switch), `Tmux.go(worktree, start:)` types the project's
resolved `session_command` (`Config#session_command_for`, global default +
per-project override) into the window — this is the "how the agent starts" knob,
e.g. `claude --dangerously-skip-permissions`. Empty ⇒ a plain shell, as before.

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
- Stateless helpers are `module_function` modules (`Hook`, `Tmux`, `Installer`,
  …); only `Model`, `Config`, `Sidebar`, and `AgentState` are classes (they hold
  state).
- All shell-outs escape args with `Shellwords` and swallow stderr; failures
  degrade gracefully (return `[]`/`{}`/`nil`) rather than crash the UI.
- Code is meant to be self-documenting; the existing comments explain *why* a
  non-obvious thing is done (the re-exec, the TTL, the capture-hash). Match that
  density — terse, only where the reason isn't on the surface.
