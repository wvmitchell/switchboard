# Changelog

Notable changes per version. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); versions match the `vX.Y.Z`
prefixes in the git history and `lib/switchboard/version.rb`.

After upgrading, re-run `bin/switchboard install` (or reload tmux) so any new
tmux bindings/hooks go live — see the "Upgrading" section in the README.

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
