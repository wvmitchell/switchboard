# Explanation: the sidebar's lifecycle

The sidebar feels like one persistent panel that follows you around. It isn't.
There's a **separate sidebar process per window**, most of them asleep at any
moment, coordinating through tmux hooks and on-disk state. This explains why it's
built that way, how a sidebar stays cheap while off screen, and the subtle bug
that the design exists to prevent.

This is the deepest part of the codebase. If you're changing visibility, poking,
or the run loop in `sidebar.rb`, read this first.

## Why one process per window

A tmux session has many windows. Each window that shows the sidebar runs its own
`switchboard sidebar` process in a `split-window` pane. There's no shared sidebar
daemon. That's the consequence of [letting tmux own the lifecycle](explanation-architecture.md):
the sidebar is just the binary re-invoked in a pane, and tmux spawns/kills it like
any other pane content.

The upside is simplicity — no IPC, no daemon to supervise. The cost is that
**state any sidebar needs to agree on must live outside the processes.** Three
features pay this cost by keeping state on disk, one file per item:

- **Agent dots** read the hook-state files (`AgentState`).
- **Bold-until-viewed** markers (`Attention`) — one file per worktree, so every
  window's sidebar bolds the same name.
- **Project collapse** folds (`Collapse`) — one file per collapsed project, so a
  fold made in one window shows in all of them and survives respawns.

