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
map and the file it's wired into (see "Hooks are wired per worktree" below).

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

## Hook delivery splits by agent: Claude per-worktree, Codex global

The same intents — report-state, the SessionStart rename plant, the Stop backstop
— reach each agent through a **per-agent adapter** behind a registry (`AgentHooks`,
`agent_hooks.rb`): `ClaudeHook` for Claude and `CodexHook` for Codex. What both agents
share — the command strings (the reporter per event, the nudge, the unified Stop), the
materialized reporter script — lives once in the shared engine `HookFile`
(`hook_file.rb`, `command_entries`). The merge-safe enable/disable JSON machinery there is
Claude-only. What differs is **where each adapter delivers** — and the two agents land on
opposite sides of that:

- **Claude is per-worktree.** `ClaudeHook` merges into
  `<worktree>/.claude/settings.local.json`, on top of your own settings, and adds
  the file to the worktree's local git excludes (`info/exclude`) so it never
  dirties `git status`. Your global `~/.claude` is never touched. This is what
  `AgentHooks::ADAPTERS` fans out over, so `enable-hooks` and the dispatch worker (`Creator.work`)
  wire it per worktree.

- **Codex is global.** Codex (checked through 0.164) deliberately does **not**
  load a *linked* git worktree's own `<worktree>/.codex/hooks.json`: it redirects
  a linked worktree's project hooks to the main checkout's `.codex/` folder. And
  switchboard is nothing but linked worktrees, so the per-worktree file is dead on
  arrival. A **config-level** hook isn't project-discovered, so it fires
  everywhere, including linked worktrees. So `CodexHook` delivers **one**
  marker-delimited `[hooks]` block in your global `~/.codex/config.toml` (written
  through the shared `MarkerBlock` — the same atomic, symlink-aware, marker-block
  surgery that manages the tmux.conf line). It covers every worktree at once, so
  there's nothing per-worktree to wire; `AgentState` only renders tracked
  worktrees, so the block firing for non-switchboard codex sessions is inert.

