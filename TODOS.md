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
  and `prune --dry-run` makes it visible before anything is killed. *Also covers
  the leaf:* `switchboard rename` (issue #42) and the sidebar `r` produce a new
  workspace leaf that `Tmux.session_name` sanitizes the same way, so `rename
  foo.bar` next to an existing `foo-bar` workspace collides on `sb/proj/foo-bar`
  — the move succeeds but `rename_session` then fails into the existing name
  (rename now reports `:partial`; prune/doctor surface the orphan). Same
  validation point should guard leaf names, not just project names.

- **`doctor` warns on missing/moved project repo dirs.** A `switchboard doctor`
  line listing config projects whose `path` no longer exists. *Why:* `prune`
  deliberately leaves unverifiable projects' sessions alone (so a moved repo never
  nukes live sessions), but that means a stale config pointer is invisible — doctor
  is the read-only place to surface it before orphans accumulate. *Start in:*
  `CLI#doctor` (a `Dir.exist?` loop over `config.projects`). Independent of the
  above.

## Rename / worktree-move (issue #42) follow-ups

- **Claude history bridge: clobber-on-name-reuse race.** `ClaudeHistory.migrate`
  (added in v0.31.1) carries the transcript dir and leaves a bridge `encode(old) ->
  encode(new)` in `~/.claude/projects`. If you rename `A->B`, keep that agent running,
  then reuse the freed name `A` for a NEW workspace, `clear_link(dst)` drops the A->B
  bridge and the still-running B agent (if it reopens the transcript by path) then
  appends into the new A's dir. *Why not now:* needs exact name reuse + a live
  renamed-away agent reopening by path; very unlikely. *Start in:*
  `ClaudeHistory.migrate` — only `clear_link(dst)` when the bridge is dangling, not
  when it resolves to a live dir. Surfaced by Codex during the v0.31.1 review.

- **Verify whether Claude reopens the transcript by path or holds an fd.** The
  `ClaudeHistory` bridge only matters if a running agent re-derives
  `projects/<encoded-cwd>/<id>.jsonl` by path on each append; if it holds an open fd,
  the dir move is transparent and the bridge is harmless dead weight. Couldn't verify
  Claude's internals from here, so the bridge is kept as cheap insurance. *Why low:*
  worst case the bridge is a no-op. Resolving it would let us simplify (drop the bridge)
  or confirm it's load-bearing (and then the clobber race above matters more).


- **`clear_bridge` only deletes a *verified* bridge, not any symlink.**
  `Git.move_worktree` calls `clear_bridge(new_path)` to reclaim a stale rename
  bridge squatting the target; `clear_bridge` deletes *any* symlink at that path
  (`git.rb:98`), trusting the comment's invariant ("only ever a symlink, never a
  real worktree"). A user-created symlink at exactly
  `<worktree_root>/<project>/<name>` would be silently removed. *Why not now:*
  `clear_bridge` is shared by `Creator.create`'s reclaim, so hardening it is
  broader than #42 and needs its own tests; the path is implausible in practice.
  *Start in:* `Git.clear_bridge` — only delete when the symlink target is dangling
  or resolves under the worktree root (a known bridge shape), else leave it and let
  the `git worktree move` fail loudly. Low priority, low likelihood.

- **Narrow the rename move→session-rename prune window (or make prune
  bridge-aware).** `Rename.perform` does `Git.move_worktree` then
  `Tmux.rename_session` as two steps. In the (microsecond) gap the dir is at the
  NEW path but the session still has the OLD leaf name, and the old path is only a
  bridge symlink — invisible to `git worktree list`. A concurrent `Reconcile.prune`
  (a `go_home` launch or a manual `switchboard prune` in another terminal) sampling
  exactly then would see `sb/<proj>/<old>` as an orphan and could kill a live
  agent. *Why low:* the window is two consecutive shell-outs, and it's pre-existing
  — the sidebar `r` rename always did move-then-rename; #42 only extracted it.
  *Start in:* teach `Reconcile.prune` to treat a session whose leaf has a live
  bridge symlink as non-orphaned, OR have `Rename` hold a brief guard. Surfaced by
  Codex during the #42 review.

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

- **Esc-timeout to close the `\e`|`[O` escape split (accepted).** `Sidebar.tokenize`
  carries an incomplete CSI across reads, but a sequence split BEFORE its `[` (a read
  ending on a lone `\e`, the next starting `[O`) flushes the `\e` as Esc and re-orphans
  the `O` → open_repo — the very symptom the tokenizer exists to prevent. *Why accepted,
  not fixed:* it needs tmux to fragment a 3-byte focus event across reads, which it
  doesn't (it writes the sequence in one `write`, and `READ_BYTES` reads it whole), so
  it's unreachable in practice — the original deterministic bug was the fixed 8-byte read
  cap, now gone. Closing it for good means carrying a lone `\e` too, which stalls the Esc
  key (filter/prompt cancel) unless the run loop grows a short Esc-timeout to disambiguate
  bare-Esc from a sequence head. That timing complexity in an already-intricate loop isn't
  worth defending an input tmux can't produce. *Start in:* `Sidebar#run` (a deadline flush
  when `@pending == "\e"`) + `tokenize` (return a lone trailing `\e` as remainder). Only
  worth it if we ever stop trusting the producer to write sequences atomically.

