# Explanation: agent presence (dots, sounds, bold)

The single most useful thing the sidebar shows is a small dot beside each
workspace telling you whether an agent there is **thinking**, **done**, or
**waiting** for you. This explains how switchboard knows that, why it uses two
different mechanisms to find out, and how the same signal fans out — to the dot,
the completion sound, the bold name, even the PR-badge and diff-count refresh.

For how to turn the exact signal on, see
[How-to: agent state & sounds](howto-agent-state-and-sounds.md). For the field
list, see [Reference: config](reference-config.md#sounds).

## The problem

You run several agents in parallel, one per worktree, and you can only watch one
window at a time. The question you keep asking is "which of these needs me right
now?" — which finished, which is blocked on a permission prompt, which is still
grinding. Without a signal you tab through every session to check. With a *wrong*
signal (a finished agent still shown as working) you ignore the one that actually
needs you.

So presence has to be both **correct** (don't say "working" when it's blocked)
and **available for every agent** (not just the one you configured). Those two
goals pull in opposite directions, which is why there are two signals.

## Two presence signals, merged

`AgentState.scan` (`agent_state.rb`) merges two independent answers to "is an
agent here, and what's it doing?" For each worktree, either signal counts as
presence:

### 1. Hook state — exact, opt-in

Claude Code *and Codex* can run a hook command on each lifecycle event.
Switchboard installs a tiny POSIX-sh reporter (`HookFile::SCRIPT`) that writes one
line — `<state>\t<cwd>\t<epoch>` — into the state dir. The sidebar reads those
files. The reporter is agent-neutral; what differs per agent is the event→state
map and the file it's wired into (see [hook delivery](#hook-delivery-splits-by-agent-claude-per-worktree-codex-global) below).

Claude's mapping (`ClaudeHook::EVENTS`) is the interesting part (Codex's, which has no
`Notification` event, is covered in the per-agent section below):

- `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure` → **thinking**.
  `PreToolUse` fires *before* a tool runs, and the permission prompt comes *after*
  it — so it can't be what clears the "waiting" state. `PostToolUse` and
  `PostToolUseFailure` fire *after* the granted tool finishes (whichever way it
  went), the earliest hook past the prompt — so the dot flips back to blue only
  once that tool is done.
- `PermissionRequest` → **waiting**. It fires the moment Claude asks for
  permission, so the dot turns magenta without waiting for Notification's
  delayed `permission_prompt` (about 6 seconds). The reporter prints nothing, and
  a hook with no output leaves the decision to you, so it only observes the
  prompt. The trade-off: no hook fires between your approval and the tool
  finishing, so after approving a long command (a build, a test run) the dot
  stays magenta until it ends. Auto mode doesn't fire it for calls it approves
  on its own.
- `Notification` → the special **notify** mode. The reporter pulls the
  `notification_type` value out of the payload (one `sed` over stdin) and
  compares it exactly, reporting **waiting** only for a prompt that needs an
  answer: `permission_prompt`, `elicitation_dialog`, `elicitation_url_dialog` or
  `agent_needs_input`. The idle timer and everything else fall through to
  **done**. Comparing the structured type rather than the human-readable message
  holds up across Claude releases, and only the type field counts: a workspace
  path or message that merely contains a type name can't trip it. An unrecognized
  notification defaults to the calm state, so it never false-alarms magenta.
- `Stop`, `SessionStart` → **done**.

A fresh hook file *is* presence — no process check needed. The hook only fires
from inside the worktree, so switchboard trusts it rather than second-guessing it
with a process scan (an agent's process cwd can differ from its project dir when
a wrapper launches it elsewhere; a scan would miss it).

The flip side of trusting a fresh file: a report counts only while fresh
(`PRESENCE_TTL`, 900s). After that it ages out, so a closed agent's last state
doesn't linger as a phantom live agent. The `.abs` on the age means a backward
clock step (a future epoch) still ages out rather than reading as eternally fresh.

### 2. Process/activity — coarse, zero-config

For agents that don't report hooks (Aider, Claude before `enable-hooks`, or Codex
before its global block is installed), `Agents.active` finds agent CLIs by scanning tmux panes by
command name plus a `pgrep`/`lsof` pass (the CLIs often run as `node`, so the
pane command alone misses them). Busy-vs-idle is then inferred by hashing
`tmux capture-pane` between scans: content changed since last scan → thinking,
else → done.

This works for any agent and installs nothing, but it's coarse: it **cannot tell
"waiting" from "done"** (a blocked agent and a finished agent both look like a
still pane), so the activity path never returns `:waiting`. That's the whole
reason hooks exist.

### Why fall through rather than pick one

`scan` tries the hook first; only if there's no fresh hook does it fall back to
the process scan (fetched lazily — skipped entirely when every worktree is
hooked). So a hooked agent (Claude *or* Codex) gets exact state, an un-hooked one
(say Aider) still gets a busy/idle dot, and the two never fight. The result is
`Hash<worktree, state>`; absent means idle (no dot).


The hook signal's one weak spot is a mass kill. Because a fresh file is trusted without
a liveness check, a `quit` that kills every agent would leave their last states behind,
and a lingering `:thinking` would read as a live, working agent for up to the TTL. So
both quit paths (`Sidebar#quit`, `CLI#quit`) call `AgentState.clear_all` to wipe the
state dir before tearing down. A restarted agent re-reports on `SessionStart`.

## Hook delivery splits by agent: Claude per-worktree, Codex global

The same intents — report-state, the SessionStart rename plant, the Stop backstop
— reach each agent through a **per-agent adapter** behind a registry (`AgentHooks`,
`agent_hooks.rb`): `ClaudeHook` (`claude_hook.rb`) for Claude and `CodexHook`
(`codex_hook.rb`) for Codex. Both agents read the same hook-config shape, so what they
share — the command strings (the reporter per event, the nudge, the unified Stop), the
materialized reporter script — lives once in the shared engine `HookFile`
(`hook_file.rb`, `command_entries`). The merge-safe enable/disable JSON machinery there is
Claude-only. What differs is **where each adapter delivers** — and the two agents land on
opposite sides of that:

- **Claude is per-worktree.** `ClaudeHook` merges into
  `<worktree>/.claude/settings.local.json` (it declares its `SETTINGS_REL` and `EVENTS`),
  on top of your own settings, and adds the file to the worktree's local git excludes
  (`info/exclude`) so it never dirties `git status`. Your global `~/.claude` is never
  touched. It's the only entry in `AgentHooks::ADAPTERS`, which is what `enable`/`disable`,
  `enable-hooks` and the dispatch worker (`Creator.work`) fan out over.