All three use the same atomic write (temp + rename) so a peer process's scan never
reads a half-written file, and all three self-heal (a marker for a vanished
worktree is GC'd). `Attention` and `Collapse` share that machinery as one module —
`KeyedMarkerStore` (`keyed_marker_store.rb`): the crc32 file key, the atomic write,
and the scan-with-GC live there once, and each store supplies only its own value and
its keep-or-GC rule (Attention keys by worktree path and GCs when the dir is gone;
Collapse keys by project name and GCs against the configured list). The difference
between the two: attention markers are cleared on `quit` (a transient "you haven't
looked yet" flag), collapse folds are not (a durable view preference that should
persist across restarts).

The same on-disk reasoning covers the **global toggles** that aren't per-item, so
they skip the keyed store for a single flag file: the full header (`H` →
`FullHeader`), the global branch fold (`z` → `BranchFold`, which folds *every*
workspace's branch-history rows tree-wide — issue #107), and the pane width
(`←`/`→` → `Width`). Each is one shared file every window's sidebar reads, so a
flip in one pane shows in all of them and survives a respawn — and like the collapse
folds, all three are durable view preferences, **not** cleared on `quit`.

## Sidebar visibility is per-session, applied to every window

The intent "show the sidebar" lives on the *session* as a tmux option
(`@sb_sidebar` on/off; unset reads as on, preserving auto-show). One primitive,
`Tmux.reconcile_sidebars`, spawns-or-kills each window's sidebar to match that
flag:

- `prefix-s` (`Tmux.toggle_sidebar`) — switchboard's one summon/dismiss verb.
  Visible ⇒ dismiss session-wide; hidden ⇒ summon on every window *and* focus the
  tree. It flips the flag and reconciles every window.
- `ensure_session` stamps `on` on first creation.
- `go`/`go_home` reconcile to the saved flag on switch-in (and `go_home` always
  restores the navigator).
- New windows are handled by the `after-new-window[99]` hook → `sidebar-sync`,
  which spawns one iff the session opts in. No spawn recursion: the sidebar is a
  `split-window`, which fires `after-split-window`, not the hooked
  `after-new-window`.

## A shown sidebar still sleeps while off screen

Because every window keeps its own sidebar, at any moment most of them are on
*inactive* windows. A sidebar that painted and scanned agents continuously on
every window would be a lot of wasted work.

So each sidebar caches whether it's currently on screen in `@visible` (mutated
only via `set_visible`). `render`, the spinner/blink animation, and the agent
scan are all gated on it. `frame_timeout` drops an off-screen sidebar from the
`REFRESH` cadence (3s) to a long `IDLE` backstop (8s). An off-screen sidebar does
essentially nothing — no paint, no agent scan, one cheap visibility check per
`IDLE` tick — until something wakes it.

What wakes it is a **poke**: tmux sends the sidebar a `C-l` byte on the events
that mean "you might be visible now":

- `client-session-changed[99]` → `poke-sidebar` (a session switch).
- `session-window-changed[99]` → `poke-window` (a same-session window switch;
  gated to `sb/` sessions so the global hook no-ops elsewhere).

The `C-l` handler, `reload_and_refresh`, **re-samples** `Tmux.visible?` rather
than assuming the poke means on-screen. This matters because the same `C-l` is
*also* sent by background PR-refresh children (`maybe_refresh_prs --poke`) to a
pane you may have navigated away from — marking that hidden pane visible would
wrongly re-wake it. An un-poked reappearance (a window switch on a tmux too old
for the hook, a bare `tmux attach`) is caught by the off→on `reappeared` branch in
`tick` within one `IDLE` tick.

### Pre-warming: fresh on arrival, without the flash

Pure dormancy has a cost you can see: switch into a session and, for a beat, its
sidebar shows whatever it last painted — maybe minutes ago — until the switch-in
poke reloads and repaints. That stale-then-snap is the flash.

Pre-warming removes it for the common case. The trick is that a tmux pane keeps
its screen grid even while off screen, so you can paint a hidden pane *before* the
user arrives and the fresh frame is already there on switch-in. So the off-screen
branch of `tick` does a small amount of work again — but only when it's worth it.
Three cheap gates, cheapest first: the `prewarm` config knob (on by default), a
`WARM_TTL` throttle (so a busy agent off screen can't make us reload every wake),
and a `warm_fingerprint` — a stat-only signal (file names + mtimes of the
agent-state, attention, and PR-cache dirs, plus each worktree's `logs/HEAD`) that
tells us whether anything the pane draws actually changed. Nothing changed → it
stays as dormant as before. Something moved → it does one quiet reload and repaint
into the hidden buffer.

"Quiet" is doing real work here, because the obvious implementation (just call the
normal `reload` off screen) is wrong in two ways that a review caught:

- `reload` re-locates "you are here", and locating a workspace **clears its bold
  attention marker** (you're looking at it, so it's been seen). Off screen you are
  *not* looking at it — so a warm reload would erase the very notification the
  on-screen sidebar just set, before you ever saw it. `warm_reload` skips locating
  entirely; an off-screen pane's current workspace can't change while you're away.
- `reload` records "I just did a full reload", which the switch-in path uses to
  *skip* a redundant reload. A warm right before you switch in would suppress the
  switch-in's PR refresh. So `warm_reload` records only its own warm clock; the
  switch-in still does its full reload.

It also doesn't fan out background PR-refresh subprocesses (one per hidden sidebar
would be a lot), and it scans agent state **hooks-only** — skipping the
tmux/pgrep/lsof process probe that the normal scan falls back to whenever a
worktree has no live hook — so an off-screen scan stays cheap. Sounds never ring
off screen.

Shared view-state (collapse a project, fold branches, toggle the full header) gets
a stronger guarantee than the lazy fingerprint: the sidebar that makes the change
**broadcasts** a "repaint now" poke to every other sidebar, so they paint the new
state into their buffers within a fraction of a second — before you can switch to
them. That's the fix for "collapse a project, switch session, and it still
flashed": the off-screen sidebars used to lag the fold until their slow warm tick
(or the switch-in reload), so you saw it snap. Now they're already folded when you
arrive. The broadcast only fires on the (rare) toggle, so it costs nothing at rest.

Honest about the remaining limits: a *continuously* changing thing — an agent dot
ticking in the last second or two before you switch — can still update on arrival
(that's a live change, not stale view-state), since dots ride the lazy warm, not
the broadcast. Width is the one view-toggle that still settles on switch-in:
changing it resizes the pane, which a background repaint can't do. And a worktree
added or removed in *another* session refreshes on the switch-in reload, as
before. `prewarm: false` turns the whole thing off and restores pure dormancy.

### Catch-up scans must not re-ring

Each sidebar has its own `@prev_hook_states`, frozen while off screen. So when a
sidebar wakes after sleeping, a naive scan would see every completion that
finished while it slept as a *new* edge — and re-ring sounds you already heard
from the sidebar that was on screen at the time, spraying duplicates as you move
between sessions.

The fix: catch-up scans (the switch-in poke `reload_and_refresh`, the off→on
`reappeared` branch) reload with `announce_sounds: false`. They re-baseline the
state and still refresh PRs and write bold markers, but ring nothing. Only
continuous *while-visible* scans announce. So a completion is heard exactly once,
from wherever you're watching when it lands.

## The bug this all exists to prevent: recycled pane ids

"One visible sidebar rings at a time" assumes a dead sidebar process actually
exits. One almost didn't, and it produced an intermittent duplicate-sound bug
worth understanding because it shaped the run loop.

A sidebar whose pane closed used to keep looping: `read_key` swallowed the stdin
`EOFError`, and nothing checked the pane still existed. Harmless on its own — but
**tmux recycles `%pane-id`s.** The orphan's frozen `ENV["TMUX_PANE"]` would later
name a *different, live* pane. When that recycled id happened to map to a pane on
the attached, active window, the orphan's `Tmux.visible?` read **true** — so it
ran announcing scans and rang completions *in parallel with the real owner*.
Duplicate, sometimes triple, sounds. Intermittent, because it depended on which
recycled id currently mapped to a visible pane.

Two guards close it:

1. **Clean exit on pane close.** `read_key` now returns `:eof` (the run loop
   exits) instead of swallowing the EOF.
2. **`owns_pane?` confirms identity by pty.** It compares the pane's current
   `#{pane_tty}` against the pty captured at startup. tmux keeps a pane's pty
   stable for its whole life but recycles ids — so a *confirmed different* tty
   means our id was handed to another pane, and `tick` returns false to exit.

A `nil` reply from the tty check is deliberately **not** treated as disownership:
it can't be told apart from a transient `display-message` failure, and
self-terminating a healthy sidebar on a flaky shell-out is worse than the leak it
would prevent. Every other tmux call here degrades on a transient miss rather than
acting on it. A genuinely dead pane reads `visible? = false` (silent, never rings)
and is reaped the instant its id is recycled onto a live pane — exactly when it
could otherwise turn harmful. So the orphan that rings duplicates stops within one
`IDLE` tick, before it can ring.

`doctor` also surfaces these as "orphaned sidebar processes" by diffing the
running-process count (`pgrep`) against the sidebar-pane count, so a straggler is
visible before it can misbehave.

## Trade-offs, named

- **Per-process state on disk** vs. a shared daemon: simpler lifecycle (tmux owns
  it), at the cost of atomic-write discipline and self-healing GC on every state
  store.
- **Sleeping off-screen sidebars** save work but mean state can lag up to `IDLE`
  (8s) on an un-poked reappearance — a conservative backstop chosen over more
  tmux hook surface. A couple of edge paths (a `prefix-z` zoomed pane, a bare
  `tmux attach`) still lean on that backstop; see `TODOS.md`.
- **Pre-warming** spends a little of that saved off-screen work back to kill the
  switch-in flash — but only behind a change-gate and a `WARM_TTL`, so an idle
  pane stays as cheap as full dormancy. The change-gate's fingerprint covers
  agent/attention/diff/PR **and shared view-state** (collapse/fold/header/width);
  view-state changes additionally **broadcast** a repaint to other sidebars so they
  update instantly rather than waiting for the gate. A worktree added/removed in
  another session is the one thing left to the switch-in reload. `prewarm: false`
  opts back into pure dormancy.
- **The pty-confirmation guard** errs toward *not* killing a sidebar on an
  ambiguous reply, accepting a brief leak over ever silencing a healthy panel.

## Related

- [Explanation: architecture](explanation-architecture.md) — why tmux owns the lifecycle.
- [Explanation: agent presence](explanation-agent-presence.md) — the edges these scans consume.
- [Reference: keybindings](reference-keybindings.md) — the `C-l`/`C-r` pokes.
