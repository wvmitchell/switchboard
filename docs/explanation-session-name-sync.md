# Explanation: session-name sync

When you rename a workspace, switchboard also renames the Claude session running in it.
It does that by typing `/rename <name>` into Claude's pane, the same as you would. This
explains why it has to type, and why every step of the typing is built to wait rather
than guess.

## The problem

Claude names a session after the workspace's *first* name and never follows a rename.
So after every `r`, the session list on your phone and Claude's resume picker showed the
old name.

There's no API to fix that from outside. The session file is read-only to us, and
`/rename` is a local CLI command, not something we can call. The only way in is the
keyboard.

## The approach: a background worker that types

On a successful rename (`:ok`, `:partial` or `:unchanged`), `Rename.perform` spawns
`switchboard sync-session-name <dest> <leaf>`. That runs `SessionName.work`
(`session_name.rb`) as a daemon, which types `/rename <leaf>` into each live Claude
session in the workspace. It only spawns when `ENV["TMUX"]` is set (which also keeps the
offline test suite from spawning it) and `sync_session_name_for` is on.

A few details around the spawn:

- **The agent is told.** `Result#spawned` makes the CLI tell the agent that the
  "session renamed" note it's about to see came from us.
- **The sidebar says so too.** The sidebar's `r` posts a status-line notice when it
  spawned a worker.
- **Retrying is just renaming again.** A same-name rename starts a fresh worker.
- **It survives the caller.** The worker spawns in its own process group, so an agent's
  tool runner can't kill it before it daemonizes.
- **It only accepts real names and real worktrees.** Rename spawns only for a leaf that
  `SessionName::NAME` accepts. A case-only rename syncs the case the directory kept. The
  public `sync-session-name` command refuses any `dest` that isn't a non-primary
  switchboard worktree.

Only Claude sessions are renamed; a Codex session keeps its first name.

## Why typing has to be careful

Typing into someone else's terminal can go wrong in ways that cost real work:

- **Enter approves things.** If a permission prompt opens in the instant before our
  Enter, our Enter approves it.
- **Characters answer prompts.** If a turn starts while we're checking, a prompt can
  open that our characters answer. A digit picks an option.
- **Backspaces can eat your keys.** If you're typing in that pane, a back-out can delete
  what you typed.