- **Codex is global.** Codex ([verified range](../CLAUDE.md#upstream-contracts-last-verified)) deliberately does **not**
  load a *linked* git worktree's own `<worktree>/.codex/hooks.json`: it redirects
  a linked worktree's project hooks to the main checkout's `.codex/` folder, and only when
  the worktree has a `.codex/` folder and is trusted (`config/src/loader/mod.rs` in Codex).
  Switchboard is nothing but linked worktrees, so the per-worktree file was dead on
  arrival; the v0.39.0 codex feature never fired in practice. A **config-level** hook
  isn't project-discovered, so it fires everywhere, including linked worktrees. So
  `CodexHook` delivers **one** marker-delimited `[hooks]` block in your global
  `~/.codex/config.toml` (`CODEX_HOME`-aware). It's written through the shared
  `MarkerBlock` (`marker_block.rb`), the same surgery that manages the tmux.conf line:
  atomic temp+rename, symlink-aware, a `.bak` on the first write, and the same
  `# >>> … >>>` markers. The block uses TOML **basic** strings (double quotes, with `\`
  and `"` escaped), since literal single-quoted strings would break on a path with an
  apostrophe.

  It covers every worktree at once, so there's nothing per-worktree to wire.
  `AgentState` only renders tracked worktrees, so the block firing for non-switchboard
  codex sessions is inert. Those sessions do leave stray state files that the
  "directory still exists" GC alone would keep forever, so an age-based GC
  (`AgentState::STALE_GC`) reaps them.

Because the codex block lives in your personal global config, switchboard writes
it **only with your consent** (`Installer`'s `step_codex_hooks`). `switchboard install`
prompts (default no on a non-tty, so a scripted install never silently touches it), or
`install --codex-hooks` / `--no-codex-hooks` decides up front. `--no-codex-hooks` leaves
even an already-installed block untouched, while a plain `install` re-ensures one.
`uninstall` removes the block; the per-worktree `disable-hooks` deliberately leaves it
(it's global). `AgentHooks.enabled?` and `enabled_adapters` fold in
`CodexHook.installed?`, so the global block counts as "on" for every worktree, and
`doctor` reports Claude per worktree, the global codex block, and the trust note.

Two more things follow from codex being global:

- **Trust.** Codex won't run any hook until it's been approved — run `/hooks` in
  codex once and trust the switchboard hooks (or start codex with
  `--dangerously-bypass-hook-trust`). Codex records each approval, keyed by the
  command's *hash*, as a `[hooks.state."…"]` table right after switchboard's
  `[hooks]`, which puts it inside the block. Re-running `install` carries those
  tables over, so approval survives as long as the commands stay byte-stable
  (they do: deterministic paths, fixed event order). A hook whose command did
  change (say, a different install's path) keeps its old approval, which codex
  re-asks for in `/hooks`; the count below checks that an approval exists, not that
  it still matches. A present block isn't proof
  the dot moves, so `switchboard doctor` counts the approvals (`N/M trusted`) and
  warns when any hook is still unapproved. It first checks that the block on disk is
  what `install` would write: an outdated block (an older release, or one written by
  another checkout) or one `install` can't safely rewrite gets "re-run `switchboard
  install`" instead, since approving it in `/hooks` would approve the wrong commands.
- **Codex keeps its own settings in the block too.** Codex appends each new
  table it writes (`[desktop]`, `[plugins."…"]`, …) after the file's last table
  and before its trailing comments. Switchboard's block sits at the end of the
  file and ends in a comment, so those tables land inside its markers. `install`
  moves them, unchanged and in order, to just above the block, and `uninstall`
  keeps them the same way (moved to just above where the block was). With no parser available, switchboard refuses (and leaves
  the file untouched) whenever moving lines could change what a setting means: a
  multi-line string, a `[[…]]` table, or keys at the very start of the block
  (before its first table) or right after its end marker. If Codex writes the file mid-install, install stops and asks you to
  re-run it rather than overwrite that change.

Both are covered in full in [inside the global codex block](#inside-the-global-codex-block).

### Nesting (#130)

A global hook fires for *every* codex, including a nested `codex exec` launched by a
`/codex` running under Claude Code. So a `GUARD` prefixes every command:

```sh
[ -n "$CLAUDECODE" ] || [ -n "$CLAUDE_CODE_SESSION_ID" ] && exit 0
```

In sh, `||` and `&&` have equal precedence and group left to right, so this exits when
either marker is set. It suppresses the reporter when a Claude Code parent is detected,
so a subagent's codex doesn't report presence up to switchboard. A top-level codex that
switchboard launches into a plain tmux shell carries neither marker, so it fires.

Since Codex 0.149 (#39314), a hook sees the environment as it was when the session
started, not the live one. Codex strips a few credential variables from that snapshot,
but not the two Claude markers, so the guard still works (verified live: both are set in
Claude 2.1.301's hook env). `codex_hook_test`'s runtime guard test pins the sh precedence
offline.

This hook contract is re-checked live when Claude Code or codex-cli changes (the [security monitor](howto-security-monitor.md) watches for that):
the payload fields, delivery in linked worktrees, the nesting-guard environment, and
a silent `PermissionRequest` hook leaving the prompt to you. The versions it last
passed on are tracked in one place,
[CLAUDE.md's upstream contracts](../CLAUDE.md#upstream-contracts-last-verified). The
opt-in `test/smoke/codex_hook_smoke_test.rb` (`SWITCHBOARD_CODEX_SMOKE=1`) checks it
against real Codex: the global block fires in a *linked* worktree (the crux of the
whole design), `PreToolUse` comes before `PostToolUse`, and the nesting guard points
the right way.

### Waiting, and what each agent can report

Both agents report `waiting` on `PermissionRequest`, the moment the prompt opens; the
reporter prints nothing, and a silent hook leaves the answer to you. Claude also keeps
`Notification` (`notify` mode) for elicitation, `agent_needs_input` and idle. Its
accepted cost is a dot that stays magenta until an approved tool finishes (or, after an
Esc rejection, until the next prompt).

Codex has no `Notification` event, so `PermissionRequest` is its only `waiting` signal.
The magenta dot shows whenever Codex blocks on you for approval, which is best-effort: a
session command that bypasses *all* approvals suppresses it.

### Subagents don't move the main dot

A subagent's tool calls fire the parent worktree's Claude hooks too, with an `agent_id`
in the payload. So do Claude's internal agents (probed live, 2.1.310). They used to turn
the main dot into a spinner claiming the *main* agent was working, and it stuck after the
subagent ended.

So the reporter (`sb-agent-hook v6`) drops a `thinking` whose payload carries an
`agent_id`. That means `thinking` reads stdin, guarded by `[ ! -t 0 ]` so a manual run
can't block. The key is value-extracted the same way as `notification_type`, so an
`"agent_id"` that appears inside a string value is escaped and never matches. Two
exceptions:

- **A subagent's `PermissionRequest` still reports `waiting`,** since it wants you.
- **Its next `PostToolUse` or `PostToolUseFailure` writes `done` when the file reads
  `waiting`,** so an approved subagent prompt can't leave the dot stuck magenta. That
  `done` is a hand-off, so it shows as ◷ (below).

`report_stop_state` passes `in: File::NULL` for the same reason the reporter checks
stdin.

### The reporter script

The reporter script itself is shared by both adapters (the state-file format is
agent-neutral) and lives in the XDG **data** dir
(`~/.local/share/switchboard/sb-agent-hook`) — an install-independent path that
survives a `git pull` or `brew upgrade`, unlike the checkout. It's rewritten
whenever it's missing or stale (versioned in the script header), so an upgrade
self-heals.

New worktrees switchboard creates get the Claude hook automatically: the dispatch
worker runs `Creator.work` → `enable_hooks` → `AgentHooks.enable`, gated on
`agent_state_hooks?`, *or* `auto_rename_for(project)`, *or* `background_presence`. So a
project that opts into `auto_rename` while the global setting is off still gets the hook
the rename nudge needs. Existing worktrees get it via `switchboard enable-hooks`. Codex
needs no per-worktree step — its global block already covers them.

## Inside the global codex block

### Trust survives a re-install

Codex records each approval in `config.toml` itself, as
`[hooks.state."<file>:<event>:…"]` tables holding the command's `trusted_hash`, appended
right after our `[hooks]` table, which puts them inside our markers. `install_global`
carries those tables into the rewritten block. So trust survives a re-install (which runs
after every upgrade) as long as the commands stay byte-stable: deterministic paths and a
fixed event order. That's why `command_entries` is centralized.

A command that *did* change (another checkout's bin path) keeps its old approval. Codex
re-asks for it in `/hooks`; it's valid again once the command changes back, and an
`enabled = false` stays put. So doctor's count credits that an approval *exists*, not that
its hash matches (dec-455f3bf8).

`remove_global` drops *our* approvals along with the block. Approvals for other hook files
stay (see [uninstall](#uninstall-keeps-what-isnt-ours)).

### What doctor counts

A present block isn't proof the dot moves. `doctor` counts approvals
(`CodexHook.trust_status` → `N/M trusted`), matching keys to our file by realpath and not
counting `enabled = false`, and warns below M. The exception is when *every*
codex-launching `session_command` (global and per-project) passes
`--dangerously-bypass-hook-trust`, where 0/M is expected. One bypassing project can't hide
the warning for the others.

The count only means something for a block `install` would leave as it is. So `doctor`
first checks `CodexHook.block_state`, which is read-only and runs install's own
`planned_install`, so the two can't disagree:

- **`:stale`** (an older release, or another checkout's bin path) and **`:unsafe`**
  (install would refuse) get "re-run `switchboard install`" instead. Approving such a
  block in `/hooks` would bless the wrong commands, since the counts are by position, not
  by command.
- **`:collision`,** your own `[hooks]` outside the block, gets "merge yours into one
  place." An `:unsafe` block outranks it, matching install's own check order.

The real-Codex smoke can't see any of this, since it passes
`--dangerously-bypass-hook-trust`. So its second case runs *without* the bypass and
asserts that an untrusted block writes no state.

### Codex's own tables, moved out of the way

Codex edits `config.toml` with toml_edit, which renders every *new* top-level table after
the document's last table but *before* its trailing comments. Our block sits at the end of
the file with a comment for an end marker, so `[desktop]`, `[marketplaces.*]` and
`[plugins."…"]` land inside our markers. v0.50.1 and earlier silently dropped them on
install and deleted them on uninstall.

Now `install_global` and `remove_global` split the region (`movable_parts`) into three
kinds of lines:

- **ours:** the note and any `hooks` table, regenerated;
- **trust:** the approval tables, carried over;
- **foreign:** everything else, moved verbatim and in order to just *above* the block,
  which stays last where `MarkerBlock.build` appends it.

With no foreign tables, the output is byte-identical to before, so trust hashes stay valid.

### What a line-based move refuses

There's no TOML parser (zero gems), so the move is line-based, and it refuses (`:unsafe`,
file untouched) whenever moving lines could change meaning or drop data:

- a multi-line string;
- a `[[…]]` array of tables;
- key lines before the region's first table or right after the end marker. A comment
  doesn't end a table, so those keys belong to a neighboring table;
- anything in *our* `[hooks]` chunk besides one-line `<Event> = [...]` arrays, since a key
  codex or you added there would be regenerated away;
- a `[hooks.<x>]` table;
- a second marker region;
- stray marker lines, which are counted and refused outright;
- a begin marker without its end line. That's checked before the collision guard, which
  would otherwise misread our own `[hooks]` as foreign.

How the splitter reads the file:

- **Only a real header opens a table.** That's a whole TOML header line (`HEADER`) at
  bracket depth 0 (`scan_lines`, ignoring strings and comments). So a multi-line array's
  `[1, 2]` or `["hooks"]` elements never split a chunk or read as a hooks table.
- **The collision guard fails closed both ways.** An unindented `[hooks…]` line collides
  even inside an open bracket, and brackets left open at the end of the file count as a
  collision. `hooks` is matched bare, double-quoted or single-quoted (`HOOKS_KEY`).
- **A line-conservation check backs up the splitter.** It discounts one copy per generated
  line, so a pasted note line outside the block still counts as kept.
- **It always reads UTF-8.** The file is read with any leading BOM dropped (`read_config`).
  Under `LC_ALL=C`, a default read is US-ASCII and every check on it misfires, and a BOM
  defeats the `\A\s*` anchors, so a `[hooks]` on your line 1 would slip past the collision
  guard.

For a block missing its end line, the `:unsafe` advice says to put the end marker back.
It never says to delete our `# >>>` line, which would orphan our `[hooks]`.

### Uninstall keeps what isn't ours

Codex files approvals for *other* hook files (a project `.codex/hooks.json`, plugins) under
the same `[hooks.state]`. So uninstall keeps those, moved out with the foreign tables, and
drops only ours. A `[hooks.state…]` table outside the block is codex's, not a competing
hooks config (though `[[hooks.state]]` still collides).

Dropping one of our approvals keeps the comments that trail it outside the block, since
they head the next table. Comments *inside* the managed block are regenerated away
(dec-3417a712).

`MarkerBlock` accepts trailing text on a marker line (older releases wrote
`# >>> … >>> (managed by …)`), and `remove_global` returns whether it changed anything, so
uninstall never reports a removal that didn't happen.

### Codex can write the file at any moment

The Codex desktop app, for one, writes `config.toml` whenever it likes. So both verbs
re-read the file before writing, and return `:conflict` rather than ever restoring a
snapshot over a newer write. That replaced the old `:corrupt` torn-write rollback:
temp+rename can't tear, so a read-back mismatch means someone else wrote. It isn't a lock,
though: a write in the last instant before our rename can't be seen.

### Failures are loud, and never "delete the block"

`Installer` reports `:unsafe` and `:conflict` as failures, and never advises deleting the
block by hand, since that would take codex's tables with it. The block's own note says so
too. A refusal fails the command with exit 1: `install` after its other steps, `uninstall`
before any, and `enable-hooks`.

`uninstall` runs the codex step *first* and stops on a refusal, so its "re-run uninstall"
advice can't point at a command it has already unlinked. A write that fails instead (a
read-only config, or one that becomes unreadable mid-run) is `:failed`: the rest of
uninstall still runs, it ends with "Done, except the codex hooks", and exits 1.

## One edge, four consumers

When a worktree's hook state newly enters a resting state (`:done`/`:waiting`),
that's a *completion edge*. Four features ride the exact same edge
(`Sidebar::Edges.completion_edges`), in one place (`Sidebar::Edges#on_scan`,
`sidebar/edges.rb` — #57 extracted the whole fanout into that collaborator;
the diff refresh rides the edge list `on_scan` returns to `refresh_agents`):

1. **Bold-until-viewed** (`attention.rb`) marks the workspace name bold — on
   every scan, since which process noticed doesn't matter (see below).
2. **PR refresh** re-fetches the badge — an agent finishing a turn is the best
   moment to catch a push.
3. **Diff-count refresh** repaints the row's `+adds −dels` — a finished turn
   likely just committed.
4. **Completion sound + sparkle** (`sound.rb`) play last, fully rescued so a
   sound fault can never starve the refreshes above, and gated so only the
   sidebar you're watching rings (a catch-up scan re-baselines silently).

The state cursor (`@prev_hook_states`, owned by `Edges`) advances in an `ensure`, so a fault in any
consumer can't corrupt the next edge diff. The PR fan-out is the one unrescued consumer; a
raise from it reaches the broad `refresh_agents` rescue, which blanks the dots for that
scan. The mark and the sound are fully rescued, so their faults never get that far.

The completion-edge consumers ride the *hook* signal only, not the coarse activity fallback — because
the capture-hash flips `:thinking ⇄ :done` every few seconds and would fire on
noise. So observation-only agents show a dot but make no sound and trigger no
badge refresh on completion.

### Completion sounds

`Sound` (`sound.rb`) plays a short sound on each completion edge. In `on_scan`, the PR
refresh runs *first*, then `play_sounds_for`, fully rescued.

**Which completions ring:**

- **One per worktree per scan.** Sounds are deduped per `[worktree, state]`, so every
  distinct worktree's completion is heard, but one worktree can't double-fire in a scan.
- **Every open permission prompt.** Since v0.51.1, a Claude permission prompt enters
  `waiting` the instant it opens (`PermissionRequest`, not the ~6-second
  `permission_prompt` Notification). So `waiting` rings once per prompt still open at the
  next scan, including in the workspace you're viewing, like every other sound. That's
  deliberate: an open prompt is exactly what the chime is for, and muting the viewed
  workspace would be a separate sound rule.
- **Only from the sidebar you're watching.** A catch-up scan re-baselines silently. How
  that works, and the recycled-pane-id bug that once made sounds ring twice, is in
  [the sidebar's lifecycle](explanation-sidebar-lifecycle.md#catch-up-scans-must-not-re-ring).

**The sounds themselves.** The two defaults are *synthesized* (16-bit PCM WAV via
`Array#pack`) and written into the XDG data dir on first use, atomically, so racing sidebar
processes never read a half-written file. It's the same self-healing trick as
`HookFile.ensure_script`, with no binary assets shipped. Bump `Sound::ASSET_VERSION` to
regenerate the cached WAVs.

`Config#sound_for` resolves each state (a global default plus per-project overrides, like
`session_command_for`) to one of:

- a built-in name (`train`, `chime`, or the variants `train_1..3` / `chime_1..3`);
- a file path;
- a bare macOS system-sound name.

The only way to mute is `enabled: false`.

### Bold until viewed

`Attention` (`attention.rb`) bolds a workspace's name from the moment its hooked agent
finishes a turn (`:done`) or asks for input (`:waiting`) until you actually look at it,
so a completion you weren't watching can't slip past unnoticed. It rides the same
`completion_edges` as the sound and the PR refresh, with two deliberate differences from
the sound.

**It lives on disk.** A completion **sound** is a one-time event — play it once, from
wherever you're watching, done. It lives only in memory. The **bold** is persistent state:
a workspace stays bold until you look at it. Because every window's sidebar is its own
process (see [sidebar lifecycle](explanation-sidebar-lifecycle.md)), that state *must* be
shared on disk, one marker file per worktree in a `switchboard/attention` sibling of the
agent-state dir, or only the one sidebar that saw the completion would render it bold.

**It isn't gated by `announce_sounds`.** Which process writes the marker doesn't matter
(an idempotent create or delete, GC'd like the hook files). So catch-up scans (`announce_sounds: false`) re-baseline
the sound state silently but *still* write the bold marker: the sound was already heard
once, while the bold is about whether *you've looked*, which doesn't depend on which
process noticed.

**Looking clears it.** The workspace you're currently in is never marked (`viewing?`
skips it on the edge), and `locate` clears the marker the instant you switch in. Viewing
is enough; no input is needed. To keep that clearing correct, `reload` runs `locate`
*before* `refresh_agents`.

**The storage is shared.** The atomic write, the crc32 filename key, the XDG `state_dir`
and the scan-with-GC aren't Attention's own: they're the shared `KeyedMarkerStore`
(`keyed_marker_store.rb`, issue #95), which `Attention`, `Collapse` and the other marker
stores delegate to. Each caller supplies only its own piece as a
`scan(dir) { |content| keep? }` block, where a falsy return GCs that marker:

- Attention: a canonicalized-realpath value and a `Dir.exist?` GC check;
- Collapse: a project name and a "still configured" check.

`dir` is total, so a failure resolving a state path degrades instead of crashing.
`FullHeader` and `Width` deliberately stay off this base: a single flag and a single
integer would only share "an XDG dir."

## The self-naming nudge (issue #92)

A new workspace starts with a placeholder name (see
[deferred naming](explanation-background-dispatch.md#deferred-naming)), so the agent is
asked to name it once it understands the work. `HookFile.enable` wires that nudge into the
same agent-state hooks. The commands re-invoke the binary, so they carry `NUDGE_MARK` and
`HookFile.ours?` recognizes them for an idempotent merge and a clean disable. The baked bin
path is guarded with `command -v`, so a stale path after a repo move degrades cleanly
instead of erroring with "command not found."

### The soft plant, on `SessionStart`

A `SessionStart` command (`rename-nudge`) rides *beside* the sh state reporter
(`… && … rename-nudge || true`). When `auto_rename` is on (`Config#auto_rename?` /
`auto_rename_for`, global plus per-project; on by default since #114 made placeholders the
only way to create), `CLI#rename_nudge` injects a `SessionStart` `additionalContext`
instruction telling the agent to `switchboard rename` the workspace once it understands the
work. Since #94, that renames both the folder and its branch.

`RenameNudge.decide` is the pure gate. It fires when the setting is on, the name is still a
placeholder, and `source` is one of `startup`, `resume`, `fork`, `clear` or `compact`.
`clear` is included because `/clear` wipes the earlier instruction from context, just like
compaction.

### The backstop, on `Stop`

A `SessionStart` plant fires *before* the agent knows anything, and then never again. So
the moment of most understanding (the work is done and you're about to walk away) had no
reminder, which is exactly how a real session here shipped a fix and left its workspace on
the placeholder name. The `Stop` hook catches that moment.

**One command owns `Stop`.** Stop hooks run in parallel with no ordering, so a plain sh
`done` reporter racing the nudge's block could record a blocked, still-working agent as
`done`, and ring a false completion (chime and bold). So `Stop` is kept *off* the `EVENTS`
reporter list on purpose, and a single command handles both:

```sh
if command -v switchboard; then switchboard rename-nudge --stop; else <sh-reporter> done; fi
```

`CLI#rename_nudge_stop` reports the state *itself*: `thinking` when it blocks (accurate,
since the agent is about to keep going) and `done` otherwise (the normal completion). It
goes through the same sh reporter (`report_stop_state` → `HookFile.script_path`), and the
child inherits the hook's cwd, so its cksum key matches the file the other events write.

- **State is reported for every hooked worktree,** even ones that aren't placeholders or
  have `auto_rename` off, since the dot depends on it. Only the block is gated.
- **The `else` branch keeps `done` flowing if the binary is stale.** The script path
  doesn't need PATH.
- **It's `if/then/else`, not `&& ||`,** so a non-zero exit from the Ruby side can't *also*
  fire the fallback and write twice.

**It nudges once, never nags.** The block payload is `RenameNudge.stop_json`
(`decision: block` and an imperative reason). `RenameNudge.decide_stop` gates it on an
explicit `stop_hook_active == false`, which is Claude's own loop guard. So it blocks once
per stop chain: the agent renames (and it never fires again), or, if it genuinely can't
yet, the second stop passes through. The `== false` fails closed: a missing or garbled flag
does *not* block, because a block on an absent flag would never see a `true` to release
it, and could trap the agent unable to stop.

### Both clear themselves

Both stop the moment the workspace is renamed, because "still unnamed" is derived, not
stored: the signal is `Placeholder.generated?(leaf)` (the name is a generated
adjective-noun), with no marker file.

The subcommand finds the worktree from the hook's stdin `cwd` (via `current_worktree`), and
**always exits 0, printing only the JSON or nothing**. A stray byte on stdout poisons
Claude even at exit 0, so the whole body is rescued to silence.

## Background monitors: the `∞`

A workspace where an agent runs a background monitor, a recurring loop or a scheduled tick
(a `/loop`, a self-paced wakeup, the Monitor tool, a background bash) used to look exactly
like a finished, idle one: a resting `●`.

The dot couldn't tell them apart because *hooks can't*. A background loop fires the same
`SessionStart` and `Stop` events as an interactive turn, and there's no `source: routine` or
`is_autonomous` signal. Cloud routines never touch the local reporter at all.

### Declared, not detected

So monitoring is *declared*. `switchboard monitoring on|off` (run by the agent or by you;
`Monitoring`, `monitoring.rb`) writes a per-worktree marker on the shared
`KeyedMarkerStore`, keyed by realpath with a `Dir.exist?` GC like `Attention`. The sidebar
draws a **steady green `∞`** for that workspace at rest.

The `∞` is a render overlay, not a fourth `@agents` value. A single `render_state` resolver,
used by *both* paint paths so the precedence can't drift, ranks
`thinking`/`waiting` > monitoring > `done`/idle. You still see live work and input requests;
only the *resting* dot becomes `∞`, so idle between ticks reads as *watching*, not
*finished*. It's steady on purpose: an animated `∞` would keep `pulsing?` true for every
monitored pane and defeat the off-screen dormancy budget.

### "The dot is up" must mean "monitoring is happening right now"

The trap: a marker only proves an agent *declared* monitoring, and a liveness check can only
prove an agent is *alive*. Neither proves it's *still* monitoring.

So liveness is the marker's mtime plus re-affirmation every cycle, not a hook heartbeat.
`monitoring on` rewrites the marker (a fresh mtime), the agent re-runs it each cycle, and
`Monitoring.monitored` shows a worktree only while `now - mtime <= TTL` (`Monitoring::TTL`,
about 10 minutes), GC'ing the stale file. Re-affirmation is the precise "still monitoring"
signal a generic heartbeat can't give: an agent that stopped, crashed, or was resumed into
other work stops re-affirming, so its dot ages out on its own. A heartbeat would keep it
falsely lit from unrelated activity. Three thought-experiment tests pin this: resume, the
user stops, and the agent stops.

### Routine ticks are quiet

A background loop must not chime and bold on every tick. So the routine `:done` per tick is
suppressed from both the completion sound and the bold (`suppress_completion?`, the one
check both `play_sounds_for` and `mark_attention_for` consult). `:waiting` still surfaces,
since it wants input, and the PR and diff refreshes still ride every edge.

`@monitoring` is hydrated in `refresh_agents`, before `Edges#on_scan`, so the suppression
is live on the scan that fires the edge. The monitoring dir is part of `warm_fingerprint`,
so a toggle warms off-screen panes.

### The declared alert — `monitoring notify`

Some cycles matter: the monitor wakes, finds the thing it's watching for, and prints a
result. Switchboard can't tell that tick from a "nothing new" one, since both are
byte-identical `Stop` (`:done`) events, the same wall the `∞` is built on. So the
significant tick is **declared, not detected**: the agent runs
`switchboard monitoring notify` (taught by the nudge, to run *after* a cycle's output
exists), which fires the normal bold, sound and sparkle with a **distinct `alert` sound**,
even though routine ticks stay silent.

It's an **independent alert channel**, not a hook edge, so it can fire mid-`:thinking`, with
no `Stop`:

- **The ring is read from an mtime.** `Notify` (`notify.rb`) is a `KeyedMarkerStore` like
  `Attention` (its content is the realpath), read by file **mtime**. `monitoring notify`
  re-touches the marker, and each sidebar's `Edges#@prev_notify` cursor rings once per mtime
  advance. That's the same "compare against your own cursor" trick the completion sound
  uses, so only the on-screen pane rings and catch-up scans re-baseline silently, with no
  delete race and no TTL.
- **The bold is written by the CLI.** It goes straight into `Attention`, not through the
  edge, so it persists even when no sidebar is on screen; you see it the moment you return.
  So the edge's `mark_attention_for` only ever sees the un-suppressed completions, and the
  forced alert drives only the announce-gated sound and sparkle.
- **`:alert` stays local.** It's the sound state and the `alert` built-in, distinct from
  `done` and `waiting`. It's not `:notify`, which the Notification hook owns. It lives in a
  throwaway `states` map and is never merged into `now`, `@prev_hook_states`, the returned
  `edges` (so the diff refresh still rides real `:done`s) or `render_state`.
- **It needs no fingerprint entry.** `Notify.pending`'s only shared render effect is the
  Attention bold, which the fingerprint already covers.

The verb is gated to a monitored workspace, since it's precisely the exception to
monitoring's suppression. `Notify.clear_all` runs on `quit` beside `Monitoring.clear_all`.
Cloud routines that never touch the local reporter can't declare a notify; that's a stated
limit, like the `∞` itself.

### How a stale `∞` clears

From fastest to slowest:

1. **Explicit `off`, and `quit`.** Both are instant. `quit` calls `Monitoring.clear_all`
   beside `AgentState.clear_all`, since a teardown kills every agent.
2. **Session boundaries.** Two hook commands (`MonitoringNudge` and `CLI#monitoring_nudge`,
   wired into the Claude hook by `HookFile.command_entries` as matcher-less `SessionStart` and
   `SessionEnd` commands, marked `MONITOR_MARK` so `ours?` can dedupe and strip them):
   - **clear on `SessionStart`** makes monitoring a per-session declaration. A resumed agent,
     whose old loop is dead, has to declare again.
   - **auto-off on `SessionEnd`:** the agent is gone, so it can't still be monitoring.
3. **A deleted worktree,** reaped by the `Dir` GC.
4. **The mtime TTL,** the floor for a crash with no clean exit.

**The clear and the nudge use different session sources.** The clear fires on `startup`,
`resume` and `fork` only. A fork is a new process (Claude 2.1.214+ and Codex 0.155+ report it
as `fork`; they used to say resume or startup). It never fires on `compact`, where the same
process continues and a live monitor's marker must survive, or on `clear`, whose `SessionEnd`
already dropped the marker; there, the re-planted nudge is what gets a still-running monitor
declared again. The nudge re-plants on `startup`, `resume`, `fork`, `clear` and `compact`,
matching `RenameNudge`, because compaction and `/clear` both push the original instruction
out of context, and `SessionStart` fires again on them precisely so a hook can re-inject it.
So an agent that starts a monitor *after* either still knows to run `monitoring on`
(`MonitoringNudge.clears_on?` vs. `nudges_on?`).

**Renames carry the marker.** `Rename.perform` carries it via the shared
`KeyedMarkerStore.carry`, capturing the old realpath *before* `move_worktree`, since the
bridge symlink resolves it to the new folder afterwards. That also fixed an older bug where
a rename silently dropped `Attention`'s bold.

The session-boundary behavior (nudge and clears) is gated on the `background_presence`
setting (global plus per-project, on by default, like `auto_rename`). The worker's
hook-enable gate includes it, so a project that uses only monitoring still gets the hook.
Cloud routines remain invisible, since they never reach the local reporter; that's a hard
limit, stated rather than worked around.

## Waiting on background work: the `◷`

When Claude hands work to a background agent, a background shell or the Monitor tool and
ends its turn, the `Stop` hook writes `done`, which shows a green `●` and plays a chime,
for work that's still running.

No hook event means "turn over, background task outstanding." (The `Stop` payload does
carry a `background_tasks` key, seen on 2.1.310, but its values haven't been probed.) But
Claude's own per-session file, `~/.claude/sessions/<pid>.json` (the one the `⇅` reads),
does say it. After such a turn its `status` *stays* `busy` (a background agent; Claude
never rewrites it at the Stop, so `statusUpdatedAt` is the turn's start) or reads `shell`
(a background shell or Monitor) instead of going `idle`. This was probed live on 2.1.310.
The sessions-file `status` contract is tracked apart from the hook contract and the `⇅`
link ([last verified](../CLAUDE.md#upstream-contracts-last-verified)), and the
[security monitor](howto-security-monitor.md) watches it.

`ClaudeSessions` (`claude_sessions.rb`) reads that one file set for both cues.
`ClaudeSessions.activity` turns one worktree's live sessions into one of:

- **`:offstage`:** any session reads `busy` or `shell`;
- **`:idle`:** every session has read `idle` for at least `SETTLE`;
- **nil, no evidence:** a missing or unknown status, `waiting`, or an `idle` that's too
  fresh.

The file is undocumented, so only those exact strings count; any other value is no
evidence, and the row shows the normal dot.

### What the row shows

`render_state` draws `:offstage` as a steady blue `◷` (`OFFSTAGE`, exactly
`SPIN_COLORED`'s `\e[1;34m`; the spinner's blue says work is happening, and a still clock
says it isn't the main agent), off the pulse cadence. It draws it only over a resting,
hooked `done`:

- **Never over `thinking` or `waiting`.**
- **Never on a row without hooks.** A session reads `busy` through every ordinary
  foreground turn too, so without the hook's `done` there's no way to tell a hand-off from
  plain work.
- **`∞` outranks it.** A declared monitor is the more specific cue, and a monitor always
  reads `shell` anyway.

The internal name is `offstage`, not "background", because `Link#bg?` already means a
session that *is* a background job. The legend says `◷ waiting on background work`.

### The settle window

Two timing facts, probed live on Claude Code 2.1.310, shape it:

- Claude writes `done` 13–29 ms *before* `idle` on an ordinary turn end.
- A finished background agent reads `idle` for about 15 ms before its follow-up turn reads
  `busy`.

A 3-second scan lands in those windows about 1% of the time. So both edges wait out
`ClaudeSessions::SETTLE` (2 seconds):

- **`◷` draws only once the hook's report is that old** (`AgentState#last_hook_ages`). Past
  `PRESENCE_TTL` the report has no age, since a background job writes no main-agent hook,
  so `Edges#last_state`'s sticky `:done` stands in.
- **A hold matures only on an `idle` that old** (below).

Nothing on disk changes when a `done` settles, so a hidden pane learns about it from a
per-file "settled" bit in the warm fingerprint's hook term (`hook_fingerprint`).
`ClaudeSessions.fingerprint` also moves when a *tracked* session crosses between offstage
and not, never for a Claude outside switchboard.

### Holding the chime

When the work is a background **agent** (the session reads `busy`), the chime and bold of
that hand-off are *held* instead of dropped. A `:done` edge whose path reads `busy`, still
unsettled (the edge scan usually lands inside the window), is a hand-off to a background
agent (`ClaudeSessions::HANDOFF_STATUS`; `@offstage_raw` holds only these).

A background **shell** (`shell`) shows the `◷` but rings as usual. It may be a dev server
that never ends, and holding its chime would mute the very turn you were waiting on. Every
heuristic review tried for telling a long-lived shell from a short job leaked (per-process
memory, respawns, chained turns). An agent, on the other hand, always reports back with a
follow-up turn, so its hold always resolves.

**The hold lives on disk.** `Edges#on_scan` writes an `OffstageHold` marker
(`offstage_hold.rb`, a `KeyedMarkerStore` keyed by realpath, holding
`realpath\tepoch\tpid`) instead of ringing or bolding, on *every* scan, warm and catch-up
included. It's on disk because the pane on screen when the work finishes may never have
seen the hand-off: it was hidden, and its baseline already read `done`. An outside review
found that a per-process hold lost it. A hold that fails to be written rings at once
instead, since early beats never.

**`Edges#settle_holds` resolves each hold on every scan, one of two ways:**

- **The follow-up turn starts** (the hook leaves `done`). That's the usual end, since Claude
  runs a normal `UserPromptSubmit` → `Stop` turn when the result arrives. The hold is
  released silently and that turn's own `Stop` rings as usual. But only an announcing scan
  releases it: an off-screen pane can catch a short follow-up turn that the on-screen pane's
  3-second scans miss, and left held, it matures for the on-screen pane instead (late, if no
  pane was on screen through the follow-up).
- **The session settles idle, or its process is gone.** A settled `idle`, or the recorded
  pid gone (`kill(0)`), matures the hold. *Anything else* (a failed read, an unknown status,
  an out-of-range pid) keeps holding, because missing evidence isn't "finished."

**Exactly one pane rings it.** Only an announcing, on-screen scan claims a mature hold, by
unlinking it, and only one unlink can succeed. Only the claimer rings *and* bolds; an
off-screen pane bolding could re-bold a workspace you'd just viewed, in the moment before
the on-screen pane claimed it.

A few more rules keep it from ringing twice or never:

- **A normal ring releases the hold.** A normal `:done` that an announcing scan rings also
  releases that path's hold (`release_rung_holds`). Otherwise a hold another pane wrote
  inside the done-before-idle race would ring that end a second time.
- **Never released by a silent pane.** A pane that sees the hand-off edge late, after the work
  ended, reads it as a plain completion and would take the only ring with it (found by an
  adversarial review).
- **Nothing is released on a failed session read** (`sessions_ok:`).
- **Monitored and first-turn paths never hold,** since they're already suppressed.

Holds are carried on rename and wiped on quit (both quit paths).

### The dispatch ping waits too

A dispatched task that fans out on its first turn would otherwise ping "done" at the
hand-off. So `ring_creations` defers a `turn_done` record's ring (`dispatch_waiting?`), but
only on *positive* evidence that a background agent is still at work: `busy`, or an `idle`
too fresh to trust (`@session_fresh`, the ~15 ms before the follow-up turn). Not `shell`,
for the dev-server reason above.

Missing evidence (no session, a failed read, a drifted `status`) rings, as it did before the
`◷`. Nobody saw this ping deferred, so the hold's "missing isn't finished" rule doesn't
apply, and failing closed would silence every dispatch if the undocumented file changed.
`ready` (a launch) and ✘ never wait. The ring is durable, so it fires once the work ends.

### One read, no machine-wide forks

`refresh_agents` runs `ClaudeSessions.scan` right after the hook read (running it before
would let its `ps` and `lsof` widen the done-before-idle race) and before `on_scan`. It
returns nil on failure, never `{}`, which would read as "finished". The same result goes to
`RemoteLink.scan(sessions:)` in the `ensure`.

The scan pre-filters by recorded cwd (raw or realpath) against the *tracked* workspace paths
before any `kill(0)`, `ps` or `lsof`. `same?` is one `ps` per session (batching measured no
faster), and 15 Claudes cost about 125 ms per 3-second scan. Filtering by config roots
instead would drop git-discovered worktrees outside `worktree_root`. Renames pass through
the bridge symlink.

## Remote links: the `⇅`

A workspace you can reach from your phone, a Claude session with `/remote-control` (`/rc`)
on, shows `⇅` right after its name. Several links show as `⇅2`. It comes before any `▸N`,
folded or expanded, and appears on workspace rows only.

### Observed, not declared

Unlike the `∞`, there's nothing to declare: Claude already writes the truth. Every live
Claude session has `<claude dir>/sessions/<pid>.json` (`ClaudeHistory.claude_root`, shared
with the transcript reader; test seam `SWITCHBOARD_CLAUDE_SESSIONS_DIR`), and `/rc` adds a
`bridgeSessionId`. It's removed on disconnect, a *new* id appears on reconnect, and the link
is `https://claude.ai/code/<id>`. No hook or env var exposes it
([last verified](../CLAUDE.md#upstream-contracts-last-verified)).

`ClaudeSessions` (`claude_sessions.rb`) reads it, one read per scan shared with the `◷`, and
`RemoteLink` (`remote_link.rb`) is the link layer on top: the bridge id, staleness,
ordering, the URL, and `health`.

**Because the file is undocumented, everything fails closed.** An unrecognized shape is no
link, never a wrong one. `scan` is total, and the sidebar hydrates `@links` *last* in
`refresh_agents`, behind its own rescue, because a raise reaching `refresh_agents`' rescue
would blank every agent dot. Files are read as UTF-8 whatever the locale, since a
smart-quoted session name would otherwise fail to parse.

### Three rules that took the most work

**Liveness is `ProcessIdentity.same?(pid, procStart)`.** Claude writes `procStart`
byte-identical to `LC_ALL=C TZ=UTC ps -o lstart=` (double-space day padding included), so
there's no parsing. A crashed session's leftover file or a recycled pid shows nothing.
Claude removes its file on a clean exit. `kill(0)` runs first, so a dead leftover never
forks a `ps`; those files can sit there forever.

**A session is placed by its *kernel* cwd, not the file's `cwd`.** The file's `cwd` and
`tmux` fields are startup stamps. After `rename A→B`, the bridge keeps `realpath(A)` correct,
until another workspace is renamed *onto* `A` (`Rename.perform` clears a dead bridge), when
`realpath(A)` names the wrong tree. One batched `lsof -a -d cwd` (`Agents.cwds_of`, shared
with `Agents.process_cwds`; about 27 ms for 4 pids, and only when at least one link is live)
follows the moved folder. The recorded `cwd` is only the fallback. (The agent dots may share
this flaw; that hasn't been verified.)

**The warm gate fingerprints the set of links, not directory mtimes.** Claude rewrites
*every* session's file on each busy/idle flip, hooked or not, inside switchboard or not, so a
`dir_fingerprint` would wake every hidden sidebar for unrelated work. `RemoteLink.fingerprint`
keeps a per-file (mtime, size, inode) stamp cache (`@link_fp_cache`; a `/rc` toggle within
the same tick still changes the size), re-parses only changed files (no `ps`, no `lsof`), and
moves only when a link appears, ends, or crosses the stale line.

### Off-screen panes scan cheaply

An off-screen pane runs the cheap scan (`cheap: !@visible`): `kill(0)` liveness and the
recorded `cwd`, with no `ps` or `lsof`. So hidden panes warm whenever anything in the
fingerprint moves. Its rare misses (a recycled pid, a rename onto an old name) last until the
pane's next visible scan, within `REFRESH`. It follows `@visible`, not `hooks_only`, because
the on-screen reload after a delete passes `hooks_only` too.

Paths are compared as bytes. Under tmux's C locale, git's paths arrive as US-ASCII and the
JSON's as UTF-8, and comparing a non-ASCII pair would raise.

### Several links, and stale ones

All of a worktree's links are kept (`{path => [Link, …]}`), newest first by `startedAt`, then
the parsed `procStart`, then pid. A bad ordering field only demotes a link.

- **Stale links are grey.** A link idle past `remote_link_stale_after` (minutes; default 120,
  global; `false` or 0 turns it off; an invalid value means 120) draws its `⇅` grey
  (`LINK_STALE_FG`, `\e[90m`); bold looked identical to normal in a real terminal. *Any*
  stale link greys the row, so an old forgotten link can't hide behind a newer busy one.
- **Live links are green** (`LINK_LIVE_FG`, `\e[32m`), because the default foreground looked
  too close to the grey.
- **Background jobs** (`kind: "bg"`, apparently always bridged) show the glyph but are never
  stale.
- **Under the cursor bar it's uncolored,** like the dots. A color code inside the
  reverse-video `\e[7m` paints the cell's *background* (foreground and background swap),
  which shows as an off-shade block in the bar.

**The name gives way, not the cues.** `fit_plain` gives up name columns, never the trailing
cues. The old `trunc(plain(node))` cut `⇅` and `▸N` first, so they vanished under the cursor
bar on a long name. The cues drop only when no name column would be left.

**The home console counts them.** It adds `N idle links` and `N linked`, and, given `cols`,
drops *whole* clauses (`linked`, then `PRs`, then `active`) before it would cut mid-word. The
idle-link warning always fits at 40 columns.

### `doctor` is the canary

Because the file is undocumented, `doctor` watches for it changing (`RemoteLink.health`):

- **No files while a Claude process runs:** the directory moved. No files with nothing open
  is normal, since Claude removes its file on exit.
- **Files, but none in the expected shape:** the format changed.
- ***Every* live Claude pid failing the start-time match:** the `procStart` format drifted.
  A single mismatch is just a recycled pid.

Only pids whose process *is* Claude count (`claude_pids`: argv[0], or the node script named
`claude`, not a substring match). It also warns when this shell's `CLAUDE_CONFIG_DIR` differs
from tmux's, since sidebars never read your rc. A *renamed* `bridgeSessionId` key can't be
detected; it reads as "nothing linked." `RemoteLink.health`'s `odd_status`, `unnamed` and
`unknown_kind` also watch the fields [session-name sync](explanation-session-name-sync.md)
depends on.

The sandbox seeds a link on `quiet-cleanup` (`Sandbox.seed_link`: a `sleep` parked in the
worktree, in a detached non-`sb/` session, so its kernel cwd is right and it dies with the
server). A real `claude /rc` inside the sandbox writes your real `~/.claude`, so it isn't
shown. Codex has no per-session equivalent (`codex remote-control` is a separate app-server
process). `test/smoke/remote_link_smoke_test.rb` proves it end to end.

### `p` draws the link as a QR code

`p` opens the link as a QR code (`@link_view`, short-lived like `@help`). `p` on a row
without a link does nothing; the missing `⇅` already says so.

**The encoder.** `QR` (`qr.rb`) has zero gems: byte mode, error-correction level M, versions
1 to 6. A link URL is at most 95 bytes, so there are no version-information blocks. It's
pinned module for module against `qrencode -8` fixtures with each mask forced. Which mask it
*picks* is pinned by hand-worked penalty cases, not by another encoder's choice, because
encoders legitimately differ on rule 3 (libqrencode#220), and segno pads differently (an
extra `0x00` before the `0xEC/0x11` run), so neither is a bit-exact reference for that.

**The overlay.** It leads with the tree's own `header` (the full one at home or with `H`, but
only the wordmark when the full one would cost the code or the URL), then the workspace
name. There's no session name, since Claude defaults that to the workspace's *first* name,
which goes stale after a rename. The code is drawn in half blocks in the theme's ANSI colors
0 and 15 (picked by eye and scanned; the fixed 256-color 16/231 pair looked wrong in a
themed terminal), with a quiet zone as wide as fits up to 4, never under 2, centered in a
wider pane. A pane that can't fit it shows the URL instead.

**Following the right session.** The link is held by pid plus `bridge_id`, not by position,
since a crash leftover can share its resumed session's bridge id. Every scan re-checks it
(`revalidate_link_view`):

- the same session stays through a re-sort and a reconnect (same pid, new bridge id);
- it follows its workspace through a rename, and another workspace renamed onto the old path
  doesn't take over the QR;
- an ended session falls back to the newest one left;
- the last one ending closes the overlay.

**Rules around the overlay:**

- **Closing drops the rest of that read's keys.** Whatever closes an overlay (a key, or a
  scan finding the link ended) drops the rest of that read's keys, but not its tmux pokes.
- **Names are sanitized.** Every name the sidebar draws (projects, workspaces, branches, the
  greeting's git name, the QR header) goes through `shown`, which strips controls and bidi
  characters and keeps accents.
- **No `flash` here.** It blocks on a keypress inside the scan.
- **Links refresh even when the dot scan fails.** For the re-check to mean anything, `@links`
  is hydrated in `refresh_agents`' `ensure`.
- **Pokes keep running.** Unlike the `?` overlay, the tmux pokes keep running under it
  (`poke`), so switching back to a session re-checks its link at once.
- **A bad frame closes the QR, not the pane.** Building the overlay frame is rescued
  (`link_view_frame`): an input nobody foresaw closes the QR and repaints the tree instead of
  killing the pane. Every specific hardening still has its own test.

**The URL isn't a bearer link.** It's gated on your account: opened in a logged-out browser,
it lands on the claude.ai sign-in page (checked 2026-10-24). So a QR on screen only helps
someone already signed in as you.

`:phone_link` sits *last* in `Keymap::ACTIONS`, because an earlier action's default beats a
later one's remap. Added mid-list, `p` would have taken the key from anyone who had remapped
`rename` (or any later action) to it.

## The dot glyphs

The shape *and* color both carry meaning, so it reads on any background:

```
(blank)    no agent
⠹ blue     thinking  — a braille spinner cycles while it works a turn
◆ magenta  waiting   — a blinking diamond; blocked on a question/permission
● green    done      — a steady dot; finished its turn (or idle), your move
◷ blue     background — a steady clock; the turn ended, but work it handed off still runs
∞ green    watching  — a steady loop; a declared background monitor
```

Colors are plain ANSI palette entries (blue/magenta/green), so they follow your
terminal's light/dark theme. The motion is in the glyph, not a brightness ramp,
so the spinner reads the same on any background.

## Trade-offs, named

- **Trusting a fresh hook file without a liveness check** makes presence instant
  and accurate, but means a mass kill (`quit`) leaves stale `:thinking` files
  that would read as live agents for up to `PRESENCE_TTL`. Both quit paths call
  `AgentState.clear_all` to wipe them; a restarted agent re-reports on
  `SessionStart`, so the wipe self-heals.
- **Capture-hash activity** gives free presence for any agent but can't
  distinguish waiting from done, and would be too noisy to drive sounds or badge
  refreshes — hence the hook-only gating on the edge consumers.
- **Split delivery** (Claude per-worktree, Codex global) is forced by codex not
  discovering project-local hooks in linked worktrees. Claude's per-worktree file
  keeps your global config clean at the cost of a wiring step per existing
  worktree (automatic only for ones switchboard creates); codex's global block is
  wired once, with consent, and covers every worktree — at the cost of touching
  your personal `~/.codex/config.toml` and a one-time `/hooks` trust step.

## Related

- [Reference: reading the sidebar](reference-sidebar.md) — the dot glyphs, the sparkle, and the bold name as they render in the row.
- [How-to: agent state & sounds](howto-agent-state-and-sounds.md) — enable hooks, pick sounds.
- [Explanation: sidebar lifecycle](explanation-sidebar-lifecycle.md) — why state is multi-process on disk.
- [Reference: config](reference-config.md#sounds) — the `sounds` and `agent_state_hooks` knobs.
