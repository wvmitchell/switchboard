# Explanation: architecture

This explains *why* switchboard is shaped the way it is — the decisions a
contributor (or a future you) needs to hold in mind before changing anything. For
the *what*, see the [reference docs](reference-cli.md); for the agent-facing map,
see [CLAUDE.md](../CLAUDE.md).

## The problem

Conductor and emdash give a great glanceable view of parallel agent workspaces,
but they own a database, run an Electron app, and want the mouse. Switching
between worktrees means reaching for a trackpad or a command palette. The goal
was the same overview, driven entirely from the keyboard, with no daemon, no
database, and no build step — something that stands up on a fresh machine in one
command and gets out of the way.

That goal forces a few decisions.

## Git is the source of truth at runtime

Switchboard does not maintain a database of worktrees. It runs `git worktree
list` and renders what it finds. The config (`~/.config/switchboard/config.yml`)
is *only a registry* of which repos to scan — names and paths, plus a few
optional knobs.

This is the single most important design choice, and most of the others follow
from it:

- **No sync problem.** A worktree you create with plain `git`, or that emdash or
  Conductor creates, shows up the instant git knows about it. There's nothing to
  reconcile, no import step, no stale rows. emdash and Conductor are peers, not
  dependencies — their worktrees appear because git finds them.
- **No coupling.** The old emdash SQLite seed import was removed (issue #3).
  `install`/`init` write an empty config; the add-project flow grows it.
- **PR badges are the one thing git doesn't know,** so they come from `gh` —
  cached on disk (`~/.cache/switchboard/prs`) so the UI never blocks on the
  network. That cache is the only piece of external state, and it self-refreshes
  (see [agent presence](explanation-agent-presence.md) for the triggers).

The trade-off: every render shells out to `git`. That's cheap (worktree list is
fast, and the per-worktree reflog parse is cached by mtime), and it buys
correctness for free — the map is never out of date with the territory, because
the territory *is* the map.

### The PR cache never forgets a badge on its own

gh's queries are windows, not the full history: the 200 most recently *updated* PRs
(`--search sort:updated-desc`, falling back to the plain creation-ordered list if the
search API fails), plus every open PR up to `OPEN_LIMIT`. A merged PR that's been quiet
for a long time falls out of both. But its badge has to stay for as long as its row
renders; you remove a workspace or a branch, never a badge.

So the cache is *sticky*: `Pr.refresh` merges each fetch onto the previous map instead of
replacing it. Around that:

- **Rows the windows never saw get backfilled.** A branch that renders but never appeared
  in a query gets a capped per-branch `--head` lookup. `rendered_branches` is each
  non-primary worktree's reflog lineage. A branch with no PR is cached as null, so it's
  asked about only once.
- **Stale open badges are re-checked.** A cached OPEN badge missing from an open query
  that *wasn't* full is provably stale, so it's queried again.
- **A reused project name starts fresh.** A `//repo` identity marker keeps a project name
  reused for a different repo from inheriting the old repo's badges.
- **Writes are atomic.** Several sidebars refresh the same file, so the write goes through
  `MarkerBlock.atomic_write`.

## One data model, one front-end

```
Config ─┐
Git ────┼──▶ Model ──▶ Tree.nodes ──▶ Sidebar (the only front-end)
Pr  ────┘   (project    (ordered      (hand-rolled ANSI TUI in a
            → worktree   Node structs)  narrow tmux pane)
            tree)
```

- **`Model`** (`model.rb`) assembles the `project → worktree` tree from `Config`
  + `Git` + cached `Pr` data. A `Worktree` knows its branch (live HEAD, from git),
  its PR badge, and whether it's the project's primary checkout. (The struct also
  carries a dirty flag, but the sidebar builds the model `with_dirty: false` — 16
  per-worktree `git status` calls would be too slow on the synchronous paint, so
  dirty is left unread.)
