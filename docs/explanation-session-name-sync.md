# Explanation: session-name sync

How a workspace rename reaches the Claude session's own name by typing `/rename` into
its pane, and why every step fails closed. This is the full implementation detail [CLAUDE.md](../CLAUDE.md) summarizes; keep the two in step.

Claude names a session after the workspace's FIRST name and never follows a rename, so the
phone's session list and the resume picker went stale after every `r`. There's no API (the
session file is read-only to us; `/rename` is a local CLI command), so `Rename.perform` — on
`:ok`/`:partial`/`:unchanged`, only with `ENV["TMUX"]` set (the offline suite's spawn gate)
and `sync_session_name_for` on — spawns `switchboard sync-session-name <dest> <leaf>`, a
daemonized `SessionName.work` (`session_name.rb`) that types `/rename <leaf>` into each live
Claude session in the workspace. `Result#spawned` makes the CLI tell the agent the "session
renamed" note it's about to see is ours. A same-name rename is the retry.

The typing rule is the whole design; every step fails closed (wait, never guess), pinned by
real 2.1.310 captures in `test/fixtures/session_name` and confirmed live on 2.1.312 (the
sidebar's `r`, the pane in view):
- **Between turns only** (`status` idle/shell). Mid-turn a permission modal can open in the
  instant before our Enter, and Enter APPROVES it; from idle a modal needs a model round trip.
  Every key send re-reads the pane (tmux), the box and the status after the slower checks, then
  the same Claude (pid + start time) holding the foreground, then the pane ONCE MORE (focus is the
  gate most likely to move, one key or a click, so it's read again after the slow `ps`) — before
  typing (a turn starting during the slower checks could open a prompt our characters answer: a
  digit picks an option), before Enter, and before backspaces.
- **Nobody at the keyboard, tri-state, and Claude's terminal.** `Tmux.panes_by_tty` reads two
  gates as true/false/nil (unparseable = maybe): `focused` (the active pane of the active window of
  an attached session: where a client's keys go) and `recent_input` (ANY client on the server had
  keys or mouse input in the last `INPUT_QUIET` = 2 s, from `list-clients`' `client_activity`, whole
  seconds so the check is `<=`: a wheel or click lands on the pane under the pointer, verified live
  to bump it; someone mid-keystroke is about to move; and a `send-keys` binding in one session can
  type into another session's pane, so it's server-wide, not per session). Not visibility: after the sidebar's `r` the agent's pane is in
  view but the keyboard is on the sidebar, and the old off-screen gate made you leave the session
  to let it land. A client that can key some other pane makes its session read unknown (never
  typed into): a control-mode client (iTerm2's `tmux -CC`, which shows every pane and keys any of
  them by %id) or one carrying the `active-pane` client flag some tmux 3.x releases have (its own
  active pane, not the window's; 3.8 has no such flag). `Tmux.visible?` reads an empty reply as hidden, so it isn't reused. The pane is found by the process's tty — a dispatched agent is a grandchild of
  the pane. The pane must not be in a tmux mode (copy mode eats keys) or synchronized
  (synchronize-panes copies keys to every sibling), our line must fit its width, and Claude must
  still be on the PANE's tty, running, and hold its foreground process group (one `ps` read of tty,
  stat, pgid, tpgid: a ^Z'd Claude's last box can still be on screen, a Claude moved to another
  terminal with reptyr owns THAT one's foreground while its old frame sits in our pane, and one
  SIGSTOPped alone keeps its group in front while our keys queue for the next reader). Interactive sessions only (`kind` allowlist).
- **Empty box.** `SessionName::Box` parses the region between the LAST two divider lines (the
  upper one carries the name), tracking SGR across lines (tmux carries the placeholder's dim
  over the break). Claude pads `❯` with an NBSP. A modal's cursor draws `❯` too, hence the
  dividers.
- **Enter only on an exact `❯ /rename <leaf>`**, every gate re-read first: the box + status after
  the slower `ps`/tmux checks (a turn starting meanwhile could open a permission prompt that Enter
  would approve; the tty must still name the same %id — tmux recycles them), then LAST the same
  Claude (pid + start time) holding the foreground (a ^Z or crash hands Enter to a shell, and a dead
  Claude's frame and session file both outlive it), then the pane once more. Otherwise back out
  exactly our line with BSpace ONLY IF NOBODY HAS TOUCHED A KEY SINCE WE TYPED (`untouched?`, read
  first and last: the pane unfocused, and no client input since `sent_at` — `last_input`, the newest
  `client_activity` of any client, whole seconds, so a key in the same second counts; unknown is no;
  `last_input` also counts every session's `session_activity`: a client that types and detaches takes
  its `client_activity` with it, but its session keeps the stamp; the session ids snapshotted just
  before the send must all still exist, so a killed session can't take it either).
  Accepted residual (dec-76a1b9be, like a racing `send-keys`): a script that creates a session linked
  to Claude's window after the snapshot, types through it and destroys it inside the checks leaves no
  trace tmux exposes.
  Three review rounds found ways backspaces into a pane someone might be at could eat their keys
  (Claude draws a key ~130 ms after it arrives; `Box.parse` strips a trailing space; focus can move in
  and out during the slow `ps` checks); that one rule closes the class instead of patching each. A
  prefix still showing after the settle is left too, since it can't be told from someone's own
  `/re…`. Otherwise leave it (`failed_send`) and post a notice held `LEFTOVER_MS` (a key clears it,
  like any notice; NEVER `-N`, which discards the client's keys until it expires — verified) to every
  attached client (`Tmux.notify_everyone`: the worker's own current client may be a session nobody is
  in) when any `/rename` or a prefix of ours is in the box, read across wrapped rows
  (`Box.region_text`): with someone's words appended, their Enter would run it. A clean back-out
  isn't spent but backs that session off 2, 4, 8… full passes (`BACKOFF_CAP`; passes are 2 s apart
  for the first 5 minutes, up to 30 s after). Enter, too, waits on `untouched?` (a key `Box.parse` can't
  see would ride in with it). A held session still
  gets a read-only box check, so OUR exact line left there is reported as a leftover (a `/rename`
  someone is typing themselves is theirs). An `ensure` backs out on a crash. A vim-mode footer reads
  as no box.
- **Settling waits out an empty box.** Right after typing the box can still read empty (render
  latency ~130 ms); settle and back-out keep polling through empty/prefix boxes (~1.2 s), and a
  back-out only counts as clean once the box reads empty again.
- **At most one Enter per session per worker.** Only a clean back-out may retry; `failed_send` or
  an Enter Claude never confirms (`unconfirmed`) spends the session for that worker. A spent worker
  keeps WATCHING (never typing) until the ceiling, so a late confirmation still ends as done, and a
  spent session that exits stops counting. A retry YOU run (same-name rename) is a new worker and may try once more (by
  decision). This rule is what ended the review's retry loops — don't add a retry around it.
- **Known gap (dec-2679bd5a):** a Claude dialog with a text field drawn like the main prompt would
  pass `Box.parse` — TODOS.md has the fix (capture one, anchor on the main prompt's footer).
- Sessions come from `ClaudeSessions.sessions_in` (the ◷/⇅ reader, stricter): full pid+start-time check and the KERNEL cwd only
  (no recorded-cwd fallback), rediscovered every poll; a per-pid flock keeps two workers apart.

Polls every 2 s for 5 min (switching away is often what lets it land), then doubles to 30 s, giving up after an hour. A pass held only by someone at the keyboard (`:held`: focused, or input just now) keeps 2 s polls but each is ONE pane read (`list-panes` + `list-clients`) of those ttys (`still_held?`), not a full pass of `ps`/`lsof` per session; a full pass still runs every `SLOW_CAP` (a session can exit or start meanwhile). Latest wins: a newer
rename leaves a bridge symlink at `dest` (`superseded?`, re-checked inside the per-pid lock), and a
newer worker for the same workspace takes `SessionName::Owner`'s claim, so a retried rename
replaces the running worker (claims are swept by pid liveness, never deleted by their owner — a
check-then-delete raced the next claim — and a missing claim reads as still ours). A worker
superseded mid-pass writes no outcome: its `dest` is a bridge to the new workspace's key. The pane
snapshot is re-read right before typing (it can be seconds old in a multi-session workspace). A couldn't-tell answer (lsof answering for nobody, or missing a session whose
recorded cwd is in this workspace; ps failing; an unwritable lock dir; a nil capture) waits; two
empty scans in a row (or one at the ceiling) end the worker (`:gone`, which clears the marker —
nobody left means nothing failed). `sessions_in` skips sessions in a worktree NESTED inside this
one (a `.git` between the cwd and the root: `claude --worktree`). A back-out re-reads like the Enter gate — untouched (same %id on the tty, no tmux mode, not
synchronized, unfocused, no input since our send), the box (exactly our line), the status
(idle/busy/shell — never a modal or an unknown one), the same Claude in the foreground, then
untouched once more; any miss leaves the text as `failed_send` — then takes back our line, and only a box
read empty again counts as clean. Failures (`failed_send`, `unconfirmed`, `unrecognized`, `ceiling`) are
`SessionName::Outcome` markers (KeyedMarkerStore, realpath-keyed) that `doctor` lists with the
retry; a success clears them. A marker is the NEWEST worker's verdict (one per pass, failed_send first; the worker keys it by
the realpath it started with and writes nothing once superseded or retired), decided by evidence — no
ranking or carrying between workers (two review passes of sticky/carry rules each grew new
corners): at the ceiling, a box still holding any `/rename …` is `failed_send` (a `:leftover`
pass), so leftover text is reported by whichever worker finds it; a rename just forgets the old
path's marker. Rename only spawns (in its own process group, so an agent's tool runner can't kill
it before it daemonizes) for a leaf `SessionName::NAME` accepts, a case-only rename syncs the case
the dir kept, and the public `sync-session-name` verb refuses any dest that isn't a non-primary
switchboard worktree. `RemoteLink.health` `odd_status`/`unnamed`/`unknown_kind` are the
canaries for Claude changing the `status`/`name`/`kind` fields. A crash in the worker records an
`error` verdict (never a silent exit), and a worker whose `dest` was already renamed again when it
booted exits before claiming (claiming through the bridge would take the newest worker's claim). The sidebar's `r` posts a status-line
notice when it spawned a worker (the CLI prints one for the agent). Codex is a TODO (its app-server's `thread/name/set`). The smoke test drives a
stand-in TUI (`test/smoke/fake_claude.rb`) — no test runs real Claude.

## Related

- [Explanation: agent presence](explanation-agent-presence.md) — the sessions file this reads.
- [How-to: run the security monitor](howto-security-monitor.md) — the live check after a Claude update.
