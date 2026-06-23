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
bin/switchboard            # start: attach home from a shell, or toggle the sidebar inside tmux (alias: sb)
bin/switchboard install    # symlinks (switchboard + sb) onto PATH + wire tmux bindings + empty config (--no-tmux/--print-tmux/--tmux-conf)
bin/switchboard uninstall  # reverse install (both symlinks + tmux marker block + live unbind)
bin/switchboard doctor     # check that tmux/git/gh + config + install wiring exist
bin/switchboard init       # create ~/.config/switchboard/config.yml (empty; grown by the add-project flow)
bin/switchboard config     # open config.yml in $EDITOR (sidebar `e` does the same)
bin/switchboard sidebar    # run the persistent sidebar standalone (normally tmux-spawned)
bin/switchboard prune      # kill orphaned sb/ sessions (reconcile vs git worktrees; --dry-run/-n previews)
bin/switchboard quit       # close ALL sb/ sessions (full teardown; current session last)
bin/test                   # run the stdlib-Minitest suite (offline; bin/test <file> for one)
```

Setup is one command: `git clone && bin/switchboard install` (`Installer`,
`installer.rb`). It symlinks `bin/switchboard` to `~/.local/bin` (plus a short
`sb` alias beside it; a collided `sb` is skipped, the real command still
installs), adds a
marker-delimited line to the tmux.conf tmux actually loads (found via
`#{config_files}`) that sources the self-locating `switchboard.tmux` fragment,
and scaffolds an empty config. The fragment binds `prefix-s` (toggle) and three
indexed hooks: `client-session-changed[99]` (poke the now-visible sidebar to
reload on a session switch), `after-new-window[99]` (give a new window its own
sidebar when the session is showing one — see per-session visibility below), and
`session-window-changed[99]` (poke the sidebar on a same-session *window* switch,
which isn't a session change — `poke-window`, gated to `sb/` sessions so the
global hook no-ops elsewhere); `home` is intentionally not bound (configurable
keys are issue #15). All steps are idempotent and reversed by `uninstall` (which
clears all three hook slots — `Installer::HOOK_SLOTS`). `doctor` reports whether
those hooks are **live** in the running server, not just present in config (they
go stale after a `git pull` until tmux reloads).

Ruby **>= 3.0** is required (`Config` uses `YAML.safe_load_file`, added in Psych
3.3 / Ruby 3.0). `bin/switchboard` re-execs itself under a modern ruby if launched
on macOS system Ruby 2.6 — relevant because tmux panes run a non-interactive shell
that skips rbenv.

Useful env overrides when running locally without disturbing real state:
`SWITCHBOARD_CONFIG` (config path), `SWITCHBOARD_STATE_DIR` (agent-state files),
`SWITCHBOARD_ATTENTION_DIR` (bold "needs attention" markers),
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
(no fzf). It's the only navigator. The bound tmux key toggles it; bare
`bin/switchboard` is context-aware (`CLI#start`) — inside tmux it toggles the
sidebar like the key, from a plain shell it bootstraps and attaches the home
session (`Tmux.go_home`), so launching switchboard is a single command.
`view.rb` is now reduced to the
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

**Sidebar visibility is per-session, applied to every window** (issue #24). The
intent lives on the session as a tmux option (`@sb_sidebar` on/off; unset reads
as on, preserving auto-show). `Tmux.reconcile_sidebars` is the one primitive that
spawns-or-kills each window's sidebar to match: `prefix-s` (`Tmux.toggle_sidebar`,
switchboard's one summon/dismiss verb — visible ⇒ dismiss session-wide, hidden ⇒
summon every window AND focus the tree) flips the flag and reconciles every window;
`ensure_session` stamps `on` on first creation; `go`/`go_home` reconcile to the
saved flag on switch-in (and `go_home` always restores the navigator). New
windows are covered by the `after-new-window[99]` hook → `sidebar-sync <window>`,
which spawns one iff the session opts in. No spawn recursion: the sidebar is a
`split-window`, which fires `after-split-window`, not the hooked `after-new-window`.

**A *shown* sidebar still goes dormant while off screen.** Every window keeps its
own sidebar process, so at any moment most of them are on inactive windows. Each
caches whether it's currently on screen in `@visible` (the single flag, mutated
only via `set_visible`); `render` and the spinner/blink (`pulsing?`) are gated on
it, and `frame_timeout` drops an off-screen sidebar from the `REFRESH` cadence to
a long `IDLE` backstop. So an off-screen sidebar does essentially nothing — no
paint, no agent scan, just one cheap visibility check per `IDLE` — until a poke
wakes it: a session switch (`client-session-changed` → C-l) or a same-session
window switch (`session-window-changed` → `poke-window` → C-l). The C-l handler
`reload_and_refresh` **re-samples** `Tmux.visible?` rather than assuming the poke
means on-screen, because the same C-l is also sent by background PR-refresh
children (`maybe_refresh_prs --poke`) to a pane you may have navigated away from —
marking that hidden pane visible would re-wake it. An un-poked reappearance (a
window switch on a tmux too old for the hook, a bare `tmux attach`) is caught by
the off→on `reappeared` branch in `tick` within `IDLE`.

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

