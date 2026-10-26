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
codex-cli 0.164.0: the payload fields, delivery in linked worktrees, the
nesting-guard environment, and a silent `PermissionRequest` hook leaving the
prompt to you.

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
