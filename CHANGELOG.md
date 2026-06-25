# Changelog

Notable changes per version. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); versions match the `vX.Y.Z`
prefixes in the git history and `lib/switchboard/version.rb`.

After upgrading, re-run `bin/switchboard install` (or reload tmux) so any new
tmux bindings/hooks go live — see the "Upgrading" section in the README.

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
