# Explanation: the sidebar's lifecycle

The sidebar feels like one persistent panel that follows you around. It isn't.
There's a **separate sidebar process per window**, most of them asleep at any
moment, coordinating through tmux hooks and on-disk state. This explains why it's
built that way, how a sidebar stays cheap while off screen, and the subtle bug
that the design exists to prevent.

This is the deepest part of the codebase. If you're changing visibility, poking,
or the run loop in `sidebar.rb` (or its `sidebar/` concern files — the #57
split: `edges`, `render`, `input`, `actions`, `prompt`, `rows`), read this first.

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

Each sidebar has its own edge baseline (`@prev_hook_states`, owned by its
`Sidebar::Edges`), frozen while off screen. So when a
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

## Swapping in new code without a restart (#48)

Every sidebar is a long-lived process, so after an upgrade each one would keep running
the code it started with. Everything else switchboard runs (hooks, PR-refresh children,
dispatch workers) re-invokes the binary, so it picks up new code by itself. The sidebars
can't, and upgrades used to end with "press the toggle key twice in each session".

Now a sidebar **execs itself in place**. The pane runs the binary directly (no shell in
between), so exec'ing the file `SWITCHBOARD_BIN` resolves to (`<bin> sidebar`) keeps the
pid, the pty and the pane id: from tmux's side nothing changed, and `owns_pane?` stays
true. Most of what the sidebar knows is already on disk (folds, width, header, attention,
holds). The few per-process things worth keeping ride one env var
(`SWITCHBOARD_SIDEBAR_RESUME`) into the new image:

- **the cursor row**, found again by identity;
- **the agent-edge baseline.** It's sticky past `PRESENCE_TTL` on purpose, and without
  it an agent that's been quiet a while would read as new, its completion would ring
  nowhere, and the ◷ would drop;
- **whether the first scan may ring.** It may only if the old process was on screen and
  scanning a moment ago. Otherwise the first scan is a silent catch-up, like any
  switch-in. The same bit tells the new image the old one had scanned, so an empty
  baseline (no hooked workspace) still counts, and a `monitoring notify` that lands
  during the swap rings instead of being taken as a first look. A hand-over too big to
  carry (over 64 KiB) drops the baseline and this bit together.

Two things ask for it:

