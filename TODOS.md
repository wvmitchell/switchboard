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