Because the codex block lives in your personal global config, switchboard writes
it **only with your consent**: `switchboard install` prompts (default no on a
non-tty, so a scripted install never silently touches it), or `install
--codex-hooks` / `--no-codex-hooks` decides up front. `uninstall` removes the
block; the per-worktree `disable-hooks` deliberately leaves it (it's global).

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
- **Nesting (#130).** A global hook fires for *every* codex, including a nested
  `codex exec` launched by a `/codex` running under Claude Code. A guard prefixes
  every command (`[ -n "$CLAUDECODE" ] || [ -n "$CLAUDE_CODE_SESSION_ID" ] && exit
  0`) and suppresses the reporter when a Claude-Code parent is detected, so a
  subagent's codex doesn't report presence up to switchboard. A top-level codex
  switchboard launches into a plain tmux shell carries neither marker, so it fires.
  Since Codex 0.149, a hook sees the environment as it was when the session
  started, not the live one. Codex strips a few credential variables from it, but
  not the two Claude markers, so the guard still works.

This hook contract was last checked live against Claude Code 2.1.301–2.1.303 and
codex-cli 0.163.0: the payload fields, delivery in linked worktrees, the
nesting-guard environment, and a silent `PermissionRequest` hook leaving the
prompt to you. codex-cli 0.164.0 has since passed the real-Codex smoke test:
delivery in linked worktrees, hook ordering, and an untrusted block staying
silent.

Codex's event map differs from Claude's in one place: Codex has no `Notification`
event, so `PermissionRequest` (which Claude also uses, above) is its only `waiting`
signal — the magenta dot shows whenever Codex blocks on you for approval, which is
best-effort (a session command that bypasses *all* approvals suppresses it).

The reporter script itself is shared by both adapters (the state-file format is
agent-neutral) and lives in the XDG **data** dir
(`~/.local/share/switchboard/sb-agent-hook`) — an install-independent path that
survives a `git pull` or `brew upgrade`, unlike the checkout. It's rewritten
whenever it's missing or stale (versioned in the script header), so an upgrade
self-heals. New worktrees switchboard creates get the Claude hook automatically
(the dispatch worker, `Creator.work` → `AgentHooks.enable`, gated on `agent_state_hooks?`,
`auto_rename`, or `background_presence`); existing
ones via `switchboard enable-hooks`. Codex needs no per-worktree step — its global
block already covers them.

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
consumer can't corrupt the next edge diff.

The completion-edge consumers ride the *hook* signal only, not the coarse activity fallback — because
the capture-hash flips `:thinking ⇄ :done` every few seconds and would fire on
noise. So observation-only agents show a dot but make no sound and trigger no
badge refresh on completion.

### The declared alert — `monitoring notify`

A workspace running a background monitor (the steady `∞`) has its routine `:done`
ticks **suppressed** — a `/loop` finishing a cycle every few seconds must not chime
and bold each time. But some cycles matter: the monitor wakes, finds the thing it's
watching for, and prints a result. Switchboard can't tell that tick from a "nothing
new" one — both are byte-identical `Stop` (`:done`) events — the same wall the `∞`
itself is built on. So the significant tick is **declared, not detected**: the agent
runs `switchboard monitoring notify` (taught by the nudge), which fires the normal
bold + sound + sparkle with a **distinct `alert` sound**, even though routine ticks
stay silent.

It's an **independent alert channel**, not a hook edge — it can fire mid-`:thinking`,
with no `Stop`. `Notify` (`notify.rb`) is a `KeyedMarkerStore` twin of `Attention`
read by file **mtime**: `monitoring notify` re-touches the marker, and each sidebar's
`@prev_notify` cursor rings once per mtime advance — the same "compare against your own
cursor" trick the completion sound uses, so only the on-screen pane rings and catch-up
scans re-baseline silently. The **bold** is written straight into `Attention` by the CLI
(not the edge), so it persists even when no sidebar is on screen — you still see it the
moment you return. The verb is **gated to a monitored workspace** (it's precisely the
exception to monitoring's suppression). Cloud routines that never touch the local
reporter can't declare a notify — a stated limit, like the `∞` itself.

### Waiting on background work — the `◷` (observed, not declared)

When Claude hands work to a background agent, a background shell or the Monitor tool
and ends its turn, the `Stop` hook writes `done` — but the work isn't done. No hook event
means "turn over, background task outstanding" (the `Stop` payload carries a
`background_tasks` field whose contents haven't been checked yet). Claude's own per-session file
(`~/.claude/sessions/<pid>.json`, the one the `⇅` reads) does say it: after such a turn
its `status` stays `busy` (a background agent) or reads `shell` (a background shell or
monitor) instead of going `idle`. `ClaudeSessions` (`claude_sessions.rb`) reads that one
file set for both cues. The file is undocumented, so only those exact strings count; any
other value is no evidence and the row shows today's dot.

The row draws a steady blue `◷` (the spinner's blue: work is happening; a still clock:
not by the main agent) in place of a resting `●`. Only a hooked agent's row: a session
reads `busy` through every ordinary turn too, so without the hook's `done` there is no
way to tell a hand-off from plain work. `∞` outranks it — a declared monitor is
the more specific cue. When the work is a background **agent** (the session reads
`busy`), the chime and bold of that hand-off are **held** rather than dropped. A
background **shell** (`shell`) shows the `◷` but rings as usual: it may be a dev server
that never ends, and holding its chime would mute the very turn you were waiting on. An
agent always reports back with a follow-up turn, so its hold always resolves. The
`:done` edge writes an `OffstageHold` marker (a `KeyedMarkerStore` twin of
`Attention`) instead of ringing. On disk, because the sidebar on screen when the work
finishes may never have seen the hand-off (it was hidden; its baseline already read
`done`). The hold resolves one of two ways:

- **The follow-up turn starts** (the hook leaves `done`) — the usual case, since Claude
  runs a normal turn when the result arrives. The hold is dropped; that turn's own `Stop`
  rings as usual. If the sidebar on screen misses a short follow-up turn between two
  scans, the hold stays and rings once the session settles instead.
- **The session settles idle, or its process is gone** — the first on-screen announcing
  scan claims the hold by unlinking it (only one unlink succeeds across every pane) and
  rings + bolds. Missing evidence (a failed read, an unknown status) never counts as
  finished: the hold just waits.

Two timing facts, probed live (Claude Code 2.1.310), shape it. Claude writes `done`
13–29ms before `idle` on an ordinary turn end, and a finished background agent reads
`idle` for ~15ms before its follow-up turn reads `busy`. A 3s scan lands in those windows
about 1% of the time, so both edges wait `ClaudeSessions::SETTLE` (2s): `◷` draws only
once the hook's `done` is that old, and a hold matures only on an `idle` that old. A
hidden pane learns when a `done` settles from a per-report "settled" bit in its warm
fingerprint, since nothing on disk changes at that moment.

A subagent's own tool calls fire the parent worktree's hooks too (their payload carries
an `agent_id`; so do Claude's internal agents'). They used to turn the main dot into a
spinner claiming the main agent was working. The reporter now ignores those, keeping a
subagent's `PermissionRequest` (it wants you) and turning the dot back to `done` after
you approve one, so its magenta can't stick.

### Why bold lives on disk but sound doesn't

A completion **sound** is a one-time event — play it once, from wherever you're
watching, done. It lives only in memory.

The **bold** is persistent state: a workspace stays bold from the moment it
finishes until you actually look at it (switch into the session clears it —
viewing is enough, no input required). Because every window's sidebar is its own
process (see [sidebar lifecycle](explanation-sidebar-lifecycle.md)), that state
*must* be shared on disk — one marker file per worktree — or only the one sidebar
that saw the completion would render it bold. Same reasoning as the hook-file
dots themselves.

This is why catch-up scans (switching into a session, an off-screen sidebar
waking up) re-baseline the sound state silently (`announce_sounds: false`) but
*still* write the bold marker: the sound was already heard once; the bold is
about whether *you've looked*, which doesn't depend on which process noticed.

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

## The global codex block, in detail

This is the full implementation detail [CLAUDE.md](../CLAUDE.md) summarizes; keep the two in step.

- **Trust.** Codex runs no hook until `/hooks`-approved (or `--dangerously-bypass-hook-trust`).
  Codex records each approval in `config.toml` itself, as `[hooks.state."<file>:<event>:…"]`
  tables holding the command's `trusted_hash`, appended right after our `[hooks]` table —
  i.e. INSIDE our markers. So `install_global` carries those tables into the rewritten
  block, and trust survives a re-install (run after every upgrade) AS LONG AS the commands
  stay byte-stable (deterministic paths + fixed event order; why `command_entries` is
  centralized). A command that DID change (another checkout's bin path) keeps its old approval
  (codex re-asks in `/hooks`; it's valid again once the command changes back, and an `enabled = false`
  stays put), so doctor's count credits presence, not a matching hash (dec-455f3bf8); `remove_global` drops OUR approvals with the block (approvals for other hook
  files stay — see below). A present block isn't proof the
  dot moves: `doctor` counts approvals (`CodexHook.trust_status` → `N/M trusted`, keys
  matched to our file by realpath, `enabled = false` not counted) and warns below M — unless
  EVERY codex-launching `session_command` (global + per-project) passes
  `--dangerously-bypass-hook-trust`, where 0/M is expected (one bypassing project can't hide it).
  The count only means something for a block install would leave as-is, so doctor first checks
  `CodexHook.block_state` (read-only, running install's own `planned_install`, so the two can't
  disagree): a `:stale` block (an older release, or another checkout's
  bin path) or an `:unsafe` one (install would refuse) gets "re-run `switchboard install`" instead
  — approving it in `/hooks` would bless the wrong commands (counts are by position, not
  command) — and a user's own `[hooks]` outside the block reads `:collision` and gets "merge
  yours into one place" (an `:unsafe` block outranks it: install's own check order). The
  real-Codex smoke can't see this (it passes `--dangerously-bypass-hook-trust`), so its
  second case runs WITHOUT the bypass and asserts an untrusted block writes no state.
  `MarkerBlock` accepts trailing text on a marker line (older releases wrote `# >>> … >>>
  (managed by …)`), and `remove_global` returns whether it changed anything, so uninstall
  never reports a removal that didn't happen.
- **Codex writes its OWN tables into our block.** Codex edits `config.toml` with toml_edit,
  which renders every NEW top-level table after the document's last table but BEFORE its
  trailing comments — and our block sits at EOF with a comment for an end marker. So
  `[desktop]`, `[marketplaces.*]`, `[plugins."…"]` land inside our markers (v0.50.1 and
  earlier silently dropped them on install and deleted them on uninstall). `install_global`
  / `remove_global` now split the region (`movable_parts`): ours (note + any `hooks` table,
  regenerated), trust (carried), foreign (moved verbatim, in order, to just ABOVE the block,
  which stays last where `MarkerBlock.build` appends it). With no foreign tables the output
  is byte-identical to before (trust hashes stay valid). There's no TOML parser (zero gems),
  so a line-based move refuses (`:unsafe`, file untouched) whenever it could change meaning
  or drop data: a multi-line string, a `[[…]]` array-of-tables, key lines before the
  region's first table / right after the end marker (a comment doesn't end a table, so they
  belong to a neighboring table), anything in OUR `[hooks]` chunk besides one-line
  `<Event> = [...]` arrays (a key codex or the user added there would be regenerated away),
  a `[hooks.<x>]` table, or a second marker region. Only a whole TOML header line
  (`HEADER`) at bracket depth 0 (`scan_lines`, strings/comments ignored) opens a table, so a
  multi-line array's `[1, 2]` / `["hooks"]` elements never split a chunk or read as a hooks
  table; the collision guard fails closed both ways (an unindented `[hooks…]` line collides
  even inside an open bracket, and brackets left open at EOF count as a collision), and
  `hooks` is matched bare, "double"- or 'single'-quoted (`HOOKS_KEY`). A line-conservation
  check is the belt over the splitter (it discounts one copy per generated line, so a pasted
  note line outside still counts as kept), and stray marker lines are counted and refused
  outright. The file is always read as UTF-8 with a leading BOM dropped (`read_config`): under
  `LC_ALL=C` a default read is US-ASCII and every check on it misfires, and a BOM defeats the
  `\A\s*` anchors (a user's line-1 `[hooks]` would slip past the collision guard). For a block
  missing its end line the `:unsafe` advice says to put the end marker back — never delete our
  `# >>>` line, which would orphan our `[hooks]`. Codex files approvals for OTHER hook files (a project
  `.codex/hooks.json`, plugins) under the same `[hooks.state]`, so uninstall keeps those
  (moved out with the foreign tables) and drops only ours; a `[hooks.state…]` table outside
  the block is codex's, not a competing hooks config (`[[hooks.state]]` still collides). Codex can
  also write the file at any moment (the desktop app does), so both verbs re-read before
  writing and return `:conflict` rather than ever restoring a snapshot over a newer write —
  which replaced the old `:corrupt` torn-write rollback (temp+rename can't tear, so a
  read-back mismatch means someone else wrote). Not a lock: a write in the last instant
  before our rename can't be seen. `Installer` reports `:unsafe`/`:conflict` as failures and
  never advises deleting the block by hand (that would take codex's tables with it) — the
  block's own note says so too. Dropping one of our approvals keeps the comments trailing it
  outside the block (they head the next table); comments INSIDE the managed block are regenerated
  away (dec-3417a712). A refusal also fails the command (exit 1: `install` after
  its other steps, `uninstall` before any, `enable-hooks`). `uninstall` runs the codex step FIRST and stops on a refusal,
  so its "re-run uninstall" advice can't point at a command it already unlinked. A write that
  fails instead (a read-only config, or one that turns unreadable mid-run) is `:failed`: the rest
  of uninstall still runs, it ends "Done, except the codex hooks" and exits 1. A begin
  marker without its end line is refused as `:unsafe` (checked before the collision guard,
  which would otherwise misread our own `[hooks]` as foreign).

## Implementation detail

This is the full implementation detail [CLAUDE.md](../CLAUDE.md) points to; keep it current with the code.

### Agent-state dots (the subtle part)

Hook contract last verified live against **Claude Code 2.1.301–2.1.303** and **codex-cli
0.163.0** (v0.51.1): payload fields, linked-worktree delivery, the nesting-guard env, and a
silent PermissionRequest hook leaving the prompt to the user. **codex-cli 0.164.0** (v0.55.2)
and **0.165.0** (v0.60.7) re-passed the real-Codex smoke only: linked-worktree delivery, hook
ordering, untrusted-block silence.

The dot beside each workspace shows whether an agent (Claude/Codex/Aider) is
thinking / done / waiting. `AgentState.scan` (`agent_state.rb`) merges **two
presence signals** per worktree:

1. **Hook state (exact).** Claude Code *and Codex* report state by running a tiny
   POSIX-sh reporter that writes `<state>\t<cwd>\t<epoch>` files into the state dir. A
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

Hooks reach each agent through a **per-agent adapter** registry `AgentHooks`
(`agent_hooks.rb`): `ClaudeHook` (`claude_hook.rb`) and `CodexHook` (`codex_hook.rb`).
Both agents read the SAME hook-config shape, so the command STRINGS, the reporter, and
the rename-nudge/Stop wiring live once in the shared engine `HookFile` (`hook_file.rb`,
`command_entries`). What **differs is the delivery target**, and the two agents land on
opposite sides of it — the subtle, hard-won part:

- **Claude is per-worktree.** `ClaudeHook` merges into
  `<worktree>/.claude/settings.local.json` (declaring its `SETTINGS_REL` + `EVENTS`),
  on top of your settings, adding the file to the worktree's git excludes so it never
  dirties `git status`; global `~/.claude` is untouched. This is the only entry in
  `AgentHooks::ADAPTERS`, so `enable`/`disable` and the dispatch worker fan out over it.
- **Codex is global.** Codex (verified 0.142 through 0.165) deliberately does NOT load a
  *linked* git worktree's own `<worktree>/.codex/hooks.json`: it redirects a linked
  worktree's project hooks to the MAIN checkout's `.codex/` (and only when the worktree
  has a `.codex/` dir and is trusted — `config/src/loader/mod.rs`). Switchboard is nothing
  but linked worktrees, so the per-worktree file was **dead on arrival** (v0.39.0's codex
  feature never fired in practice). A CONFIG-level hook isn't project-discovered,
  so it fires everywhere. So `CodexHook` writes ONE marker-delimited `[hooks]` block into
  `~/.codex/config.toml` (`CODEX_HOME`-aware) via the shared `MarkerBlock`
  (`marker_block.rb`, extracted from the tmux.conf surgery — atomic temp+rename,
  symlink-aware, first-write `.bak`, the same `# >>> … >>>` markers). The block is
  emitted as TOML **basic** strings (double-quote, escape `\`/`"`; literal single-quote
  strings would break on an apostrophe path). It covers every worktree at once, so
  there's nothing per-worktree to wire; `AgentState` only renders tracked worktrees, so
  the block firing for non-switchboard codex sessions is inert (an **age-based GC**,
  `AgentState::STALE_GC`, reaps the resulting stray state files the dir-exists GC alone
  would keep forever).

Because the codex block lives in the user's personal global config, `Installer`
writes it **only with consent** (`step_codex_hooks`): `install` prompts (default NO on a
non-tty, so a scripted install never silently touches it), `--codex-hooks` /
`--no-codex-hooks` decide up front (`--no-codex-hooks` leaves even an installed block
untouched; a plain `install` re-ensures one). `uninstall` strips the block; the per-worktree
`disable-hooks` deliberately leaves it. `AgentHooks.enabled?` / `enabled_adapters` fold
in `CodexHook.installed?` so the global block counts as "on" for every worktree, and
`doctor` reports Claude per-worktree + the global codex block + the trust note.

Two consequences of codex being global:
- **Trust.** Codex runs no hook until `/hooks`-approved (or `--dangerously-bypass-hook-trust`),
  and files each approval as a `[hooks.state."…"]` table right after our `[hooks]` table —
  INSIDE our markers. `install_global` carries those tables, so trust survives a
  re-install as long as the commands stay byte-stable (deterministic paths + fixed event
  order; why `command_entries` is centralized). `doctor` counts approvals
  (`CodexHook.trust_status` → `N/M trusted`) only for a block install would leave as-is
  (`CodexHook.block_state`: `:stale`, `:unsafe` and `:collision` get their own advice).
- **Codex writes its OWN tables into our block** (toml_edit renders new top-level tables
  before the trailing end-marker comment). `install_global` / `remove_global` split the
  region (`movable_parts`): ours (regenerated), trust (carried), foreign (moved verbatim to
  just above the block). There's no TOML parser, so anything a line-based move could
  change the meaning of is refused as `:unsafe` (file untouched), and a write codex made
  meanwhile is `:conflict`, never overwritten. Never advise deleting the block by hand.

  Full detail (the refusal list, the collision guard, UTF-8/BOM reads, uninstall order):
  [docs/explanation-agent-presence.md](explanation-agent-presence.md#the-global-codex-block-in-detail).
- **Nesting (#130).** A global hook fires for EVERY codex, including a nested `codex exec`
  (a `/codex` under Claude). A `GUARD` (`[ -n "$CLAUDECODE" ] || [ -n
  "$CLAUDE_CODE_SESSION_ID" ] && exit 0`, equal-precedence left-assoc sh) prefixes every
  command and suppresses the reporter when a Claude-Code parent is detected; a top-level
  codex switchboard launches into a plain tmux shell carries neither marker, so it fires.
  Since Codex 0.149 (#39314) a hook's env is a snapshot taken at session start (minus a
  few credential vars), not the live env — the two Claude markers aren't stripped, so the
  guard still sees them (verified live: both are set in Claude 2.1.301's hook env).

Both agents report `waiting` on `PermissionRequest`, the moment the prompt opens (a silent
hook leaves the answer to the user). Claude also keeps `Notification` (`notify`) for
elicitation / `agent_needs_input` / idle; its accepted cost is a dot that stays magenta
until an approved tool finishes (or, after an Esc rejection, until the next prompt). Codex
has no `Notification` event, so `PermissionRequest` is its only `waiting` (best-effort —
suppressed by a session command that bypasses *all* approval gates). A SUBAGENT's events
fire the parent worktree's Claude hooks too, with an `agent_id` in the payload (Claude's
internal agents too; probed live, 2.1.310), so the reporter (`sb-agent-hook v6`) drops a
`thinking` whose payload carries one — the spinner would claim the MAIN agent is working,
and stick after the subagent ends. `thinking` therefore reads stdin (`[ ! -t 0 ]`, so a
manual run can't block); the key is value-extracted like `notification_type` (an
`"agent_id"` inside a string value is escaped, so it never matches). Two exceptions: a
subagent's `PermissionRequest` still reports `waiting` (it wants you), and its next
`PostToolUse`/`PostToolUseFailure` writes `done` when the file reads `waiting`, so an
approved subagent prompt can't leave the dot magenta (that `done` is a hand-off: ◷).
`report_stop_state` passes `in: File::NULL` for the same reason. New worktrees get the Claude hook automatically
(`Creator.work` → `enable_hooks` → `AgentHooks.enable`, gated on `agent_state_hooks?` **or**
`auto_rename_for(project)` — so a project opting into `auto_rename` with the global off
still gets the hook the runtime nudge needs); existing ones via `switchboard
enable-hooks`. Codex needs no per-worktree step. The runtime contract — the global block
fires in a LINKED worktree (the bug-fix crux), the `PreToolUse`→`PostToolUse` ordering,
the nesting guard's direction — is verified against real Codex by the opt-in
`test/smoke/codex_hook_smoke_test.rb` (`SWITCHBOARD_CODEX_SMOKE=1`); the guard's sh
precedence is pinned offline by `codex_hook_test`'s runtime guard test.

### Agent self-naming nudge (issue #92)

`HookFile.enable` also wires the nudge into the agent-state hooks, re-invoking the binary (so
the commands carry `NUDGE_MARK` and `HookFile.ours?` recognizes them for idempotent merge /
clean disable) and `command -v`-guarding the baked bin path so a stale path after a repo
move degrades cleanly instead of erroring "command not found":

- a **`SessionStart` command** (`rename-nudge`) — the **soft plant**, riding *beside* the
  sh state reporter (`… && … rename-nudge || true`): when `auto_rename` is on
  (`Config#auto_rename?` / `auto_rename_for`, global + per-project, default on since #114
  made placeholders the only create path),
  `CLI#rename_nudge` injects a `SessionStart` `additionalContext` instruction telling the
  agent to `switchboard rename` the workspace once it understands the work — which
  (post-#94) names the dir and its branch. `RenameNudge.decide` is the pure gate (fires on
  `source ∈ {startup,resume,fork,clear,compact}` when on + placeholder — `clear` because /clear
  wipes the earlier plant from context, like compaction).
- the **`Stop` command** — the **backstop**, and (deliberately) the Stop **state reporter
  itself**. A SessionStart plant fires *before* the agent knows anything and then never
  again, so the moment of maximum understanding (work done, about to walk away) has no
  reminder — exactly how a real session here shipped a fix and left the workspace on its
  placeholder. The Stop hook catches that moment. But Stop is kept **off the `EVENTS`
  reporter list** on purpose: Stop hooks run in **parallel with no ordering**, so a plain
  sh `done` reporter racing the block could record a blocked (still-working) agent as
  `done` and ring a **false completion** (chime + attention-bold). So ONE command owns the
  event — `if command -v switchboard; then switchboard rename-nudge --stop; else
  <sh-reporter> done; fi` — and `CLI#rename_nudge_stop` reports the state ITSELF:
  `thinking` when it blocks (accurate — the agent is about to keep going), `done` otherwise
  (the normal completion), via the same sh reporter (`report_stop_state` →
  `HookFile.script_path`; the child inherits the hook's cwd so its cksum key matches the file
  the other events write). State is reported for **every** hooked worktree (even
  non-placeholder / `auto_rename`-off — the dot depends on it); only the block is gated.
  The `else` fallback keeps `done` flowing if the binary is stale (the script path doesn't
  need PATH); `if/then/else` not `&& ||` so a Ruby-side non-zero can't *also* fire the
  fallback (double-write). The block payload is `RenameNudge.stop_json` (`decision: block`
  + an imperative reason); `RenameNudge.decide_stop` gates it on an explicit
  `stop_hook_active == false` — Claude's own loop guard — so it blocks **once per
  stop-chain** (nudge, don't nag): the agent renames (then it never fires again) or, if it
  genuinely can't yet, the second stop passes through. The `== false` is fail-closed: a
  missing/garbled flag does NOT block, since a block on an absent flag would never see a
  `true` to release it and could trap the agent unable to stop.

Both self-clear the instant the workspace is renamed — "still unnamed" is **derived, not
stored**: `Placeholder.generated?(leaf)` (the leaf is a generated `adjective-noun`) is the
signal, no marker file. The subcommand resolves the worktree from the hook's stdin `cwd`
(via `current_worktree`), and **always exits 0 with only the JSON or nothing on stdout**
(a stray byte poisons Claude even at exit 0; the whole body is rescued to silence).

### Completion sounds (the audible twin)

`Sound` (`sound.rb`) plays a short sound when a worktree's hook state newly
enters a resting state — the same `Sidebar::Edges.completion_edges` the PR
refresh rides. Both consumers live in `Sidebar::Edges#on_scan` (`sidebar/edges.rb`,
the #57 collaborator that owns the edge state): it computes the edges once, runs
the PR refresh **first**, then `play_sounds_for` (fully rescued), and advances
`@prev_hook_states` in an `ensure` — so a sound fault can never starve the PR
trigger, blank the dots (the broad `refresh_agents` rescue), or corrupt the next
edge diff; the returned edge list is what `refresh_agents` rides for the diff
refresh. Hook-only states, like the PR trigger, so observation-only
agents make no sound. Deduped per `[worktree, state]`: every distinct worktree's
completion is heard, but one worktree can't double-fire in a scan. Since v0.51.1 a Claude
permission prompt enters `waiting` the instant it opens (`PermissionRequest`, not the ~6s
`permission_prompt` Notification), so `waiting` rings once per prompt still open at the next
scan — the workspace you're viewing included, like every other sound. Deliberate: an open prompt is what the
chime exists to surface; a viewed-workspace mute would be a separate sound rule.

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
`HookFile.ensure_script`, no shipped binary assets. Config resolves a state to a
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
the sound/PR triggers (the third consumer in `Sidebar::Edges#on_scan`), but with
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

The atomic temp+rename write, the crc32 filename key, the XDG `state_dir`, and the
`scan`-with-GC are not Attention's own machinery: they're the shared
**`KeyedMarkerStore`** (`keyed_marker_store.rb`, issue #95) that both `Attention` and
`Collapse` delegate to. Each caller supplies only its *domain* — Attention a
canonicalized-realpath value and a `Dir.exist?` GC predicate, Collapse a project name
and a config-membership predicate — as a `scan(dir) { |content| keep? }` block (a falsy
return GCs that marker; `dir` is total so a state-path failure degrades, never crashes).
`FullHeader`/`Width` deliberately stay **off** this base — single flag / single int,
they'd only share "an XDG dir."

### Background-agent presence (the ∞ dot — declared, not detected)

A workspace where an agent is running a **background monitor / recurring loop /
scheduled tick** (a `/loop`, a self-paced wakeup, the Monitor tool, a background bash)
looked identical to a finished-and-idle one — both a resting `●`. The dot couldn't
tell them apart because **hooks can't**: a background loop fires the same
`SessionStart`/`Stop` events as an interactive turn, and there is no
`source: routine` / `is_autonomous` signal (cloud routines never touch the local
reporter at all). So presence here is **declared, not detected**: `switchboard
monitoring on|off` (agent- or human-invoked; `Monitoring`, `monitoring.rb`) writes a
per-worktree marker on the shared `KeyedMarkerStore` — a twin of `Attention`, keyed by
realpath, `Dir.exist?` GC — and the sidebar draws a **steady green ∞** for that
workspace at rest. The dot is a render overlay, not a fourth `@agents` value: a single
`render_state` resolver (used by BOTH paint paths, so precedence can't drift) yields
`thinking`/`waiting > monitoring > done/idle` — you still see live work and input
requests; only the *resting* dot becomes ∞ (idle-between-ticks reads as *watching*, not
*finished*). Steady, deliberately: an animated ∞ would keep `pulsing?` true for every
monitored pane and defeat the off-screen dormancy budget.

**"The dot is up" must mean "monitoring is happening right now."** The trap: a marker
only proves an agent *declared* monitoring, and a liveness gate can only prove an agent
is *alive* — neither proves it's *still* monitoring. So liveness is **marker-mtime +
per-cycle re-affirmation**, NOT a hook heartbeat: `monitoring on` (re)writes the marker
(fresh mtime), the agent re-runs it each cycle, and `Monitoring.monitored` shows a
worktree only while `now - mtime <= TTL` (`Monitoring::TTL`, ~10 min) — GC'ing the stale
file. Re-affirmation is the *precise* still-monitoring signal a generic heartbeat can't
produce: a stopped/crashed/resumed-into-other-work agent stops re-affirming, so its dot
ages out on its own (a heartbeat would keep it falsely lit from unrelated activity).
This is why Option A beat the heartbeat — see `thoughts/` and the three
thought-experiment tests (resume, user-stops, agent-stops).

The **routine `:done` per tick is suppressed** from the completion sound AND the
attention-bold (`suppress_completion?`, the one predicate both `play_sounds_for` and
`mark_attention_for` consult) — a background loop must not chime/bold every tick — but
`:waiting` still surfaces (it wants input) and the PR/diff refresh still rides every
edge. `@monitoring` is hydrated (in `refresh_agents`, before `Edges#on_scan`) so the
suppression is live on the scan that fires the edge; the monitoring dir joins
`warm_fingerprint` so a toggle warms off-screen panes.

**The one exception is a DECLARED notify** (`switchboard monitoring notify`, `notify.rb`)
— the agent's "come look, this cycle surfaced something" for the case that routine
suppression would otherwise swallow. Same "declared, not detected" wall: switchboard
can't tell a "found it" tick from a "nothing new" tick (both are byte-identical `:done`
Stops), so the agent declares the one that matters. It's an **independent alert channel**,
not a hook edge — it may fire mid-`:thinking`. `Notify` is a `KeyedMarkerStore` twin of
`Attention` (content = realpath, like Attention) read by **mtime**: `monitoring notify`
re-touches the marker (fresh mtime), and each sidebar's `Edges#@prev_notify` cursor rings
once per advance (the completion-sound "compare-to-your-own-cursor" trick, so only the
on-screen pane rings and catch-up scans re-baseline silently — no delete race, no TTL).
The **bold** is written **directly by the CLI** into `Attention` (so it persists even
when no sidebar is on screen — the away-user case), so the edge's `mark_attention_for`
sees only the un-suppressed *completions*; the forced alert drives only the announce-gated
sound + sparkle. `:alert` (the sound state + `alert` built-in, distinct from `done`/
`waiting` — NOT `:notify`, which the Notification hook owns) stays **strictly local** to
sound/sparkle: a throwaway `states` map, never merged into `now`/`@prev_hook_states`, the
returned `edges` (so the diff refresh still rides real `:done`s), or `render_state`. The
verb is **gated to a monitored workspace** (it's the exception to monitoring's
suppression) and `Notify.clear_all` rides `quit` beside `Monitoring.clear_all`. The nudge
teaches it: fire *after* a cycle's output exists, not before. `Notify.pending` needs no
`warm_fingerprint` entry — its only shared render effect is the Attention bold, already
covered there.

**Clears, fastest to slowest (defense in depth):** explicit `off` and `quit`
(`Monitoring.clear_all`, beside `AgentState.clear_all` — a teardown kills every agent)
are instant; `Dir`-GC reaps a deleted worktree; the mtime **TTL** is the floor for a
crash with no clean exit. Two **session-boundary clears** (Layer 2, `MonitoringNudge` +
`CLI#monitoring_nudge`, wired into the Claude hook by `HookFile.command_entries` as
matcher-less `SessionStart`/`SessionEnd` commands — `MONITOR_MARK` so `ours?` dedups/
strips them) tighten those windows to instant: **clear-on-SessionStart** makes
monitoring a per-session declaration (a resumed agent, its old loop dead, re-declares) —
and **SessionEnd auto-off** (the agent's gone, so it can't still be monitoring). The
clear and the nudge have **different source gates** (the compaction split): the clear
fires on `startup`/`resume`/`fork` only (a fork is a new process — Claude ≥ 2.1.214 and
Codex ≥ 0.155 report it as `fork`, where they used to say resume/startup), NEVER
`compact` (same process continues, a live monitor's marker must survive) or `clear` (its
SessionEnd already dropped the marker; the re-planted nudge is what gets a still-running
monitor re-declared); the
**nudge** re-plants on `startup`/`resume`/`fork`/`clear`/`compact` (matching
`RenameNudge`), because compaction and `/clear` both drop the original instruction out of
context and SessionStart re-fires on them precisely so a hook can re-inject it — so an
agent that sets a monitor *after* either still knows the `monitoring on` convention (`MonitoringNudge.clears_on?` vs `nudges_on?`). Both rename-safe: `Rename.perform` carries the marker via the shared
`KeyedMarkerStore.carry` (capture the old realpath BEFORE `move_worktree` — the bridge
symlink resolves it to the new dir after), which also fixes the pre-existing bug where a
rename silently dropped `Attention`'s bold. The whole Layer-2 behavior (nudge + session
clears) is gated on the `background_presence` config knob (global + per-project, default
**on**, like `auto_rename`); the worker's hook-enable gate now includes it, so a
project using only monitoring still gets the hook wired. Cloud routines remain invisible
(they never reach the local reporter) — a hard limit stated, not worked around.

### Remote-link glyph (the ⇅ — observed, not declared)

A workspace reachable from the phone — a Claude session with `/remote-control` (`/rc`)
on — shows `⇅` right after its name (`⇅2` for several links; before any `▸N`, folded or
expanded; workspace rows only). Unlike the ∞ there is nothing to declare: Claude
already writes the truth. Every live Claude session has `<claude dir>/sessions/<pid>.json`
(`ClaudeHistory.claude_root`, shared with the transcript reader; test seam
`SWITCHBOARD_CLAUDE_SESSIONS_DIR`), and `/rc` adds a `bridgeSessionId` (removed on
disconnect, a NEW id on reconnect; the link is `https://claude.ai/code/<id>`). Verified
live on Claude Code 2.1.308 (`doctor`'s canary still clean on 2.1.312); no hook or env
exposes it. `ClaudeSessions` (`claude_sessions.rb`) reads it — one read per scan, shared with the ◷ below — and
`RemoteLink` (`remote_link.rb`) is the link layer on top (bridge id, staleness, ordering,
URL, `health`). Because the file is **undocumented**, everything fails closed — an
unrecognized shape is no link, never a wrong one, and `scan` is total (the sidebar
hydrates `@links` LAST in `refresh_agents` behind its own rescue: a raise reaching
`refresh_agents`' rescue would blank every agent dot). Files are read as UTF-8 whatever
the locale (a smart-quoted session name would otherwise fail to parse).

Three hard-won rules:
- **Liveness is `ProcessIdentity.same?(pid, procStart)`.** Claude writes `procStart`
  byte-identical to `LC_ALL=C TZ=UTC ps -o lstart=` (double-space day padding kept), so
  no parsing; a crashed session's leftover file or a recycled pid shows nothing. Claude
  removes its file on clean exit. `kill(0)` runs first, so a dead leftover never forks a
  `ps` (the files can sit there forever).
- **Place a session by its KERNEL cwd, not the file's `cwd`.** `cwd` and `tmux` are
  startup stamps. After `rename A→B` the bridge keeps `realpath(A)` correct — until
  another workspace is renamed ONTO `A` (`Rename.perform` clears a dead bridge), when
  `realpath(A)` names the wrong tree. One batched `lsof -a -d cwd` (`Agents.cwds_of`,
  shared with `Agents.process_cwds`; ~27 ms for 4 pids, only when ≥1 link is live)
  follows the moved dir; the recorded `cwd` is only the fallback. (The agent dots may
  share this flaw — a verify-first TODO.)
- **The warm gate fingerprints the linked SET, not dir mtimes.** Claude rewrites EVERY
  session's file on each busy/idle flip, hooked or not, inside switchboard or not, so a
  `dir_fingerprint` would wake every hidden sidebar for unrelated work.
  `RemoteLink.fingerprint` keeps a per-file (mtime, size, inode) stamp cache
  (`@link_fp_cache` — a same-tick `/rc` toggle still changes the size), re-parses only
  changed files (no `ps`, no lsof), and moves only when a link appears, ends, or
  crosses the stale line.

An OFF-SCREEN pane runs the cheap scan (`cheap: !@visible`): `kill(0)` liveness and the
recorded `cwd`, no `ps`/lsof — hidden panes warm whenever anything in the fingerprint
moves. Its rare misses (a recycled pid, a rename onto an old name) last until the pane's
next visible scan, within `REFRESH`. It follows `@visible`, not `hooks_only`: the
on-screen post-delete reload passes `hooks_only` too. Paths are compared as bytes — under
tmux's C locale git's paths arrive US-ASCII and the JSON's UTF-8, and a non-ASCII pair
would raise.

All of a worktree's links are kept (`{path => [Link, …]}`, newest first by `startedAt`
→ parsed `procStart` → pid; a bad ordering field only demotes). A link idle past
`remote_link_stale_after` (minutes, default 120, global; `false`/0 off; invalid → 120)
renders its `⇅` **grey** (`LINK_STALE_FG`, `\e[90m`) — bold read identical in Will's
terminal — and ANY stale link greys the row, so an old forgotten link can't hide behind
a newer busy one. A live link is **green** (`LINK_LIVE_FG`, `\e[32m`): the default fg read
too close to the grey. Background jobs (`kind: "bg"`, apparently always bridged) show the
glyph but are never stale. Under the reverse-video cursor bar the `⇅` is uncolored like
the dots: a color code inside `\e[7m` paints the cell's BACKGROUND (fg/bg swap), an
off-shade block in the bar (keeping colors there is a TODOS.md item). Truncation: `fit_plain` gives up NAME columns, never the trailing cues
(the old `trunc(plain(node))` cut `⇅`/`▸N` first, so they vanished under the cursor bar
on a long name); the cues drop only when no name column would remain. The home
`console` adds `N idle links` and `N linked`, and given `cols` drops WHOLE clauses
(`linked` → `PRs` → `active`) before it would cut mid-word — the idle-link warning
always seats at 40 cols. `doctor` is the canary (`RemoteLink.health`): 0 files while a
Claude process runs (the dir moved — 0 with nothing open is normal, since Claude removes
its file on exit), files but none in the expected shape (format changed), or EVERY live
Claude pid failing the start-time match (`procStart` format drifted; a single drift is a
recycled pid). Only pids whose process IS Claude count (`claude_pids`: argv[0] or the
node script named `claude`, not a substring), and it warns when this shell's
`CLAUDE_CONFIG_DIR` differs from tmux's (sidebars never read your rc). A
RENAMED `bridgeSessionId` key is undetectable — it reads as "nothing linked". The
sandbox seeds a link on `quiet-cleanup` (`Sandbox.seed_link`: a `sleep` parked in the
worktree in a detached non-`sb/` session, so its kernel cwd is right and it dies with the
server); a real `claude /rc` inside the sandbox writes the real `~/.claude` and isn't
shown. Codex has no per-session equivalent (`codex remote-control` is a separate
app-server process). Proven end to end by `test/smoke/remote_link_smoke_test.rb`.

**`p` draws the link as a QR code** (`@link_view`, transient like `@help`). The encoder is
`QR` (`qr.rb`): zero gems, byte mode, EC level M, versions 1-6 (a link URL is at most 95
bytes, so there are no version-information blocks), pinned module for module by
`qrencode -8` fixtures with each mask forced. Which mask it picks is pinned by
hand-worked penalty cases, not by another encoder's choice: encoders legitimately differ
on rule 3 (libqrencode#220), and segno pads differently (an extra `0x00` before the
`0xEC/0x11` run), so neither is a bit-exact reference for that. The overlay leads with the tree's own `header`
(full at home or with `H`, but only the wordmark when the full one would cost the code or the URL),
then the workspace name; no session name, since Claude defaults it to
the workspace's FIRST name, stale after a rename. The code is drawn in half blocks
in the theme's ANSI 0/15 (picked by eye and scanned; the fixed 256-color 16/231 pair
looked wrong in a themed terminal), with a quiet zone as wide as fits up to 4 and never
under 2, centered in a wider pane; a pane that can't fit it shows the URL instead. The
link is held by pid + `bridge_id`, not index (a crash leftover can share its resumed session's
bridge id), and every scan re-checks it (`revalidate_link_view`): the same session stays
through a re-sort and a reconnect (same pid, new bridge id) and follows its workspace through a rename (another workspace renamed onto
the old path doesn't take over the QR), an ended one falls back to the newest left, and the
last one ending closes the overlay. Whatever closes an overlay (a key, or a scan finding the link ended) drops the rest of that read's keys, but not its tmux pokes. Every name the sidebar draws (projects, workspaces, branches, the greeting's git name, the QR header) goes through `shown`: controls and bidi stripped, accents kept. Never `flash` there: it blocks on a keypress inside
the scan. For that check to mean anything, `@links` is hydrated in `refresh_agents`'
`ensure`, so links refresh even when the dot scan raises. Unlike the `?` overlay, the tmux
pokes keep running under it (`poke`), so switching back to a session re-checks its link at
once. `p` on a row without a link does nothing (the missing `⇅` already says so). Building the
overlay frame is rescued (`link_view_frame`): an input nobody foresaw closes the QR and repaints
the tree instead of killing the pane; every specific hardening still has its own test. The URL
is account-gated, not a bearer link: opened in a logged-out browser it lands on the claude.ai
sign-in page (checked 2026-10-24), so a QR on screen only helps someone already signed in as you.
`:phone_link` sits LAST in `Keymap::ACTIONS`, because an earlier action's default beats a
later one's remap: added mid-list, `p` would have taken the key from anyone who had remapped
`rename` (or any later action) to it.

### Waiting on background work (the ◷ — observed, not declared)

Sessions-file `status` contract last verified live against **Claude Code 2.1.308–2.1.310**
(v0.56.0), re-checked live on 2.1.311–2.1.312 (a background agent's hand-off held its
chime) — tracked apart from the hook contract and the ⇅ link; the security monitor
(`docs/howto-security-monitor.md`) watches it.

Claude hands work to a background agent / background Bash / the Monitor tool and ends its
turn: the Stop writes `done`, a green `●` and a chime — for work still running. No hook
EVENT says so (the Stop payload does carry a `background_tasks` key, seen on 2.1.310 but
its values never probed — a TODOS.md item), but the sessions file the ⇅ reads can: after such a turn `status` STAYS `busy` (a background agent — Claude never rewrites
it at the Stop, so `statusUpdatedAt` is the turn's start) or reads `shell` (Bash, Monitor);
probed live on 2.1.310, design + review + probe logs in
`thoughts/background-wait-glyph.md`. `ClaudeSessions.activity` turns one worktree's live
sessions into `:offstage` (any busy/shell), `:idle` (every one idle for ≥ `SETTLE`) or nil
(no evidence: missing/unknown status, `waiting`, a fresh idle). Exact strings only.

- **Render.** `render_state` draws `:offstage` (◷, `OFFSTAGE` = `SPIN_COLORED`'s exact
  `\e[1;34m`, steady — off the pulse cadence) over a resting, hooked `done`, never over
  thinking/waiting, never on a hook-less row (its session reads `busy` through every
  foreground turn too, so with no `done` there's no hand-off); ∞ outranks it (a monitor always reads `shell`). The
  internal name is `offstage`, not "background": `Link#bg?` already means a session that IS
  a background job. The legend says `◷ waiting on background work`.
- **The settle window.** Claude writes `done` 13–29ms BEFORE `idle` on a normal turn end, and
  a finished background agent reads `idle` ~15ms before its follow-up turn's `busy`. A 3s scan
  lands in those ~1% of the time, so: ◷ draws only when the hook's report is ≥ `SETTLE` (2s)
  old (`AgentState#last_hook_ages`; past `PRESENCE_TTL` the report has no age — a background
  job writes no main-agent hook — so `Edges#last_state`'s sticky `:done` stands in), and a hold
  matures only on an idle that old. Nothing on disk changes when a `done` settles, so the warm
  fingerprint's hook term carries a per-file settled bit (`hook_fingerprint`), and
  `ClaudeSessions.fingerprint` moves when a TRACKED session crosses offstage↔not (never for a
  Claude outside switchboard).
- **The held chime** (`OffstageHold`, `offstage_hold.rb`, a `KeyedMarkerStore` twin of
  Attention keyed by realpath, content `realpath\tepoch\tpid`). A `:done` edge whose path is
  reading `busy` (unsettled — the edge scan usually lands inside the window) is a hand-off to
  a background AGENT (`ClaudeSessions::HANDOFF_STATUS`; `@offstage_raw` holds only these).
  `shell` draws ◷ but never holds: a background shell may never end (a dev server), and a
  hold beside it would mute that turn — and, as review found, every heuristic for telling a
  long-lived shell from a short job leaked (per-process memory, respawns, chained turns). An
  agent always reports back with a follow-up turn, so its hold always resolves.
  `Edges#on_scan` writes the hold instead of ringing/bolding, on EVERY scan (warm + catch-up
  too). ON DISK because the pane on screen at the finish may never have seen the edge — its
  baseline already read `done` (Codex review O1; a per-process hold lost it).
  `Edges#settle_holds` resolves each hold every scan: the hook leaving `done` (the follow-up
  turn — the usual end, since Claude runs a normal UserPromptSubmit → Stop turn when the result
  arrives) releases it silently and that turn's Stop rings normally — but only from an
  announcing scan: an off-screen pane can catch a short follow-up turn the on-screen pane's
  3s scans miss, and left held it matures for the on-screen pane instead (late, if no pane
  was on screen through the follow-up — a TODOS.md item). A normal `:done` an ANNOUNCING scan
  rings also releases the path's hold (`release_rung_holds`): one another pane wrote inside
  the done-before-idle race would ring that end twice. Never a silent pane: one that sees the
  hand-off edge late, after the work ended, reads it as a plain completion and would take
  the only ring with it (Codex adversarial review). Nothing releases on a failed session read
  (`sessions_ok:`). A settled `idle` or the recorded pid gone
  (kill(0)) matures it; ANYTHING else — a failed read, an unknown status, an out-of-range
  pid — keeps holding (O2: absence of evidence is not "finished"). A hold that fails to land
  rings at once instead (early beats never). Only an announcing (on-screen)
  scan claims a mature hold, by unlink (exactly one wins), and only the claimer rings AND
  bolds — an off-screen pane bolding could re-bold a workspace you just viewed, in the moment
  before the on-screen pane claims. Monitored and first-turn paths never hold (already
  suppressed). Carried on rename, wiped on quit (both quit paths).
- **The dispatch ping.** `ring_creations` defers a `turn_done` record's ring (O3;
  `dispatch_waiting?`) only on POSITIVE evidence a background agent is still at work: `busy`,
  or an idle too fresh to trust (`@session_fresh`, the ~15ms before its follow-up turn) — not
  `shell`, for the dev-server reason above. Missing evidence — no session, a failed read, a
  drifted `status` — rings, as before the ◷: nobody saw this ping deferred, so the hold's
  absence-isn't-finished rule doesn't apply, and failing closed would silence every dispatch
  if the undocumented file changed. `ready` (a launch) and ✘ never wait. A
  dispatched task that fans out on turn one would otherwise ping "done" at the hand-off; the
  ring is durable, so it fires once the work ends.
- **One read, no machine-wide forks.** `refresh_agents` runs `ClaudeSessions.scan` right after
  the hook read (before it, its ps/lsof would widen the done-before-idle race) and before
  `on_scan` (nil
  on failure — not `{}`, which would read as "finished") and hands the same result to
  `RemoteLink.scan(sessions:)` in the ensure. The scan pre-filters by recorded cwd (raw or
  realpath) against the TRACKED ws paths before any kill(0)/ps/lsof: `same?` is one `ps` per
  session (batching measured no faster) and 15 Claudes = ~125ms per 3s scan (D10 — config roots
  would drop git-discovered worktrees outside `worktree_root`, Codex O4). Renames pass via the
  bridge symlink.


## Related

- [Reference: reading the sidebar](reference-sidebar.md) — the dot glyphs, the sparkle, and the bold name as they render in the row.
- [How-to: agent state & sounds](howto-agent-state-and-sounds.md) — enable hooks, pick sounds.
- [Explanation: sidebar lifecycle](explanation-sidebar-lifecycle.md) — why state is multi-process on disk.
- [Reference: config](reference-config.md#sounds) — the `sounds` and `agent_state_hooks` knobs.
