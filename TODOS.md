# TODOs

Deferred work, captured so the reasoning isn't lost. Each item says what, why,
and where to start.

## Session lifecycle (issue #7) follow-ups

- **Validate/normalize project names at `add` time.** At registration, reject or
  de-dupe names that collapse to the same sanitized session prefix, and strip
  path-traversal characters. *Why:* `Tmux.session_name`/`session_prefix` sanitize
  `. : whitespace` to `-`, so `app.dev` and `app-dev` collide on the `sb/app-dev/`
  prefix. `Reconcile.prune` diffs against the **union** of all *verified* projects'
  valid names, so two live colliding projects protect each other — but a
  *de-registered* project colliding with a live one is unresolvable at prune time
  (you can't tell the two apart by name). Same root cause as the raw-name path
  traversal in `Creator` (`switchboard add` passes the project name straight into
  `File.join(worktree_root, project_name, name)`). One validation point closes
  both. *Start in:* `Registrar.register` / `CLI#add_project`; decide the collision
  policy (reject vs auto-suffix). Low priority — the collision needs unusual names
  and `prune --dry-run` makes it visible before anything is killed.

- **`doctor` warns on missing/moved project repo dirs.** A `switchboard doctor`
  line listing config projects whose `path` no longer exists. *Why:* `prune`
  deliberately leaves unverifiable projects' sessions alone (so a moved repo never
  nukes live sessions), but that means a stale config pointer is invisible — doctor
  is the read-only place to surface it before orphans accumulate. *Start in:*
  `CLI#doctor` (a `Dir.exist?` loop over `config.projects`). Independent of the
  above.

## PR-badge refresh (issue #19) follow-ups

- **Trailing/coalescing debounce.** The per-project background refresh uses a
  *leading* debounce (`PR_DEBOUNCE`, `sidebar.rb`): a second distinct event for
  the same project inside the window is dropped. Today the idle backstop and the
  next navigation heal it, so it self-corrects within `BACKSTOP_TTL`. If that
  staleness window is ever felt in practice (e.g. two worktrees of one project
  open PRs seconds apart), switch `spawn_due?` / `maybe_refresh_prs` to a
  trailing debounce so the *latest* event always results in a fetch. Low
  priority — only worth it if observed.

- **Watch-while-working freshness for hook-less agents.** The agent-completion
  refresh trigger (T1) fires only on the *hook* signal (`AgentState#last_hook_states`),
  because the coarse activity fallback flips `:thinking ⇄ :done` every 3s and
  would fire on noise. So codex/aider worktrees (or Claude before
  `enable-hooks`) get badge freshness from navigation + the backstop, not the
  live edge. If you run non-Claude agents and want their badges as live as
  Claude's, add a presence-precise signal for them rather than leaning on the
  capture-hash. Start in `agent_state.rb` (`activity`) and the T1 wiring in
  `sidebar.rb` (`refresh_prs_on_agent_edges`).

## Sidebar input handling follow-ups

- **Flush the rest of the read buffer after an in-dispatch confirm.** `Sidebar#confirm`
  (used by `q` quit, `d` delete) reads its y/N from `$stdin` directly, while `#handle`
  may still hold later bytes from the same `read_key` chunk in its local buffer. So a
  fast `qy`/`dy` or pasted/`tmux send-keys` input can leave stale keys that dispatch
  *after* the confirm resolves. The `q`→quit footgun is already closed (`#handle` now
  breaks on a stop-token), so the residue is benign today — extra navigation, at worst
  another confirm. *Why not fix now:* a clean fix means draining the buffer across all
  three confirm callers (`q`/`d`, and the `rename`/`create` cooked-mode prompts), which
  is broader than the quit change. *Start in:* `Sidebar#handle` / `#confirm` — either
  pass the remaining buffer into the prompt helpers, or clear `$stdin` after a prompt
  returns. Low priority — needs buffered/pasted input to trigger and nothing destructive
  results.

## Sidebar off-screen-work (architecture-review) follow-ups

- **Tighten off-screen detection (zoom + bare-attach).** After the visibility-aware
  sidebar work, two paths still leave a hidden/stale sidebar to the idle backstop
  (`IDLE`, ~8s): (1) `Tmux.visible?` checks `window_active` + `session_attached` but
  **not** pane zoom, so a sidebar hidden behind a `prefix-z` zoomed work pane reads as
  visible and keeps scanning/painting; (2) a bare `tmux attach -t sb/...` (not the
  sidebar-driven `switch-client`) may fire neither `client-session-changed` nor
  `session-window-changed`, so that session's sidebar isn't poked and only refreshes on
  the ~8s backstop. *Why deferred:* the conservative `IDLE` makes both self-heal within
  ~8s, so they're low-severity; closing them is extra tmux surface (a `window_zoomed_flag`
  check + a third global hook). *Start in:* `Tmux.visible?` (consult
  `#{window_zoomed_flag}` and whether our pane is the zoomed one); add a
  `client-attached[99]` poke in `switchboard.tmux` + clear it in
  `Installer.teardown_live`. Low priority — measure whether either is felt in practice
  first.

## Community / contributor hygiene (devex-review) follow-ups

- ~~**Add CONTRIBUTING.md once there's contributor interest.**~~ ✓ Done — added
  `CONTRIBUTING.md` (tests, the zero-gem/Ruby-3.0 constraints, the
  module-vs-class conventions, and the release process) as part of the full
  `docs/` Diataxis set. The conventions also live human-readable in
  `docs/explanation-architecture.md`.
