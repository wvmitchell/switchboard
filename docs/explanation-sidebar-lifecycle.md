# Explanation: the sidebar's lifecycle

The sidebar feels like one persistent panel that follows you around. It isn't.
There's a **separate sidebar process per window**, most of them asleep at any
moment, coordinating through tmux hooks and on-disk state. This explains why it's
built that way, how a sidebar stays cheap while off screen, how it swaps in new code
without restarting, and the subtle bug that the design exists to prevent.

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
folds, all three are durable view preferences, **not** cleared on `quit`. How each
one works is in [the sidebar's views](explanation-sidebar-views.md).

The hook reporter writes atomically too (temp+rename, `hook_file.rb`), and so does
the code that installs the reporter script itself, since `sh` reads a running script
as it goes. That's what lets the pre-warm fingerprint (below) trust what it sees: it
can never catch a torn state file and mark it as clean.

## Sidebar visibility is per-session, applied to every window

The intent "show the sidebar" lives on the *session* as a tmux option
(`@sb_sidebar` on/off; unset reads as on, preserving auto-show; issue #24). One
primitive, `Tmux.reconcile_sidebars`, spawns-or-kills each window's sidebar to match
that flag:

- `prefix-s` (`Tmux.toggle_sidebar`) — switchboard's one summon/dismiss verb.
  Visible ⇒ dismiss session-wide; hidden ⇒ summon on every window *and* focus the
  tree. It flips the flag and reconciles every window.
- `ensure_session` stamps `on` on first creation.
- `go`/`go_home` reconcile to the saved flag on switch-in (and `go_home` always
  restores the navigator).
- New windows are handled by the `after-new-window[99]` hook → `sidebar-sync <window>`,
  which spawns one iff the session opts in. No spawn recursion: the sidebar is a
  `split-window`, which fires `after-split-window`, not the hooked
  `after-new-window`.

## A shown sidebar still sleeps while off screen

Because every window keeps its own sidebar, at any moment most of them are on
*inactive* windows. A sidebar that painted and scanned agents continuously on
every window would be a lot of wasted work.

So each sidebar caches whether it's currently on screen in `@visible` (mutated
only via `set_visible`). `render`'s callers, the spinner/blink animation
(`pulsing?`), and the agent scan are all gated on it. `frame_timeout` drops an
off-screen sidebar from the `REFRESH` cadence (3s) to a long `IDLE` backstop (8s).
An off-screen sidebar does essentially nothing — no paint, no agent scan, one cheap
visibility check per `IDLE` tick — until something wakes it.

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
its screen grid even while off screen (`render` itself doesn't check `@visible`; its
callers do), so you can paint a hidden pane *before* the user arrives and the fresh
frame is already there on switch-in. So the off-screen branch of `tick` does a small
amount of work again, but only when it's worth it. It runs `warm_reload` plus
`render` only when three cheap gates all pass, checked cheapest first:

1. **The `prewarm` setting** (`prewarm?`, on by default).
2. **A `WARM_TTL` throttle** (`@last_warm`), so a busy agent off screen can't make us
   reload on every wake.
3. **A changed `warm_fingerprint`,** compared with the `@warm_fp` baseline.

The fingerprint is stats only, with no git or process shell-outs. It's a
`dir_fingerprint` (each file's name and mtime) over the agent-state, attention,
PR-cache and collapse directories, plus:

- the full-header, branch-fold and width marker files;
- the config file's mtime (`Config.path`);
- each tracked worktree's `logs/HEAD` mtime.

So it sees agent dots, bold names, badges, commits, the project registry and the
shared view state move. Nothing changed: the pane stays as dormant as before, costing
about one `Tmux.visible?` call per `IDLE`. Something moved: it does one quiet reload
and repaints into the hidden buffer. The fingerprint deliberately doesn't cover a
*worktree* added or removed in another session; that still refreshes on the switch-in
reload.

### Why the warm reload isn't `reload` with flags

"Quiet" is doing real work here. The obvious implementation, calling the normal
`reload` off screen, caused two real bugs that a review caught:

- **It erased notifications before you saw them.** `reload` calls `locate` to find
  "you are here", and locating a workspace *clears its bold attention marker* for
  `@current_path` (you're looking at it, so it's been seen). Off screen you are *not*
  looking at it, so a warm reload would erase the bold the on-screen sidebar had just
  set for that workspace's completion. `warm_reload` skips `locate` entirely, since an
  off-screen pane's `@current_path` can't change while you're away.
- **It suppressed the switch-in's PR refresh.** `reload` stamps `@last_reload`, which
  the switch-in path uses to *skip* a redundant reload within `POKE_TTL`. A warm just
  before you switched in would make `reload_and_refresh` skip its PR refresh. So
  `warm_reload` stamps only `@last_warm`, and the switch-in still does its full reload
  and PR refresh.

It also keeps the off-screen work small:

- **No PR-refresh fan-out.** It passes `refresh_prs: false`, since a background PR
  refresh per hidden sidebar would be a lot of processes. The edge fan-out
  (`Edges#on_scan`) still marks and advances the baseline; only the spawn is skipped.
- **Hooks-only agent scans.** It passes `hooks_only: true` to `AgentState.scan`,
  skipping the tmux/pgrep/lsof `Agents.active` fallback. That fallback otherwise runs
  whenever *any* worktree lacks a live hook, which is almost always, so skipping it is
  what keeps an off-screen scan cheap. Dots from the activity fallback just refresh on
  switch-in.
- **No sounds.** Off-screen scans pass `announce_sounds: false`.

### Shared view state is broadcast, not just fingerprinted

Shared view state (collapsing a project, folding branches, toggling the full header)
gets a stronger guarantee than the lazy fingerprint. The sidebar where you made the
change calls `Tmux.broadcast_warm`, which sends a `C-w` "repaint now" poke
(`WARM_POKE_BYTE`) to every *other* sidebar pane (`all_sidebar_panes`, minus itself).
Each one handles it in `warm_poke`:

- **Off screen:** `warm_reload` plus a render, painting the new view state into the
  hidden buffer.
- **On screen:** a silent `reload` plus a render.

So an off-screen sidebar shows the fold within about 0.2 seconds, before you can switch
to it.

That's the fix for "collapse a project, switch session, and it still flashed." The first
version of pre-warming shipped without the broadcast, and its fingerprint left out view
state entirely, so a collapse never warmed off-screen panes and every switch-in repainted
the fold: a flash in exactly the case people test first. The broadcast fires only on the
rare toggle, so it costs nothing at rest, and the view-state entries in the fingerprint
are the backstop if a broadcast is missed.

### A project added in another session

Each sidebar process caches `@config`, since git is the runtime truth and the config is
just the project registry. That meant a project registered in another session stayed
invisible until the pane's process was respawned.

Now `rebuild`, the one place every reload path goes through (the switch-in poke, the
~15-second tree tick, the off-screen warm), calls `refresh_config` (`sidebar/actions.rb`).
It's an mtime-gated re-read: one `stat` when the file hasn't changed, and a `Config.new`
only when it has. On a parse error it keeps the last good `@config`, like `reload_config`,
which shares the same `@config_mtime` baseline. So the frequent `C-l` reload stays as cheap
as before, yet a changed registry lands on the next reload.

It propagates the same way as shared view state:

- **A broadcast.** The verbs that change the config (`add_local`, `add_clone`, `add_create`,
  `remove_project`, and the `e` / CLI `reload-config` path) also call `Tmux.broadcast_warm`,
  so every other sidebar re-reads right away.
- **A fingerprint backstop.** The config's mtime is part of `warm_fingerprint`.

Because peers now read the config while a writer may be writing it,
`Config.add_project`, `remove_project` and `scaffold` write atomically
(`MarkerBlock.atomic_write`: temp+rename, aware of symlinks and file modes). That's the
same rule the marker stores, `HookFile` and `MarkerBlock` already follow. A plain
`File.write` truncates first (`O_TRUNC`), and a peer reading in that window gets an empty file. An
empty file is *valid YAML*, so `load_error` wouldn't catch it, and the peer would adopt a
config with zero projects and blank its whole tree.

### What pre-warming doesn't cover

- **A last-second change.** It greatly reduces the flash; it doesn't eliminate it. A change
  in the last `IDLE` + `WARM_TTL` or so before you switch can still be caught mid-warm. An
  agent dot ticking in the final second or two is a live change, not stale view state, and
  dots ride the lazy warm, not the broadcast.
- **Width.** It's the one view toggle that still settles on switch-in. Changing it
  *resizes* the pane (a `pin`, not just a render), which a background repaint can't do off
  screen. The fingerprint tracks it as a backstop, but the resize lands on the switch-in
  `pin`.
- **Worktrees added or removed in another session.** Those refresh on the switch-in
  reload, as before.
- **Clients of different sizes.** The warm frame is drawn at the off-screen pane's size.
  That's right for a single client at a stable size, the common case, but with several
  clients of different sizes it can be briefly mis-sized until the switch-in poke
  re-renders. It fixes itself through that poke and is never worse than no pre-warming.

`prewarm: false` turns the whole thing off and restores pure dormancy.

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

### The sidebar execs itself in place

A running sidebar execs its own `SWITCHBOARD_BIN` (`CodeReload`, `code_reload.rb`, plus
the reload section of `sidebar.rb`). The pane runs the binary directly, with no shell in
between (`Tmux.spawn_sidebar`), so exec keeps the pid, the pty and the `%pane` id. From
tmux's side nothing changed, and `owns_pane?` stays true.

Each sidebar re-execs its *own* binary. Under Homebrew that's the opt path (`StablePath`),
so it lands in the new keg, and a dogfood checkout's sidebar stays on its checkout.
Nothing can repoint a sidebar at another install.

Most of what the sidebar knows is already on disk: folds, width, header, attention, holds.
The few per-process things worth keeping ride one env var, `SWITCHBOARD_SIDEBAR_RESUME`,
into the new image:

- **the cursor row,** found again by identity;
- **the agent-edge baseline.** It's sticky past `PRESENCE_TTL` on purpose. Without it, an
  agent that's been quiet a while would read as new, its completion would ring nowhere,
  and the ◷ would drop;
- **whether the first scan may ring.** It may only if the old process was on screen and
  scanning a moment ago. Otherwise the first scan is a silent catch-up, like any
  switch-in.

The details of that payload are [below](#the-resume-payload).

### What asks for a reload

**A signal.** `upgrade --finish` (installed binary only) and `switchboard reload-sidebars`
(any binary) send `SIGUSR1`. Senders read `list-panes -a` once
(`Tmux.sidebar_reload_targets`) to pick targets, and signal every one that takes a signal
before running any restart check below. Those checks take seconds, and a pid read from the
listing that long ago could belong to another process by the time it's signaled, which
`SIGUSR1` would quit.

- **Tagged panes get the signal.** A pane counts as tagged when its `@sb_reload` tag equals
  its `#{pane_pid}`, or names a direct child of it (checked in one `ps`), since a shell like
  fish runs the sidebar as a child instead of exec'ing it. The signal goes to the tagged pid.
  If the signal fails, the sidebar closed after the listing, and it's counted `unreached`.
  "Failed to reload last time (asked again now)" counts only flagged panes whose signal
  landed or that are already mid-reload, never a restarted or left one.
- **A tag of `0` is left alone.** It means the sidebar is between images in another reload,
  and a respawn would kill the boot.
- **Dead panes are never targets** (`#{pane_dead}`, under remain-on-exit).

**Untagged panes are restarted instead.** A sidebar older than 0.59, or one on tmux older
than 3.0, has no tag, and `SIGUSR1`'s default action would kill it. So it's restarted with
`respawn-pane -k` and *no* command, which reruns the pane's own start command. The respawn
adds `-e` for the resume marker, and retries without `-e` on old tmux.

Two limits of a restart are accepted. On tmux older than 3.0 every reload is one, and a cold
one (no resume marker), so a home pane reruns its launch-time prune. And a half-typed prompt
in an old sidebar is lost: once on tmux 3.0 and later, on every reload below it.

Respawn kills first, so a broken or deleted checkout would cost the window its sidebar.
It only happens when all of these hold:

- **The pane really is a sidebar.** Its start command must be exactly
  `<…/switchboard> sidebar` (`Tmux.start_bin`), since any program can title its pane
  `sb-sidebar`.
- **The binary passes `CodeReload.restartable`,** checked once per distinct binary:
  - it's resolved once (`start_file`): an absolute path, realpath'd with no opt/ rewrite,
    because tmux reruns the pane's own command, so a keg path runs that keg whether or not
    cleanup has removed it;
  - it's an executable file;
  - `version` prints `switchboard X.Y.Z`;
  - from 0.59 on, `sidebar --check` with the resume marker passes on that same file. Older
    releases only get the `version` check, since they'd run `sidebar --check` as a full
    hidden sidebar, and a home one would prune.
- **The link still resolves to the checked file** just before the respawn. A brew relink
  since then leaves the pane as it is.
- **The pane hasn't changed.** It's re-read just before (`Tmux.same_reload_target?`: same
  pid, tag, liveness and command), because the checks take time and `-k` kills whatever is
  running there now. Any tag change aborts.

Otherwise the pane is left running and counted. One caveat: the check runs in the sender's
environment, which can resolve a different config than the tmux server the pane restarts in.

**A moved install.** Each `tick` runs the backstop `CodeReload.stale?`: does
`SWITCHBOARD_BIN`'s realpath root still equal `LOADED_ROOT`, captured when the code was
loaded? Only a Homebrew keg move changes it, so a plain `brew upgrade` (which repoints
`opt/` at a new keg) reloads the sidebar without anyone telling it. It does nothing for
clones, whose path never moves, and it costs a stat or two with no tmux call. A test pins
that an idle tick costs no more than it did before (R3, in `sidebar_reload_test`).

### When the swap happens

**The trap only sets a flag.** The `SIGUSR1` handler sets `@reload_signal` and writes a
self-pipe (`@wake_r` is in the `IO.select` set). It's installed in `run`, restored in
`teardown`, and installed *before* the tag goes on.

**`maybe_reexec`, at the top of the run loop, turns the flag into a request:**

- **On screen,** the request is due now.
- **Off screen,** it's due after `CodeReload.spread_delay` (0 to 30 seconds), so a fleet of
  sidebars doesn't boot and rescan git all at once. A switch-in makes it due right away.

**A switch-in catches up first.** It still runs its usual silent reload (throttled by
`reload_due?`, like any switch-in), because keys typed with the switch act on the tree
before the loop top swaps, the swap may fail, and the new image has to baseline against that
reload or it would replay chimes another sidebar already rang. That reload keeps the cursor
on the same row (`keep_cursor`). Inside `POKE_TTL` there's no catch-up scan, so the switch-in
drops `@last_announce_scan` and the swap's first scan is silent instead.

**It never swaps at a bad moment.** Never under `?`, the QR code or the `/` filter; never
mid-prompt (prompts block the loop); and never with half an escape sequence in `@pending`,
since the new image would read its tail (`O`, from a focus-out) as a key. All of these live
in `reexec_allowed?`. `frame_timeout` consults it too, and honors `@reexec_at` only while
the reload is allowed, so a held reload can't spin `IO.select` on a deadline that has passed.

### The swap, step by step

`reexec` first repaints an on-screen sidebar, so the caught-up tree is on screen during the
check. Then:

**0. Resolve the binary once** (`CodeReload.real_bin`). The check and the exec both run that
one file, so a `brew upgrade` repointing opt/ mid-check can't make the sidebar exec a keg the
check never ran.

A binary that won't resolve (brew mid-relink, a deleted checkout) fails the reload: no check,
the pane flagged with the binary's path, and the blocked root left as it was. A signal or the
backstop tries again. A deleted checkout has to show up in `doctor`. After a brief relink,
the next reload that lands clears the flag; a relink of the same keg needs a
`reload-sidebars` for that.

The new image still exports the opt path, since `bin/switchboard` runs its realpath through
`StablePath`. The exception is when opt/ is missing at that boot: then it keeps the keg path.
So `real_bin` runs a keg path through `StablePath` first, and that sidebar follows opt/ again
at the next upgrade. One case isn't covered: brew cleanup deleting the checked keg after the
exec, mid-boot. That takes an upgrade landing during a reload, for example a
`reload-sidebars` run while `brew upgrade` is going.

**1. Test-run the new code** with `<bin> sidebar --check`, the resume payload in its env.

`exec` only fails safe when the exec call itself fails. A new release that loads but can't
build a sidebar or take its payload would otherwise kill the pane. So `Sidebar.check`:

- refuses a missing config, since the new image would exit and close the pane;
- refuses a config with a `load_error`. This image keeps its last good config, and the new
  one would blank the tree;
- builds a sidebar and runs `apply_resume` (shared with `resume_start`) on the payload. It
  doesn't rebuild, because `rebuild` writes.

So the check proves the new code can construct a sidebar and take the payload, not just
load. It's limited to 3 seconds, runs with `{"SB_REEXEC"=>nil}` so a re-exec off system
Ruby still happens, and has all stdio on `/dev/null`, since it keeps the pane as its
controlling terminal.

If it ends `:failed` or `:timeout`:

- **That root is blocked for the backstop** (`@reexec_blocked_root`). A newer keg gets its
  own try, and a signal (`reload-sidebars`) still asks again, which is how a timed-out check
  is retried. There's deliberately no retry clock: in review, a second wake time that every
  gate had to honor produced a spin and a stale tree.
- **The pane is flagged** `@sb_reload_failed=<root>`, after the failed exec's re-tag.
  `doctor` lists those panes, and the next reload's summary reports those it signals again
  or finds mid-reload.

**Only new code starting clears that flag.** A new image's first tag clears it, in the same
tmux call as the tag (`clear_failed:`), retries of that tag included (`@tag_clears`). A later
failed reload revokes that (`reload_failed` drops `@tag_clears` before it flags). The old
code's re-tag after a failed exec, and its retries, never clear it, so `doctor` keeps listing
a sidebar whose reload failed.

**A tag that didn't land is retried.** It's owed (`@tag_pending`), and `tick` retries it
(`retry_tag`), `TAG_TRIES` (5) attempts in all, then gives up. Without the retry, a `0` left
behind by the exec would make every later reload skip a running sidebar. The cap exists
because tmux older than 3.0 (no `set-option -p`) fails every time, and an uncapped retry
would cost every tick.

**2. Write the resume payload,** and delete `SB_REEXEC`.

**3. Ignore `SIGUSR1` (`trap(USR1, "IGNORE")`) and set the tag to `0`.** Caught handlers reset across exec, but an
ignored signal (`SIG_IGN`) stays ignored, and a second reload landing during the boot would
otherwise kill the new image. The new image installs its handler, then re-tags.

**4. Flush stdout, then exec.**

A failed exec puts the env, the trap and the tag back, and flags the failure.

Two things exec skips that the new image makes up for:

- **`ensure` blocks.** So the terminal stays in raw mode with focus events on, and the new
  image re-asserts that.
- **The old image's `Process.detach` threads.** So a resumed image sweeps
  `Process.wait(-1, WNOHANG)` each tick (`reap_strays`). That's safe because nothing in the
  sidebar waits on an asynchronous child: every such spawn is detached, and shell-outs wait
  inline.

### The resume payload

`SWITCHBOARD_SIDEBAR_RESUME` is JSON, version 1, at most 64 KiB. `take_resume` reads *and
deletes* it before anything spawns.

**It carries:**

- **The cursor,** by identity (`CodeReload::CURSOR_FIELDS`). It's restored after the first
  reload's `locate`, falling back to `cursor_to_current`. A respawn's marker carries no
  cursor, so it starts on the current workspace.
- **The scroll offset.**
- **The Edges baseline** (`Edges#baseline` / `restore_baseline`): the sticky hook states past
  `PRESENCE_TTL`, and the notify cursor. The notify markers' mtimes are carried exactly as
  `[sec, nsec]`, because `File.mtime` has nanoseconds, and a cursor that comes back a hair
  early re-rings the alert it already rang.
- **`announce`.** It's true only if the old image was visible and ran an announcing scan
  within `REFRESH` + `ANNOUNCE_GRACE`. Otherwise the first reload is silent, so a switch-in
  reload never replays chimes another pane already rang. A missing field reads as silent.

`announce` also tells `restore_baseline` that the old image had scanned; only an announcing
scan counts. A pane with no hooked worktree carries an empty baseline, which would otherwise
restore as "never scanned" and swallow a `monitoring notify` that landed mid-reload.

**Writing it never fails.** `encode` never raises, and never writes something `decode` would
refuse:

- **Bad bytes are scrubbed.** Names that aren't valid UTF-8 get scrubbed, because git branch
  names can be any bytes, `JSON.generate` raises on them, and the whole fleet reloads at once.
- **An oversized payload drops the baseline.** Past `PAYLOAD_MAX`, the baseline is dropped,
  the cursor is kept, and `announce` goes false. With no notify cursor left, an announcing
  first scan would re-ring every alert, so a chime or alert landing during that reload is
  baselined silently. Dispatch pings are durable, so they still ring on the next scan.
- **A pending cursor travels as is.** A cursor still waiting for its row is passed on
  unchanged.
- **A crash hands over the minimum.** A raise in `resume_payload` hands over a minimal
  payload.

**A payload that won't decode is still a reload.** It reads as `BLANK`, not nil, so there's
no clear and no launch-time prune.

**On resume, the old frame stays up.** `setup` skips its `\e[2J`, and `run` skips the empty
first paint, so the old frame shows until the new one overwrites it. Off screen, the first
warm waits out the spread (`@warm_not_before`). The home sidebar skips its launch-time
prune, since a reload isn't a launch.

### A cross-version contract

The resume payload and the signal are a contract between versions, since an old sidebar
hands over to a new one:

- **Newer code accepts every older payload.** It reads each field leniently. One that won't
  decode is a blank resume, still a reload; only an absent payload is a cold start.
  `code_reload_test` pins a frozen v1 string.
- **The signals never change meaning.** `@sb_reload`, `@sb_reload_failed` and `SIGUSR1`
  keep what they mean.
- **`Creation` records stay readable by older launchers,** because a launcher
  (`Creator.launch`) lives as long as its agent and keeps the code it started with.

### How it's tested

`code_reload_test`, `sidebar_reload_test`, the reload summary in `upgrade_test` and
`cli_test`, and two smoke files.

Both smoke files run sidebars from a fake Homebrew prefix in the tmpdir
(`test/smoke/fake_keg.rb`: copies under `Cellar/switchboard/<keg>` plus an `opt` link;
`StablePath`'s pattern doesn't care what the prefix is).

- **`sidebar_reload_smoke_test`** covers the signal swap (same pane and pid, cursor kept),
  the backstop flip, a broken new version leaving the old sidebar alive, an untagged pane
  being respawned, and back-to-back reloads.
- **`upgrade_reload_smoke_test`** runs `upgrade --finish` as the installed binary (through a
  PATH symlink). It patches the running keg's code in place, so only the signal can make it
  show, and covers reloading in place, restarting, and another copy's finish leaving
  sidebars alone.

## Trade-offs, named

- **Per-process state on disk** vs. a shared daemon: simpler lifecycle (tmux owns
  it), at the cost of atomic-write discipline and self-healing GC on every state
  store.
- **Sleeping off-screen sidebars** save work but mean state can lag up to `IDLE`
  (8s) on an un-poked reappearance — a conservative backstop chosen over more
  tmux hook surface. A couple of edge paths (a `prefix-z` zoomed pane, a bare
  `tmux attach`) still lean on that backstop.
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

## Related

- [Explanation: architecture](explanation-architecture.md) — why tmux owns the lifecycle.
- [Explanation: agent presence](explanation-agent-presence.md) — the edges these scans consume.
- [Explanation: the sidebar's views](explanation-sidebar-views.md) — the shared view state these reloads carry.
- [Reference: keybindings](reference-keybindings.md) — the `C-l`/`C-r` pokes.
