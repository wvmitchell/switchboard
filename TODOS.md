# TODOs

Deferred work, captured so the reasoning isn't lost. Each item says what, why,
and where to start.

## Release automation (issues #8, #9) follow-ups

- **Test that release.yml's trigger list and `GATES` agree.** *Why:* the
  `workflow_run.workflows: [test, formula]` trigger and the job's `GATES: test
  formula` must match, and only a comment ties them; adding a gate to one but not
  the other either skips that gate's check before tagging or stops its completion
  from triggering a release. *Start in:* `test/release_test.rb` — `YAML.safe_load_file`
  the workflow (note Psych reads the `on:` key as `true`), assert the trigger list
  equals `GATES.split`, and that each gate is the `name:` of a file under
  `.github/workflows/`. **Priority:** P2.

## `switchboard upgrade` (issue #10) follow-ups

Found by the 0.52.0 ship reviews and deliberately deferred (the behavior fails loudly or
safe today; each is narrow).

- **A settings file with an overflowing number (`1e400`) crashes current?/refresh.** *Why:*
  `JSON.parse` yields Infinity, `merged`'s `JSON.generate` raises `GeneratorError`, unrescued
  on `leftovers?`, `doctor` and `enable-hooks`. *Start in:* round-trip in `load_settings`
  and raise `Corrupt`. **Priority:** P2.
- **Clear GIT_DIR / GIT_WORK_TREE / GIT_INDEX_FILE for the clone upgrade's git commands.**
  *Why:* `-C` doesn't override them, so upgrade run with them exported (inside a git hook)
  acts on another repo. *Start in:* `Upgrade.clone_pull`/`clone_behind?`/`stamp`/`git_out`.
  **Priority:** P2.
- **Other binaries still rewrite the shared reporter.** *Why:* `HookFile.enable` (enable-hooks,
  `Creator.work`) and `CodexHook.install_global` call `ensure_script` from any binary, so a
  dogfood checkout flips the reporter and the installed `upgrade` re-finishes. *Start in:*
  gate on `Installer.installed_bin?` unless the script is missing. **Priority:** P2.
- **Confirm a running Claude picks up hooks after an atomic rename.** *Why:* `write_json`
  now replaces settings.local.json by rename and the output says "a running Claude picks the
  change up on its own"; unverified live. *Start in:* rewrite mid-session, check a new hook
  fires; else restore the restart / `/hooks` hint. **Priority:** P2.
- **Homebrew edges.** *Why:* the bare `brew upgrade switchboard` resolves through PATH (a
  second Homebrew prefix, a same-named core formula, a pinned keg), and a formula revision at
  the same version is never applied (up-to-date is decided by the tag). *Start in:* the
  keg's own `brew`, the qualified `wvmitchell/switchboard/switchboard`, `brew outdated`.
  **Priority:** P2.
- **A clone on a merged/deleted branch reads up to date forever.** *Why:* clones compare
  only with their upstream, never release tags. *Start in:* add `LatestRelease` to the clone
  path as a note. **Priority:** P2.
- **Smaller upgrade/doctor nits.** Refuse a non-Homebrew install that isn't its repo's
  top level; doctor's tmux rows advise `upgrade` where it can't help (tmux < 3.0, unwired);
  clone failure advice on a diverged or detached clone says "re-run", which can't succeed;
  install's closing hint names the configured key, not a fallback; concurrent upgrades can
  re-apply the older one's wiring; release lookup: proxy/CA dropped, `GIT_CONFIG_PARAMETERS`
  inherited, repo discovery when TMPDIR sits in a repo (`GIT_CEILING_DIRECTORIES`), a git
  helper that ignores TERM outlives the deadline; doctor's network call could be cached;
  the reporter's `script_state` reads a FIFO/`/dev/zero` unbounded; a non-UTF-8 `$HOME`
  keeps hooks from ever converging. **Priority:** P3.
- **Code tidy-ups.** `Upgrade.git_out` → a status-aware `Git` helper; `HookFile.bin` ==
  `CodexHook.bin`; `unreadable?` reads the whole file; the tmux 3.0 floor literal ×4 → a
  constant; the `upgrade.rb` header diagram lacks `update_blocked`; `reporter_unwritable`'s
  message omits the exec bit; `hooked_worktrees`' comment omits unreadable files;
  `doctor_hooks` calls Claude-only adapter methods; a 0444 settings file is now replaced
  by the rename; `refresh` drops a user's empty hook groups once; `install --print-tmux`
  still refreshes hooks; the `'{ // mine'` test fixtures trip json's comment warning; the
  stalled-lookup test's timing margin. **Priority:** P3.
- **tmux fragment digest.** *Why:* `leftovers?` notices stale hook slots and the toggle key,
  not a fragment whose other lines changed. *Start in:* hash the fragment into a
  `@switchboard-*` option at bind time. **Priority:** P3.

## Background dispatch (v0.51.0) follow-ups

- **Scope typeahead to the task prompt, and never let it submit.** *Why:* `Sidebar#handle`
  hands the rest of a read batch to whichever `prompt_line` opens mid-batch. That fixed `n`
  + fast typing losing the task, but it's too broad: a line pasted into the TREE pane
  (bracketed paste is only on inside the task prompt) that contains `n` dispatches an agent
  with the rest of the line, prompt never shown; `r name↵` in one read renames unseen; a
  key after `↵` in the batch folds the `↵` (prompt stays open); keys after a cancel are
  dropped; a paste-end marker split into `@pending` isn't handed over (paste-mode wedge);
  `read_char` (the `a` menu, `confirm`) ignores typeahead so keys apply out of order.
  *Start in:* `prompt.rb` `prompt_line` (`typed = task ? … : ""`, feed tokens up to the
  first `\r`/`\n` and keep the prompt open), `input.rb` `handle`; consider bracketed paste
  in tree mode with the pasted span dropped. Tests: a pasted line with `n` must not
  dispatch; assert `@typeahead` is cleared. **Priority:** P1.
- **Renaming an un-set-up build can drop its guard.** *Why:* in the few ms between
  `git worktree move` and `leave_bridge`, another sidebar's GC sees the old path missing
  (rule 3) and deletes the unfinished record; `certified?(nil)` then lets a later
  re-entry start the agent on the un-set-up tree. Relatedly a stale failed record can
  attach to an unrelated tree later renamed (or clash-relabeled) onto its path, and then
  `unfinished_at?` lets a confirmed `d` force past that tree's lock. *Start in:*
  `Creation.renamable?` (refuse an `unfinished?` record) and `Rename.perform` (refuse a
  destination a record claims). The same check closes a newer case (v0.57.1 review): a
  workspace renamed onto the exact placeholder an in-flight build reserved makes that
  build's `worktree add` fail with "already exists" over a tree on its branch, so the
  build fails and keeps it (nothing is lost, but the renamed workspace wears the build's
  ✘ until dismissed). Check under `Creation.with_project_lock`, as `reserve` does.
  **Priority:** P2.
- **Input edges in the task prompt and modals.** *Why:* an unpaired paste-start marker
  wedges the task prompt in paste mode (Esc/^C/↵ all become text; `prefix-s` escapes); a
  literal paste-end inside pasted text ends the paste early; a 1 KB read split on a
  terminal without bracketed paste can submit early and spill keys; the worker's C-w warm
  poke and the C-l refresh poke are read as the answer by `confirm`, `flash` and the `a`
  menu (see learning modal-dismiss-must-ignore-synthetic-tmux-bytes). *Start in:*
  `prompt.rb` `edit_buffer`/`read_char` — bound paste mode, and loop `read_char` past
  `POKE_BYTES`. **Priority:** P2.
- **Say what's actually wrong when the config fails a build.** *Why:* the `config`
  reason's pane/row text says the config couldn't be read, but `setup_invalid?` now fires
  it for a file that parsed fine; `doctor` never checks `setup_invalid?`; the config
  branch of `launch` ignores whether `mark_failed` landed (wrong text after a racing
  cancel); a worker starting on an unparseable config fails as `worktree_add` "unknown
  project"; a failed ✘ never shows the typed task again. *Start in:* `Creation::REASONS`
  (a `setup_config` reason or text keyed on `load_error`), `CLI#doctor`,
  `Creator.launch`/`work`. **Priority:** P2.
- **Make the record store fail closed.** *Why:* one record file that parses as JSON but
  isn't an object makes `all` return `[]` for every pane, and any read error reads as "no
  record" — both turn `certified?(nil)` into "start the agent". Writes aren't fsynced;
  records and their dir are world-readable (tasks may hold secrets); record ids aren't
  validated as path segments. *Start in:* `Creation.all`/`read` (keep only Hashes;
  distinguish "unreadable" from "absent"), `write` (`perm: 0o600`, fsync), `state_dir`
  (`0o700`), id shape check. **Priority:** P2.
