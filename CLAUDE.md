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
for the user-facing feature tour, and `docs/` for the full Diataxis documentation
set. The explanation docs (`docs/explanation-architecture.md`,
`explanation-agent-presence.md`, `explanation-sidebar-lifecycle.md`) are the
human-readable companions to this file; `CONTRIBUTING.md` collects the
test/zero-gem/release conventions; `AGENTS.md` is the tool-neutral pointer back
here.

## Commands

```sh
bin/switchboard            # start: attach home from a shell, or toggle the sidebar inside tmux (alias: sb)
bin/switchboard install    # symlinks (switchboard + sb) onto PATH + wire tmux bindings + empty config (--no-tmux/--print-tmux/--tmux-conf)
bin/switchboard uninstall  # reverse install (both symlinks + tmux marker block + live unbind)
bin/switchboard doctor     # check that tmux/git/gh + config + install wiring exist
bin/switchboard init       # create ~/.config/switchboard/config.yml (empty; grown by the add-project flow)
bin/switchboard config     # open config.yml in $EDITOR (sidebar `e` does the same)
bin/switchboard sidebar    # run the persistent sidebar standalone (normally tmux-spawned)
bin/switchboard rename NAME # rename the current workspace from inside it (dir move + bridge + session rename + Claude `/resume` history carry + the git branch when safe — see #94); for the agent to (re)name its own live workspace (#42). No NAME prints usage + the current name (switchboard doesn't guess one)
bin/switchboard prune      # kill orphaned sb/ sessions (reconcile vs git worktrees; --dry-run/-n previews)
bin/switchboard quit       # close ALL sb/ sessions (full teardown; current session last; clears agent state)
bin/test                   # run the stdlib-Minitest suite (offline; bin/test <file> for one)
```

Setup is one command: `git clone && bin/switchboard install` (`Installer`,
`installer.rb`). It symlinks `bin/switchboard` to `~/.local/bin` (plus a short
`sb` alias beside it; a collided `sb` is skipped, the real command still
installs), adds a
marker-delimited line to the tmux.conf tmux actually loads (found via
`#{config_files}`) that sources the self-locating `switchboard.tmux` fragment,
and scaffolds a config (an **annotated template** — `Config::SCAFFOLD_TEMPLATE`,
whose only uncommented keys are `worktree_root` + `projects`, so it parses to
`default_data` while showing every optional knob commented out; comments are
stripped on the first `add_project` YAML.dump rewrite, after the new user has read
them). The fragment runs `switchboard tmux-bind` (which
binds the configured keys — see keybindings below) and sets three indexed hooks:
`client-session-changed[99]` (poke the now-visible sidebar to reload on a session
switch), `after-new-window[99]` (give a new window its own sidebar when the session
is showing one — see per-session visibility below), and `session-window-changed[99]`
(poke the sidebar on a same-session *window* switch, which isn't a session change —
`poke-window`, gated to `sb/` sessions so the global hook no-ops elsewhere). All
steps are idempotent and reversed by `uninstall` (which clears all three hook slots
— `Installer::HOOK_SLOTS` — plus the bound keys and `@switchboard-*` options). `doctor` reports whether
those hooks are **live** in the running server, not just present in config (they
go stale after a `git pull` until tmux reloads). `doctor` also flags **orphaned
sidebar processes** — a `switchboard sidebar` that outlived its pane — by diffing
the running-process count (`pgrep`) against the sidebar-pane count
(`Tmux.sidebar_pane_count`); a straggler matters because tmux recycles pane ids,
so it can end up reading a different live pane and double-fire completion sounds.