- **A signal.** `upgrade` and `switchboard reload-sidebars` send `SIGUSR1`, but only to a
  pane whose `@sb_reload` tag equals its `pane_pid`, or names a direct child of it (a shell
  like fish runs the sidebar as a child instead of exec'ing it). A tag of `0` means the
  sidebar is between images, so it is left alone. A sidebar older than 0.59 has no tag,
  and the signal's default action would kill it, so instead it is restarted with
  `respawn-pane` (its own start command) after a test run of that binary: the same
  `sidebar --check` a signalled sidebar runs, when the binary is 0.59 or later (older ones
  only answer `version`, since they would run the check as a whole sidebar).
- **A moved install.** Each tick checks whether `SWITCHBOARD_BIN` still resolves to the
  code it loaded. Under Homebrew a plain `brew upgrade` repoints `opt/` at a new keg, so
  the sidebar notices without being told. It's a stat or two, no subprocess. A clone's
  path never moves, so this check never fires there.

The signal's trap only sets a flag and writes a self-pipe that `IO.select` watches. The
exec happens at the top of the run loop, never inside a prompt (prompts block the loop),
and never under `?`, the QR code or the filter. An on-screen sidebar goes at once. An
off-screen one waits a random 0–30s so a fleet doesn't boot and rescan git at once, and a
switch-in makes it go right away. That switch-in still runs its usual quiet catch-up
reload first, keeping the cursor on the row it was on: keys typed with the switch act on
a current tree, the exec may fail, and the new image's first scan baselines against that
reload, or it would replay chimes another sidebar already rang. A switch-in inside the
reload throttle skips that reload, so the swap's first scan is silent instead.

Before exec, an on-screen sidebar repaints, so the caught-up tree shows during the check.
It resolves `SWITCHBOARD_BIN` once (under Homebrew, through `opt/` to the current keg's
file), then test-runs and execs that same file, so a `brew upgrade` landing during the
check can't swap in a release the check never ran. An install that won't resolve (brew
mid-relink, a deleted checkout) skips that reload and marks the pane for `doctor`; a later
signal or the moved-install check tries again. Otherwise it test-runs
`<bin> sidebar --check` with its resume payload, stdio closed and the `SB_REEXEC` guard cleared, bounded at 3s. That builds a sidebar off
screen and applies the payload (no rebuild: that writes). exec only fails safe when the
exec call itself fails, and a new release that can't construct a sidebar or take its
payload would otherwise kill the pane. A failure keeps the old code and marks the pane for
`doctor`. A timeout counts as a failure; the next `reload-sidebars` retries it. Just
before exec it sets `SIGUSR1` to ignored and clears its tag: caught handlers reset across
exec, an ignored signal stays ignored, and a second reload landing during the boot would
otherwise kill the new image. The new image installs its handler, then re-tags. If that
tag doesn't land it retries on later ticks, a few times, because a `0` left behind would
make every later reload skip a running sidebar. Only new code starting clears the pane's
failure mark: the old code's re-tag after a failed exec never does, so `doctor` keeps
listing a sidebar whose reload failed.

The resume payload and the signal are a **cross-version contract**: newer code must read
every older payload (one it can't read is a blank resume, still a reload; only an absent one is a cold start), and the tag and the
signal never change meaning. The same holds for `Creation` records, because a launcher
(`Creator.launch`) lives as long as its agent and keeps the code it started with.

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
- **Exec in place** over `respawn-pane` for a reload: same pid and pane, no blank
  frame, state carried, and a release that won't load is caught before anything is
  replaced. Respawn stays the fallback for sidebars too old to take the signal.

## The code reload, in detail

This is the full implementation detail [CLAUDE.md](../CLAUDE.md) summarizes; keep the two in step.

A running sidebar **execs its own `SWITCHBOARD_BIN` in place** (`CodeReload`,
`code_reload.rb`, plus the reload section of `sidebar.rb`). The pane runs the binary with
no shell (`Tmux.spawn_sidebar`), so exec keeps the pid, pty and `%pane` id, and
`owns_pane?` holds. Each sidebar re-execs its OWN bin: under brew that's the opt path
(StablePath), so it lands in the new keg, and a dogfood checkout's sidebar stays on its
checkout. Nothing can repoint a sidebar at another install.

- **Triggers.**
  - `SIGUSR1`, from `upgrade --finish` (installed binary only) and `switchboard
    reload-sidebars` (any binary). Senders read `list-panes -a` once
    (`Tmux.sidebar_reload_targets`). A pane counts as tagged when its `@sb_reload` tag is
    its `#{pane_pid}`, or a child of it (checked in one `ps`): a shell like fish doesn't
    exec its command. Tagged panes get the signal, sent to the tagged pid. A tag of `0`
    means mid-exec from another reload: it's left alone, because a respawn would kill the
    boot. An untagged pane (older than 0.59, or tmux < 3.0, where SIGUSR1's default action
    would KILL it) is instead `respawn-pane -k`'d with NO command, so it reruns the pane's
    own start command. The respawn adds `-e` for the resume marker, retried without `-e` on
    old tmux. The pane is re-read just before (`Tmux.same_reload_target?`: same pid, tag,
    liveness and command), because the preflights take time and `-k` kills whatever runs
    there now; any tag change aborts it. Dead panes (`#{pane_dead}`, under remain-on-exit)
    are never targets. The respawn only happens when that start command is exactly `<…/switchboard> sidebar`
    (`Tmux.start_bin`: any program can title its pane `sb-sidebar`), and the binary passes
    `CodeReload.restartable` (once per distinct binary): resolved once (`start_file`: an
    absolute path, realpath'd with no opt/ rewrite, since tmux reruns the pane's own command, so
    a keg path runs that keg, gone after cleanup or not), an
    executable file, `version` prints `switchboard X.Y.Z`, and from 0.59 on, `sidebar --check`
    with the resume marker passes on that same file. Older releases get `version` only: they'd
    run `sidebar --check` as a full hidden sidebar, and a home one prunes. Just before the
    respawn the link must still resolve to the checked file (a brew relink since then leaves
    the pane). Otherwise the pane is left running and counted: respawn kills first, so a broken
    or deleted checkout would cost the window its sidebar. The check runs in the sender's env,
    which can resolve a different config than the tmux server the pane restarts in.
  - The backstop in `tick`: `CodeReload.stale?`, which checks whether `SWITCHBOARD_BIN`'s
    realpath root is still `LOADED_ROOT` (captured at require time). Only a Homebrew keg
    move changes it (so a plain `brew upgrade` reloads too). It's inert for clones, and
    costs stats only, no tmux call: the R3 contract pins that an idle tick costs what it did.
- **The trap** only sets `@reload_signal` and writes a self-pipe (`@wake_r` is in
  `IO.select`). It's installed in `run`, restored in `teardown`, and installed BEFORE the
  tag goes on.
- **`maybe_reexec`, at the loop top**, turns the flag into a request.
  - On screen the request is due now. Off screen it's due after `CodeReload.spread_delay`
    (0–30s) so a fleet doesn't boot plus rescan at once, and a switch-in makes it due at
    once. The switch-in still runs its usual silent reload first (throttled by `reload_due?`,
    like any switch-in): keys read with the poke act on the tree before the loop top swaps,
    the swap may fail, and the new image must baseline against that reload or it replays
    chimes. Inside POKE_TTL there is no catch-up scan, so the switch-in drops
    `@last_announce_scan` and the swap's first scan is silent. That reload keeps the cursor
    by row identity (`keep_cursor`), and `reexec` paints before its preflight, so the
    caught-up tree is on screen during the check.
  - It's never due under `?`, QR or `/`, never mid-prompt (prompts block the loop), and
    never with half an escape sequence in `@pending`: the new image would read its tail
    (`O`, from focus-out) as a key. All of these live in `reexec_allowed?`, which
    `frame_timeout` also consults, so a held reload can't spin on an overdue deadline.
  - `frame_timeout` honors `@reexec_at` only while the reload is allowed, else a passed
    deadline would spin `IO.select`.
- **`reexec`**:
  0. Resolve the bin once (`CodeReload.real_bin`): the check and the exec both run that
     file, so a `brew upgrade` repointing opt/ mid-check can't make the sidebar exec a keg
     the check never ran. A bin that won't resolve (brew mid-relink) fails the reload: no
     check, the pane flagged with the bin path (a deleted checkout must show; after a brief
     relink the next reload that lands clears it, which a same-keg relink needs a
     `reload-sidebars` for), the blocked root left as it was; a signal or the backstop retries. The new image still exports the opt path
     (`bin/switchboard` runs its realpath through `StablePath`), unless opt/ is missing at that
     boot: then it keeps the keg path, so `real_bin` runs a keg path through `StablePath`
     first and that sidebar follows opt/ again at the next upgrade. Not covered: brew cleanup
     deleting the checked keg after the exec, mid-boot (an upgrade landing during a reload,
     e.g. a `reload-sidebars` run while `brew upgrade` is going).
  1. Preflight: `<bin> sidebar --check` with the resume payload in its env.
     `Sidebar.check` refuses a missing config (the new image would exit and close the
     pane) or one with a `load_error` (this image keeps its last-good config; the new one
     would blank the tree). It then builds a sidebar and runs `apply_resume` (shared with
     `resume_start`) on the payload. It runs no rebuild, because rebuild writes. So it
     proves the new code can construct a sidebar and take the payload, not just load. It's
     bounded to 3s, runs with
     `{"SB_REEXEC"=>nil}` so a system-Ruby re-exec still happens, and with all stdio
     `/dev/null` since it keeps the pane as its ctty. Outcomes:
     - `:failed` or `:timeout` blocks that root for the backstop (`@reexec_blocked_root`;
       a newer keg gets its own try). A signal (`reload-sidebars`) still asks again, which
       is a timed-out check's retry. There's deliberately no retry clock: a second wake
       time that every gate had to honor produced a spin and a stale tree in review.

     Either way it flags the pane `@sb_reload_failed=<root>`, after the failed exec's
     re-tag. `doctor` lists those panes, and the next reload's summary reports them. Only a
     new image's first tag clears the flag, in the same tmux call as the tag
     (`clear_failed:`), retries of it included (`@tag_clears`), until a later failed reload
     revokes that (`reload_failed` drops `@tag_clears` before it flags); the failed exec's
     re-tag, and its retries, leave it.
     A pid tag that didn't land is owed (`@tag_pending`) and `tick` retries it
     (`retry_tag`), `TAG_TRIES` (5) attempts in all, then gives up: without it a `0` left by
     the exec would make every later reload skip a running sidebar, and tmux < 3.0 (no
     `set-option -p`) fails every time, so an uncapped retry would cost every tick.
  2. Write the resume payload, delete `SB_REEXEC`.
  3. `trap(USR1, "IGNORE")` plus tag `0`: caught handlers reset across exec, `SIG_IGN`
     survives it, and a second reload during the boot would otherwise kill the new image.
  4. Flush stdout, then exec.

  A failed exec puts the env, trap and tag back and flags the failure. exec skips
  `ensure`, so the tty stays raw with focus events on, and the new image re-asserts that.
  It also drops the old image's `Process.detach` threads, so a resumed image sweeps
  `Process.wait(-1, WNOHANG)` each tick (`reap_strays`). That's safe because nothing in
  the sidebar waits on an asynchronous child: every such spawn is detached, and
  shell-outs wait inline.
- **Resume** (`SWITCHBOARD_SIDEBAR_RESUME`, JSON v1, ≤64 KiB, read AND deleted by
  `take_resume` before anything spawns):
  - `encode` never raises and never writes what `decode` would refuse. Names that aren't
    valid UTF-8 are scrubbed: git branch names can be any bytes, `JSON.generate` raises on
    them, and the whole fleet reloads at once. Past `PAYLOAD_MAX` the baseline is dropped
    and the cursor kept, and `announce` goes false: with no notify cursor left, an announcing
    first scan would re-ring every alert (so a chime or alert landing during that reload is
    baselined silently; dispatch pings, being durable, ring on the next scan). A cursor still
    waiting for its row travels as it came, and a raise in `resume_payload` hands over a
    minimal payload.
  - A payload that was handed over but won't decode is `BLANK`, not nil, so it's still a
    reload: no clear, no launch-time prune.
  - It carries:
    - the cursor (identity: `CodeReload::CURSOR_FIELDS`, restored after the first
      reload's `locate`, falling back to `cursor_to_current`; a respawn's marker carries
      none, so it starts "here");
    - the offset;
    - the Edges baseline (`Edges#baseline`/`restore_baseline`: the sticky hook states past
      PRESENCE_TTL and the notify cursor). The notify marker mtimes are carried as exact
      `[sec, nsec]`, because `File.mtime` has nanoseconds and a cursor that comes back a
      hair early re-rings the alert it already rang;
    - `announce`.
  - `announce` is true only if the old image was visible with an announcing scan within
    REFRESH + `ANNOUNCE_GRACE`. Otherwise the first reload is silent, so a switch-in
    reload never replays chimes another pane already rang. A missing field reads as
    silent. It also tells `restore_baseline` the old image scanned (only an announcing scan
    licenses it): a pane with no hooked worktree carries an empty baseline, which would
    otherwise restore as "never scanned" and swallow a `monitoring notify` that landed
    mid-reload.
  - On resume, `setup` skips its `\e[2J`, and `run` skips the empty first paint: the old
    frame stays up until the new one overwrites it. Off screen, the first warm waits out
    the spread (`@warm_not_before`). The home sidebar skips its launch-time prune: a
    reload isn't a launch.
- **Cross-version contract**: newer code accepts every older payload (lenient, per field;
  one that won't decode is a blank resume, still a reload; only an absent one is a cold start; `code_reload_test` pins a frozen v1 string).
  `@sb_reload`, `@sb_reload_failed` and `SIGUSR1` never change meaning. `Creation` records
  stay readable by older launchers (`Creator.launch` lives as long as its agent and keeps
  old code).
- **Tests**: `code_reload_test`, `sidebar_reload_test`, the reload summary in
  `upgrade_test` / `cli_test`, and two smoke files.
  - Both smoke files run sidebars from a fake brew prefix in the tmpdir
    (`test/smoke/fake_keg.rb`: `Cellar/switchboard/<keg>` copies plus an `opt` link;
    StablePath's regex is prefix-agnostic).
  - `sidebar_reload_smoke_test` covers the signal swap (same pane and pid, cursor kept),
    the backstop flip, a broken B leaving the old sidebar alive, an untagged pane
    respawned, and back-to-back reloads.
  - `upgrade_reload_smoke_test` runs `upgrade --finish` as the installed binary (a PATH
    symlink). It patches the running keg's code in place so only the signal can show it,
    and covers in place, restarted, and another copy's finish leaving sidebars alone.

## Visibility, dormancy and pre-warming, in detail

This is the full implementation detail [CLAUDE.md](../CLAUDE.md) points to; keep it current with the code.

**Sidebar visibility is per-session, applied to every window** (issue #24). The
intent lives on the session as a tmux option (`@sb_sidebar` on/off; unset reads
as on, preserving auto-show). `Tmux.reconcile_sidebars` is the one primitive that
spawns-or-kills each window's sidebar to match: `prefix-s` (`Tmux.toggle_sidebar`,
switchboard's one summon/dismiss verb — visible ⇒ dismiss session-wide, hidden ⇒
summon every window AND focus the tree) flips the flag and reconciles every window;
`ensure_session` stamps `on` on first creation; `go`/`go_home` reconcile to the
saved flag on switch-in (and `go_home` always restores the navigator). New
windows are covered by the `after-new-window[99]` hook → `sidebar-sync <window>`,
which spawns one iff the session opts in. No spawn recursion: the sidebar is a
`split-window`, which fires `after-split-window`, not the hooked `after-new-window`.

**A *shown* sidebar still goes dormant while off screen.** Every window keeps its
own sidebar process, so at any moment most of them are on inactive windows. Each
caches whether it's currently on screen in `@visible` (the single flag, mutated
only via `set_visible`); `render` and the spinner/blink (`pulsing?`) are gated on
it, and `frame_timeout` drops an off-screen sidebar from the `REFRESH` cadence to
a long `IDLE` backstop. So an off-screen sidebar does essentially nothing — no
paint, no agent scan, just one cheap visibility check per `IDLE` — until a poke
wakes it: a session switch (`client-session-changed` → C-l) or a same-session
window switch (`session-window-changed` → `poke-window` → C-l). The C-l handler
`reload_and_refresh` **re-samples** `Tmux.visible?` rather than assuming the poke
means on-screen, because the same C-l is also sent by background PR-refresh
children (`maybe_refresh_prs --poke`) to a pane you may have navigated away from —
marking that hidden pane visible would re-wake it. An un-poked reappearance (a
window switch on a tmux too old for the hook, a bare `tmux attach`) is caught by
the off→on `reappeared` branch in `tick` within `IDLE`.

**Pre-warming keeps an off-screen sidebar's buffer fresh so switch-in doesn't
flash a stale tree** (`prewarm?`, default on; `prewarm: false` restores full
dormancy). Without it, switching into a session shows that pane's *last* render
(possibly minutes old) until the switch-in poke reloads — a visible flash. A tmux
pane buffers writes even while off screen (its grid persists; `render` doesn't
gate on `@visible`, the caller does), so the fix is to paint it *before* you
arrive. The off-screen branch of `tick` does a **change-gated, `WARM_TTL`-bounded,
visibility-safe** warm: when `prewarm?` AND `WARM_TTL` has elapsed (`@last_warm`)
AND a cheap `warm_fingerprint` differs from the `@warm_fp` baseline, it runs
`warm_reload` + `render`. The gates are cheapest-first, so a fully idle pane still
costs ~one `Tmux.visible?` call per `IDLE` (today's dormancy). `warm_fingerprint`
is stats only — a `dir_fingerprint` (name+mtime per file) over the agent-state,
attention, PR-cache, and **collapse** dirs, the **full-header / branch-fold /
width** marker files, the **config file** (`Config.path`) mtime, plus each tracked
worktree's `logs/HEAD` mtime — so it sees agent dots, bold, badges, commits, the
**project registry** (a project added/removed in another session), **and the
shared view-state** move without a git/process shell-out. It deliberately does NOT
cover a *worktree* added/removed in **another** session; that refreshes on the
switch-in reload as before.

**A project added/removed in another session propagates like shared view-state.**
`@config` is cached per sidebar process (git is the runtime truth; the config is
just the project registry), so a project registered elsewhere used to stay
invisible until the pane's process was respawned. `rebuild` — the one chokepoint
every reload path funnels through (switch-in poke, the ~15s tree-tick, the
off-screen warm) — now calls `refresh_config` (`sidebar/actions.rb`): an
**mtime-gated** re-read that costs one `stat` when the file is unchanged and a
`Config.new` only when it actually changed (keeping the last-good `@config` on a
parse error, like `reload_config`, which shares the same `@config_mtime` baseline).
So the frequent `C-l` reload stays as cheap as when it never re-read config, yet a
changed registry lands on the next reload. The config-mutating verbs
(`add_local`/`add_clone`/`add_create`/`remove_project`, and the `e`/CLI `reload-config` path)
also `Tmux.broadcast_warm` so every *other* sidebar re-reads immediately, and the
config mtime rides `warm_fingerprint` as the lazy backstop — the same
broadcast-plus-fingerprint shape as the shared view-state. Because peers now read
the config concurrently with a writer, `Config.add_project`/`remove_project`/
`scaffold` write **atomically** (`MarkerBlock.atomic_write`, temp+rename, symlink-
and mode-aware) — the same invariant the marker stores / `HookFile` / `MarkerBlock`
already hold: a plain `File.write`'s `O_TRUNC` window would let a peer read the
empty file, which is *valid YAML* (`load_error` wouldn't catch it), and adopt a
zero-project config that blanks its whole tree.

**Shared view-state propagates instantly via a broadcast, not just the lazy
fingerprint.** A collapse/branch-fold/full-header toggle in one sidebar is a user
action that writes a shared on-disk store; the toggling sidebar then
`Tmux.broadcast_warm`s a `C-w` "repaint now" poke (`WARM_POKE_BYTE`) to every
*other* sidebar pane (`all_sidebar_panes`, except itself). Each handles it in
`warm_poke`: off screen → `warm_reload` + render (paint the new view-state into the
buffer); on screen → a silent `reload` + render. So an off-screen sidebar reflects
the fold within ~0.2s — before you can switch to it — instead of lagging until its
~`IDLE` warm tick (the bug where "collapse then switch still flashed"). The
broadcast is event-driven (fires only on the rare toggle, zero steady-state cost,
so dormancy is preserved); the view-state entries in `warm_fingerprint` are the
lazy backstop if a broadcast is missed. The earlier `prewarm` shipped WITHOUT
this — its fingerprint omitted view-state, so a collapse never warmed off-screen
panes and every switch-in repainted the fold = a flash on exactly the case folks
test with. Width is the one view-state that still defers to switch-in: changing it
*resizes* the pane (a `pin`, not just a render), so a warm repaint can't apply it
off screen — the fingerprint tracks it as a backstop but the resize lands on the
switch-in `pin`.

`warm_reload` is **not** `reload` with flags — reusing `reload` off screen caused
two real bugs (caught in review): `reload`→`locate` clears `Attention` for
`@current_path`, so an off-screen warm would erase the bold the on-screen sidebar
just set for that workspace's completion *before you saw it*; and `reload` stamps
`@last_reload`, so a warm within `POKE_TTL` of a switch would make
`reload_and_refresh` skip its PR refresh. So `warm_reload` **skips `locate`
entirely** (an off-screen pane's `@current_path` can't change while you're away)
and stamps only `@last_warm` (never `@last_reload`, so switch-in still does its
full reload + PR refresh). It also passes `refresh_prs: false` (no off-screen
PR-spawn fan-out — the edge fanout (`Edges#on_scan`) still marks + advances the baseline, only the
spawn is gated) and `hooks_only: true` to `AgentState.scan` (skip the
tmux/pgrep/lsof `Agents.active` fallback — which otherwise fires whenever *any*
worktree lacks a live hook, i.e. almost always — so an off-screen scan stays
cheap; hook-less/activity dots just defer their freshness to switch-in). Sounds
are never rung off screen (`announce_sounds: false`). Honest scope: this
*drastically reduces* the flash, it doesn't kill it — a change in the last
`~IDLE+WARM_TTL` before a switch can still be caught mid-warm. One limitation:
the warm frame is drawn at the off-screen pane's size, which is correct for a
single client at a stable size (the dominant case) but may be briefly mis-sized
under multiple clients of different sizes until the switch-in poke re-renders
(self-heals via the poke we already have, never worse than today). The hook
reporter writes atomically (temp+rename, `hook_file.rb`; the reporter script itself too, since sh
reads a running script as it goes) so the warm fingerprint
can never catch — and stamp-as-clean — a torn state file.


## Related

- [Explanation: architecture](explanation-architecture.md) — why tmux owns the lifecycle.
- [Explanation: agent presence](explanation-agent-presence.md) — the edges these scans consume.
- [Reference: keybindings](reference-keybindings.md) — the `C-l`/`C-r` pokes.