- **One ping per task for hook-less dispatches (codex, wrapped claude).** *Why:* a
  `hooked: false` record pings on `ready` (we can't see its first turn), but codex's
  global hook block — and a claude behind a wrapper, whose per-worktree hook is still
  written — DOES report that turn, so its first `:done` edge rings and bolds a second
  time. `owns_first_turn?` only covers hooked records. *Start in:*
  `Creation.owns_first_turn?` / `Edges#suppress_completion?` — e.g. suppress exactly one
  `:done` edge for an unacked tasked record that already rang on ready, then let go.
  Codex trust (D18) is why it's `hooked: false` at all. **Priority:** P2.
- **A dispatch stuck before its first turn is silent.** *Why:* a brand-new worktree path
  makes Claude show its folder-trust prompt; no hooks run until you answer, so a hooked
  record sits `ready` with no ping and no dot — and `n` no longer drops you in the pane
  where you'd have seen it. *Start in:* `Creation.ringing?` / the sidebar scan — ping (or
  a distinct glyph) when a hooked `ready` record gets no hook state file within N
  seconds of launch. **Priority:** P1.
- **Re-certify a hand-fixed failed dispatch.** *Why:* a build whose setup failed (or was
  canceled) keeps its ✘ at rest and re-enters as a plain shell for as long as its tree
  exists; finishing setup by hand can't clear that guard — today only deleting the tree
  (and the work in it) does. The notices say so honestly now. *Start in:* a re-run path
  (e.g. retyping the launch line on an unfinished record: failed → launching under the
  lock, take ownership, rerun setup, then `authorize_launch`), or a confirmed "mark set
  up" on `d`. Overlaps #22 (retry on ✘). **Priority:** P2.
- **Smaller dispatch edges noted in review, all below the fix bar.** A ring for the
  workspace you're viewing if its `wait: false` ack was skipped that scan; GC racing a
  rename's `worktree move` can drop a hooked record's first-turn ping; `quit` from
  outside tmux cancels every server's builds; renaming onto a path a record still holds;
  the launcher claiming by path rather than record id (`launch <id> <dest>` would make
  every by-path lookup moot). From the 0.51.0 /ship run: a finished record whose path git
  stops listing shows an undismissable "still creating…" row; `reap_dead_owner` waits on
  the record lock and can return a just-deleted record (one-scan ghost); an empty
  `owner_start` leaves ◌ up to `PID_ONLY_CEILING`; a project hand-removed from config.yml
  mid-build leaves an orphan session; `add_reserved` giving up after a clash leaves a
  failed record on someone else's tree and keeps retrying after a cancel;
  `terminate_group` returns once the leader exits (a TERM-ignoring helper survives);
  wall-clock deadlines trip across laptop sleep; `^Z` in the agent hangs the launcher's
  `wait2`, and `SB_REEXEC`/rbenv vars leak into the agent; `{task}` in single quotes of
  `bash -lc '…'` re-parses as code (documented), inside `$(…)` it word-splits, after a
  `#` it's silently dropped; a task starting with `-` reads as an agent option (no `--`);
  a huge task hits E2BIG; the prompt draws C1/bidi characters raw; `project_node` takes
  the first same-name entry, `projects` the first with a path; `Sidebar#create`'s rescue
  misses ArgumentError/TypeError (a bad `worktree_root`); `send-keys -t name` lacks the
  exact-match `=`; a pre-upgrade sandbox/smoke `server.pid` (local-TZ start time) never
  matches the UTC read, so that throwaway server leaks. **Priority:** P3.
- **Test and cleanup gaps from the 0.51.0 review.** *Tests:* `git_test`'s stalled-fetch
  timeout test can't fail (`GIT_SSH_COMMAND="sleep 3"` exits on git's appended args — use
  `"sleep 3;:"`); `spawn_worker`'s `SystemCallError` rescue; `undo_add` on a locked tree;
  `unfinished_at?` with a newer set-up record / a `setup_ok` failure / a canceled record;
  `setup_invalid?` for a valueless per-project key over a junk global; the typeahead test
  can't see a missing `@typeahead.clear`, and rename/add typeahead is untested; 10
  untested state cells (queued/turn_done/canceled×d, building/ready/turn_done×enter,
  queued/launching/turn_done/canceled×remove_project); three wall-clock-bounded tests lack
  `gstack-timing-ok`. *Cleanup:* `doctor_sounds` skips `failed` (loop over
  `DEFAULT_SOUNDS.keys`); comments cite D*/DR* ids that live only in gitignored
  `thoughts/`; stale `start` docstrings (`tmux.rb` `go`, `Config#session_command_for`)
  and `columns`; declare `@typeahead` in `Sidebar#initialize`; `NOTE_WIDE` as `\u{…}`
  ranges; drop `terminal?` (always true at its caller), the dead `PRE_READY` clause on
  the project rule, `drop?`'s unused defaults, `owner_fields`' `pid` param,
  `notify_pane`'s trailing `true`; share the column-walk in `tail_view`/`fit_columns`;
  `@warming` → a `rebuild` kwarg. **Priority:** P3.

## `?` help paging (v0.55.0) follow-ups