- **`Tree.nodes`** (`tree.rb`) flattens that into an ordered list of `Node`
  structs: a project header, its workspaces, and — for a workspace that has held
  more than one branch — inline branch rows. The branch history comes from the
  worktree's own HEAD reflog (`Git.branch_history`), a signal neither GUI uses.
  This is the multiple-PRs-per-workspace case made visible.
- **`Sidebar`** draws the nodes as a 3-level tree in a fixed-width tmux pane. No
  fzf, no curses — a hand-rolled ANSI renderer. It is the *only* navigator.
  `sidebar.rb` is the run-loop core. The #57 split carved the rest into concern files
  under `sidebar/`: `edges`, a collaborator class that owns the agent-edge fan-out state,
  and the `render`, `input`, `actions`, `prompt` and `rows` mixins. It's one class in
  several files, each with its own `test/sidebar_*_test.rb` built on the shared
  `test/support/sidebar_case.rb`.
- **`view.rb`** is down to the compact PR-badge helpers the sidebar uses
  (`pr_identifier`, `pr_tag`): the state shown by color, and just the `#number`, to fit
  the ~40-column pane.

The primary trunk checkout (`primary`) is always filtered out as a switch target
(you never switch *to* `main`).

> There used to be a second front-end — an `fzf` popup picker (`picker.rb`,
> `Tree.lines`, the `view.rb` preview functions, and `_`-prefixed fzf-callback
> subcommands in `cli.rb`). It was removed so the sidebar is the single source of
> truth. References to it in old commits or issues are stale.

## The binary re-invokes itself to spawn the sidebar

`bin/switchboard` exports its own absolute path as `$SWITCHBOARD_BIN`. `tmux.rb`
uses that to `split-window` a pane running `switchboard sidebar` beside each
session. So the sidebar is just the same binary in a different mode, and tmux —
not a daemon — owns its lifecycle. The same trick lets the tmux hooks call back
into the binary (`poke-sidebar`, `sidebar-sync`, `tmux-bind`). `cli.rb` dispatches
the user-facing commands plus the tmux-internal ones like `toggle-sidebar` and
`poke-sidebar`.

Bare `bin/switchboard` adapts to where you run it (`CLI#start`). Inside tmux it toggles
the sidebar, like the bound key. From a plain shell it sets up and attaches the home
session (`Tmux.go_home`), so starting switchboard is always one command. Every command
and flag is in [Reference: the `switchboard` command](reference-cli.md).

## tmux is the window manager

Each worktree maps to exactly one tmux session named `sb/<project>/<leaf>`
(`tmux.rb`).

- **Switching** (`↵`) creates the session on demand and attaches a fixed-width
  sidebar pane. On a session switch, a tmux hook "pokes" the sidebar with `C-l`
  (`poke-sidebar`) so it reloads.
- **Only a new session gets a start line.** When `Tmux.ensure_session` *creates* a
  session (never on a re-switch), it types the session's `start` line into the window.
  `ensure_session` returns whether this call created it (false if it already existed or
  `new-session` failed), and a live session is never disturbed.
  - Switching into a workspace whose session died starts the project's resolved
    `session_command` (`Config#session_command_for`: a global default plus per-project
    overrides). That's the "how the agent starts" knob, for example
    `claude --dangerously-skip-permissions`. Empty means a plain shell.
  - A *new* workspace starts the dispatch launcher instead.
- **Creating** (`n`) happens in the background and never moves you. It writes a
  Creation record; a detached worker builds the worktree and opens a *detached*
  session, and the one line typed into it is `switchboard launch <dest>`. The
  launcher runs the `worktree_creation_command` (the setup a fresh checkout needs —
  `.env`, `bundle install`) through `sh -ec` as one argument, so a multi-line script
  survives intact and the first failing step stops it. Only after setup succeeds
  does it start the agent, as its own child — so the agent never opens on a
  half-built tree, whatever the `session_command` looks like. Setup runs once per
  *worktree*: a later switch back carries the bare `session_command`. See
  [background dispatch](explanation-background-dispatch.md) for the full lifecycle.