So the rule for the whole design is: **every check fails closed.** If switchboard can't
tell whether it's safe, it waits. The behavior is pinned by real Claude screen captures
in `test/fixtures/session_name` and confirmed live
([versions](../CLAUDE.md#upstream-contracts-last-verified)). No test runs real Claude; the
smoke test drives a stand-in TUI, `test/smoke/fake_claude.rb`.

## The gates

Before switchboard types anything, all of these have to hold.

### Claude is between turns

Claude's `status` must be idle or shell. Mid-turn, a permission modal can open at any
moment. From idle, opening one takes a model round trip, which gives the checks time to
see it coming. Only interactive sessions qualify (an allowlist on `kind`).

### Nobody is at the keyboard

`Tmux.panes_by_tty` reads two gates. Each answer is true, false, or unknown (an
unparseable reply), and unknown counts as "maybe someone is there":

- **`focused`:** the pane is the active pane of the active window of an attached
  session, which is where a client's keys go.
- **`recent_input`:** any client on the server had key or mouse input in the last
  `INPUT_QUIET` (2 seconds), read from `list-clients`' `client_activity`. The stamp is in
  whole seconds, so the check uses `<=`. Mouse input counts because a wheel or click
  lands on the pane under the pointer (verified live to bump the stamp), and someone
  mid-keystroke is about to move. It's server-wide, not per session, because a
  `send-keys` binding in one session can type into another session's pane.

The gate is focus, not visibility. After you press `r` in the sidebar, the agent's pane
is on screen but your keyboard is on the sidebar. An older version gated on "off
screen", which meant you had to leave the session before the rename could land.

Some clients can send keys to a pane that isn't the window's active one, so a session
with one of them attached reads as unknown and is never typed into:

- a control-mode client, such as iTerm2's `tmux -CC`, which shows every pane and can key
  any of them by `%id`;
- a client with the `active-pane` flag that some tmux 3.x releases have (tmux 3.8
  doesn't), which keeps its own active pane.

`Tmux.visible?` isn't reused here because it reads an empty reply as hidden, and here
empty has to mean unknown.

### It's the right pane and the right Claude

The pane is found by the Claude process's tty, since a dispatched agent is a grandchild
of the pane, not its direct child. Then:

- **The pane is in normal mode.** Copy mode would swallow the keys.
- **The pane isn't synchronized.** synchronize-panes would copy our keys into every
  sibling pane.
- **Our line fits the pane's width.**
- **Claude is still in charge of that terminal.** One `ps` read of tty, stat, pgid and
  tpgid confirms it's still on the pane's tty, still running, and holds the terminal's
  foreground process group. Each of these has caught a real case:
  - a suspended (`^Z`) Claude can leave its last prompt box on screen;
  - a Claude moved to another terminal with `reptyr` owns *that* terminal's foreground,
    while its old frame still sits in our pane;
  - a Claude stopped on its own with SIGSTOP keeps its group in front, while our keys
    would queue for whoever reads next.

### The prompt box is empty

`SessionName::Box` finds Claude's input box and checks that it's empty. It parses the
region between the *last* two divider lines; the upper divider carries the session name.
It anchors on the dividers because a modal's cursor also draws `❯`, so the arrow alone
can't tell the main prompt from a dialog. Two rendering details matter:

- **Styles carry across lines.** tmux carries the placeholder text's dim style over the
  line break, so the parser tracks SGR state from line to line.
- **Claude pads `❯` with a non-breaking space.**

A vim-mode footer reads as no box at all.

### Every gate is read again before every key

Checks take time, mostly the `ps` and `lsof` calls, and the world can change while they
run. So before each send (the typing, the Enter, and any backspaces), switchboard
re-reads the gates in a fixed order:

1. the pane, through tmux;
2. the box and the status, after the slower checks, since a turn could have started;
3. that the same Claude (pid plus start time) still holds the foreground;
4. the pane once more.

Focus is read last because it's the gate most likely to move: one key or one click
changes it.

## Sending Enter, or backing out

After typing, switchboard waits for the box to show the text. Claude takes about 130 ms
to draw a key, so right after typing the box can still read empty. Settling and backing
out both keep polling through empty or partly drawn boxes, for about 1.2 seconds.

**Enter is pressed only on an exact `❯ /rename <leaf>`,** with every gate re-read first:

- the box and the status, after the slower `ps` and tmux checks, since a permission
  prompt that opened meanwhile would be approved by Enter;
- the same `%id` still on the tty, since tmux recycles pane ids;
- last, the same Claude holding the foreground, because a `^Z` or a crash would hand our
  Enter to a shell, and a dead Claude's frame and session file both outlive it;
- then the pane once more.

Enter also waits on `untouched?` (below), because a key that `Box.parse` can't see would
ride in with it.

**If anything is off, switchboard backs out its own line,** but only if nobody has
touched a key since it typed. That's `untouched?`, read both first and last:

- the pane is unfocused;
- no client input since `sent_at`. This uses `last_input`, the newest `client_activity`
  of any client. Whole seconds, so a key in the same second counts, and unknown counts as
  "touched." `last_input` also counts every session's `session_activity`, because a
  client that types and then detaches takes its `client_activity` with it, but its
  session keeps the stamp. The session ids snapshotted just before the send must all
  still exist, so a killed session can't take the evidence with it either.

A back-out re-reads the same gates as Enter: untouched (same `%id`, no tmux mode, not
synchronized, unfocused, no input since our send), the box holding exactly our line, the
status (idle, busy or shell, never a modal or an unknown status), the same Claude in
front, then untouched once more. Only then does it take back our line, and the back-out
counts as clean only once the box reads empty again.

Why one blanket rule instead of a list of special cases: three review rounds each found
a new way backspaces into a pane someone might be using could eat their keys. Claude
draws a key about 130 ms after it arrives, `Box.parse` strips a trailing space, and focus
can move in and out during the slow `ps` checks. "Never back out if anyone touched a
key" closes the whole class at once. A prefix of our text still showing after the settle
is left alone too, since it can't be told apart from someone's own `/re…`.

**If it can't back out, it leaves the text and says so.** The pass is marked
`failed_send`, and switchboard posts a notice to every attached client
(`Tmux.notify_everyone`, since the worker's own current client may be a session nobody's
in). The notice fires when the box holds any `/rename` or a prefix of ours, read across
wrapped rows (`Box.region_text`), because with someone's words appended, their next
Enter would run it. It holds for `LEFTOVER_MS` (10 seconds), and a key clears it like any
notice. It never uses `display-message -N`, which discards the client's keys until the
message expires (verified).

A session that's held off still gets a read-only box check each pass. So our exact line
left behind is reported as a leftover, while a `/rename` someone is typing themselves is
left as theirs. If the worker crashes mid-send, an `ensure` backs out.

## At most one Enter per session per worker

Only a clean back-out may try again. A `failed_send`, or an Enter that Claude never
confirms (`unconfirmed`), spends that session for this worker.

A clean back-out isn't spent, but that session is backed off for 2, 4, 8… full passes,
capped at `BACKOFF_CAP`.

A worker whose sessions are all spent keeps *watching*, never typing, until the time
limit, so a late confirmation still ends as done. A spent session that exits stops
counting.

A retry *you* run (renaming to the same name again) is a new worker, so it may try once
more. That's deliberate.

This rule is what ended the retry loops earlier reviews kept finding. Don't add a retry
around it.

## How long it keeps trying

The worker polls every 2 seconds for the first 5 minutes; switching away from the session
is often what lets the rename land. After that it doubles the interval up to 30 seconds
(`SLOW_CAP`), and gives up after an hour (`CEILING`).

When the only thing holding a pass is someone at the keyboard (`:held`: the pane is
focused, or there was input just now), it keeps 2-second polls, but each one is a single
pane read (`list-panes` plus `list-clients`) of those ttys (`still_held?`), not a full
pass with `ps` and `lsof` per session. A full pass still runs every `SLOW_CAP`, since a
session can exit or start in the meantime.

The pane snapshot is re-read right before typing, since in a workspace with several
sessions it can be seconds old.

## Which sessions it types into

Sessions come from `ClaudeSessions.sessions_in`, the same reader behind the ◷ and ⇅
glyphs, used here in its stricter form:

- **A full identity check.** The pid and its start time must match.
- **The kernel's cwd only.** There's no fallback to the cwd Claude recorded.
- **Rediscovered every poll.**
- **Nested worktrees are skipped.** A session in a worktree nested inside this one (a
  `.git` between the cwd and the root, as `claude --worktree` creates) belongs to that
  worktree.

A per-pid flock keeps two workers from typing into the same session.

## The latest rename wins

If you rename again while a worker is running, the newer one takes over:

- **The old path points at the new one.** The newer rename leaves a bridge symlink at
  the old `dest` (`superseded?`, checked again inside the per-pid lock).
- **The newest worker holds the claim.** A newer worker for the same workspace takes
  `SessionName::Owner`'s claim, so a retried rename replaces the running worker.
- **Claims are swept, never deleted by their owner.** Stale claims are swept by pid
  liveness, because a check-then-delete raced the next claim. A missing claim reads as
  still ours.
- **A superseded worker writes no outcome.** Its `dest` is now a bridge to the new
  workspace.
- **A late-booting worker steps aside.** A worker whose `dest` was renamed again before
  it even booted exits before claiming, since claiming through the bridge would take the
  newest worker's claim.

## When it can't tell, it waits

Any "couldn't tell" answer makes the worker wait rather than act:

- `lsof` answering for nobody, or missing a session whose recorded cwd is in this
  workspace;
- `ps` failing;
- an unwritable lock directory;
- a capture that returns nothing.

Two empty scans in a row (or one at the time limit) end the worker as `:gone`, which
clears the marker: nobody left means nothing failed.

## Outcomes and `doctor`

Failures (`failed_send`, `unconfirmed`, `unrecognized`, `ceiling`) are recorded as
`SessionName::Outcome` markers, a `KeyedMarkerStore` keyed by realpath. `doctor` lists
them along with how to retry, and a success clears them. A crash in the worker records
an `error` verdict, so it never exits silently.

A marker is the *newest* worker's verdict. The worker keys it by the realpath it started
with, writes one per pass (`failed_send` first), and writes nothing once it's superseded
or retired. The verdict comes from evidence alone. There's no ranking, and nothing
carries over between workers; two review passes tried sticky and carry-over rules, and
each grew new corner cases. At the time limit, a box still holding any `/rename …` is a
`failed_send` (a `:leftover` pass), so leftover text is reported by whichever worker
finds it. A rename simply forgets the old path's marker.

`RemoteLink.health`'s `odd_status`, `unnamed` and `unknown_kind` are canaries for
Claude changing the `status`, `name` or `kind` fields this depends on.

## Known gaps and accepted risks

- **A dialog that looks like the prompt.** A Claude dialog with a text field drawn
  exactly like the main prompt would pass `Box.parse`. (dec-2679bd5a)
- **A short-lived linked session.** A script that creates a session linked to Claude's
  window after the snapshot, types through it and destroys it, all inside the checks,
  leaves no trace tmux exposes. That's accepted, like a racing `send-keys`. (dec-76a1b9be)

## Related

- [Explanation: agent presence](explanation-agent-presence.md) — the sessions file this reads.
- [How-to: run the security monitor](howto-security-monitor.md) — the live check after a Claude update.