- **Input bursts leak past a mode change.** *Why:* two paths let a burst of keys reach the
  tree after a mode ends. (a) A read that fills `READ_BYTES` can end mid escape sequence;
  `Input.tokenize` flushes the trailing `\e` as Esc (repro: 344 `→` in one buffer — the
  first read closes help, the second's arrows resize the pane, a persisted width). (b) A key
  that closes help hands the rest of its read to `dispatch`: a held `→` on a one-page help
  (never paged, so not sticky) closes it, then widens the pane. Both predate paging.
  *Start in:* `help_key` (clear the rest of `@typeahead` on a dismiss) and `tokenize`
  (carry a trailing `\e` when a read filled `READ_BYTES`, or an Esc timeout in the run
  loop). **Priority:** P3.

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
  both. *Start in:* `Registrar.register`/`create` / `CLI#add_project`; decide the
  collision policy (reject vs auto-suffix). Note `Registrar.create`'s
  `/\A[\w.-]+\z/` already blocks traversal + spaces but still permits the dot/dash
  collapse (`example.com` and `example-com` both map to `sb/example-com/`), so the
  fix belongs at this shared point, not a create-only regex tweak. Low priority — the collision needs unusual names
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

## Add-project error handling (create/clone) follow-ups

- **Guard `mkdir_p(projects_root)` and give clone/create actionable errors.**
  Both `Registrar.clone` and `Registrar.create` (`registrar.rb`) call
  `FileUtils.mkdir_p(config.projects_root)` unguarded — a non-writable
  `projects_root` raises straight up through the sidebar input loop instead of
  flashing a message. Both also surface a generic tail error (`"clone failed"` /
  `"create failed: <name>"`) that doesn't name the cause: for `create` the usual
  culprit is a missing git identity (the `--allow-empty` initial commit fails
  when git can't derive `user.name`/`user.email` and `user.useConfigOnly` is set)
  or a global `commit.gpgsign` with no key; for `clone` it's usually no network
  or a bad URL. *Why deferred:* pre-existing and shared with `clone`, so folding
  it into the create-repo feature would mix unrelated cleanup into a focused diff
  (per the 2026-07 plan-eng-review). *Start in:* rescue the `mkdir_p` in
  `Registrar.clone`/`create` (→ `[nil, err]`), and have `Git.init`/`Git.clone`
  distinguish the failing step so the message can hint at identity vs permissions
  vs network. Low priority — `projects_root` defaults to `~` (writable) and the
  generic errors match today's posture.

## Rename / worktree-move (issue #42) follow-ups

- **Agent dots may land on the wrong row after a rename onto a dead bridge
  (suspected, verify first).** *What:* rename `A->B` while its agent runs, then rename
  another workspace `C->A` (`Rename.perform` clears the stale `A` bridge,
  `rename.rb:49-51`). The hook reporter keys state on `cwd=$(pwd -P)`
  (`hook_file.rb:82`). If Claude spawns hooks with cwd = its remembered project path
  `A`, the B agent's dots and chimes now show on C's row; if hooks inherit Claude's
  kernel cwd, it's already right (`lsof -a -d cwd` and tmux `pane_current_path` both
  report the moved dir, probe-verified 2026-10-22). *Why:* wrong-row dots/chimes/bold.
  *Pros:* one attribution rule for dots and the remote-link glyph. *Cons:* a fix needs
  the reporter to write its pid (a reporter-script rewrite on every machine, the
  `hook-reporter-atomic-rewrite` care applies). *Context:* the remote-link glyph
  (eng review D10) already attributes by live pid cwd via one batched `lsof`; start by
  reproducing the sequence above with a real hooked agent, then reuse that helper.
  *Depends on:* remote-link PR 1 (the lsof helper).

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
  it needs its own tests and the path is implausible in practice (`move_worktree`
  is now its only caller — dispatch's `Creator.reserve` skips a symlink instead).
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

- **Opt-in gh-runtime smoke for the sticky-cache query contracts.** The sweep now
  rides `gh pr list --state all --search "sort:updated-desc"` and backfill rides
  `--head <branch> --state all --limit 1` — gh runtime contracts the offline suite
  can only pin as command *strings* (verified live against gh 2.96.0 during the
  sticky-cache work, including that `--search` still returns `isDraft`/
  `headRefName`). If a future gh rejects either combo, the sweep degrades to the
  plain creation-ordered fallback (`Pr.fetch`) rather than failing — but backfill
  has no fallback and would silently stop rescuing badges. An opt-in networked
  smoke (the `SWITCHBOARD_CODEX_SMOKE` shape, needs `gh` auth + a real repo)
  would make the contract auditable. Low priority — the fallback bounds the blast
  radius to pre-sticky behavior.

- **Residual sticky-cache freeze: a PR opened AND closed inside one unseen gap.**
  The stale-OPEN backfill re-query fixes the frozen-wrong-OPEN case (absence from
  the open query proves staleness), and a PR that's still open always lands via
  the open-500 query. The one remaining freeze: a branch negative-cached as null
  whose PR is opened *and* merged/closed while no refresh runs and >200 other PRs
  get updated (a weeks-long absence on a very active repo) — the null suppresses
  backfill and the state flip aged out of the sweep. Self-heals on ANY later
  activity on that PR (comment/label/merge touches `updatedAt`). If ever felt in
  practice: make `R` (`refresh_prs_now`) drop null entries, or expire nulls when
  the cache mtime shows a long refresh gap. Start in `Pr.backfill` /
  `Sidebar#refresh_prs_now`.

- **Unify the two "is this the primary checkout?" predicates.** `Model#build_worktrees`
  marks primary by string equality (`w[:path] == project["path"]`) while
  `Pr.rendered_branches` uses `File.identical?` (symlink-proof) — under a symlinked
  config-path spelling the true primary can render as a phantom workspace row
  (pre-existing Model quirk) while backfill correctly excludes it. Safe direction,
  but two predicates in two files will drift; extract one `File.identical?`-based
  helper both use (which also fixes the phantom row). Surfaced by the sticky-cache
  red-team pass. Related: the sanitized `Pr.cache_file` name can collide for two
  registered projects (`app one` / `app_one`) — pre-existing shadowing that the
  new REPO_KEY identity guard turns into a wipe-and-refill alternation; the add-time
  name validation TODO (top of this file) is the right chokepoint for both.

- **`Pr.repo_slug` doesn't pin the host.** It parses `owner/repo` out of any
  origin URL, so a GitLab/self-hosted origin queries the same-named *GitHub* repo
  via `gh` — and sticky now makes any resulting wrong badges durable (pre-existing
  exposure, worsened at the margin). Fix: return nil unless the origin host is
  github.com (or the `gh`-configured host), so non-GitHub projects cleanly show no
  badges. Start in `Pr.repo_slug`; surfaced by the sticky-cache adversarial review.

- **Trailing/coalescing debounce.** The per-project background refresh uses a
  *leading* debounce (`Edges::PR_DEBOUNCE`, `sidebar/edges.rb`): a second distinct event for
  the same project inside the window is dropped. Today the idle backstop and the
  next navigation heal it, so it self-corrects within `BACKSTOP_TTL`. If that
  staleness window is ever felt in practice (e.g. two worktrees of one project
  open PRs seconds apart), switch `spawn_due?` / `maybe_refresh_prs` to a
  trailing debounce so the *latest* event always results in a fetch. Low
  priority — only worth it if observed.

- **Watch-while-working freshness for hook-less agents.** The agent-completion
  refresh trigger (T1) fires only on the *hook* signal (`AgentState#last_hook_states`),
  because the coarse activity fallback flips `:thinking ⇄ :done` every 3s and
  would fire on noise. So hook-less worktrees (Aider, or Claude/Codex before
  `enable-hooks`) get badge freshness from navigation + the backstop, not the
  live edge. (Codex now has exact hooks too — #110 — so an *enabled* Codex
  worktree already rides the live edge; this is about agents with no hook
  surface.) If you run a hook-less agent and want its badges as live as a hooked
  one's, add a presence-precise signal for it rather than leaning on the
  capture-hash. Start in `agent_state.rb` (`activity`) and the T1 wiring in
  `sidebar/edges.rb` (`refresh_agents` → `Edges#on_scan`).

## Sidebar input handling follow-ups

- **Flush the rest of the read buffer after an in-dispatch confirm.** `Sidebar#confirm`
  (used by `q` quit, `d` delete) reads its y/N from `$stdin` directly, while `#handle`
  may still hold later bytes from the same `read_key` chunk in its local buffer. So a
  fast `qy`/`dy` or pasted/`tmux send-keys` input can leave stale keys that dispatch
  *after* the confirm resolves. The `q`→quit footgun is already closed (`#handle` now
  breaks on a stop-token), so the residue is benign today — extra navigation, at worst
  another confirm. *Why not fix now:* a clean fix means draining the buffer across all
  three confirm callers (`q`/`d`, and the `rename`/`create` cooked-mode prompts), which
  is broader than the quit change. *Start in:* `Input#handle` (`sidebar/input.rb`) / `Prompt#confirm` (`sidebar/prompt.rb`) — either
  pass the remaining buffer into the prompt helpers, or clear `$stdin` after a prompt
  returns. Low priority — needs buffered/pasted input to trigger and nothing destructive
  results.

- **Esc-timeout to close the `\e`|`[O` escape split (accepted).** `Input.tokenize`
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
  when `@pending == "\e"`) + `Input.tokenize` (return a lone trailing `\e` as remainder). Only
  worth it if we ever stop trusting the producer to write sequences atomically.

- **Unify the name-prompt reader onto `tokenize`.** `Prompt#edit_buffer` (the inline
  `r`/`n` name prompt, `sidebar/prompt.rb`) still slices escapes at a fixed 3 bytes, the same
  shape the main loop's `handle` had before the tokenizer. *Why low:* the prompt already
  reads 1024 bytes and no destructive key is bound during a name edit, so a split sequence
  there just drops a stray char into the name you can see and backspace — not a footgun
  like the open-repo orphan was. *Start in:* `Prompt#edit_buffer` — route it through
  `Input.tokenize` so both readers share one grammar. Pure cleanup; do it next time
  the prompt path is touched.

## Sidebar hot reload (issue #48, v0.59.0) follow-ups

Found by the /ship reviews after the 3-cycle fix limit; deferred with Will's OK (D4).
*Start in:* the reload section of `lib/switchboard/sidebar.rb`, `CodeReload.reload_all`.

- **A `0` tag whose replacement never lands still strands the pane.** *Why:* since 0.60.3 a
  new image retries its pid tag (`retry_tag`) up to `TAG_TRIES`; if every attempt fails, the
  `0` from the exec stays and later reloads skip the pane, with no failure flag for `doctor`.
  Rarer than before (five failures in a row, or tmux < 3.0, where the exec path can't tag at
  all). *Fix:* on give-up, flag the pane best-effort, or stamp the `0` with its time beside the
  tag (`@sb_reload_boot`) so senders can treat an old one as stuck. **Priority:** P3.
- **A keg-path sidebar spawns from that keg until it reloads.** *Why:* an image that booted
  while opt/ was missing keeps the keg path in `SWITCHBOARD_BIN`. Since 0.60.4 its reload
  follows opt/ (`real_bin`), but the env var itself doesn't, so until the swap (up to the
  spread off screen, or never if the check fails) new-window sidebars, PR refreshes, the
  pane's own respawn and other `SWITCHBOARD_BIN` spawners run that keg, which `brew upgrade`'s
  cleanup deletes. *Fix:* re-point `ENV["SWITCHBOARD_BIN"] = StablePath.resolve(bin)` in `tick`
  once opt/ resolves. **Priority:** P3.
- **Reload doc and backstop nits from the 0.60.4 review.** *Why:* `code_moved?` resolves the bin
  twice (`stale?`, then `current_root`), so opt/ dangling in between requests a reload that then
  skips; and CLAUDE.md's "Nothing can repoint a sidebar at another install" is no longer strict,
  since a keg-path sidebar now follows opt/ (a `--HEAD` keg included, after a channel switch).
  *Fix:* resolve once in `code_moved?`; reword the guarantee to "its own install's opt/ link".
  **Priority:** P3.
- **An unresolved-bin flag can outlive a same-keg relink.** *Why:* since 0.60.4 a reload that
  can't resolve the install flags the pane with the bin path, and only a reload that lands
  clears it. If opt/ comes back on the keg the sidebar already runs (`brew reinstall`, a
  same-version relink), the backstop never fires, so `doctor` and every reload summary report a
  failure until a `reload-sidebars`. Also: an empty `SWITCHBOARD_BIN` writes an empty flag (reads
  as not failed), and a transient exec errno (ETXTBSY) blocks a keg that still exists. *Fix:*
  remember the unresolved state and, once `real_bin` resolves to `LOADED_ROOT`, clear the flag
  (or request a same-code reexec); treat `""` like nil; block on a failed exec only when the file
  is gone. **Priority:** P3.