- **The `sb/` prefix is the ownership signal.** There's no separate session
  registry; a session named `sb/…` is switchboard's, anything else isn't. This is
  what lets `prune` reconcile sessions against worktrees (`reconcile.rb`) without
  tracking state — it diffs the live `sb/` sessions against the worktrees git
  reports.
- **`sb/home`** maps to no worktree (it lives in `$HOME`), so it never matches a
  project prefix and is never pruned. It's the safe fallback (deleting the
  workspace you're *in* switches you here first, then kills it) and the stable
  launch base (bare `switchboard` from a shell lands here).

## Adding a project

The add-project flow (`Registrar`, `registrar.rb`; the sidebar's `a`, and the CLI's
`add`, `clone` and `create`) has three modes:

- **register** a repo that's already on disk;
- **clone** one from a URL into `projects_root`;
- **create** a brand-new empty repo there.

All three end in the same `Config.add_project` write, so the CLI and the sidebar can't
drift apart.

Create is the subtle one (`Git.init`). A bare `git init` leaves an *unborn* HEAD, and the
`git worktree add … <base>` that `Creator` runs for `n` fails with `invalid reference`
against it. So `Git.init` makes an empty initial commit, which makes the repo
worktree-able right away. Around that commit:

- **No `-b`.** It honors your `init.defaultBranch`, and `register` reads the base from
  `current_branch`.
- **Your global setup can't break it.** `--no-gpg-sign` and `--no-verify` keep a global
  signing key or pre-commit hook from failing the synthetic commit.
- **A failure cleans up.** It removes `dest` on any failure, so a retry with the same name
  isn't blocked by a half-made repo.
- **The name has to be stable.** The name is free-form input, so `Registrar.create`
  rejects anything that wouldn't survive sanitizing unchanged (`\A[\w.-]+\z`, no leading
  dot). That keeps the source folder, the project name and Creator's worktree folder
  identical, with no `my repo` vs `my-repo` split.

## Install, doctor and prune

### Install is one command

Setup is `git clone && bin/switchboard install`, or for Homebrew
`brew tap wvmitchell/switchboard && brew trust wvmitchell/switchboard && brew install switchboard && switchboard install`
(`Installer`, `installer.rb`). Install does five things:

1. **Puts switchboard on your PATH.** It symlinks `bin/switchboard` into `~/.local/bin`,
   plus the short `sb` alias beside it. If something else already owns `sb`, the alias is
   skipped and the real command still installs.
2. **Wires tmux.** It adds a marker-delimited line to the tmux.conf tmux actually loads
   (found via `#{config_files}`), sourcing the self-locating `switchboard.tmux` fragment.
3. **Writes a starter config.** It's an annotated template (`Config::SCAFFOLD_TEMPLATE`)
   that shows every optional knob but whose only value-carrying keys are `worktree_root`
   and `projects`, so its *effective* config equals `default_data`.
4. **Offers the global codex hooks block.** This is opt-in and prompted, since it writes
   your personal `~/.codex/config.toml` (see
   [agent presence](explanation-agent-presence.md)). `--codex-hooks` and
   `--no-codex-hooks` skip the prompt, and without a terminal the default is no.
5. **Refreshes the Claude hooks in existing worktrees** that already have them, through
   the same `refresh_wiring` as `switchboard upgrade`, and only when run as the
   `switchboard` on your PATH.

A few details of the starter config matter:

- **Nested headers are present but empty.** The nested-map headers (`sounds`,
  `tmux_keys`, `sidebar_keys`) are uncommented but empty. An empty map reads exactly like
  an absent one (`@data["sounds"]` is nil either way), so they change nothing. But a child
  override is then one uncomment away with its parent already in place, and a key can't
  end up orphaned at the margin because its header was commented out.
