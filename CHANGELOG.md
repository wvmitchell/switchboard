# Changelog

Notable changes per version. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); versions match the `vX.Y.Z`
prefixes in the git history and `lib/switchboard/version.rb`.

After upgrading, re-run `bin/switchboard install` (or reload tmux) so any new
tmux bindings/hooks go live — see the "Upgrading" section in the README.

## [0.41.0] — user-configurable in-sidebar keybindings (#108) (2026-06-29)

### Added
- **`sidebar_keys:` — remap the keys *inside* the sidebar (#108).** The in-pane sibling of
  #15's `tmux_keys:`. Map an **action** to a key (`new_workspace: c`, `delete: x`, …) rather
  than a raw byte, so the config records intent. The full action list is in the keybindings
  reference and the `?` overlay; omit an action to keep its default. Editing via `e` re-binds
  live on save.
- A single `Keymap` source of truth (an ordered action enum) now feeds the `dispatch` loop,
  the `?` help overlay, and `doctor` — so the shown keys can never drift from what actually
  fires. The overlay and footer render *your* keys, not the defaults.

### Changed
- Values are a **single printable character**, which reserves every structural key for free
  (`↵`, `Esc`, `Backspace`, the arrows, the resize `←`/`→`, and the `^N`/`^P`/`^O` movement
  aliases stay fixed — a remap can't shadow them, and movement can't be locked out). An
  invalid value or a clash (two actions on one key) degrades to defaults and is reported by
  `switchboard doctor`; nothing crashes.

## [0.40.0] — fold every workspace's branch rows with `z` (#107) (2026-06-29)

### Added
- **`z` — a global "toggle branches" key (#107).** A workspace that has held more than
  one branch expands into inline branch-history rows; that's useful occasionally and noise
  usually. `z` now folds **every** workspace's branch rows at once — tree-wide, regardless
  of where the cursor is — and `z` again brings them back. A folded multi-branch workspace
  collapses to a single row that shows its **own** diff/PR badge again (the expanded-row
  suppression from #90 only applies while the branches are visible) plus a dim `▸N` cue
  marking how many branches are tucked away.
- The fold is a **durable, shared-on-disk view preference** (`BranchFold`, a single
  existence-flag marker beside the project folds — the same shape as the `H` full-header
  toggle), so every window's sidebar folds alike, it survives a respawn, and it is **not**
  cleared on `q`. Default is unfolded, so nothing changes until you press `z`. The `?` help
  overlay and the keybindings reference document it.

## [0.39.1] — Codex hooks actually fire (the linked-worktree fix) (2026-06-29)

### Fixed
- **Codex agent-state hooks now fire in switchboard worktrees (#110, #130).** v0.39.0
  delivered Codex's hooks as a per-worktree `<worktree>/.codex/hooks.json`, but Codex
  0.142.x does **not** discover project-local hooks in a *linked* git worktree — and every
  switchboard workspace is a linked worktree, so the feature never fired in practice (it
  degraded silently to the coarse process/activity fallback). Codex delivery now ships as
  **one marker-delimited `[hooks]` block in your global `~/.codex/config.toml`**, which is
  config-level (not project-discovered) and so fires everywhere, including linked worktrees.

### Added
- **Consented global codex-hooks install.** `switchboard install` offers to write the
  global block (prompted; default no on a non-tty), or decide up front with
  `--codex-hooks` / `--no-codex-hooks`. `uninstall` removes it; `install` re-ensures an
  existing block so it doubles as a repair path. After installing, run `/hooks` in codex
  once to trust the hooks (or start codex with `--dangerously-bypass-hook-trust`).
- **Nested-codex guard (#130).** A global hook fires for every codex, including a nested
  `codex exec` under a `/codex` running inside Claude Code. Every command is prefixed with a
  `CLAUDECODE`/`CLAUDE_CODE_SESSION_ID` guard that suppresses the reporter under a Claude
  parent, so a subagent's codex doesn't report presence up to switchboard.

### Changed
- **Hook delivery split by agent.** Claude stays per-worktree
  (`.claude/settings.local.json`); Codex becomes the global, consented,
  Installer-managed block. The shared command strings, reporter, and rename-nudge/Stop
  wiring are centralized in `HookFile.command_entries`; the marker-block file surgery
  (atomic, symlink-aware, mode-preserving) is extracted to a shared `MarkerBlock` used by
  both the tmux.conf line and the codex config block. An age-based GC reaps the stray
  state files the global hook leaves in non-switchboard codex dirs.

## [0.39.0] — Codex gets the exact agent-state experience (#110) (2026-06-27)

### Added
- **Codex agent-state hooks — exact dots, completion sounds, attention-bold, and the
  self-naming nudge for Codex-first users (#110).** Previously everything exact was wired
  to Claude Code and Codex fell through to the coarse process/activity fallback (no real
  `waiting`, no completion sound, no nudge). Now a Codex worktree gets the same precise
  thinking/done/waiting dot Claude does.
- **Per-agent hook adapter layer.** A new `AgentHooks` registry fans out over `Hook`
  (Claude, `.claude/settings.local.json`) and `CodexHook` (`.codex/hooks.json`), both on a
  shared engine `HookFile` that owns the merge-safe enable/disable, the materialized sh
  reporter, and the rename-nudge/Stop wiring. An adapter declares only its delivery file and
  its event→state map. `enable-hooks` wires both (each dormant until that agent runs there).
- **`doctor` reports hook status per adapter** and flags the Codex trust caveat (project-local
  hooks load only once the project layer is trusted — `/hooks`).
- **Opt-in real-Codex smoke** (`test/smoke/codex_hook_smoke_test.rb`, run with
  `SWITCHBOARD_CODEX_SMOKE=1`): drives a real `codex` and asserts the project hooks fire, the
  event order holds, and the Stop chain releases — a standing guard against a Codex version
  silently breaking parity.

### Changed
- **`Hook` is now the Claude *adapter*, not the only hook path.** `Creator.create`,
  `enable-hooks`, `disable-hooks`, and `doctor` route through `AgentHooks` so a new worktree
  is wired for every supported agent.

### Fixed
- **The agent-state reporter command now shell-escapes the script path.** An inherited
  footgun: a space in `$XDG_DATA_HOME`/`$HOME` would split the command and the dot would
  silently never update. Fixed once in the shared engine.

## [0.38.1] — fill documentation gaps from recent features (2026-06-27)

### Added
- **`docs/reference-sidebar.md` ("Reading the sidebar")** — a new reference for the
  sidebar's visual vocabulary, which had no single home: the agent-state dots and the
  completion sparkle, the `»` current-workspace pointer, the bold-yellow "needs attention"
  name, the `+adds −dels` diff counts (committed `base...HEAD`, green/red, `1.5k`
  abbreviation, fixed columns), the `#pr` badge colours (open/draft/merged/closed), the
  `▸`/`▾` collapse glyphs, and the wordmark-vs-full header. Linked from the docs index, the
  tutorial, the keybindings reference, and the agent-presence explanation.

### Fixed
- **The tutorial described a name prompt that no longer exists.** Step 4 told you to press
  `n` and "type a name"; since #119 `n` creates a placeholder with no prompt. Rewrote it to
  the real flow (instant placeholder, rename later with `r` or let `auto_rename` name it).
- **`explanation-architecture` claimed the sidebar surfaces a worktree's dirty state.** The
  `Worktree` struct carries a dirty flag, but the sidebar builds the model `with_dirty:
  false` (16 per-worktree `git status` calls would be too slow on the synchronous paint), so
  it's never read. Corrected to say so.

### Changed
- **`reference-keybindings`** now lists `←`/`→` to resize the sidebar pane (#82) — present in
  the in-app `?` overlay but missing from the reference table.
- **`explanation-agent-presence`** updated from "three consumers" to **four** on the
  completion edge (the diff-count refresh rides it alongside the bold mark, PR refresh, and
  sound/sparkle).
- **`howto-manage-projects`** rename section now says `rename` syncs the branch name too when
  it's unsynced-safe (not just the directory); **`howto-housekeeping`** notes `quit` also
  preserves the full-header toggle and pane width, not only folded projects.

## [0.38.0] — diff counts and PR badges align into fixed columns (2026-06-27)

### Changed
- **The `+adds`, `−dels`, and `#pr` cells on each ws/br row now stack into straight,
  right-justified columns** instead of a flush-right block that floated with each row's
  widths (the old "staircase"). Column widths are a property of the whole visible row set,
  so they're measured once per render (`Sidebar#column_widths` over the full `@rows`,
  collapse-/filter-aware) and threaded into every `line`, which right-justifies each cell
  into its column. The diff column is split into an **adds sub-column** and a **dels
  sub-column**, each right-justified, so `+` numbers stack under `+` and `−` under `−`; the
  PR numbers stay right-flush to the pane edge exactly as before. An absent cell renders as
  aligned blanks rather than a gap that shifts its neighbour, so the #90 expanded-workspace
  suppression now reads as clean empty columns. The narrow-pane backstop still drops the
  whole diff column first (uniformly across rows, so the columns never split), keeping the
  name its `MIN_NAME_COLS`. Per-process, no shared state — each pane sizes its own columns.
  (#118)

## [0.37.3] — a split escape sequence can no longer open your repo on GitHub (2026-06-27)

### Fixed
- **Creating a workspace no longer sometimes throws you to the repo on GitHub.** The
  sidebar read keys in a fixed 8-byte chunk and sliced escape sequences at a fixed 3
  bytes. 8 isn't a multiple of 3, so the focus-event flurry tmux sends on a session
  switch (3 events = 9 bytes) got capped mid-sequence, orphaning the trailing byte of a
  focus-out `\e[O` — a bare `O`, which is the "open repo" key. So right after `n` created
  a workspace, you'd land on GitHub. Input is now read in a larger chunk and parsed by the
  real terminal grammar (`Sidebar.tokenize`): an incomplete escape sequence is carried to
  the next read and reassembled instead of having its final byte read alone as a key. A
  malformed CSI no longer swallows a following control key (the `\f` reload poke, Enter,
  ^N/^P/^R), and the carry is length-capped so a junk byte stream can't grow it unbounded.

## [0.37.2] — a new workspace no longer flashes as its panes resize on create (2026-06-27)

### Fixed
- **`n` now reveals a finished layout instead of a resize flash.** A new worktree's tmux
  session was created **detached** with no size, so it was born at tmux's 80×24 default —
  the moment you switched into it tmux resized the window to your client and every pane (the
  freshly split sidebar, the just-started agent) visibly reflowed: the "creating" flash.
  `ensure_session` now builds the session at the current window's size up front
  (`new-session -x/-y`, read via `current_window_size`), so the switch shows the final layout
  with nothing to move. Off-tmux (the exec-attach launch path) the size is unknown and
  omitted — the attach sizes the window as before; a `0` dimension is dropped rather than
  passed as `-x 0` (which tmux rejects with "width too small", which would turn a create that
  used to succeed at the default into a no-op). Unit tests cover the parse, the argv assembly,
  and the zero guard.
## [0.37.1] — a trailing slash on `branch_prefix` no longer breaks every create (2026-06-27)

### Fixed
- **`branch_prefix` now tolerates a surrounding slash.** Switchboard owns the separator
  (`[prefix, name].join("/")`), so a user-typed `branch_prefix: "wvmitchell/"` built the
  branch `wvmitchell//<name>` — an **invalid git ref**. `git worktree add` rejected it
  (stderr is swallowed), so *every* `n` failed, and the auto-name path reported the
  misleading "couldn't find a free placeholder name" — pointing at the wrong thing
  entirely. `r` rename hit the same ref the same way. `Config#branch_prefix` now strips
  leading/trailing slashes (`"wvmitchell/"` ⇒ `wvmitchell/<name>`), fixing create and
  rename at one point. A config unit test and a creator integration test (which actually
  cuts a worktree through a trailing-slash prefix) lock it.

## [0.37.0] — `auto_rename` is on by default (2026-06-26)

### Changed
- **Agent self-naming (`auto_rename`) now defaults on.** With #114 making `n` create
  placeholders the *only* way, something has to name them — so the agent does, by default.
  When on, each new worktree's Claude hooks plant a `SessionStart` nudge (and a `Stop`
  backstop) telling the agent to `switchboard rename` once it understands the work, naming
  the dir and its branch; it self-clears the moment the workspace is named. This is a pure
  runtime-behavior flip: the nudge commands were already wired into every worktree (they
  ride the agent-state hooks, which already default on — `Hook.enable` writes them
  unconditionally), they were just dormant while `auto_rename` resolved false. Set
  `auto_rename: false` (global or per-project) to opt out — the placeholder then stays
  until you rename it yourself with `r`. Non-Claude agents are unaffected. (#114 follow-up)

## [0.36.2] — real-tmux smoke test layer; the sidebar stops wedging on a closed work pane (2026-06-27)

### Added
- **A real-tmux smoke test layer (`bin/test-smoke`, issue #104).** The offline suite stubs
  every tmux call — right for unit tests, but structurally blind to the bugs that actually
  bite: the lifecycle ones (pane recycling, hook firing, split/kill timing, attach/detach).
  The new `test/smoke/` layer boots a real tmux server on an isolated socket, attaches a real
  client via the stdlib `PTY` (so the sidebar actually renders instead of staying dormant),
  sources the real `switchboard.tmux` hooks, and drives the real binary end-to-end through the
  create → switch → toggle → new-window → close-pane → rename → prune → quit lifecycle. It's
  deliberately out of `bin/test` (the fast offline suite stays the inner loop) and runs as its
  own blocking CI job. A socket-path guard refuses any destructive op not pointed at the
  throwaway server, so the harness can never touch your real `sb/` sessions.

### Fixed
- **The sidebar no longer wedges the window full-width when you close the work pane (#64).** A
  window is work-pane + sidebar (a split); closing the work pane left the sidebar the sole pane,
  which tmux forces to full width and keeps open. The sidebar now detects "I'm the only pane"
  (a confirmed `window_panes == 1`, degrade-safe like the recycled-`%id` guard — a flaky reply
  never self-terminates it): from a workspace it falls home and exits so the wedged window
  closes; from the home anchor it self-heals in place by re-growing a work shell beside the
  tree. It reaps within a frame on focus-in, and an off-screen sidebar never yanks the client
  home.

## [0.36.1] — slim the README into an inviting overview (2026-06-26)

### Changed
- **The README is now a glanceable overview, not a second copy of the docs.** It had
  grown to ~450 lines that re-documented install internals, housekeeping (with a raw
  shell teardown snippet), the full `config.yml` reference, the agent-state/hooks and
  sound internals, a keybindings deep-dive, and the whole CLI usage table — all of which
  the Diataxis [`docs/`](docs/README.md) set already covers in depth. It's now ~115 lines:
  a value-first hook, a concrete picture of the sidebar tree, a three-command quickstart,
  the five-key core loop (`a`/`n`/`↵`/`/`/`?`), and a clean hand-off to the docs — a more
  inviting first impression ahead of going open source. No behavior change; docs only.

## [0.36.0] — `n` auto-creates, no name prompt (2026-06-26)

### Changed
- **`n` now creates a workspace instantly with a placeholder name — no name prompt.**
  One keystroke instead of `n` → type → `↵`. Pressing `n` (and filter-mode `↵` on a
  project header) hands `Creator.create` a blank name, which cuts a throwaway
  `adjective-noun` placeholder dir + branch and drops you in. Naming moves to *after*
  creation — `r`, `switchboard rename`, or the agent self-naming nudge — doubling down
  on deferred naming (#94) and agent self-naming (#92). Someone who knows the name up
  front trades the prompt for create-then-`r`; accepted as rare and covered by `r`.
  The now-unused custom-hint plumbing on `prompt_line`/`draw_prompt` was removed (only
  `create` used it; `a`/`r` keep the default `(esc cancel)` hint). (#114)

## [0.35.4] — shared KeyedMarkerStore for Attention/Collapse (2026-06-26)

### Changed
- **`Attention` and `Collapse` now sit on a shared `KeyedMarkerStore`**
  (`keyed_marker_store.rb`, #95). The two near-identical keyed-marker stores — crc32-keyed
  files, atomic temp+rename writes, `scan`-with-GC — shared ~40 lines of copy-paste; that
  machinery is now one module both delegate to, each caller supplying only its domain
  (Attention's canonicalized-realpath value + `Dir.exist?` GC predicate; Collapse's project
  name + config-membership predicate) via a `scan(dir) { |content| keep? }` block where a
  falsy return GCs the marker. A pure no-behavior-change refactor — the existing
  Attention/Collapse suites are untouched and green. `KeyedMarkerStore.dir` is total
  (degrades to a tmpdir sibling) so a state-path failure can't crash the sidebar paint.
  Sets up #107's per-workspace fold store as a near-trivial third instance.

## [0.35.2] — self-naming nudge steers toward fuller names (2026-06-26)

### Changed
- **The agent self-naming nudge now asks for a descriptive, few-word name.** The
  SessionStart plant and the Stop backstop (`RenameNudge.message` / `stop_message`)
  were silent on length, so the agent over-compressed — defaulting to two-token names
  off its git-branch instinct and mimicry of the two-token `adjective-noun` placeholder
  it was replacing. Both messages now name the shape they want (a few-word hyphenated
  name, with a concrete example) and tell the agent not to over-compress.

## [0.35.1] — branch-row ↵ hint tells the truth (2026-06-26)

### Changed
- **A branch row's `↵` footer/help hint now says "open", not "switch".** Pressing `↵` on
  an expanded branch row opens its workspace's session — the *same* session as the
  workspace row (one session per worktree, keyed on path, not branch), and deliberately
  never checks out the branch (swapping branches under a working agent is a footgun). The
  old "switch" label implied a checkout it never did. The branch row now reads the
  workspace verb (`open`), and the `?` overlay's `↵` line matches.

## [0.35.0] — `?` help overlay + one-line footer; cross-project PR badge fix (2026-06-26)

### Added
- **`?` help overlay (#62).** Press `?` in the sidebar for the full key map — the
  discoverable home for the keys the footer can't fit: navigation (`g`/`G` jumps, `←`/`→`
  resize, the `^N`/`^P` aliases), the selected-row actions, the filter- and prompt-mode
  keys, and — resolved from your own `tmux list-keys` — the keys that operate the sidebar
  (show/hide, and **your** pane-switch keys, the one step switchboard never binds itself).
  A real keystroke closes it; background pokes (PR refresh, focus) pass through so it can't
  be dismissed out from under you. Surfaced because a daily user never discovered `g`/`G`:
  they were invisible in-app.

### Changed
- **The footer is now a single line (#62).** With the overlay holding the complete
  reference, the footer drops its two action-key lines to one context-sensitive
  `nav · ? help`, handing the tree two more rows. The `?` gateway is always shown so the
  overlay stays discoverable (a help you must already know `?` to find would be circular).
- **PR badges are keyed by `(project, branch)` (#66).** `Model#pr_for` looked PRs up by
  bare branch name against a map merged across every project, so two registered repos
  sharing a branch name could cross-render each other's PR badge on a branch row. The map
  is now keyed per project, so a badge can't leak between repos.

## [0.34.4] — self-naming nudge: name it, don't ask (2026-06-26)

### Changed
- **The SessionStart self-naming nudge now tells the agent to pick the name itself, not to
  ask the user (#92 follow-up).** With `auto_rename` on, naming the workspace is delegated to
  the agent — but the old wording never said so, so a helpful agent surfaced it as a question
  ("what should I call this?"). That drags the user into a chore they handed off and, because
  the question ends the turn on a placeholder, exposes the **Stop backstop** — a silent guard
  the user is normally never meant to see. `RenameNudge.message` now leads with the opt-in
  framing ("This project opted into agent self-naming, so choosing the name is your job here —
  don't ask the user what to call it") and notes the rename is redoable if the user later wants
  a different name.

## [0.34.3] — rename nudge says renaming in place is safe (2026-06-26)

### Changed
- **The self-naming nudge now reassures that renaming a live workspace is safe (#101).**
  A careful agent reasoned (correctly in general, wrongly here) that `switchboard rename`
  would move the worktree dir out from under its own running shell and strand the session,
  so it **deferred** the rename — defeating the Stop backstop's "you can't miss it" intent.
  The fear is false: `Rename.perform` leaves a bridge symlink at the old path so a frozen
  cwd stays resolvable and the session is renamed in place, never restarted. Both nudge
  messages (`RenameNudge.message` / `stop_message`) now carry one terse clause —
  "switchboard re-links the old path, so the move won't strand this session" — and
  `docs/reference-cli.md` states the same where an agent reads about the dir move.

## [0.34.2] — agent self-naming backstop + create-prompt hint (2026-06-26)

### Added
- **Stop-hook rename backstop (#92).** The self-naming nudge no longer rests on a single
  SessionStart plant (which fires before the agent knows anything, then never again — so
  the moment it actually understands the work has no reminder). A `Stop` hook now catches
  the agent as it tries to end a turn still on a placeholder name and blocks **once**
  (guarded by Claude's `stop_hook_active`) with an imperative `switchboard rename`
  reminder. Gated on an explicit `stop_hook_active == false` — fail-closed, so a missing
  flag never traps the agent unable to stop — and self-clears the instant the workspace is
  renamed (`Placeholder.generated?` ⇒ false).
- **The create prompt advertises the bare-↵ auto-name path (#94).** Pressing `n` to make a
  workspace now shows a `(↵ auto-name · esc)` hint instead of the same `(esc cancel)` every
  other prompt shows, so the placeholder/auto-name shortcut is discoverable instead of
  hidden behind a bare ↵.

### Changed
- **The `Stop` event is reported by one unified command, not a separate sh reporter.** Stop
  hooks run in parallel with no ordering, so a standalone `done` reporter racing the
  backstop's block could record a blocked (still-working) agent as `done` and ring a false
  completion. The backstop now reports the state itself — `thinking` when it blocks, `done`
  otherwise — with a stale-binary fallback to the sh reporter so `done` is never lost.
  Re-enabling an existing worktree (`switchboard enable-hooks`) migrates it off the old
  racing reporter.

## [0.34.1] — toggleable git diff counts (2026-06-26)

### Added
- **`diff_counts` config knob (#88).** A global boolean (default on) that turns the
  `+adds −dels` row counts off. When `diff_counts: false`, the sidebar doesn't just
  hide the label — `refresh_diffs` early-returns, so there are **no per-worktree
  `git diff` shell-outs at all** (zero added work, as before #79). Resolves like the
  other behavior toggles (`agent_state_hooks` / `prune_on_launch`); global-only by
  design, a per-project override stays a follow-up. Documented in `reference-config.md`
  and the README.

### Changed
- **The diff count no longer renders on an expanded workspace's name row (#90).** When
  a workspace expands into per-branch rows, its HEAD count duplicated the active branch
  row right below it. The count now shows on the branch rows only — the same `expanded`
  condition that already drops the PR badge there. Both the toggle and this suppression
  flow through one `Sidebar#diff_visible?` predicate.

## [0.34.0] — the agent names its own workspace (2026-06-26)

### Added
- **Agent self-naming nudge (`auto_rename`, off by default) (#92).** Turn on
  `auto_rename` (global or per-project) and switchboard plants a `SessionStart`
  instruction in a worktree's Claude hooks telling the running agent to
  `switchboard rename <name>` once it understands the work — naming the workspace
  **and** its branch (see #94). It only fires while the workspace still has its
  generated placeholder name (`Placeholder.generated?`), so it self-extinguishes the
  moment the work is named; no on-disk marker. The instruction is advisory — the
  agent names it when ready, or not at all — so nothing is renamed behind your back.
  The whole thing replaces the stale pane-title *suggestion* removed in #93: the
  agent, which has the live conversation, is the one source that's both smart and
  current. Flip it on for existing worktrees with `switchboard enable-hooks`.

## [0.33.0] — placeholder workspace names + rename syncs the branch (2026-06-26)

### Added
- **Placeholder workspace names (#94).** Create a workspace from the sidebar (`n`)
  without typing a name — a bare `↵` — and switchboard gives it a throwaway
  *adjective-noun* name (e.g. `wandering-finch`) plus a matching branch, so you can
  start working before you've decided what the work is. A generated name that
  collides (dir or branch) just regenerates. (Esc still cancels; typing a name still
  works as before.)

### Changed
- **`switchboard rename <name>` now renames the git branch too (#94).** It rebuilds
  the branch as `<branch_prefix>/<name>` (the worktree dir stays the bare `<name>`),
  so naming a workspace late still yields a clean, convention-correct branch. It only
  syncs when safe: the branch must still be the auto-created one (its name still
  matches the old leaf) **and** unpushed (no remote-tracking ref or configured
  upstream — renaming a pushed branch would orphan its PR). A pushed or
  hand-switched branch is left intact and only the dir moves. If a branch by the
  target name already exists (a leftover from a deleted workspace), rename stops and
  moves nothing — pick another name — so the dir and branch never diverge. New worktree
  branches are cut with `--no-track` so they don't inherit the base as an upstream.

## [0.32.1] — remove the pane-title rename suggestion (2026-06-26)

### Removed
- **The `rename` name suggestion (#84/#89) is gone (#93).** It harvested Claude's
  pane title — falling back to the branch's first commit subject — into a suggested
  workspace name. But that title is the harness's one-shot `ai-title`: generated once
  from the opening message and never refreshed, so for any session that ran long or
  pivoted the suggestion couldn't beat the branch name you already started with.
  Removed `Rename.suggest` / `slugify_title`, `Tmux.agent_pane_title` /
  `glyph_titled`, `Git.first_commit_subject`, and the `suggest_names` config knob.
  The sidebar `r` prompt now opens empty, and no-arg `switchboard rename` prints
  usage plus the current workspace name (it never guesses one). The manual rename
  verb — `switchboard rename <name>` and the sidebar `r` key — is unchanged.
  Agent-driven self-naming replaces the suggestion (see #92).

## [0.32.0] — suggest a workspace name from the agent's pane title (2026-06-25)

### Added
- **`rename` suggests a name, so you rarely type one (#84).** Claude Code already
  writes a model-generated summary of the conversation to its pane title (e.g.
  `⠐ Fix tmux status bar text truncation`); switchboard now harvests it as the rename
  suggestion. The sidebar `r` prompt is **prefilled** with it (just press `↵`, or
  edit), and no-arg `switchboard rename` **prints** the candidates plus the command
  to apply one (it never renames on the no-arg form — the title drifts, so the
  suggestion is a proposal you pick). The agent's pane is found by the leading
  activity glyph on its title (a non-ASCII spinner/✳), which also filters out a plain
  shell's hostname title and the sidebar's own pane — `pane_current_command` can't be
  used because Claude reports it as its version, not `claude`. The name is
  glyph-stripped, downcased, sanitized, slash-rejected, and capped at a word boundary
  so it fits the pane. When there's no usable title it falls back to the branch's
  first commit subject (local-only, no fetch). Invalid-UTF-8 titles/subjects are
  scrubbed, never crashing the prompt.
- **`suggest_names` config knob (default on).** Set `suggest_names: false` to turn
  the whole thing off — the sidebar `r` prompt opens empty and no-arg `rename` prints
  usage.

## [0.31.1] — carry the Claude `/resume` history across a rename (2026-06-25)

### Fixed
- **Renaming a workspace no longer orphans your Claude conversation.** Claude Code
  keys each conversation transcript by the workspace's cwd
  (`~/.claude/projects/<encoded-cwd>/`), so when `switchboard rename` moved the
  worktree dir the cwd changed out from under it: mid-conversation kept working (the
  running agent froze its project dir at the old path, and the worktree bridge kept
  that resolvable), but after a restart `/resume` came up empty because every
  transcript still sat under the old path's key (#42). Rename now carries the project
  dir to the new key too (`ClaudeHistory`), mirroring `Git.move_worktree`: it moves the
  real dir and leaves a symlink bridge so an in-flight session's appends keep landing
  in the moved dir. The key is the canonicalized cwd (`pwd -P`) — symlinked ancestors
  (macOS `/var`→`/private/var`, a symlinked `$HOME`) resolved the same way the agent
  dots already do — so the carry works on symlinked roots, not just literal paths. An
  existing target is merged into, never clobbered. Best-effort throughout: a failure
  degrades to "history didn't move" rather than crashing the rename.
- **`prune` now GCs the rename bridges left in `~/.claude/projects`.** The twin of the
  worktree-bridge sweep (`Reconcile.reap_bridges`): `ClaudeHistory.reap_bridges` removes
  a history bridge once it dangles (its transcript dir is gone), so they don't accumulate.

## [0.31.0] — `switchboard rename` from inside a workspace (2026-06-25)

### Added
- **`switchboard rename <name>` renames the current workspace.** The agent inside a
  worktree has the best context for a good name — its branch, its diff, the task it's
  on — but until now renaming was UI-only (sidebar `r`). The new verb resolves the
  workspace from your cwd, moves the worktree directory, leaves a bridge symlink so a
  running agent's hooks keep resolving, and renames the `sb/` tmux session in place so
  the live agent and its conversation survive (#42). The git branch is left untouched
  (its PR link stays intact). The sidebar `r` key and the CLI now share one path
  (`Rename`). It refuses the primary checkout, a name that sanitizes to empty, and a
  name containing `/` (the leaf must be flat); it exits non-zero on failure so
  `switchboard rename x && cd …` is safe to chain, and prints the exact `cd` to run
  (the shell's cwd goes stale — the bridge keeps the old path resolvable, but `pwd`
  still reports it), preserving any subdir you were in. A case-only rename (`Old`→`old`)
  is handled correctly on case-insensitive filesystems. If the dir moves but the tmux
  session rename fails, it reports a partial result and points you at `switchboard prune`.

## [0.30.0] — show the git diff count on workspace rows (2026-06-25)

### Added
- **A `+adds −dels` diff count on each workspace/branch row**, flush-right just
  before the PR badge (issue #79). It's the branch's **committed** work versus its
  base (`base...HEAD`), green/red, abbreviated past 1000 (`+1.5k`) so a big diff
  can't crowd out the name, and hidden entirely on a clean branch. The footer
  reads `+/− vs base` while a workspace/branch row is highlighted, so the count's
  meaning is clear in place — it is NOT your uncommitted working tree, which every
  other tool's `+/−` means.
- `Git.diff_counts` (a `git diff --numstat` parse — locale-proof, unlike the
  gettext-translated `--shortstat` summary) and the `View.diff_label`/`diff_tag`
  badge helpers, mirroring the existing PR-badge pair.

### Changed
- **`R` now refreshes diff counts too** (alongside PR badges) — the manual
  "show it now" for the rare case a just-merged branch's count is briefly stale.
- The counts are computed **off the paint loop and cached** (keyed on each
  worktree's `logs/HEAD` mtime, like the PR badges and agent dots), so the per-
  worktree `git diff` never stalls a repaint. A row recomputes only when its
  reflog moves or its PR newly flips merged/closed (once), staying bounded.

## [0.28.0] — resize the sidebar pane with ←/→ (2026-06-25)

### Added
- **`←`/`→` resize the sidebar pane.** The pane was a fixed 40 columns that the
  width-pin re-asserted on every paint, so a long workspace/branch name just
  truncated and there was no way to give the work pane more room (#78). In the
  tree, `→` widens and `←` narrows the pane (2 cols/press, bounds 20–80). The
  chosen width is a **durable, global, on-disk preference** (shared by every
  window's sidebar like the `H` full-header toggle), so all panes size alike and
  it survives a respawn and restart. Holding the key resizes smoothly (the pin and
  the on-disk write are coalesced once per key-repeat burst), and `←`/`→` stay
  inert in `/` filter mode. The width persists across `quit`. The initial split is
  clamped to the client width, so a width chosen on a wide monitor can't leave a
  narrow terminal with no sidebar.

## [0.27.2] — keep the name-prompt hint inside the 40-col pane (2026-06-25)

### Fixed
- **The `(esc cancel)` hint no longer scrolls a stale prompt line into scrollback
  (#80).** `draw_prompt` truncated only the label+input to the pane width and then
  appended the dim hint *after* the budget, so a long label plus the 13-col hint
  overflowed the bottom row; the over-width character auto-wrapped (DECAWM) and
  pushed a copy of the prompt up on every cancel→reopen. The hint's display width
  is now reserved inside the truncation budget, so the whole line always fits — a
  long label is clipped while the buffer is empty and restored the moment you type.

## [0.27.1] — cancel the inline name prompts with Esc (2026-06-25)

### Fixed
- **`Esc` now cancels the `n`/`a`/`r` name prompts.** They read in cooked mode, so
  Esc was swallowed by the terminal line discipline and the only way out was a bare
  Enter (undiscoverable) or killing the sidebar (#68). The prompts now edit in raw
  mode: `Esc` or `Ctrl-C` cancels with nothing created, `↵` submits, `Backspace`/
  `Ctrl-U` edit, and the prompt advertises `(esc cancel)` until you type.
- **Pasting works in the prompts again.** The raw-mode reader handles a multi-byte
  burst (a paste, or fast key-repeat) by appending its printable bytes while still
  dropping arrow-key sequences — so a pasted clone URL or repo path lands intact,
  the way cooked-mode `gets` buffered it.

## [0.27.0] — a "you are here" pointer on the current workspace (2026-06-25)

### Added
- **A `»` pointer marks the workspace your current session is in.** Until now the
  current workspace was distinguished only by its cyan name — colour alone, which
  doesn't read for everyone. The pointer adds *shape* in the otherwise-blank
  gutter, so "you are here" is legible without relying on colour. It's one column,
  so name alignment and the PR badges don't move, and it rides the selection bar
  too, so it stays visible even when that row is highlighted. The cyan name stays —
  this is colour *and* shape, not a replacement.

## [0.26.0] — toggle the full header on every session (2026-06-25)

### Added
- **`H` seats the full header on every session.** The home sidebar always leads
  with the full brand header (the `◖═◗ Switchboard` wordmark plus a greeting, a
  one-line console of what the board is handling, and a rule); every other session
  shows just the wordmark. Pressing `H` in any sidebar flips a shared toggle so the
  full header renders on *all* sessions, not just home. It's a durable view
  preference — shared across every window's pane (like a project fold) and kept
  across restarts.

## [0.25.2] — linger the completion sparkle to three seconds (2026-06-25)

### Changed
- **The completion sparkle now twinkles for three seconds** before settling to the
  steady DONE dot (was one). More time to notice a finished agent out of the corner
  of your eye.

## [0.25.1] — restore j/k movement; filter enters on the first row (2026-06-25)

### Changed
- **`j`/`k` move in the tree again.** They were vi-style down/up until 0.24.0,
  which dropped them so they'd be free to type into the `/` filter. Now they move
  in the normal tree (alongside the arrows + `Ctrl-N`/`Ctrl-P`) and remain query
  input *only* while filtering — so any name is still reachable by typing, but
  muscle-memory vi movement works again outside the filter.
- **`/` filter mode now enters on the first row, not the first workspace.** Pressing
  `/` leaves the cursor on the top item (the leading project header); the cursor
  snaps to the first workspace match as soon as you type, so type-then-`↵` still
  jumps straight to the best match.

## [0.25.0] — a branded sidebar header + completion sparkle (2026-06-25)

### Added
- **A brand header above the tree.** Every session now leads with a
  `◖═◗ Switchboard` wordmark, so the name has presence beyond the footer. The
  home sidebar (the anchor) additionally seats a time-of-day greeting that
  addresses you by name and a one-line console of what the board is handling —
  worktrees, agents working right now, and open PRs. The header drops
  automatically on a pane too short to seat it.
- **A completion sparkle.** A brief `✦` twinkle lands on a workspace row the
  moment its hooked agent finishes a turn — the visual twin of the completion
  sound. It rides the same `announce_sounds` gate (only the sidebar you're
  watching twinkles, never a catch-up scan) and has a wall-clock lifetime, so it
  expires in real time and never replays when you switch back to a session.

## [0.24.0] — type-to-filter the sidebar (2026-06-24)

### Added
- **`/` filters the sidebar** — an in-sidebar, fzf-style incremental filter (not
  the removed external `fzf` popup). Type to narrow the tree to fuzzy
  (subsequence, case-insensitive) matches on the project + workspace name, kept
  grouped under their project headers and reaching into collapsed projects too.
  `↵` on a workspace switches to it; `↵` on a project header creates a new
  workspace there. `Esc` (or backspacing past an empty query) restores the full
  tree. A project also matches on its name alone, so one with no workspaces yet
  still appears — that's how you reach it to create its first.

### Changed
- **Movement keys are now arrows + `Ctrl-N`/`Ctrl-P` everywhere; `j`/`k` are no
  longer movers.** They were vi-style down/up before; now they do nothing in the
  normal tree and type into the query while filtering, so any name is reachable
  by typing (and the binding is identical in both modes).

## [0.23.0] — open a workspace's repo from the sidebar (2026-06-24)

### Added
- **`O` opens the highlighted row's repo in the browser** — a sibling to `o`
  (which opens the row's PR). It rides every row kind, including the project
  header. When the row has an open PR, it opens the repo at that branch;
  otherwise it opens the repo home (the default branch). Like `o`, it runs
  `gh` detached so the sidebar never blocks on the network, and quietly does
  nothing if there's no GitHub remote.

## [0.22.2] — doc fix: worktrees hold multiple branches (2026-06-24)

### Changed
- **Corrected the "manage projects" how-to's definition of a worktree.** It
  called a worktree "a branch checkout," which conflated worktree with branch and
  contradicted the multiple-branches-per-workspace model the rest of the docs
  describe. A worktree is a separate git working directory that can hold several
  branches over its life (the inline branch rows). Docs only.

## [0.22.1] — a full documentation set (2026-06-24)

### Added
- **A `docs/` directory with the complete documentation set**, organized by the
  Diataxis framework (tutorial / how-to / reference / explanation) and cross-linked
  from the README. New: a getting-started tutorial; how-to guides for managing
  projects, agent state & sounds, keybindings, and housekeeping; reference docs for
  the CLI, `config.yml`, and keybindings; and explanation docs for the architecture,
  agent presence, and the sidebar lifecycle. Plus a `CONTRIBUTING.md` (tests, the
  zero-gem/Ruby-3.0 constraints, conventions, release process) and an `AGENTS.md`
  pointer for tool-neutral AI agents. Everything that was implicit in the README and
  `CLAUDE.md` is now structured and discoverable. Docs only — no behavior change.

## [0.22.0] — shared project collapse across every sidebar (2026-06-24)

### Added
- **Folding a project header is now shared across every window's sidebar, and
  survives a respawn.** Collapse state used to live in each sidebar process's
  memory, so a project you folded in one session came back expanded everywhere
  else — and any sidebar respawn (toggle off/on, a new window, a reconcile) lost
  the fold entirely. It now lives on disk (one file per collapsed project), the
  same shared-state trick behind the agent dots and the bold "needs attention"
  markers: every sidebar hydrates the fold on reload, and a toggle writes through
  so the others pick it up on their next switch-in. Unlike the attention markers
  it is a durable view preference — a folded project stays folded across restarts
  (it is deliberately *not* cleared on `quit`).

## [0.21.2] — sidebar shows every branch a worktree has held (2026-06-24)

### Fixed
- **A worktree that cut more than one branch in place now lists them all.** The
  sidebar reads each worktree's branch history from its HEAD reflog, but only
  captured the branch each `checkout` moved *to* — so a branch you only ever
  moved *away* from (including the one the worktree was born on) was dropped, and
  the workspace collapsed to a single row. It now captures both ends of each
  checkout, so all of a worktree's branches expand as inline rows again.
- **An expanded workspace no longer shows its PR badge twice.** When a workspace
  fans out into per-branch rows, the current branch's PR (`#number`) now shows
  only on its branch row, not also on the workspace row above it. A single-branch
  workspace still shows the badge on its row, where it's the only place for it.

## [0.21.1] — a self-documenting starter config (2026-06-24)

### Changed
- **A fresh `install`/`init` now writes an annotated config**, not two bare
  lines. Every optional knob (`session_command`, `sounds`, `tmux_keys`, `base`,
  `branch_prefix`, `agent_state_hooks`, `prune_on_launch`, `projects_root`) is
  shown commented out at its default, so the options are discoverable in the
  file itself instead of only in the README. Only `worktree_root` + `projects`
  are active, so the effective config (and behavior) is unchanged. Existing
  configs are left untouched — `install` never overwrites. (The comments are
  stripped the first time you add a project, by which point you've seen them.)

## [0.21.0] — remap the sidebar toggle: configurable tmux keys (2026-06-24)

### Added
- **`tmux_keys` config: remap the sidebar toggle (and an optional home jump).**
  `prefix-s` collided with tmux's default `choose-tree`; now `tmux_keys.toggle`
  rebinds it to any key (a char, a named key like `Space`/`F1`, or a `C-`/`M-`
  combo), and `tmux_keys.home` optionally binds a one-key jump to the home
  session (unbound by default). Editing the key with `switchboard config` (or
  `e`) takes effect on save — switchboard rebinds it immediately and flashes a
  confirmation — instead of waiting for a tmux reload.
- **`doctor` reports your key wiring.** New rows show the configured toggle key,
  flag an unusable value (and the fallback it used), a `home`/`toggle`
  collision, a config that failed to parse, and a key that displaced a prior
  non-switchboard binding.

### Changed
- **The install fragment now binds via `switchboard tmux-bind`** instead of a
  hardcoded `prefix-s`. It tracks the key it bound last in tmux options
  (`@switchboard-*-key`) and cleans up exactly that on a rebind, so changing the
  key never leaves the old one live and never clobbers your own bindings.
- **A malformed `config.yml` no longer crashes anything.** It degrades to
  defaults (the sidebar keeps its last-good config; `doctor` reports the parse
  error) rather than raising.

## [0.20.0] — fresher signals: faster PR refresh + quit clears stale dots (2026-06-24)

### Added
- **`R` refreshes PR badges on demand.** A PR you merge or close *on GitHub*
  fires no local signal, so the badge could lag behind the real state. Press
  `R` in the sidebar to force a refresh of every project's badges now; the
  detached `gh` children repaint the tree as they return. The status line
  confirms the keypress (and stays quiet when there's no wrapper to spawn a
  refresh, so it never claims work it can't do).

### Changed
- **PR badges refresh faster on their own.** Lowered the idle backstop
  (`BACKSTOP_TTL`) from 10 minutes to 2, so an externally merged/closed PR
  reflects within ~2 minutes while the sidebar is on screen, without anyone
  pressing `R`.
- **`quit` now clears agent state.** Tearing down every session (the sidebar's
  `q` or `switchboard quit`) kills every agent at once, leaving their last hook
  state stale — a lingering `:thinking` would otherwise show as a live, working
  agent for up to 15 minutes, even though you'd have to `/resume` it. Quit now
  wipes those states so a torn-down agent doesn't come back looking busy. The
  "bold until viewed" markers are deliberately left intact (an unviewed
  completion is still unviewed after a quit).

## [0.19.0] — the sidebar cursor follows the workspace you're in (2026-06-24)

### Changed
- **Returning to the sidebar now selects the workspace you're in.** Switching
  into a workspace still drops you in its pane (the conversation or active
  field, as before); when you move focus back to the sidebar, the selection bar
  now lands on *that* workspace instead of wherever the cursor last sat. It's
  edge-triggered on focus-in (and on the first paint of a freshly summoned
  sidebar), so it never fights `j`/`k` while you navigate — and it's a no-op at
  home, or when the workspace's row is hidden under a collapsed project.

## [0.18.0] — doctor reports orphaned sidebar processes (2026-06-23)

### Added
- **`switchboard doctor` now reports orphaned sidebar processes.** A
  `switchboard sidebar` that outlived its tmux pane (the pane closed but the
  process didn't exit) is invisible until it misbehaves — and because tmux
  recycles pane ids, a straggler can end up reading a *different* live pane and
  double-fire completion sounds. doctor now diffs the count of running sidebar
  processes against the number of sidebar panes tmux actually has and flags the
  difference. The line is silent-skipped when `pgrep` is absent or tmux is
  unreachable (no count to compare).

## [0.17.3] — exit orphaned sidebars so they stop ringing duplicate sounds (2026-06-23)

### Fixed
- **A workspace completion no longer rings twice (or more).** When a sidebar's
  tmux pane closed, the process kept looping instead of exiting — `read_key`
  swallowed the stdin `EOFError`, and nothing checked the pane still existed.
  Because tmux **recycles `%pane-id`s**, the orphan's frozen `TMUX_PANE` would
  later name a *different, live* pane; when that pane was on the attached/active
  window the orphan read it as visible and rang completion sounds in parallel
  with the real sidebar — duplicate (sometimes triple) sounds, intermittent by
  which recycled id happened to map to the visible pane. The sidebar now exits
  when its pane goes away: `read_key` returns `:eof` (the loop exits on it) for a
  clean close, and `owns_pane?` compares the pane's current `#{pane_tty}` against
  the pty captured at startup — a **confirmed** different tty means our id was
  recycled onto someone else's pane, so `tick` returns false and the loop exits
  within one `IDLE` cycle, before it can ring. A `nil` reply (pane gone *or* a
  transient tmux hiccup) is not treated as disownership, so a flaky shell-out
  never self-terminates a healthy sidebar; a dead pane reads as not-visible
  (silent) and is reaped the moment its id is recycled onto a live pane.

## [0.17.2] — keep a symlinked tmux.conf intact on install (2026-06-22)

### Fixed
- **`install` no longer clobbers a symlinked `~/.tmux.conf`.** When your
  tmux.conf is a symlink into a dotfiles repo, the atomic write now follows the
  link and rewrites the real file instead of replacing the symlink with a
  detached copy — which silently decoupled `~/.tmux.conf` from the repo it
  pointed at, so later `git pull`s in the dotfiles never reached the live
  config. The install output now shows the resolved destination
  (`tmux: wired in ~/.tmux.conf → …`).
- **The test suite no longer touches your real tmux server.** Uninstall's live
  cleanup runs `tmux unbind-key`/`set-hook -gu` ungated by `$TMUX` by design, so
  `bin/test` was shelling those into the running server and unbinding live
  switchboard keys. Tests now redirect tmux's socket dir (`TMUX_TMPDIR`) into the
  sandbox, restoring the offline-test guarantee.

## [0.17.1] — make the unviewed-completion highlight pop (2026-06-22)

### Changed
- The "needs attention" workspace name now renders **bold yellow** instead of
  bold alone — many terminal themes barely weight bold on default-foreground
  text, so the cue was easy to miss. Yellow is distinct from the cyan
  "you are here" highlight.

## [0.17.0] — bold a workspace until you view its completion (2026-06-22)

### Added
- **Unviewed completions go bold.** When a hooked agent finishes a turn
  (done) or asks for input (waiting), its workspace name turns **bold** in the
  sidebar and stays bold until you switch into that session — so a completion
  that lands while you're working elsewhere is still flagged when you glance
  back. Viewing clears it (no input required); the workspace you're already in
  is never bolded. The dot is the live state now; the bold is the
  unviewed-since-it-finished flag (the visual twin of the completion sound).
  Shared on disk (one marker per worktree), so every window's sidebar bolds the
  same rows.

## [0.16.0] — sidebar off-screen dormancy + honest doctor (2026-06-22)

### Changed
- **Sidebar does far less work off screen.** Each window's sidebar now tracks
  whether it's actually on screen and gates rendering, animation, and the
  per-tick tmux calls on that. Off screen it drops to a long idle backstop and
  wakes instantly when you switch in (no constant repaint/poll of panes nobody
  is looking at). Switching away from a thinking agent stops the spinner
  promptly instead of fast-spinning a hidden pane.
- A session switch-in now reloads the tree once instead of twice.
- `branch_history` is cached per worktree (keyed on the reflog mtime), so a
  visible reload skips the per-workspace `git rev-parse` when nothing changed.

### Added
- A same-session window switch now refreshes that window's sidebar via a
  `session-window-changed` tmux hook (previously only session switches did).
- `switchboard doctor` now reports whether `prefix-s` and the tmux hooks are
  **live** in the running server (not just present in your config), whether `gh`
  is authenticated, and how stale each project's PR-badge cache is — so a stale
  tmux server (e.g. `prefix-s` unbound after a `git pull`) or a silently frozen
  badge set is diagnosable.

## [0.14.0] — one-command startup + `sb` shorthand
- Bare `switchboard` is context-aware: from a shell it bootstraps and attaches
  the home session; inside tmux it toggles the sidebar. Install adds a short
  `sb` alias beside the command.

## [0.13.0] — sidebar quit/hide keys
- `q` tears down every switchboard session (confirms first); `h` hides the
  sidebar session-wide.

## [0.12.x] — config editing + sound variants
- Edit config in a dedicated pane beside the home tree, resolving `$EDITOR` at
  runtime; selectable `train`/`chime` sound variants; completion-sound trigger
  fixes.

## [0.11.0] — per-session sidebar visibility
- Sidebar show/hide is per session, synced across all of its windows.

## [0.10.0] — completion sounds
- A short sound plays when a hooked agent finishes a turn or asks for input.

## [0.9.x] — session lifecycle
- `prune`/`quit` reconcile and tear down `sb/` sessions; auto-reconcile on
  landing home; session-switch poke throttled to stop a reload storm.

## [0.8.0] — animated agent-state icons
- Theme-following thinking/waiting/done dots beside each workspace.

## [0.7.1] — test suite
- Offline stdlib-Minitest suite (plus path-traversal and `branch_history` fixes).