- **A reload's `announce` is judged on a possibly stale `@visible`.** *Why:* a key batched with
  the switch poke can move you away (`↵` to another session); `@visible` stays true until the
  next tick, so a swap in between hands over `announce: true` from a hidden pane. The new
  image re-samples visibility before its first scan, so it doesn't ring off screen today.
  *Fix:* re-sample `Tmux.visible?` in `resume_payload`. **Priority:** P3. Found by the 0.60.2
  adversarial review.
- **A reload signal can reach a recycled pid.** *Why:* `reload_all` reads every pane's pid at
  the start, then can spend seconds in `restartable` preflights for untagged panes before it
  signals later ones. A sidebar that exits in that gap, its pid reused by another process of
  yours, gets SIGUSR1 (default action: quit) on that process instead. *Fix:* signal every
  tagged and fish-child pane in a first pass, before any preflight; or check pid + start time
  (`ProcessIdentity.same?`). **Priority:** P2. Found by the 0.60.8 adversarial review.

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
- **The warm fingerprint can record a file rebuild never drew.** `reload` runs `rebuild`
  (which reads config, collapse, full header, branch fold, width) BEFORE it samples
  `warm_fingerprint`, so a peer's write landing between the two is baselined as drawn,
  and a hidden pane then skips the warm that would show it until that file moves again
  or you switch in. *Why deferred:* nobody has seen it (the window is milliseconds and a
  switch-in reload heals it); #47 fixed it only for its own two entries (the update cache
  and the installed `version.rb`). *Start in:* `Sidebar#reload` / `#warm_fingerprint` —
  #47's rule (fingerprint each rebuild-read file by the mtime `rebuild` captured when it
  read it, one look per file) is the template. Depends on #47 landing. **Priority:** P3.

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
  `Actions.browse_args` (`sidebar/actions.rb`) + a `Git` remote-branch helper. Low
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

## Sandbox / dogfooding (issue #126) follow-ups

- **`lone_pane_handled` learns to skip a non-switchboard split.** Teach
  `lone_pane_handled` (`sidebar.rb`, the run-loop core) to ignore a sidebar that isn't a
  switchboard-managed split, so a hand-run lone `switchboard sidebar` doesn't
  self-`go_home` and exit. *Why:* `switchboard sandbox` (#126) avoids the #64 trap
  by always seeding a work pane beside the sidebar, so the normal flow never trips.
  But if someone manually runs a *lone* `switchboard sidebar` inside the sandbox, it
  still self-exits. Inside the isolated server that's harmless (`go_home` lands on the
  sandbox home, not real sessions), which is why it's deferred — but #126 explicitly
  flagged it as "worth deciding on separately," and #64 is now CLOSED so this is a
  fresh small enhancement, not a reopen. *Start in:* `Sidebar#lone_pane_handled` — gate the
  fall-home on a marker that identifies OUR split (pane title / an `@sb_*` option)
  before acting. Independent of the sandbox PR. Low priority — the seeded work pane
  already covers the real flow, and the manual-lone case is harmless in the sandbox.

## Sidebar split (issue #57) follow-ups

- **Option (not obligation): a pure `Frame`/view-model render object.** The #57
  split chose concern mixins over extracting render into a `Frame.build(state) →
  lines` object because mid-refactor it was the wrong trade: ~17 state fields
  through a constructor and a rewrite of 100+ white-box render tests, for zero
  behavior gain (per the 2026-07 plan-eng-review, decisions D5/D15 in
  `thoughts/57-sidebar-split.md`). That calculus flips once `render.rb` is a
  single file with `sidebar_render_test.rb` beside it — the Frame becomes a
  contained experiment, not a big bang. *Triggers that would justify it:* wanting
  render tests that don't construct a `Sidebar` at all; a second front-end; the
  mixin's implicit ivar coupling actually causing bugs (a render change breaking
  a non-render concern). *Start in:* `lib/switchboard/sidebar/render.rb` — the
  paint paths are already the leaf of the call graph. If none of the triggers
  ever fire, this entry is correctly ignored forever.


## Silent failures (v0.57.1) follow-ups

- **State-dir globs break on a path with glob characters.** *What:* ten `Dir.glob` calls
  build their pattern from a state dir (`creation.rb` `all`, `agent_state.rb`, `notify.rb`,
  `monitoring.rb`, `pending_delete.rb`, `keyed_marker_store.rb`, `offstage_hold.rb`,
  `Sidebar#dir_fingerprint`; grep `Dir.glob(File.join` for the rest); switch each to `Dir.glob(pattern, base: dir)` the way
  `ClaudeSessions.session_files` now does. *Why:* an `XDG_STATE_HOME` containing `[`, `{`, `*`
  or `?` makes them match nothing; worst is `Creation.all` coming back empty, which drops a
  failed build's guard (`certified?(nil)` lets re-entry start the agent un-set-up).
  *Pros:* mechanical, one test per store. *Cons:* touches every store. *Context:* found in
  the TODO triage that produced v0.57.1. **Priority:** P2.

- **A C-locale tmux client mangles `-F` output.** *What:* with `LC_ALL=C`, tmux replaces
  the tab and any non-ASCII byte in `-F` formats with `_`, so `Tmux.sessions` misparses and
  `quit`/`kill_all` can't match names (prune is saved only because `created` reads as 0,
  inside the grace window). Use a printable ASCII separator (or one field per call) in the
  formats switchboard parses. *Why:* teardown silently does nothing under a C-locale client.
  *Pros:* small. *Cons:* every `-F` parser changes at once. *Context:* v0.57.1 triage.
  **Priority:** P2.

- **The rest of `Git`'s readers on a non-UTF-8 path.** *What:* v0.57.1 made
  `Git.worktrees` skip an undecodable entry; `current_branch`, `commits_since` and the diff
  readers (with `core.quotePath=false`) can still raise on one. Audit each caller and either
  scrub or compare as bytes. Also `parse_worktrees` itself: it drops a whole entry when ANY
  line is undecodable, so a worktree on a branch whose name isn't valid UTF-8 (git prints
  `branch <ref>` raw) vanishes from the tree, and `strict: true` returns nil for the whole
  listing (rollback then keeps everything, prune skips the project: safe, but silent).
  Validate only the `worktree` line and drop or scrub just the bad field. *Why:* a
  Linux-only crash path in the sidebar's helpers, and an invisible row.
  *Context:* v0.57.1 item 3 caller audit; ship 4 red team. **Priority:** P3.

- **`keep_branch`'s listing and its delete aren't one step.** *What:* between
  `Git.worktrees(strict: true)` and `update-ref --no-deref -d`, another process could check
  the branch out. *Why:* at worst a worktree is left on a deleted branch at base (no commits
  lost, the old-value guard holds). *Pros:* closes the last race on the rollback. *Cons:*
  git offers no atomic "delete unless checked out"; it needs a lock switchboard doesn't
  have. *Context:* v0.57.1 review, accepted as theoretical. **Priority:** P4.

