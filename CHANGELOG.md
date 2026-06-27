# Changelog

Notable changes per version. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); versions match the `vX.Y.Z`
prefixes in the git history and `lib/switchboard/version.rb`.

After upgrading, re-run `bin/switchboard install` (or reload tmux) so any new
tmux bindings/hooks go live — see the "Upgrading" section in the README.

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