**Configurable keybindings (issue #15).** The fragment delegates binding to
`switchboard tmux-bind` (`Installer.apply_keybindings`), which reads `tmux_keys:`
from config (`Config#tmux_key` — global, resolve-with-default like `sound_for`;
`toggle` defaults to `s`, `home` is unbound). Cleanup tracks the key it bound last
in tmux options (`@switchboard-toggle-key` / `@switchboard-home-key`) and unbinds
exactly that — never a scan of `list-keys`, so it can't clobber a user's own
`switchboard` binding and survives a repo move (tmux key bindings and `@options`
share a lifetime: both die on server restart). It binds before it unbinds, so a
key tmux rejects falls back to the default without stranding the recovery key, and
records a displaced foreign binding in `@switchboard-*-clobbered` for `doctor` to
warn about. The decision is the pure `Installer.rebind_ops` (unit-tested via the
`run_tmux` seam); validation is a **minimal denylist** (`Config#valid_tmux_key?`) —
tmux is the authority on real keys. Editing `tmux_keys` via `e`/`switchboard config`
re-applies immediately (`reload_config_poke` / `edit_config` call `apply_keybindings`,
`announce: true` flashing the result); a from-scratch `install` still needs a tmux
reload. A malformed config no longer crashes anything — `Config#initialize` rescues
the parse error to `{}` + `load_error` (the sidebar keeps its last-good config; the
`tmux-bind` path falls back to defaults; `doctor` reports it).

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

**Workspace naming is deferred** (issue #94). Creating a worktree without a name
(`n` in the sidebar, bare ↵) gives it a **placeholder** — a throwaway adjective-noun
leaf from `Placeholder.generate` (`placeholder.rb`, a tiny in-repo word list, no
gem) — and a matching branch, so you start work before naming it. `Creator.create`
cuts the branch with `--no-track` so a branch off `origin/main` doesn't inherit it
as an upstream (else the rename gate below would misread every fresh worktree as
"pushed"); generated names retry past a dir/branch collision. `Rename.perform` then
renames **both** the dir (bare `<name>`) and the branch (`<branch_prefix>/<name>`) —
but only when the branch is **unsynced-safe**: still the auto-created branch (its
basename still equals the old leaf) AND not pushed (`Git.pushed?` = a
remote-tracking ref exists, NOT `@{upstream}`). A pushed/diverged branch is left
intact (dir-only rename). All branch checks (`valid_branch_name?`, `branch_exists?`
⇒ the `:branch_exists` result) run BEFORE any move, and the branch is renamed first,
so a collision fails clean (nothing moved) and the agent retries with another name.

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
   The flip side: because a fresh file is trusted without a liveness check, a
   `quit` that kills every agent leaves their last states stale (a lingering
   `:thinking` would read as a live, working agent for up to the TTL). So both
   quit paths (`Sidebar#quit`, `CLI#quit`) call `AgentState.clear_all` to wipe
   the state dir before tearing down; a restarted agent re-reports on SessionStart.
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
`agent_state_hooks?` **or** `auto_rename_for(project)` — resolved per project, so a
project that opts into `auto_rename` with the global off still gets the hook the
runtime nudge needs); existing ones via `switchboard enable-hooks`.

### Agent self-naming nudge (issue #92)

`Hook.enable` also plants a **second `SessionStart` command** beside the reporter:
`switchboard rename-nudge` (re-invoking the binary, so it carries `NUDGE_MARK` and
`Hook.ours?` recognizes both commands for idempotent merge / clean disable). It's
`command -v`-guarded (`… && … rename-nudge || true`) so a baked bin path gone stale
after a repo move is a silent no-op at session start, never a "command not found". When
`auto_rename` is on (`Config#auto_rename?` / `auto_rename_for`, global + per-project,
default off), that subcommand (`CLI#rename_nudge`) injects a `SessionStart`
`additionalContext` instruction telling the running agent to `switchboard rename` the
workspace once it understands the work — which (post-#94) names the dir and its branch.
"Still unnamed" is **derived, not stored**: `Placeholder.generated?(leaf)` (the leaf is
a generated `adjective-noun`) is the signal, so it self-clears on rename — no marker
file. `RenameNudge.decide` is the pure gate (fires on `source ∈ {startup,resume,compact}`
when on + placeholder); the subcommand resolves the worktree from the hook's stdin `cwd`
(via `current_worktree`), and **always exits 0 with only the JSON or nothing on stdout**
(a stray byte poisons Claude startup; the whole body is rescued to silence).

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

### Shared project collapse (the same multi-process trick)

Folding a project header (▸/▾ on ↵) hides its workspace rows. `Collapse`
(`collapse.rb`) keeps that fold **on disk, not in a sidebar ivar**, for the exact
reason the dots and bold do: every window's sidebar is its own process, so a fold
held in one process's `@collapsed` would leave every other pane — and every
respawn (toggle off/on, a new window, a reconcile) — showing the project expanded.
One file per collapsed project (name digest → name, `SWITCHBOARD_COLLAPSE_DIR` /
`XDG_STATE_HOME`), so a toggle is a single atomic create/delete (`collapse` /
`expand`) with no read-modify-write race, mirroring `Attention`. `rebuild`
**hydrates** `@collapsed` from the store every reload (so a fold made in one window
lands in the others on their next switch-in poke or while-visible scan);
`toggle_collapse` writes through *and* updates the in-memory set for same-frame
feedback. Unlike the attention markers it is a **durable view preference** — NOT
cleared on `quit`; a folded project stays folded across restarts. `collapsed`
GCs a fold whose project is no longer configured, but only when handed a
non-empty project list (the key is a name, not a checkable path, so a transient
empty/failed config can't wipe a user's folds).

### Full header on every session (the same trick, one global flag)

The home sidebar always seats the full brand header — wordmark + greeting +
console + rule (`Sidebar#header`); every other session shows just the wordmark.
`H` toggles that full header onto **all** sessions. `FullHeader` (`full_header.rb`)
keeps the flag **on disk, not in a sidebar ivar**, for the same multi-process
reason as `Collapse`/`Attention`/the dots: only a shared flag renders the same
header in every window's pane (and survives a respawn). It's a **single** marker
file whose mere existence is the flag (`SWITCHBOARD_FULL_HEADER_FILE` /
`XDG_STATE_HOME`), so a toggle is one idempotent create/delete — and because only
existence is read (never the contents), no temp+rename dance is needed (unlike
`Collapse`, which reads names). `rebuild` **hydrates** `@full_header` every reload
(so a flip in one window lands in the others on their next poke/scan);
`toggle_full_header` writes through *and* flips the in-memory flag for same-frame
feedback. Like the folds it is a **durable view preference** — NOT cleared on
`quit`.

### Sidebar width (the same trick, holding a number)

The sidebar pane was a hardcoded 40 cols (`Tmux::SIDEBAR_WIDTH`) that
`pin_if_resized` re-asserted every paint — so a naive `resize-pane` was clobbered
by the next pin. `←`/`→` in the tree now step the width (`WIDTH_STEP` cols/press,
issue #78), and the chosen width is the value the pin **respects**. `Width`
(`width.rb`) keeps it **on disk, not in a sidebar ivar**, for the same
multi-process reason as `Collapse`/`FullHeader`/the dots: only a shared value sizes
every window's pane alike (and survives a respawn). A **single global** file
(`SWITCHBOARD_WIDTH_FILE` / `XDG_STATE_HOME`) like `FullHeader`, but holding an
**integer** — so unlike the existence-only flag the value is *read*, which means a
torn write could misread; hence `Collapse`'s atomic temp+rename. `resolved` clamps
to `[MIN, MAX]` and degrades to `DEFAULT` (40) on a missing/garbage/torn file, so a
bad read just sizes the pane normally. `Tmux.pin(pane, width = Width.resolved)`
defaults to it (every cross-session caller pins to the saved width, no flash); the
sidebar's per-tick `pin_width` passes its hydrated `@width` to skip a disk read in
the hot loop. `spawn_sidebar`'s `-l` uses the saved width too, but clamped through
`fit_width` against the target window's `window_cols` (keeping `RESERVE_COLS` for the
work pane) — else a width chosen on a wide client would make `split-window` fail and
leave a narrow client with no sidebar at all. `rebuild` **hydrates** `@width` every
reload (a resize in one window lands in the others on their next poke/scan) — and
when the hydrated width *changed*, it nils `@geom` so the next `pin_if_resized`
actually re-pins; otherwise that throttle would short-circuit on the peer pane's
still-unchanged geometry and leave it stuck at the old width until a cross-session
re-pin. Like the folds it is a **durable view preference** — NOT cleared on `quit`.

The held-key detail: `resize` is **flag-only** (clamp `@width`, set `@resized`) —
no I/O. `handle` drains a whole autorepeat burst calling it per token, then the run
loop fires `commit_resize` **once** (one `Width.set` + one `resize-pane`), and
`render` reflows to the new `winsize` next iteration. So holding `←`/`→` resizes
smoothly instead of flooding one subprocess + disk write per repeat; `@geom`
self-heals on the next `pin_if_resized` (it pins to the same `@width`, never
fighting the resize). In `/` filter mode `←`/`→` are inert (the escapes aren't
printable, so `filter_key` ignores them) — movement-free there like `j`/`k`.

### Workspace diff counts (off-paint, per-process, mtime-gated)

Each ws/br row shows `+adds −dels` of its branch vs base (`base...HEAD`, committed
— not the working tree) just left of the PR badge (issue #79). Like the per-worktree
`git status` the model skips (`with_dirty: false`), a `git diff` per worktree can't
ride the synchronous paint, so it gets the **agent-dot / PR-badge treatment**: a
per-process `@diffs` cache (`[path, branch] => [logs/HEAD mtime, adds, dels]`)
refreshed by `Sidebar#refresh_diffs` off the paint loop. NOT shared on disk (a count
isn't a view preference) and NOT on the every-3s scan — it rides exactly the issue's
triggers: `reload` (switch-in / idle / tree-tick) and `on_agent_edges` (a finished
turn likely just committed). `Git.diff_counts` uses `--numstat` (the localized
`--shortstat` summary would slip past a word regex on a non-English git) and
`Git.range(base, ref)` so an inline branch row diffs its *own* ref, not HEAD.

The cache key is the worktree's `logs/HEAD` mtime, **stat'd fresh** in `refresh_diffs`
— NOT reused from `@branch_cache[path][1]`, which only refreshes on `rebuild`; the
`on_agent_edges` caller has no rebuild, so a cached mtime would compare stale-to-stale
and skip the just-landed commit. Only the gitdir (`@branch_cache[path][0]`, stable +
already absolute — the relative-`.git` bug that once blanked the tree) is reused.
`refresh_diffs` computes **value-or-nil** and `delete`s on nil, so a row that loses
its cache slot, base, or diffability clears instead of painting a ghost count. A
**MERGED/CLOSED** PR row bypasses the mtime gate: origin fast-forwarding past a merged
branch zeroes `base...HEAD` without moving `logs/HEAD` (the PR badge's blind spot),
and `R` (`refresh_prs_now`) clears `@diffs` as the manual catch-all. `View.diff_label`
(plain, for width math) / `diff_tag` (green adds / red dels) mirror the `pr_*` pair and
abbreviate counts ≥1000 (`1.5k`) so a huge diff can't swallow the name in the pane.

### Type-to-filter (the deliberately un-shared one)

`/` enters an in-sidebar incremental filter (issue #60) — fzf-style, but NOT the
removed external `fzf` popup: it's the same single navigator, just searchable.
`@filter` is `nil` (off) or a query string; `recompute_rows` branches on it to
`filtered_rows`, which keeps each project's matching ws/br rows **under their
header** (the grouping you navigate by stays visible) — a header with no match is
dropped. Matching is the pure `Sidebar.fuzzy_match?` (case-insensitive
subsequence) over `filter_text` (project + name/branch). Filtering spans the
**whole tree, collapse ignored** — the point is reaching any workspace fast, even
a folded one. Entry (`start_filter`) leaves the cursor on the first row; a query
keystroke then snaps it to the first workspace match (so type-then-`↵` jumps),
but headers ARE selectable — `↵` (`switch_to_filtered`) is
context-sensitive: a workspace switches, a **project header creates a new
workspace there** (`create(node)`; collapse is meaningless mid-filter, so
`↵`-on-project becomes the project-level action). Backspacing past an empty query
exits, like Esc. `dispatch` routes every key to `filter_key` while `@filter` is
set: printables extend the query, `↵`/`Esc` open-or-create/cancel, and crucially
no destructive key (`d`/`q`) can fire mid-search. `footer` swaps to
`filter_footer` (live query + a `↵`-label that tracks the row + a workspace-only
match count); a `/ filter` hint rides the nav line otherwise.

Movement in the tree is **arrows / `^N`/`^P` / `j`/`k`** (vi-style down/up). In
filter mode `j`/`k` are query input instead — there movement is arrows / `^N`/`^P`
only, so any name stays reachable by typing (see #60).

Unlike `Collapse`/`Attention`/the dots, this is **deliberately NOT shared on
disk** — a search is a transient act, not a view preference, so it's a plain
per-process ivar. A background reload re-applies it (recompute is filter-aware),
but it's never persisted, GC'd, or seen by another window's pane.

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