- **`ours?` misses a bin path containing `$`, `"` or `\`.** *What:* `tmux list-keys`
  prints the run-shell argument double-quoted and backslash-escapes those characters, so the
  raw `bin_path` never matches and switchboard's own binding is recorded as a clobber
  (doctor then warns about itself). Unescape the binding before matching. The key column has
  the same problem: `list-keys` prints a `;` key as `\;`, so `foreign_binding` can't find a
  user's own binding on `;` (tmux's default last-pane) and the clobber goes unrecorded. *Why:* a false
  warning, not a lost key; pre-existing. *Context:* v0.57.1 pass-3 red team. **Priority:** P4.

- **`uninstall` says Done over a codex config it can't read from the start.**
  *What:* `step_codex_unhooks` returns early when `CodexHook.installed?` is false, and that
  reads false for an unreadable `config.toml`, so uninstall exits 0 with our block still in
  the file. Only a file that turns unreadable mid-uninstall is reported. *Why:* a silent
  success, though an inert one (codex can't read the file either). *Cons of the obvious
  fix:* treating "unreadable" as a failure would fail uninstall on every run for someone
  whose unreadable `config.toml` never held our block; a fix needs a way to say "couldn't
  check" without failing. *Context:* ship 4 red team, deferred by the user. **Priority:** P4.

- **Two narrow paths that can still act on someone's work.** *What:* (a) `prune` takes
  its valid session names from Model's `Git.worktrees` and verifies the project with a
  second, strict listing; if the first comes back partial and the second full, a live
  session older than `SESSION_GRACE` reads as orphaned. Build `names` from the strict
  listing itself. (b) A post-checkout hook that starts a rebase or bisect and then fails
  leaves a worktree git lists as detached, so `keep_branch` finds no holder and
  `delete_branch_at` deletes a branch the rebase still needs (the old `branch -D` refused
  it). Check rebase/bisect state before deleting. *Why:* each can kill a session or delete
  a branch; neither trigger was reproducible in normal use. *Context:* v0.57.1 ship 5
  adversarial review (Claude + Codex structured P2), deferred by the user. **Priority:** P3.

- **Rollback and key-tracking design notes.** *What:* (a) `undo_add` assumes git cuts the
  `-b` branch before it checks the path (true in current `builtin/worktree.c`, no version
  pinned); (b) an older switchboard install whose fragment tmux also sources rewrites
  `@switchboard-*-key` but not `-rejected`/`-config-path`, so doctor can show a stale row
  (upgrade is gated on `fragment_wired_here?`, doctor isn't); (c) a config value spelled
  `\\;` resolves to `\;` while tmux records `;` (drift row never clears); (d) a branch kept
  after `move_off` (named in the ✘) is never collected later; (e) a project with a
  non-UTF-8 worktree path keeps every failed create's branch and is never pruned, and
  doctor doesn't name why; (f) on a tmux too old for `list-keys -- KEY`, the whole-table
  fallback reads a bound `C-;` as unbound (its regex allows a backslash only before the
  whole key). *Why:* all fail safe or say so in the ✘ text; worth a pass once (a)-(b) of
  the entry above land. *Context:* v0.57.1 ship 5 adversarial + state-machine reviews.
  **Priority:** P4.

- **Small cleanups from the v0.57.1 review.** *What:* the `rebind_ops` header doesn't
  mention `taken:`; `Upgrade.tmux_stale?` and `CLI#doctor_key_drift` hard-code
  `%w[toggle home]` instead of `Installer::ROLE_SUBCOMMANDS.keys`; the
  `@switchboard-<role>-rejected` name is hand-built at 7 sites (route it through
  `tmux_argv` ops like `-key`/`-clobbered`); `install` re-parses config.yml to pick its
  "Done, except …" label instead of asking `refresh_wiring` which part failed; the
  `key_drift?` comment lists only two of the reasons it returns nil (`bound_from?` has them
  all); a dead `if p["name"]` guard in `Reconcile.prune` (`Config#projects` drops nameless
  entries); `docs/howto-manage-projects.md` hard-codes "5 tries" where the code uses
  `PLACEHOLDER_TRIES`. *Why:* no behavior change today; each is a place a later edit can
  drift. *Context:* ship 5 and 6 maintainability reviews, deferred by the user. **Priority:** P4.

- **Rollback edges from the v0.57.1 lock and config fixes.** *What:* (a) `delete_branch_at`
  ignores a failed `git config --remove-section` (a held `config.lock`), so a hook-set
  upstream can survive onto the next branch cut under that name; (b) `d` on a ✘ row whose
  tree the rollback kept "(it's locked)" still double-forces after the confirm, and the prompt
  doesn't say the tree is locked; (c) a failed `git` spawn in `Git.lock_reason` also reads as
  "(it's locked)" (fails safe, wrong reason); (d) `LANGUAGE=en` from `add_worktree` reaches
  the user's own checkout hooks; (e) a config.yml of literal `null`/`~` reads as empty (YAML's
  meaning) rather than broken. *Why:* all fail safe or only mislabel; none loses work.
  *Context:* ship 6 Claude + Codex adversarial reviews, deferred. **Priority:** P4.

- **More rollback and config edges (ship 7).** *What:* (a) `Config.add_project` /
  `remove_project` read config.yml raw, so a top level that isn't a map (a list, or one
  string after a dropped colon) raises a Ruby error out of `add` and sidebar `a` instead of
  `load_error_message` (pre-existing; `load_data` now calls that file broken); (b) when a
  clash leads `add_reserved` to retry under a new name, the `kept` text `undo_add` returned
  is dropped, so anything it kept goes unnamed; (c) the "can't tell whose they are" return
  skips `move_off`, so if the tree really is a workspace renamed onto the placeholder, its
  row keeps our ✘ and `d` there can force-remove a clean live workspace; (d) `run_tmux`
  escapes ANY argument ending in `;`, including the `@switchboard-config-path` value, so a
  config path ending in `\;` never matches `bound_from?` (escape only key arguments);
  (e) `upgrade` re-runs "finishing setup" forever when the fragment is wired here but its
  bind fails, since `finish` never re-checks `key_drift?` after `reload_fragment`; (f) a
  `locked` entry that isn't a regular file (a dir or FIFO) reads as unlocked, so the ✘ says
  "(couldn't remove it)" instead of "(it's locked)"; (g) git older than about 2.17 words
  "A branch named 'x' already exists." differently, so the clash checks miss it there.
  *Why:* each fails safe, mislabels, or predates the branch. *Context:* ship 7 Claude
  adversarial and red-team reviews, deferred by the user. **Priority:** P3 for (a) and (c),
  P4 for the rest.

- **Ship 8 edges.** *What:* (a) a placeholder landing on a folder someone `rm -rf`'d without
  `git worktree prune` fails the create with git's last line ("use 'add -f' to override, or
  'prune' or 'remove' to clear"), which drops the path, and isn't retried under a fresh name;
  read git's `fatal:` line and treat "is a missing but already registered worktree" as a
  collision; (b) a relative `SWITCHBOARD_CONFIG` expands against a different directory in the
  tmux server than in the shell, so `bound_from?` never matches and key drift is never
  flagged, and a `~nosuchuser/...` value raises out of `tmux-bind` after the binds ran;
  (c) widens ship 7 (a): `Config.add_project` reads a top-level `false` as `{}` and rewrites
  the file with only the new project, dropping `worktree_root` and every comment (check
  `load_error` before writing); (d) on a tmux too old for `list-keys -- KEY`, the whole-table
  fallback can't match a quoted `"C-;"` (tmux 3.8 prints it quoted), so `upgrade` would loop
  on a `C-;` toggle there (design note (f) above). *Why:* each fails safe or is pre-existing.
  *Context:* ship 8 Claude adversarial review, deferred by the user. **Priority:** P3 for (c),
  P4 for the rest.

- **Rollback and cancel paths still trust a status check.** *What:* (a) the cancel teardowns,
  `Creator.discard` (`creator.rb` after `untouched?`) and `Sidebar#discard_built` (`d` on a
  built ◌ row, via `reap_worktree!` and `branch -D`), check the tree clean and then remove it
  with `--force`, so a file written between the check and the removal is deleted; remove
  unforced under `-c status.showUntrackedFiles=all` the way `undo_add` now does, and delete
  the branch with `delete_branch_at` at the base commit; (b) a tracked file flagged
  `assume-unchanged` or `skip-worktree` (sparse checkout, or a hook that flags it) hides its
  edits from `Git.clean?` and from git's own unforced `worktree remove`, so `undo_add` can
  delete them; fail closed when `git ls-files -v` shows an `h`/`S` entry; (c) the new
  `--ignore-submodules=none` in `Git.clean?` has no test (a submodule with
  `diff.ignoreSubmodules=all`); (d) `test/git_test.rb`: the "point of the fail-closed twin"
  comment now sits above the untracked-files test instead of the status-error one. *Why:*
  (a) and (b) can still lose a file in a narrow race or an unusual setup; (c)-(d) are test
  hygiene. *Context:* ship 8 reviews (security, red team, Codex adversarial), deferred by the
  user. **Priority:** P2 for (a)-(b), P4 for (c)-(d).

## Agent CLI hooks (Claude 2.1.301 / Codex 0.163 compat review) follow-ups

- **Remote-link glyph: rare edges deferred at ship review (v0.53.0).** *What, in priority
  order:* (1) the doctor canary misses a format change while one old-format leftover file sits
  beside the new ones (shaped > 0, alive 0 reads healthy); (2) `claude_pids` misses a
  Claude whose process shows as `node …/cli.js`; (3) an empty workspace name shifts that
  row's columns — let `fit_plain` report whether the cues were kept and share it with
  `colored` (the cursor-bar grey half of this went away in v0.53.1); (4) a stale comment:
  `Agents.lsof_path`'s encoding rationale predates the byte compares.
  *Why:* none hits a normal setup (the one verified user-visible item, the glob, shipped in v0.57.1). *Pros:*
  small, testable changes. *Cons:* each touches a reviewed path, so give it its own short
  review. *Context:* ship review of v0.53.0 (D2/D3 — deferred to keep the release from
  reopening its review loop). *Depends on:* v0.53.0.

- **Remote-link glyph: one batched `ps` for the start-time checks.** *What:* the full
  scan (`RemoteLink.scan`, visible panes, every `REFRESH`) calls
  `ProcessIdentity.same?` once per LIVE linked session on the machine (dead leftovers
  already skip it via `kill(0)`), each a `ps` fork; batch them into one
  `LC_ALL=C TZ=UTC ps -o pid=,lstart= -p a,b,c` (a `ProcessIdentity.starts_of(pids)`).
  *Why:* N linked sessions = N forks every 3s on the visible pane's input loop (6 on
  Will's machine at ship time, ~30-60 ms). *Pros:* one subprocess per scan whatever
  the count. *Cons:* a new helper + tests. *Context:* deferred at ship review (pass 2,
  D2=B); measure first. *Depends on:* remote-link PR 1.

