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

Claude Code can run a hook command on each lifecycle event. Switchboard installs
a tiny POSIX-sh reporter (`Hook::SCRIPT`) that writes one line —
`<state>\t<cwd>\t<epoch>` — into the state dir. The sidebar reads those files.

The mapping (`Hook::EVENTS`) is the interesting part:

- `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure` → **thinking**.
  `PreToolUse` fires *before* a tool runs, and the permission prompt comes *after*
  it — so it can't be what clears the "waiting" state. `PostToolUse` and
  `PostToolUseFailure` fire *after* the granted tool runs (whichever way it went),
  the earliest hook past the prompt — so the dot flips back to blue once work
  actually resumes.
- `Notification` → the special **notify** mode. The reporter reads the whole
  payload off stdin and glob-matches it for the `permission_prompt` /
  `elicitation_dialog` type tokens (`case "$(cat)" in *permission_prompt*…` — a
  substring match, not a JSON-field parse), reporting **waiting** only when one is
  present; the idle timer and everything else fall through to **done**. Matching
  those structured type tokens rather than the human-readable message wording
  holds up across Claude releases, and defaulting to the calm state means an
  unrecognized notification never false-alarms magenta.
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

For agents that don't report hooks (Codex, Aider, or Claude before
`enable-hooks`), `Agents.active` finds agent CLIs by scanning tmux panes by
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
hooked). So a hooked Claude gets exact state, an un-hooked Codex still gets a
busy/idle dot, and the two never fight. The result is `Hash<worktree, state>`;
absent means idle (no dot).

## Hooks are wired per worktree, never globally

`Hook.enable` (`hook.rb`) merges switchboard's events into
`<worktree>/.claude/settings.local.json` — Claude merges that on top of your user
settings, so your global `~/.claude` is never touched. It also adds that file to
the worktree's local git excludes (`info/exclude`), so it never dirties
`git status`.

The reporter script itself lives in the XDG **data** dir
(`~/.local/share/switchboard/sb-agent-hook`) — an install-independent path that
survives a `git pull` or `brew upgrade`, unlike the checkout. It's rewritten
whenever it's missing or stale (versioned in the script header), so an upgrade
self-heals the next time any worktree is enabled. New worktrees switchboard
creates get hooks automatically (`Creator.create` → `Hook.enable`, gated on
`agent_state_hooks?`); existing ones via `switchboard enable-hooks`.

## One edge, four consumers

When a worktree's hook state newly enters a resting state (`:done`/`:waiting`),
that's a *completion edge*. Four features ride the exact same edge
(`Sidebar.completion_edges`), in one place (`Sidebar#on_agent_edges`):

1. **Bold-until-viewed** (`attention.rb`) marks the workspace name bold — on
   every scan, since which process noticed doesn't matter (see below).
2. **PR refresh** re-fetches the badge — an agent finishing a turn is the best
   moment to catch a push.
3. **Diff-count refresh** repaints the row's `+adds −dels` — a finished turn
   likely just committed.
4. **Completion sound + sparkle** (`sound.rb`) play last, fully rescued so a
   sound fault can never starve the refreshes above, and gated so only the
   sidebar you're watching rings (a catch-up scan re-baselines silently).

The state cursor (`@prev_hook_states`) advances in an `ensure`, so a fault in any
consumer can't corrupt the next edge diff.

The completion-edge consumers ride the *hook* signal only, not the coarse activity fallback — because
the capture-hash flips `:thinking ⇄ :done` every few seconds and would fire on
noise. So observation-only agents show a dot but make no sound and trigger no
badge refresh on completion.

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
- **Per-worktree hooks** keep your global config clean at the cost of a wiring
  step per existing worktree (automatic only for ones switchboard creates).

## Related

- [Reference: reading the sidebar](reference-sidebar.md) — the dot glyphs, the sparkle, and the bold name as they render in the row.
- [How-to: agent state & sounds](howto-agent-state-and-sounds.md) — enable hooks, pick sounds.
- [Explanation: sidebar lifecycle](explanation-sidebar-lifecycle.md) — why state is multi-process on disk.
- [Reference: config](reference-config.md#sounds) — the `sounds` and `agent_state_hooks` knobs.