- **Unify the name-prompt reader onto `tokenize`.** `Sidebar#edit_buffer` (the inline
  `r`/`n` name prompt, `sidebar.rb`) still slices escapes at a fixed 3 bytes, the same
  shape the main loop's `handle` had before the tokenizer. *Why low:* the prompt already
  reads 1024 bytes and no destructive key is bound during a name edit, so a split sequence
  there just drops a stray char into the name you can see and backspace — not a footgun
  like the open-repo orphan was. *Start in:* `Sidebar#edit_buffer` — route it through
  `self.class.tokenize` so both readers share one grammar. Pure cleanup; do it next time
  the prompt path is touched.

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

## Sidebar `O` open-repo (issue #63) follow-ups

- **Deep-link branches that are pushed but have no *open* PR.** `O` (open the
  highlighted row's repo) deep-links to `/tree/<branch>` only when the row has an
  OPEN PR — the one signal that proves, without a keypress network call, that the
  branch is still on the remote (GitHub closes a PR the moment its head branch is
  deleted, so an open PR ⇒ live branch). A branch that's pushed but has a
  merged/closed PR, or no PR yet, falls back to the repo home / default branch.
  *Why deferred:* covering it needs either a keypress network call (`git ls-remote`
  — rejected; `O` detaches precisely to stay off that path) or a local
  `refs/remotes/origin/<branch>` check that's itself imperfect (a push without
  `-u` and no fetch leaves no tracking ref, so it still falls back). *Start in:*
  `Sidebar.browse_args` (`sidebar.rb`) + a `Git` remote-branch helper. Low
  priority — repo home is a fine fallback; only worth it if the gap is felt.

- **Residual `O` deep-link 404 windows (accepted).** The OPEN-PR gate avoids the
  common 404 but isn't airtight (both adversarial reviewers flagged this): (1) a
  **stale PR cache** — a PR open at the last `gh` fetch, then merged + head-branch
  deleted before the next background refresh (worse when the fetch is failing, since
  `Pr.refresh` preserves the last-good cache) — keeps an `OPEN` badge, so `O` opens
  `/tree/<dead-branch>` → 404; (2) **fork PRs** (`headRefName` is the fork's branch,
  absent in the base repo); (3) ~~the **cross-project branch-name collision**~~ ✓
  **Fixed (#66)** — `Model#pr_for` now keys PRs by `(project, branch)`, so a `br` row
  can't pick up another project's badge. (1) and (2) still open a recoverable GitHub
  404 (never data loss/security), so they're accepted, not blocking. The would-be fix
  (a keypress-time remote check) is rejected for the same reasons as the bullet above.
  Captured so the reasoning isn't lost.

## Community / contributor hygiene (devex-review) follow-ups

- ~~**Add CONTRIBUTING.md once there's contributor interest.**~~ ✓ Done — added
  `CONTRIBUTING.md` (tests, the zero-gem/Ruby-3.0 constraints, the
  module-vs-class conventions, and the release process) as part of the full
  `docs/` Diataxis set. The conventions also live human-readable in
  `docs/explanation-architecture.md`.

## Sidebar diff count (issue #79) follow-ups

- **Working-tree (uncommitted) diff count as a config knob.** The row diff count
  (`+22 −333`) shows **committed** branch-vs-base work (`git diff --numstat
  base...HEAD`). Add a per-project/global option — resolved like `sound_for` /
  `session_command_for` — to switch a project to the **uncommitted** working-tree
  view (`git diff --numstat HEAD`) instead. *Why:* `+22 −333` reads like "current
  git diff" to many users, but we deliberately show committed-only (it's the
  PR-shaped number and it's cache-friendly); some users will want the dirty-tree
  view. *The catch (the real design work):* working-tree mode **can't** ride the
  `logs/HEAD` mtime gate the committed count uses — editing files never touches the
  reflog, so an edit wouldn't invalidate the cache. It needs a different
  invalidation (index + working-tree mtimes, or accept a per-scan shell-out cost —
  the exact thing `with_dirty: false` avoids). *Start in:* `Config` (a `diff_source_for`
  resolver) + `Sidebar#refresh_diffs` (a mode branch + its own invalidation). Low
  priority — the committed default is the right one for the PR-workflow case; only
  worth it if the dirty-tree view is asked for.