- **Agents' own session files as a presence source (research Claude AND Codex).**
  *What:* Claude Code (2.1.308) writes `~/.claude/sessions/<pid>.json` per live session
  with `status` (busy/idle/waiting), `statusUpdatedAt`, `cwd`, `procStart`, `kind`; let
  `AgentState` read it for Claude sessions WITHOUT a fresh hook file. Research whether
  Codex keeps an equivalent live state: candidates seen locally are
  `~/.codex/sessions/YYYY/MM/DD/` (transcripts), `~/.codex/app-server-control/`,
  `~/.codex/ipc/`, and the `*.sqlite` stores; no per-pid status file like Claude's was
  visible. *Why:* exact thinking/waiting/done for hook-less sessions, and possibly
  retiring much of the coarse fallback (`Agents.active`: tmux panes + `pgrep`/`lsof` +
  `capture-pane` hashing) and some hook plumbing; Will expects it would "simplify a lot
  of code". *Pros:* one source each agent writes itself; reuses the remote-link
  `RemoteLink` reader (PR 1). *Cons:* ties core dot logic to undocumented files (the
  reason the remote-link design ruled it out of scope); must never override a fresh hook
  state; a format change needs a doctor canary like the remote-link one. *Context:*
  `agent_state.rb` merge path; start with the Codex research (decides whether this is
  one mechanism or Claude-only). *Depends on:* remote-link PR 1.

- **Check whether Claude fires `Stop` when a turn ends on an API error.** *Why:*
  Claude documents a separate `StopFailure` event for a turn that dies on an API
  error. If `Stop` doesn't also fire there, the dot stays blue ("thinking") until
  `PRESENCE_TTL`. Wiring `StopFailure → done` is a one-line `ClaudeHook::EVENTS`
  entry, but only safe once we know `Stop` doesn't also fire. If both fire and the
  rename backstop blocks (writing `thinking`), a parallel `done` would race it,
  which is the race the single-command Stop design exists to avoid. *Start in:* a
  live `claude -p` run with a payload-capture hook on `Stop` + `StopFailure` and a
  forced API failure (bad model id or offline), then `claude_hook.rb` EVENTS. Note
  that it would chime and bold like a normal completion. **Priority:** P3.

- **Move a Codex-written `[[…]]` array-of-tables out of our block instead of refusing.**
  *Why:* Codex appends new tables inside our EOF marker block (toml_edit puts them before
  the trailing end-marker comment). `CodexHook.movable_parts` refuses any `[[…]]` chunk as
  `:unsafe`, so if Codex ever wrote one there, install, doctor and uninstall would all
  refuse, and uninstall (which runs the codex step first) would stop until the file was
  edited by hand. None in a real 0.163 config yet, but the 0.163 binary has a
  `skills/config` writer for `[[skills.config]]` entries; `UNSAFE_ADVICE` now tells the user
  codex may have written them and how to move them (decision dec-aae03c57; `gstack-shortcut`
  marker in `CodexHook.chunk_kind`). *Start in:* `movable_parts` / `chunk_kind`: move a
  contiguous run of one `[[name]]` array plus its `[name.…]` sub-tables as a single foreign
  piece when every `[[name]]` outside the block comes before it, keeping `:unsafe` for an
  array split across the marker boundary or interleaved. **Priority:** P3.

- **Codex: keep comments inside the block that head a codex table.** *Why:* comments are kept
  outside the block when an approval next to them is dropped, but inside the managed block a
  comment trailing our `[hooks]` chunk or a dropped approval goes with it, even one above a codex
  table that then moves out (decision dec-3417a712; `gstack-shortcut` marker in
  `CodexHook.movable_parts`). *Start in:* carry a dropped or regenerated chunk's trailing
  comment run onto the next kept chunk in `movable_parts`, and list it in what `conserved?`
  checks. **Priority:** P3.

- **Sandbox: wall off CODEX_HOME so a pane can't rewrite the real codex block.** *Why:*
  `Sandbox.sandbox_env` keeps the real HOME and leaves CODEX_HOME alone, so `enable-hooks` /
  `install` / `uninstall` typed in a sandbox pane rewrite the real `~/.codex/config.toml` block to
  call the sandbox's throwaway bin and reporter (dead after teardown); codex then re-asks in
  `/hooks` for the changed commands while doctor still counts the carried approvals. A first fix (seed a private auth.json
  copy, write a refreshed one back on teardown) was pulled from v0.51.1 (decision
  dec-540ed953). *Start in:* `sandbox_env` + a seed step, with: capture the real CODEX_HOME
  before the redirect (one tested helper); copy only auth.json, 0700 dir / 0600 file created
  with that mode (not chmod after); write back only after the tmux server is killed, only a
  copy that parses as JSON, changed and newer than the real file, via a 0600 temp + rename
  removed on failure; never create a real auth.json that wasn't there. Or the smaller
  alternative: refuse CodexHook writes under SWITCHBOARD_SANDBOX. **Priority:** P2.

- **Doctor: tell a codex approval from a stale carried-over one.** *Why:* v0.50.1's install
  carries every `[hooks.state]` approval across a command change (a brew ↔ clone bin switch) —
  v0.51.1 keeps that on purpose (dropping them lost approvals across a checkout round trip and
  erased `enabled = false`; decision dec-d24d649e) — so such a block reads as N/M trusted while
  codex skips those hooks (decision dec-455f3bf8; `gstack-shortcut` marker in
  `CodexHook.trust_status`). The v0.51.1 CHANGELOG asks upgraders to review `/hooks` once.
  *Start in:* record a fingerprint of each group's command beside the block on install (or
  reproduce codex's `trusted_hash`) and count only approvals that match. **Priority:** P3.

- **Claude: check whether auto-compaction fires SessionStart mid-turn.** *Why:* the SessionStart
  `done` reporter has no matcher, so a SessionStart(compact) while the agent keeps working would
  ring a false completion chime + bold until the next tool call (pre-existing since v0.50.1;
  decision dec-549dc4af; `gstack-shortcut` marker in `ClaudeHook::EVENTS`). *Start in:* force a
  `/compact` mid-turn in a live session and watch the dot; if it flips, give the reporter a
  matcher skipping `compact` (every worktree then needs `enable-hooks`). **Priority:** P3.

- **Install: say `/hooks` when a re-ensure changes the commands.** *Why:* after a brew ↔ clone
  switch, re-running `install` rewrites the block's commands and carries their old approvals,
  and the one-time `/hooks` note is skipped on a re-ensure, so nothing tells the user codex now
  re-asks. *Start in:* check `CodexHook.block_state` before `install_global` in
  `step_codex_hooks`; print the note when it was `:stale`. **Priority:** P3.

- **Doctor: tighten the trust-bypass and disabled-hook reporting.** *Why:*
  `codex_bypasses_trust?` matches the bypass flag anywhere in a command, so
  `codex --dangerously-bypass-hook-trust; codex` (or the flag in a comment) reads as bypassed,
  and the bypass row shows green even for a hook set `enabled = false`, which bypass doesn't
  re-enable. *Start in:* `CLI#codex_bypasses_trust?` (match per launch) and count disabled
  handlers separately in `CodexHook.trust_status`. **Priority:** P3.

- **Codex: refuse (or decode) an escaped spelling of `hooks`.** *Why:* `["\u0068ooks"]` is a
  valid spelling of `[hooks]` that `chunk_kind`/`HOOKS_KEY` read as foreign, so a block whose
  own header were spelled that way would be moved out and a second `[hooks]` written (contrived:
  switchboard never writes it). *Start in:* decode basic-string escapes in `TOML_KEY` matches,
  or refuse any quoted key holding a backslash. **Priority:** P3.

- **Monitoring: don't let a fork clear a still-running session's ∞.** *Why:* the marker is
  per worktree, so `SessionStart(fork)` (now in `CLEARS_ON`) clears a marker the original,
  still-live session declared; the ∞ drops until its next `monitoring on`. *Start in:* store the
  declaring session id in the marker and clear only on a matching id. **Priority:** P3.

- **MarkerBlock: create the temp file with the target's mode.** *Why:* `atomic_write` writes
  `<dest>.<pid>.sb-tmp` with umask permissions and copies the mode after, so a 0600
  `config.toml` (MCP tokens) is briefly readable through the temp file and a failed write leaves
  it behind. *Start in:* open the temp with `File::EXCL` and the destination mode (default
  0600 for a new file), and remove it in an `ensure` when the rename didn't happen.
  **Priority:** P3.

- **Smoke: tell "the model didn't run the tool" from a trust failure.** *Why:* the untrusted
  codex smoke flunks if the model answers in text instead of running `cp`, and a future codex
  that refuses unreviewed hooks would read as auth/network trouble and skip. *Start in:* skip
  when `sb-seen.txt` is missing, and add a pattern for codex's untrusted-hook text that asserts
  instead of skipping. **Priority:** P3.