### Completion sounds (the audible twin)

`Sound` (`sound.rb`) plays a short sound when a worktree's hook state newly
enters a resting state — the same `Sidebar.completion_edges` the PR refresh
rides. Both consumers live in `Sidebar#on_agent_edges`: it computes the edges
once, runs the PR refresh **first**, then `play_sounds_for` (fully rescued), and
advances `@prev_hook_states` in an `ensure` — so a sound fault can never starve
the PR trigger, blank the dots (the broad `refresh_agents` rescue), or corrupt
the next edge diff. Hook-only states, like the PR trigger, so observation-only
agents make no sound. Deduped per `[worktree, state]`: every distinct worktree's
completion is heard, but one worktree can't double-fire in a scan.

Each window's sidebar is its own process with its own `@prev_hook_states`, frozen
while off-screen — so a naive scan on switch-in would re-ring every completion
that finished while that sidebar slept (already heard from the sidebar on screen
then), spraying duplicates as you move between sessions. Catch-up scans (the
switch poke `reload_and_refresh`, and the off→on `reappeared` branch in `tick`)
therefore reload with `announce_sounds: false`: they re-baseline and still
refresh PRs, but ring nothing. Only continuous while-visible scans announce — so a
completion is heard once, from wherever you're watching when it lands.

That "one visible sidebar at a time" guarantee assumes a dead sidebar process
actually exits — and one almost didn't. A sidebar whose pane closed used to keep
looping: `read_key` swallowed the stdin `EOFError`, and nothing checked that the
pane still existed. Because tmux **recycles `%pane-id`s**, the orphan's frozen
`ENV["TMUX_PANE"]` would later name a *different, live* pane; when that pane was
on the attached/active window the orphan's `Tmux.visible?` read true, so it ran
announcing scans and rang completions **in parallel with the real owner** —
duplicate (sometimes triple) sounds, intermittent because it depended on which
recycled id currently mapped to the visible pane. Two guards close it:
`read_key` now returns `:eof` (the run loop exits on it) for the clean
pane-close, and `owns_pane?` compares the pane's current `#{pane_tty}`
(`Tmux.pane_tty`) against the pty captured at startup — tmux keeps a pane's pty
stable for its whole life but recycles ids, so a **confirmed** different tty
means our id was handed to another pane, and `tick` returns false to exit. A
`nil` reply is deliberately *not* treated as disownership: it can't be told
apart from a transient `display-message` failure, and self-terminating a healthy
sidebar on a flaky shell-out is worse than the leak it would prevent — every
other tmux call here degrades rather than acts on a transient miss. A genuinely
dead pane reads `visible?`=false (silent, never rings) and is reaped the instant
its id is recycled onto a live pane — exactly when it could otherwise turn
harmful. So the recycled-id orphan, the one that rings duplicates, stops within
one `IDLE` tick before it can ring.

The two defaults are **synthesized** (16-bit PCM WAV via `Array#pack`) and
materialized into the XDG data dir on first use (atomic temp+rename, so racing
sidebar processes never read a half-written file) — same self-healing trick as
`Hook.ensure_script`, no shipped binary assets. Config resolves a state to a
built-in name (`train`/`chime`, plus the variants `train_1..3` / `chime_1..3`), a
file path, or a bare macOS system-sound name,
via `Config#sound_for` (global default + per-project override, like
`session_command_for`; mute only via `enabled: false`). Bump
`Sound::ASSET_VERSION` to regenerate the cached WAVs.

### Bold until viewed (the visual twin)

`Attention` (`attention.rb`) bolds a workspace's name in the sidebar from the
moment its hooked agent finishes a turn (`:done`) or asks for input
(`:waiting`) until you actually look at it — so a completion you weren't
watching can't slip past unnoticed. It rides the **same `completion_edges`** as
the sound/PR triggers (the third consumer in `Sidebar#on_agent_edges`), but with
two deliberate differences from the sound: (1) it is **persistent on-disk
state**, one marker file per worktree in a `switchboard/attention` sibling of the
agent-state dir — because every window's sidebar is its own process, only a
shared file renders bold consistently across all of them (same reasoning as the
hook-file dots); and (2) it is **not gated by `announce_sounds`** — which process
writes the marker doesn't matter (idempotent create/delete, GC'd like the hook
files), so catch-up scans mark too. The workspace you're *currently in* is never
marked (`viewing?` skips it on the edge, and `locate` clears the marker the
instant you switch in — bold gone on view, no input required). To keep that
clearing correct, `reload` runs `locate` **before** `refresh_agents`.

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