- **Tests check the effective shape.** `assert_effective_default_config` compares the
  parse with the nil headers removed.
- **The comments are temporary.** They're stripped by the first `add_project` rewrite
  (a `YAML.dump`), after a new user has read them.
- **Misplaced keys are caught.** Stray top-level keys, usually a misindented child, are
  reported by `Config#unknown_keys` through `doctor`.

### The tmux fragment

The fragment runs `switchboard tmux-bind`, which binds the configured keys (see
[below](#configurable-tmux-keys)), and sets three indexed hooks:

- **`client-session-changed[99]`** pokes the now-visible sidebar to reload when you switch
  sessions.
- **`after-new-window[99]`** gives a new window its own sidebar when the session is showing
  one (see [per-session visibility](explanation-sidebar-lifecycle.md)).
- **`session-window-changed[99]`** pokes the sidebar when you switch *windows* within a
  session, which isn't a session change. It runs `poke-window`, gated to `sb/` sessions so
  the global hook does nothing elsewhere.

Every step is idempotent, and `uninstall` reverses all of them. It clears the three hook
slots (`Installer::HOOK_SLOTS`), the bound keys, the `@switchboard-*` options and the
global codex `[hooks]` block.

### What doctor checks beyond presence

**Hooks that are live, not just configured.** `doctor` reports whether those hooks are
loaded in the *running* server. They go stale after a `git pull` until tmux reloads.

**Orphaned sidebar processes.** A `switchboard sidebar` can outlive its pane. `doctor`
finds them by comparing the number of running sidebar processes (`pgrep`) with the number
of sidebar panes (`Tmux.sidebar_pane_count`). A straggler matters because tmux recycles
pane ids, so it can end up reading a different live pane and double-fire completion sounds.

### Prune only touches what it can prove is stale

**Sessions.** `prune` kills only `sb/` sessions under the prefix of a project it could
*verify*: one whose worktree listing is non-empty and that `Git.worktrees(strict: true)`
read in full. Every configured project it couldn't verify (a missing folder, a failed or
undecodable listing) protects its prefix, since another project's name may sanitize to the
same one (`app.dev` and `app-dev`).

**Orphaned sidebars.** `prune` also reaps them (`Reconcile.reap_sidebars`). It pairs each
running sidebar with its tty (`Tmux.sidebar_processes`) and SIGTERMs any whose tty matches
no live pane (`Tmux.live_pane_ttys`). So a sidebar that owns a pane is never touched, and an
empty or nil pane list (a flaky or garbled `tmux` read) reaps nothing rather than wiping
every sidebar.

**Only this server's sidebars.** `Tmux.sidebar_processes` is scoped by parent pid to the
tmux server's own children (`ppid == Tmux.server_pid`). A sidebar is a direct child of the
server that ran its `split-window`, so this machine-wide `ps` can only reach sidebars *this*
server owns. A different server's sidebar, such as your real one while a throwaway smoke or
sandbox server runs a prune, is out of range by construction, not just by an env check.

That closed a real bug: running the smoke suite used to SIGTERM the developer's live
sidebars. Their ttys aren't panes on the isolated server, but they're another server's
children, so the ppid scope now excludes them. It fails safe: a nil server pid, or a wrong
assumption about the process tree, reaps too little, never too much. `SWITCHBOARD_SANDBOX`
is a second guard on top of that: inside a throwaway server, the reap is skipped entirely
(see [the sandbox](#the-sandbox)).

Orphans mostly pile up from interrupted `bin/test-smoke` runs, whose daemon servers outlive
the run; the smoke harness now sweeps those before each run.

## Configurable tmux keys

The fragment leaves binding to `switchboard tmux-bind` (`Installer.apply_keybindings`,
issue #15). It reads `tmux_keys:` from the config through `Config#tmux_key`, which is
global and resolves with a default like `sound_for`: `toggle` defaults to `s`, and `home` is
unbound.

### Unbinding exactly what we bound

Cleanup remembers the key it bound last in tmux options (`@switchboard-toggle-key`,
`@switchboard-home-key`) and unbinds exactly that. It never scans `list-keys`, so it can't
clobber your own `switchboard` binding, and it survives the repo moving. tmux key bindings
and `@options` share a lifetime: both die when the server restarts.

The rest of the rules:

- **It binds before it unbinds,** so a key tmux rejects falls back to the default without
  losing the key you'd use to recover.
- **A displaced binding is recorded.** If binding replaced someone else's, that's recorded
  in `@switchboard-*-clobbered` for `doctor` to warn about. `ours?` means our bin path
  followed by *either* role's exact subcommand, so swapping toggle and home isn't counted as
  clobbering ourselves.
- **A refused key is remembered** in `@switchboard-<role>-rejected`.
- **One role never takes another's key.** Cleanup never unbinds a key another role wants or
  now holds (`taken:`), so swapping toggle and home keeps both.
- **Toggle wins a tie.** When the toggle's fallback lands on home's key, home yields, is
  recorded as refused, and `doctor` names it (`Installer.refused_key`).

The decision is the pure `Installer.rebind_ops`, unit-tested through the `run_tmux` seam.
Validation is a minimal denylist (`Config#valid_tmux_key?`), since tmux is the authority on
which keys are real.

**Keys ending in `;` need escaping.** tmux reads *any* argument ending in an unescaped `;`
(such as `C-;`) as a command separator, even through `system` with no shell. So
`Installer.run_tmux` escapes it to `\;`. tmux then records the bound key as a bare `;`, so
`Config#tmux_key` reads the tmux.conf spelling `C-\;` as `C-;`; otherwise the drift check
would never clear.

### Applying changes, and catching drift

Editing `tmux_keys` with `e` or `switchboard config` re-applies right away
(`reload_config_poke` and `edit_config` call `apply_keybindings`, and `announce: true`
flashes the result). A from-scratch `install` still needs a tmux reload.

A hand edit of `config.yml` shows up as *key drift* (`Installer.key_drift?`: the configured
key is neither the bound one nor a refused one). `doctor` shows a row per role, and `upgrade`
treats it as stale setup (`tmux_stale?`), so an otherwise up-to-date run re-applies it.

Drift is judged only against the config file the keys were bound from. `tmux-bind` records
that path in `@switchboard-config-path` (`Installer.bound_from?`), because the tmux server's
environment can resolve `config.yml` differently from your shell. Without that, a mismatch
would make every `upgrade` re-run forever.

### A malformed config

A malformed config never crashes anything. `Config#initialize` rescues the parse error to
`{}` plus a `load_error`. The sidebar keeps its last good config, and `tmux-bind` keeps the
keys already bound, binding the defaults only when none are.

But it's never silent either. `doctor`'s config row turns red, and `install` and `upgrade`
print the error and exit 1. `Installer.config_readable?` gates `refresh_wiring`, whose hook
refresh would otherwise walk zero projects and report success.

A file that parses to anything other than a map (a dropped colon makes one string, or a
bare `false`, or a list) counts as malformed too. Only an empty or comment-only file reads
as `{}`.

## Everything degrades, nothing crashes

The house rule, enforced everywhere: every shell-out escapes its args with
`Shellwords` and swallows stderr, and every failure returns `[]`/`{}`/`nil`
rather than raising into the UI. A lapsed `gh` token freezes the badges (it
doesn't blank them — see `Pr.refresh`); a malformed config degrades to empty, is
reported by `doctor` (`Config#load_data`), and makes `install`/`upgrade` print the
parse error and exit 1 (`Installer.config_readable?`); a missing audio player just stays
silent. The TUI is a long-lived loop with a person watching it, so a crash is the
worst outcome — worse than briefly-stale data. `doctor` exists precisely because
the UI degrades *quietly*: it's the honest surface where silent degradation
becomes visible.

## The sandbox

The sidebar is the whole UX, but it's a live tmux TUI the offline suite can't show you.
Checking a UI change means *looking* at it, and running an in-progress branch inside your
real tmux lets its own actions (`go_home`, a reconcile, a `quit`) land on your real `sb/`
sessions.

`switchboard sandbox` (`sandbox.rb`, issue #126) is the smoke harness with you as the
client. It:

1. boots a throwaway tmux server on an isolated socket;
2. seeds a self-contained repo with worktrees in a range of visual states: a `#12` PR
   badge, a big `+/−` diff, a row with no PR, an expanded multi-branch workspace, and
   agent dots;
3. points the integration at *this* checkout;
4. drops you into an attached home session you drive by hand;
5. tears down the whole server and its state when you detach.

### Shared with the smoke layer

The isolated-server scaffolding is shared with the smoke tests. `IsolatedServer`
(`isolated_server.rb`) owns the socket lifecycle:

- **`make_socket_dir`** makes a short, `0700`, symlink-safe directory with an
  unpredictable suffix.
- **`sweep_stale`** sweeps dead servers' directories, gated on the pid being dead, with a
  prefix per caller (smoke uses `sbk`, the sandbox `sbx`).
- **`isolated_socket?`** is the boundary-aware guard.

`SmokeCase` delegates to it, so the guard that keeps teardown away from a real server has
one source and can't drift.

### Teardown can't leak a server

Teardown and the sweep both go through one primitive,
`IsolatedServer.kill_server(sock_dir)`.

The bug it closes: a tmux daemon *outlives its socket*. Once the socket file is unlinked,
`tmux kill-server`, which finds the server by path, can never reach it. The old
socket-only teardown removed the directory after a kill that had merely been *attempted*,
which stranded a live daemon where `sweep_stale` (keyed by directory) could never find it.
About 15 such zombies had piled up.

So `kill_server` does both:

1. **`kill-server`,** confined by `kill_env`. That's the clean path while the socket is
   still there.
2. **A pid-kill guarantee.** `ensure_dead` SIGKILLs the server's pid, the only thing that
   reaches a daemon with no socket.

**Only the throwaway server's pid is ever killed.** The pid comes only from this server,
either read through its own confined socket or from a `server.pid` file that
`record_server_pid` writes at boot. That file stores `pid<TAB>start-time`, and
`recorded_pid` returns the pid only while the live process's start time still matches. A
pid that went stale and got *recycled* to another live process (even your real tmux
server) won't match, reads as nil, and is never killed. On top of that, `ensure_dead` only
SIGKILLs a process that's still a live `tmux`. So it can never reach your real server.

Callers remove the directory only *after* `kill_server` returns, so a kill that doesn't
take can no longer orphan a daemon.

`test/smoke/isolated_server_smoke_test.rb` verifies this: it unlinks a live server's socket
and asserts the server is still reaped by its recorded pid. The pure pieces
(`recorded_pid`, `tmux_comm?`, the recycle guard) are unit-tested offline.

### Walled off from your real state

`Sandbox` reuses `SandboxTest`'s full environment wall-off. `sandbox_env`:

- **Redirects every state path.** Every `SWITCHBOARD_*`, `XDG_*`, `GIT_CONFIG_*` and `GH_*`
  path goes into the throwaway tree, which sits *under* the socket directory so one sweep
  removes both.
- **Clears `TMUX` and `GH_TOKEN`.** Without clearing `TMUX`, a nested attach from inside
  your real tmux would fail.
- **Keeps your real `HOME`,** so the pane's shell, tmux and Ruby still work. That's safe
  because every state path is redirected.

The seeded config carries `base: main`, `projects:`, `auto_rename: false` and
`agent_state_hooks: false`, all in the emitted YAML. Without `base`, the repo (which has no
origin) would default to `origin/main` and break `n` and the diff counts. Without
`projects:`, the tree would be empty. The lone-pane trap from #64 is avoided by always
seeding a work pane plus sidebar split, which is never touched.

### Three things that would escape the isolated server

**Two are gated by switchboard itself.** The command exports `SWITCHBOARD_SANDBOX=1`, and
switchboard's own code checks it in two places:

- **`prune`'s `Reconcile.reap_sidebars` does nothing.** Its `ps`-based process list is
  machine-wide, so inside an isolated server every *real* sidebar would look orphaned and
  get SIGTERM'd.
- **The sidebar's background PR refresh (`maybe_refresh_prs`) doesn't spawn.** The seeded
  repo has no origin, so a refresh would fetch `{}` and wipe the badge you're dogfooding.

**The third is Claude Code's self-updater, which switchboard can't gate with its own
flag.** It would install under the redirected `XDG_DATA_HOME` but repoint the *global*
`~/.local/bin/claude` symlink there, which teardown then deletes, leaving
`command not found: claude` system-wide (#145). So `sandbox_env` also passes Claude its own
opt-outs, `DISABLE_UPDATES` and `DISABLE_AUTOUPDATER`, both set to 1. The first is the
documented superset of the second; both are set to be safe.

### Testing this checkout, not another

The checkout under test is found from `sandbox.rb`'s own `__dir__`, not the
symlink-resolved `SWITCHBOARD_BIN`, and printed as a banner. So running `switchboard
sandbox` from your PATH can't silently dogfood the canonical checkout instead.

`test/smoke/sandbox_smoke_test.rb` verifies that the seed renders, that view-state toggles
land in the throwaway tree, and that the self-updater guards reach a pane. The pure pieces
(`sandbox_env`, `isolated_socket?`, `stale_sock_dirs`, the `SWITCHBOARD_SANDBOX` guards) are
unit-tested offline.

## Trade-offs, named

- **Shelling out vs. a library.** Pure stdlib + `git`/`tmux`/`gh` subprocesses
  means zero gems and zero build step, but it means parsing porcelain output and
  paying process-spawn cost. Worth it: the install story is `git clone &&
  bin/switchboard install`, and the code stays readable.
- **Git as truth vs. a cache.** Re-deriving from git every render costs
  subprocesses but eliminates an entire class of staleness bugs. Caches are added
  only where the network is involved (PRs) or the parse is expensive (the reflog,
  memoized by mtime).
- **tmux as the substrate.** Leaning on tmux for sessions, panes, and hooks means
  switchboard does no window management itself, but it inherits tmux's quirks —
  most sharply, [recycled pane ids](explanation-sidebar-lifecycle.md), which drove
  a real duplicate-sound bug.

## Conventions

- Every file starts with `# frozen_string_literal: true`.
- Stateless helpers are `module_function` modules (`ClaudeHook`, `Tmux`, `Installer`,
  `Git`, `Pr`, …). Only `Model`, `Config`, `Sidebar` (plus its `Sidebar::Edges`
  collaborator — see above), and `AgentState` are classes — they hold state.
- Comments explain *why* a non-obvious thing is done, not *what* the code does.
  Match that density.

See [CONTRIBUTING](../CONTRIBUTING.md) for how this maps to the test suite. To run
switchboard locally against throwaway state, see the env overrides in
[Reference: config](reference-config.md#filesystem-locations).

## Related

- [Explanation: agent presence](explanation-agent-presence.md) — the dots, sounds, and bold.
- [Explanation: sidebar lifecycle](explanation-sidebar-lifecycle.md) — per-session visibility and the orphan bug.
- [Explanation: background dispatch](explanation-background-dispatch.md) — how `n` builds a workspace.
- [Reference: the `switchboard` command](reference-cli.md) — every command and flag.
- [Reference: config](reference-config.md) — the registry this all reads.