- **Small hook-path hardening.** *Why:* each is low-impact today. (1) The notify reporter's
  `sed` takes the last `"notification_type"` on a line (a nested copy would win; Claude's
  payload is flat): anchor the first match. (2) `HookFile.ensure_script` reads the script in the
  process locale, so under `LC_ALL=C` it rewrites it on every call: read it as UTF-8.
  (3) `enable-hooks` outside a worktree exits 0 with only a warning. (4) The `conserved?`
  comment claims more than the uninstall-side check does. **Priority:** P4.

- **Tests: pin the rescue-only and untested-but-correct paths.** *Why:* the
  `block_state` / `trust_status` rescues and the `same_file?` expand_path fallback survive
  mutation, and the v0.51.1 state-machine review listed ~19 cells the code handles correctly but
  no test exercises (bare `[hooks.state]` on reinstall, `--no-codex-hooks` over each block state,
  enable-hooks over codex tables or a missing end marker, …). *Start in:* the cell list in the
  ship review; `test/codex_hook_test.rb`, `test/installer_test.rb`. **Priority:** P4.

## Background-wait `◷` (v0.56.0) follow-ups

- **Probe the Stop payload's `background_tasks` field.** *What:* Claude 2.1.310's `Stop`
  hook payload carries `background_tasks` (and `session_crons`) keys; the v0.56.0 probe
  logged key names only. *Why:* if it lists the outstanding work, it's an exact, hook-side
  hand-off signal — no session-file read, no settle window, and it would cover Codex if
  Codex grows the same. *Context:* rerun the T0 probe harness (a throwaway tmux + real
  claude, `DISABLE_UPDATES`) dumping the field's values for a background agent, a
  background Bash and a Monitor. *Depends on:* nothing.
- **Reporter v6 attribution gaps (both reproduced at ship QA).** (a) `field agent_id`
  matches an `agent_id` key nested in a main-agent tool's `tool_input` (the sed match is
  greedy, last wins), so that `thinking` refresh is dropped; fix by matching only
  top-level keys once a probe confirms Claude's payload key order (does `agent_id` precede
  `tool_input`?). (b) A background subagent's `PostToolUse` turns a MAIN agent's open
  `waiting` into `done` (no owner on the state line); fix with a 4th `owner` field
  (`main` or the agent_id) that `AgentState` tolerates, cleared only by its owner. Neither
  is a regression: v5 wrote `thinking` over the main `◆` on every subagent tool call.
- **A matured hold bolds only on an on-screen claim.** *What:* a hold that matures with no
  follow-up turn (pid gone, settled idle) while no sidebar is on screen leaves no bold,
  then chimes late on return. *Why kept:* an off-screen pane can't tell what you're
  viewing, so bolding there could re-bold a workspace you just looked at (Build note 1).
  *Fix idea:* stamp maturity time on the hold; any pane bolds; drop the sound when the
  claim comes long after maturity.
- **Pid-based maturity can't tell finished from abandoned.** A Claude killed or `/exit`ed
  mid-background-work matures its hold (a "done" chime for abandoned work); a recycled
  pid after a clean exit keeps a hold until the next settled idle there. Store
  `procStart` in the hold and use `ProcessIdentity.same?` on visible scans; treat "gone
  and file removed" as release.
- **Holds of a removed project aren't GC'd** (GC is `Dir.exist?` only): re-adding the
  project could ring a stale chime. Drop holds past an age ceiling in `held`.
- **Late chime after an unwatched follow-up turn.** Only an announcing scan releases a hold
  (a silent pane can't tell a late-seen hand-off from a finished follow-up), so a follow-up
  turn that ends while no sidebar is on screen leaves the hold to mature — and chime — when
  you return, on a workspace already bold. Fix with a completion identity on the hold (the
  hook report's epoch), so a pane can tell "the turn after the hand-off ended" from "the
  hand-off itself". The same identity closes the two rare double-chime races: a delayed
  off-screen writer re-creating a hold an on-screen pane already rang (Codex review), and
  the hold write vs release ordering at a follow-up turn's own race window.
- **A per-file unreadable session reads as absent.** `ClaudeSessions.records` drops a file
  it can't parse, so a sole garbled busy session lets a dispatch ping ring early, and a busy
  one beside an idle sibling can mature a hold early. Count unreadable files per worktree
  and treat them as "no evidence".
- **The tracked-cwd pre-filter drops a session after an EXTERNAL `git worktree move`** (no
  rename bridge): its recorded cwd matches nothing, so lsof never runs and its ⇅/◷ vanish
  (D10's accepted trade). Fall back to an lsof pass when a live session matches no root.
- **A held chime is lost beside a running background shell (verification review).** A turn
  starts a background agent AND a dev server; the agent's follow-up turn finishes inside one
  3s scan (no `:thinking` seen, no edge); the session then reads `shell`, so `activity` never
  says `:idle`, the hold can't mature, and your next prompt releases it silently. Candidate
  fix: mature when the path leaves the `busy` set with no fresh idle — but first probe what
  `status` reads between an agent finishing and its follow-up turn (an early ring there,
  then the follow-up's own Stop, would double-chime).
- **Off-screen panes write holds from cheap-scan evidence.** A crashed Claude's leftover
  `busy` file whose pid got recycled passes the kill(0)-only cheap scan, so a hidden pane
  holds a normal turn the on-screen pane already rang — a double chime each turn while the
  recycled process lives. Write holds only from full scans, or store `procStart` in the hold.
- **Smaller ship-review notes (pass 3).** The tracked-cwd pre-filter `realpath`s every
  session file's cwd (dead leftovers too) before `kill(0)` — a cwd on a hung mount could stall
  a scan; `doctor`'s canary checks file shape, not `status` values (a renamed `idle` would
  leave holds waiting on pid exit); `settled_offstage` trusts a negative hook age after a
  backward clock step; a tab in a worktree path breaks `OffstageHold`'s tab-split content;
  `quit` clears holds before `Tmux.kill_all`, so a sidebar can write one in between.
- **A dispatched first turn bolds at the hand-off.** `Creation.stamp_first_turn` →
  `advance` marks Attention at `turn_done` immediately; only the sound waits for the work.
  Defer the bold with the ring.
- **Tests worth adding:** pin `report_stop_state`'s `in: File::NULL` (a never-closing
  stdin pipe + timeout); `ClaudeSessions.fingerprint`'s alive bit (kill a busy session's
  pid, file unchanged); a hold maturing on the viewed workspace (sound yes, bold no); a
  sidebar-level `ClaudeSessions.scan` raise keeping dots and links (plan T3).
- **Simplification (advisory, ship review):** one stamp-gated record cache for both
  `RemoteLink.fingerprint` and `ClaudeSessions.fingerprint` (each changed file is parsed
  twice per warm check); `roots_for`/`tracked?` helpers in `ClaudeSessions`;
  `RemoteLink.linked_records` = `ClaudeSessions.records.select { linked? }`; a shared
  `KeyedMarkerStore.clear_all` for OffstageHold/Notify/Monitoring.

## Sidebar cursor bar follow-ups

- **Keep row colors under the cursor bar.** *Why:* the focused cursor row is reverse video
  (`\e[7m`), so every color on it is stripped: the agent dot, the attention/current-name
  colors, the `⇅` live/idle color, the diff `+/−` and the PR state. Only shapes survive, and
  the selected row is exactly the one you're reading. Re-coloring a cell inside the reverse
  run doesn't work: fg and bg swap, so the color paints that cell's *background* (the idle
  `⇅` showed an off-shade block, which is why v0.53.1 dropped it). *Start in:* `Sidebar#line`,
  `note_line` and `line_without_note` (`sidebar/render.rb`), the three `\e[7m` bar returns.
  Likely shape: draw the bar as an explicit background (`\e[48;…m`) with the normal `colored`
  row on top instead of reverse video, which keeps fg colors intact. The hard part is
  theme-relativity: a fixed bg has to read on light and dark themes (the #23 constraint behind
  the bright-black branch rows), so audition candidates in Will's terminal before choosing.
  Check the reset codes inside `colored` (`\e[0m` would also clear the bar's bg mid-row; they'd
  need to re-assert it or use targeted resets like `\e[39m`). **Priority:** P2.

## Agent session-name sync follow-ups

- **A Codex adapter for session-name sync.** *Why:* v1 syncs only Claude sessions, by typing
  `/rename` into the pane. Codex looks like it has a real API instead: codex-cli 0.164.0's
  app-server protocol includes `thread/name/set` and a `thread/name/updated` event (found in
  the binary's strings, not tested live), and Codex thread names live in
  `~/.codex/session_index.jsonl` as `thread_name`. That would need no typing at all. *Start
  in:* a spike answering one question: can switchboard reach the shared local app-server
  daemon (`codex agents` / `codex remote-control`) for the thread running in a given
  workspace, authenticate to it, and call `thread/name/set`? If yes, add a
  `SessionName::Codex` adapter beside the Claude one. **Priority:** P3.

- **Anchor the prompt box on the main prompt's footer.** *Why:* `SessionName::Box` accepts any
  single-line `❯` input between the last two divider lines. If one of Claude's local dialogs with a
  text field (config, feedback, agent creation) draws the same box while `status` stays idle, the
  worker could submit `/rename <name>` into it (no shell runs it, nothing is approved; unverified).
  Accepted at ship time (decision dec-2679bd5a, `gstack-shortcut` marker in `Box.parse`). *Start in:*
  capture those dialogs on a private tmux server (no model call), add them as fixtures that must
  parse `:unrecognized`, then require a footer line only the main prompt draws. **Priority:** P2.
- **Session-name sync: small items deferred at ship time (decision 4827ff6d).** None changes what
  gets typed or where; each was found by the /ship review and deferred by the owner. **Priority:** P2.
  - A session spent as `failed_send` that later carries the name (the user pressed Enter on our
    leftover) stays `failed_send`: drop any spent entry once the session carries the name.
  - Doctor's verdict is written on the pass that spends a session, and a crash after a newer
    worker's claim writes no verdict. Both are untested (worker tests read Outcome at the ceiling).
  - `RemoteLink.health`'s docstring doesn't describe the session-name canary keys, and `doctor`
    scans health twice (once per section). Compute it once and pass it to both.
  - Outcome kinds are symbols in the worker and strings in `Outcome::MESSAGES`: key both the same
    way, or test that every recordable verdict has a message.
  - `test/cli_test.rb`'s unknown-kind test carries the name-canary's value header; the
    zero-sessions check has a header nested in another test. `test/sandbox_test.rb` doesn't list
    `SWITCHBOARD_SESSION_NAME_DIR`.
  - One unreadable session file can read as "no session" (a false `:done` that clears the marker):
    tell an unparseable live file apart from a confirmed absence.
  - No subprocess (`lsof`, `ps`, `tmux`) has a timeout, so a hung one keeps the worker and its
    typing lock past the ceiling. Bound them.
  - The ceiling uses `CLOCK_MONOTONIC`, which pauses while a Mac sleeps: add a wall-clock cap.
  - A verdict can point at the wrong cause: a too-narrow pane or an unreadable `#{pane_synchronized}`
    ends as `ceiling`; a user's own `/rename …` draft reads as our leftover.
  - Design call: a session name the user chose by hand is overwritten by every workspace rename.
  - Run-3 review, none typing-safety: the session-file vocabulary (`INTERACTIVE`, `KINDS`,
    `STATUSES`, the bare `"bg"` in `RemoteLink.bg_kind?`) belongs in `ClaudeSessions` beside
    `OFFSTAGE_STATUSES`; `Sandbox.park_session` should default `kind` to `"bg"` (both callers
    override it, and the interactive default is the one a worker would type into); `Owner.claim` /
    `Owner.file` re-resolve an already-real path (key by it as given, like `Outcome.record_real`,
    and fix the comment and CLAUDE.md's superseded-outcome reason) — Codex round C showed the cost:
    a rename landing between `work`'s check and the claim lets the old worker overwrite the new
    one's claim through the bridge, both retire, and the newest name is never synced; the state matrix's untested
    verdict cells (`none`/`unrecognized`/`leftover`/`failed_send` × superseded or next pass).
  - Hardening, unconfirmed risks (run-3 review, below the report bar): `sessions_in` trusts the
    session file's pid without checking it runs Claude (`RemoteLink.claude_pids` could gate it); a
    vim NORMAL mode with no footer label would read as an empty box (capture a real one); idle
    overlays drawn above the box (the session survey) might take digit keys; whether a custom
    `rename` command can shadow the built-in `/rename`.
  - Run-3 adversarial, needs real captures before any fix: `foreground?` compares Claude's pgid
    to the tty's, so a child sharing Claude's group (the ^G external editor without an alternate
    screen, a nested interactive Claude) passes and an old frame can read `:empty` (check `ps -t`
    for a sole `+` foreground process); a box whose content is all dim (a paste chip?) reads empty;
    a whitespace-only draft reads empty and a user's trailing space reads as our exact line. Each
    can only leave text behind (no Enter matches), never submit it.
  - Run-3 adversarial, bookkeeping: the typing lock is per pid, but keys go to a tty (two sessions
    on one tty could interleave lines — both are then left); `:skip` (a tty missing from a stale
    pane snapshot, another tmux server) counts as done and clears doctor's marker; an `unconfirmed`
    Enter never re-reads the box, so leftover text reads `unconfirmed`; a SystemCallError inside
    `type_rename` discards the back-out's `failed_send`.
  - Run-3 adversarial round B: `Tmux.parse_panes_by_tty` merges rows that share a tty, so a
    `remain-on-exit` dead pane still listing a recycled pty mixes its flags with the live pane's
    (keys would go to the dead pane and be dropped): add `#{pane_dead}` and skip dead rows, or read
    two `%id`s on one tty as unknown. And a worker whose late gates keep flapping can type and back
    out every 2–30 s for an hour: cap clean back-outs per session.
  - Run-3 adversarial round C (not typing-safety): `sync_session_name?` (global, `!= false`) and
    `sync_session_name_for` (per project, `== true`) read a quoted "false"/"true" oppositely — give
    both one parse; `doctor_session_names` prints marker paths/names without stripping control
    bytes; nothing caps concurrent hour-long workers across workspaces. (The Owner race above was re-raised by
    Codex round D's structured review and deferred again, D2.)
  - Run-3 final rounds F/G (none typing-safety): the Enter gate checks `superseded?` right after
    the settle, before the pane/box/status re-reads (the typing gate checks it just before
    `still_claude?`; a rename landing in between submits the stale name); keys aren't re-checked
    against the session's kernel cwd, so a Claude whose cwd moved to another workspace mid-pass gets
    this workspace's name; `ClaudeSessions.own_session?` treats a submodule's `.git` file as a nested
    worktree, so a Claude started inside a submodule is never synced (and two empty scans clear the
    marker); `Claude.current` trusts `<pid>.json` without matching its own pid/procStart.
  - Captures to add as fixtures (verified live on Claude 2.1.311 during run 3, not yet pinned): the
    background-tasks dialog REPLACES the prompt box (`Box.parse` → `:unrecognized`; it has an
    `x to stop` key); typing while the footer task indicator is focused returns focus to the prompt;
    a foreground `!cmd` reads `busy`. Still uncaptured: other focusable footer items, and an open
    picker whose selected row is drawn dim.
- **Check whether a typed `/rename` fires `UserPromptSubmit`.** *Why:* switchboard's Claude hook maps
  `UserPromptSubmit` to `thinking`; a local slash command runs no model turn, so no `Stop` follows,
  and the workspace dot could stick on thinking until `PRESENCE_TTL`. Unverified (the smoke uses a
  stand-in). Deferred at ship time (decision dec-32768b9c, `gstack-shortcut` marker before the
  Enter in `type_rename`). *Start in:* a hooked workspace in the sandbox: rename it, watch the state file. If it
  fires, have the worker re-report the pre-type state once the rename is confirmed. **Priority:** P2.
- **Session-name focus gate (v0.60.1): items deferred at ship time.** None lets our keys land
  anywhere but our own empty prompt; each was found by the /ship reviews and deferred under the
  owner's rule that only a reachable typing-safety bug blocks. **Priority:** P2.
  - Accepted residual (decision 76a1b9be): inside the ~1.5 s of checks after our send, a script
    that creates a session linked to Claude's window, attaches, types and destroys that session
    leaves no trace tmux exposes (its `session_activity` dies with it), so Enter or the backspaces
    could follow that key. Same capability as the accepted `send-keys` race. Close it if tmux ever
    exposes a monotonic server-wide input stamp or its next session id.
  - Input from a `/remote-control` phone session never goes through tmux, so the input gates can't
    see it; it can't touch the local box or approve a modal without a model round trip.
  - No notice when a session waits as `:unrecognized` or behind a modal; doctor only reports it at
    the ceiling.
  - Held-phase cost: each held poll is one `list-panes` + `list-clients` + `list-sessions` read for
    up to an hour; and a held pass can hide another worker's leftover line.
  - `doctor` wording for a `tmux -CC` (control-mode) client, which makes its session read unknown
    and so holds the worker indefinitely.
  - `display-message` gets no `--` before the notice text, and `Tmux.display_time` is read on every
    notice instead of memoized.
  - A truncated `list-panes` row (a session name holding a tab) is skipped, not read as unknown.
  - A clean back-out caused by a stall (Claude stays busy for seconds) still costs a visible
    type-and-erase before the back-off; and the back-off counts passes, so near minute 5 it can
    last ~15 min.
  - Test quality: a few FakeClaude tests assert call counts rather than outcomes, and the smoke
    typing test paces keys with sleeps.
