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
- **`Sidebar`** (`sidebar.rb` — the run-loop core, plus the `sidebar/` concern
  files the #57 split carved out: `edges`, a collaborator owning the agent-edge
  fanout state, and the `render`/`input`/`actions`/`prompt`/`rows` concern
  mixins — one class in several files) draws the nodes as a 3-level tree in a
  fixed-width tmux pane. No fzf, no curses — a hand-rolled ANSI renderer. It is the *only*
  navigator.

The primary trunk checkout is always filtered out as a switch target (you never
switch *to* `main`).

> There used to be a second front-end — an `fzf` popup picker (`picker.rb`,
> `Tree.lines`, fzf-callback subcommands). It was removed so the sidebar is the
> single source of truth. References to it in old commits are stale.

## The binary re-invokes itself to spawn the sidebar

`bin/switchboard` exports its own absolute path as `$SWITCHBOARD_BIN`. `tmux.rb`
uses that to `split-window` a pane running `switchboard sidebar` beside each
session. So the sidebar is just the same binary in a different mode, and tmux —
not a daemon — owns its lifecycle. The same trick lets the tmux hooks call back
into the binary (`poke-sidebar`, `sidebar-sync`, `tmux-bind`).

## tmux is the window manager

Each worktree maps to exactly one tmux session named `sb/<project>/<leaf>`.

- **Switching** (`↵`) creates the session on demand and attaches a fixed-width
  sidebar pane. On *creation only* (never a re-switch), switchboard types the
  project's resolved `session_command` into the window — the "how the agent
  starts" knob. A live session is never disturbed.
- **Creating** (`n`) happens in the background and never moves you. It writes a
  Creation record; a detached worker builds the worktree and opens a *detached*
  session, and the one line typed into it is `switchboard launch <dest>`. The
  launcher runs the `worktree_creation_command` (the setup a fresh checkout needs —
  `.env`, `bundle install`) through `sh -ec` as one argument, so a multi-line script
  survives intact and the first failing step stops it. Only after setup succeeds
  does it start the agent, as its own child — so the agent never opens on a
  half-built tree, whatever the `session_command` looks like. Setup runs once per
  *worktree*: a later switch back carries the bare `session_command`. See CLAUDE.md
  "Background dispatch" for the full lifecycle.
- **The `sb/` prefix is the ownership signal.** There's no separate session
  registry; a session named `sb/…` is switchboard's, anything else isn't. This is
  what lets `prune` reconcile sessions against worktrees (`reconcile.rb`) without
  tracking state — it diffs the live `sb/` sessions against the worktrees git
  reports.
- **`sb/home`** maps to no worktree (it lives in `$HOME`), so it never matches a
  project prefix and is never pruned. It's the safe fallback (deleting the
  workspace you're *in* switches you here first, then kills it) and the stable
  launch base (bare `switchboard` from a shell lands here).

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

See [CONTRIBUTING](../CONTRIBUTING.md) for how this maps to the test suite.

## The command map, in detail

This is the full implementation detail [CLAUDE.md](../CLAUDE.md) points to; keep it current with the code.

```sh
bin/switchboard            # start: attach home from a shell, or toggle the sidebar inside tmux (alias: sb)
bin/switchboard install    # symlinks (switchboard + sb) onto PATH (skipped under Homebrew) + wire tmux bindings + empty config (--no-tmux/--print-tmux/--tmux-conf)
bin/switchboard upgrade    # fetch the newest version the way it was installed (brew / brew --HEAD / clone fetch + ff-only merge), then exec the NEW binary's `upgrade --finish`: refresh reporter + stale worktree hooks + codex block, run the tmux fragment in the live server from any shell, then reload every running sidebar in place (#48). Already current ⇒ says so, unless setup is stale (then finishes it, minus the sidebar reload, which needs new code)
bin/switchboard uninstall  # reverse install (both symlinks — left to `brew uninstall` under Homebrew — + tmux marker block + live unbind)
bin/switchboard doctor     # check that tmux/git/gh + config + install wiring exist
bin/switchboard init       # create ~/.config/switchboard/config.yml (empty; grown by the add-project flow)
bin/switchboard config     # open config.yml in $EDITOR (sidebar `e` does the same)
bin/switchboard sidebar    # run the persistent sidebar standalone (normally tmux-spawned)
bin/switchboard rename NAME # rename the current workspace from inside it (dir move + bridge + session rename + Claude `/resume` history carry + the git branch when safe — see #94; inside tmux it also spawns the session-name worker); for the agent to (re)name its own live workspace (#42). No NAME prints usage + the current name (switchboard doesn't guess one)
bin/switchboard monitoring on|off # flag/unflag this workspace as running a background monitor/loop (steady ∞ dot; bare = status). Agent- or human-invoked; re-run `on` each cycle to keep it live (liveness = marker mtime within Monitoring::TTL). Layer-2 SessionStart/SessionEnd hooks (monitoring-nudge) clear it per-session + nudge, gated on config background_presence
bin/switchboard monitoring notify # (from a MONITORED workspace) declare "come look — this cycle surfaced something": bold + a distinct `alert` sound + sparkle, the one exception to the silent routine ticks. Gated to monitored; writes an Attention bold (direct) + a Notify mtime marker (the sidebar's announce-gated ring). See the ∞ section.
bin/switchboard prune      # kill orphaned sb/ sessions (reconcile vs git worktrees) + reap orphaned sidebar processes; --dry-run/-n previews
bin/switchboard sandbox    # dogfood THIS checkout's sidebar in a throwaway, fully-isolated tmux — auto-torn-down on detach (the interactive twin of bin/test-smoke, #126)
bin/switchboard reload-sidebars # every running sidebar swaps in its OWN binary's current code, in place (SIGUSR1 to tagged panes, respawn for older ones — #48); inside the sandbox, the dogfood loop for a sidebar code edit
bin/switchboard quit       # close ALL sb/ sessions (full teardown; current session last; clears agent state)
bin/test                   # run the stdlib-Minitest suite (offline; bin/test <file> for one)
bin/test-smoke             # run the real-tmux smoke layer (boots a server; needs tmux; out of bin/test — #104)
```

## Install, doctor and prune, in detail

This is the full implementation detail [CLAUDE.md](../CLAUDE.md) points to; keep it current with the code.

Setup is one command: `git clone && bin/switchboard install` (or `brew tap
wvmitchell/switchboard && brew trust wvmitchell/switchboard && brew install switchboard &&
switchboard install`) (`Installer`, `installer.rb`). It symlinks `bin/switchboard` to `~/.local/bin` (plus a short
`sb` alias beside it; a collided `sb` is skipped, the real command still
installs), adds a
marker-delimited line to the tmux.conf tmux actually loads (found via
`#{config_files}`) that sources the self-locating `switchboard.tmux` fragment,
and scaffolds a config (an **annotated template** — `Config::SCAFFOLD_TEMPLATE`,
whose only **value-carrying** keys are `worktree_root` + `projects`, so its
*effective* config equals `default_data` while showing every optional knob. The
nested-map headers (`sounds`/`tmux_keys`/`sidebar_keys`) are uncommented but **empty**
— an empty map reads identically to absent (`@data["sounds"]` is nil either way), so
they change nothing, yet a child override is a single uncomment away with its parent
already in place (the anti-trap: a key can't get orphaned at the margin because its
header is never commented). Tests assert the effective shape via
`assert_effective_default_config` — the parse minus nil headers. Comments are stripped
on the first `add_project` YAML.dump rewrite, after the new user has read them.
Stray top-level keys (a misindented child) are caught by `Config#unknown_keys` →
`doctor`.) Finally it offers to install the **global codex hooks** block — opt-in,
prompted (`--codex-hooks` / `--no-codex-hooks` skip the prompt; default no on a
non-tty), since it writes the user's personal `~/.codex/config.toml` (see the
agent-state-dots section). The fragment runs `switchboard tmux-bind` (which
binds the configured keys — see keybindings below) and sets three indexed hooks:
`client-session-changed[99]` (poke the now-visible sidebar to reload on a session
switch), `after-new-window[99]` (give a new window its own sidebar when the session
is showing one — see per-session visibility below), and `session-window-changed[99]`
(poke the sidebar on a same-session *window* switch, which isn't a session change —
`poke-window`, gated to `sb/` sessions so the global hook no-ops elsewhere). All
steps are idempotent and reversed by `uninstall` (which clears all three hook slots
— `Installer::HOOK_SLOTS` — plus the bound keys, the `@switchboard-*` options, and the
global codex `[hooks]` block). `doctor` reports whether
those hooks are **live** in the running server, not just present in config (they
go stale after a `git pull` until tmux reloads). `doctor` also flags **orphaned
sidebar processes** — a `switchboard sidebar` that outlived its pane — by diffing
the running-process count (`pgrep`) against the sidebar-pane count
(`Tmux.sidebar_pane_count`); a straggler matters because tmux recycles pane ids,
so it can end up reading a different live pane and double-fire completion sounds.
`prune` kills only `sb/` sessions under the prefix of a project it could VERIFY (a
non-empty listing that `Git.worktrees(strict: true)` reads in full); every configured
project it couldn't (missing folder, failed or undecodable listing) protects its
prefix — another project's name may sanitize to the same one (`app.dev` / `app-dev`).
It also **reaps** those orphaned sidebars (`Reconcile.reap_sidebars`): it pairs each running sidebar
with its tty (`Tmux.sidebar_processes`) and SIGTERMs any whose tty matches no live
pane (`Tmux.live_pane_ttys`) — so a sidebar that owns a pane is never touched, and
a nil/empty pane list (a flaky/garbled `tmux` read) reaps nothing rather than wipe
every sidebar. Crucially `Tmux.sidebar_processes` is **scoped to this server's own
children by parent pid** (`ppid == Tmux.server_pid`): a sidebar is a direct child of
the tmux server that split-window'd it, so this machine-global `ps` can only ever
reach sidebars *this* server owns — a **different** server's sidebar (the dev's real
one, when a throwaway smoke/sandbox server runs a prune) is structurally out of range,
not merely env-gated. That closes the bug where running the smoke suite SIGTERM'd the
developer's live sidebars: their tty is no pane on the isolated server, but they're
another server's children, so the ppid scope excludes them. It fails safe — a nil
server pid, or a wrong process-tree assumption, under-reaps (never over-reaps). The
`SWITCHBOARD_SANDBOX` env guard is the belt over that structural scope: inside a
throwaway server it skips the reap entirely (see the sandbox section). They accumulate
mostly from interrupted `bin/test-smoke` runs, whose daemon servers outlive the run;
the smoke harness now sweeps those before each run.

## Configurable tmux keys, in detail

This is the full implementation detail [CLAUDE.md](../CLAUDE.md) points to; keep it current with the code.

**Configurable keybindings (issue #15).** The fragment delegates binding to
`switchboard tmux-bind` (`Installer.apply_keybindings`), which reads `tmux_keys:`
from config (`Config#tmux_key` — global, resolve-with-default like `sound_for`;
`toggle` defaults to `s`, `home` is unbound). Cleanup tracks the key it bound last
in tmux options (`@switchboard-toggle-key` / `@switchboard-home-key`) and unbinds
exactly that — never a scan of `list-keys`, so it can't clobber a user's own
`switchboard` binding and survives a repo move (tmux key bindings and `@options`
share a lifetime: both die on server restart). It binds before it unbinds, so a
key tmux rejects falls back to the default without stranding the recovery key, and
records a displaced foreign binding in `@switchboard-*-clobbered` for `doctor` to
warn about (`ours?` = our bin path followed by EITHER role's exact subcommand, so a
toggle/home swap isn't a clobber of ourselves). A refused key is remembered in
`@switchboard-<role>-rejected`. Cleanup never unbinds a key another role wants or now
holds (`taken:`), so swapping toggle and home keeps both; and when the toggle's
fallback lands on home's key, the **toggle wins** — home yields, is recorded as
refused, and `doctor` names it (`Installer.refused_key`). The decision is the pure
`Installer.rebind_ops` (unit-tested via the `run_tmux` seam); validation is a
**minimal denylist** (`Config#valid_tmux_key?`) — tmux is the authority on real keys.
A key ending in `;` (`C-;`) needs care: tmux reads ANY argv element ending in an
unescaped `;` as a command separator, even via `system` with no shell, so
`Installer.run_tmux` escapes it to `\;`; tmux records the bound key as the bare `;`,
so `Config#tmux_key` reads the tmux.conf spelling (`C-\;`) as `C-;`, or drift would
never clear.
Editing `tmux_keys` via `e`/`switchboard config` re-applies immediately
(`reload_config_poke` / `edit_config` call `apply_keybindings`, `announce: true`
flashing the result); a from-scratch `install` still needs a tmux reload. A hand edit
of config.yml is caught as **key drift** (`Installer.key_drift?`: configured ≠ bound
and ≠ refused) by `doctor` (a row per role) and by `upgrade` (`tmux_stale?`, so an
up-to-date run re-applies it). Drift is judged only against the config file the keys
were bound from — `tmux-bind` records it in `@switchboard-config-path`
(`Installer.bound_from?`) — because the tmux server's environment can resolve
config.yml differently from your shell; without that, a mismatch would make every
`upgrade` re-run forever. A malformed config never crashes anything —
`Config#initialize` rescues the parse error to `{}` + `load_error` (the sidebar keeps
its last-good config; `tmux-bind` keeps the keys already bound, and binds the defaults
only when none are) — but it is never
silent either: `doctor`'s config row turns red, and `install` / `upgrade` print it
and exit 1 (`Installer.config_readable?` gates `refresh_wiring`, whose hook refresh
would otherwise walk zero projects and report success). A file that parses to
anything but a map (a dropped colon makes one string, a bare `false`, a list) is
malformed too; only an empty or comment-only file reads as `{}`.

## Environment overrides for local runs

This is the full implementation detail [CLAUDE.md](../CLAUDE.md) points to; keep it current with the code.

Useful env overrides when running locally without disturbing real state:
`SWITCHBOARD_CONFIG` (config path), `SWITCHBOARD_STATE_DIR` (agent-state files),
`SWITCHBOARD_ATTENTION_DIR` (bold "needs attention" markers),
`SWITCHBOARD_RELEASES_URL` (where `LatestRelease` reads release tags — the suite points
it at a dead path so nothing reaches GitHub), `SWITCHBOARD_UPDATE_CACHE` (the update
line's cache file) and `SWITCHBOARD_NO_UPDATE_CHECK` (no background update check — the
suite, smoke runs and the sandbox set it), `SWITCHBOARD_RELOAD_SPREAD` (seconds an
off-screen sidebar may wait before a code reload, default 30 — the reload smoke sets 0),
`XDG_DATA_HOME`/`XDG_STATE_HOME` (reporter script + state dirs), `CODEX_HOME` (the
global codex `config.toml` the codex hooks block is written into — sandboxed in tests).

## The runtime model, in detail

This is the full implementation detail [CLAUDE.md](../CLAUDE.md) points to; keep it current with the code.

**Git is the source of truth at runtime; the config is just a project registry.**
Worktrees are discovered live via `git worktree list`; the config
(`~/.config/switchboard/config.yml`) only lists which repos to scan. emdash and
Conductor are peer tools whose worktrees still show up (git finds them), but
there's **no database coupling** — `install`/`init` write an empty config and
the add-project flow grows it (the old emdash SQLite seed import was removed in
issue #3). PR badges come from `gh`, cached on disk (`~/.cache/switchboard/prs`)
so the UI never blocks on the network. The cache is **sticky** (`Pr.refresh`
merges each fetch ONTO the previous map, never replaces): gh's queries are
windows — the 200 most recently *updated* PRs (`--search sort:updated-desc`,
falling back to the plain creation-ordered list if the search API fails) plus
every open PR up to `OPEN_LIMIT` — so a long-quiet merged PR falls out of both,
but its badge must outlive that for as long as its row renders (you remove a
workspace or branch, never a badge). Rendered branches the windows never saw get
a capped per-branch `--head` backfill (`rendered_branches` = each non-primary
worktree's reflog lineage; no-PR branches are negative-cached as null so they're
asked once); a cached OPEN badge absent from a *non-full* open query is provably
stale and re-queried; a `//repo` identity marker keeps a project name reused for
a different repo from inheriting the old badges; and the write rides
`MarkerBlock.atomic_write` because concurrent sidebar refreshers share the file.

The **add-project flow** (`Registrar`, `registrar.rb`; sidebar `a`, CLI
`add`/`clone`/`create`) has **three modes** that all funnel through one
`Config.add_project` write so the CLI and sidebar never drift: **register** a repo
already on disk, **clone** one from a URL under `projects_root`, or **create** a
brand-new empty one there. The subtle one is create (`Git.init`): a bare `git init`
leaves an **unborn HEAD**, and `Creator`'s `git worktree add … <base>` (what `n`
runs) fails `invalid reference` against it — so `Git.init` makes an **empty initial
commit** to birth the repo, immediately worktree-able. No `-b`: it honors the user's
`init.defaultBranch` and `register` derives the base from `current_branch`.
`--no-gpg-sign`/`--no-verify` keep a global signing key or pre-commit hook from
failing the synthetic commit, and it removes `dest` on any failure so a same-name
retry isn't blocked by a half-made repo. The name is free user input, so
`Registrar.create` rejects anything not sanitize-stable (`\A[\w.-]+\z`, no leading
dot) — keeping the source dir, the project name, and Creator's worktree segment
identical (no `my repo` vs `my-repo` divergence).

**One data model, one front-end.** `Model` (`model.rb`) assembles the
`project → worktree` tree from `Config` + `Git` + cached `Pr` data. `Tree.nodes`
(`tree.rb`) turns that into ordered `Node` structs, which the **persistent
sidebar** (`sidebar.rb` — the run-loop core; #57 split the rest into `sidebar/`
concern files: `edges.rb`, a collaborator class owning the agent-edge fanout
state, plus the `render`/`input`/`actions`/`prompt`/`rows` concern mixins — one
class in several files, each with its own `test/sidebar_*_test.rb` over the
shared `test/support/sidebar_case.rb`) draws as a hand-rolled ANSI TUI in a narrow tmux pane
(no fzf). It's the only navigator. The bound tmux key toggles it; bare
`bin/switchboard` is context-aware (`CLI#start`) — inside tmux it toggles the
sidebar like the key, from a plain shell it bootstraps and attaches the home
session (`Tmux.go_home`), so launching switchboard is a single command.
`view.rb` is now reduced to the
compact PR-badge helpers the sidebar uses (`pr_identifier` / `pr_tag`: state via
color, just the `#number` to fit the ~40-col pane).

> Until recently there was a second front-end — an `fzf` popup picker
> (`picker.rb`, `Tree.lines`, the `view.rb` preview functions, and `_`-prefixed
> fzf-callback subcommands in `cli.rb`). It was removed so the sidebar is the
> single source of truth; if you see references to it in old commits or issues,
> that's why it's gone.

The sidebar expands a workspace that has multiple branches in its HEAD-reflog
history into inline child rows (`Git.branch_history`) — the
multiple-PRs-per-workspace case. The canonical trunk checkout (`primary`) is
always filtered out as a switch target.

**The binary re-invokes itself to spawn the sidebar.** `bin/switchboard` exports
its own absolute path as `SWITCHBOARD_BIN`; `tmux.rb` uses it to `split-window`
a pane running `switchboard sidebar` beside each session. `cli.rb` dispatches the
user-facing commands plus the tmux-internal `toggle-sidebar` / `poke-sidebar`.

**tmux mapping** (`tmux.rb`): each worktree ⇆ one session named
`sb/<project>/<leaf>`. Switching creates the session on demand and attaches a
fixed-width sidebar pane. The sidebar reloads on session-change via a tmux hook
that "pokes" it with `C-l` (`poke-sidebar`). On the *creation* of a session
(only — never a re-switch), `Tmux.ensure_session` types its `start` line into the
window. For a re-switch into a workspace whose session died, that's the project's
resolved `session_command` (`Config#session_command_for`, global default +
per-project override) — the "how the agent starts" knob, e.g. `claude
--dangerously-skip-permissions`; for a NEW workspace it's the dispatch launcher (see
Background dispatch below). Empty ⇒ a plain shell. `ensure_session` returns whether
THIS call created the session (false if it existed or new-session failed).

## The sandbox, in detail

This is the full implementation detail [CLAUDE.md](../CLAUDE.md) points to; keep it current with the code.

The sidebar is the whole UX but it's a live tmux TUI the offline suite can't show
you, so verifying a UI change means *looking* at it — and running an in-flight
branch inside your real tmux lets its self-actions (`go_home`, a reconcile, a
`quit`) land on your real `sb/` sessions. `switchboard sandbox` (`sandbox.rb`) is
**"the smoke harness, but you're the client":** it boots a throwaway tmux server on
an isolated socket, seeds a hermetic repo with worktrees in varied visual states (a
`#12` PR badge, a big `+/−` diff, a no-PR row, an expanded multi-branch workspace,
agent dots), points the integration at **this** checkout, drops you into an attached
home session you drive by hand, and tears the whole server + state down on detach.

The isolated-server scaffolding is **shared** with the smoke layer: `IsolatedServer`
(`isolated_server.rb`) owns the socket lifecycle — `make_socket_dir` (short `0700`,
unpredictable suffix, symlink-safe), the dead-pid-gated `sweep_stale` (prefix-
parameterized: smoke uses `sbk`, the sandbox `sbx`), and the boundary-aware
`isolated_socket?` guard. `SmokeCase` delegates to it, so the guard that stops
teardown from reaching a real server is single-source and can't drift.

Teardown/sweep go through one primitive, `IsolatedServer.kill_server(sock_dir)`,
which is why a throwaway server can't leak. The subtle bug it closes: a tmux daemon
**outlives its socket** — once the socket file is unlinked, `tmux kill-server` (path-
based) can never reach it, so the old socket-only teardown, which removed the dir
after a merely-*attempted* kill, stranded a live daemon where `sweep_stale` (dir-keyed)
could never find it (~15 such zombies had accumulated). So `kill_server` does BOTH:
`kill-server` (confined by `kill_env` — the clean path while the socket is live) AND a
**pid-kill guarantee** — `ensure_dead` SIGKILLs the server's pid, which is the only
thing that reaches a socketless daemon. The pid comes only from THIS throwaway server
(a read through the server's own confined socket, or a `server.pid` file
`record_server_pid` writes at boot). That recorded pid is **identity-checked** — the file
stores `pid<TAB>start-time`, and `recorded_pid` returns it only when the live process's
start-time still matches, so a pid that went stale and was **recycled** to another live
process (even the dev's real tmux server) mismatches → nil → never killed; `ensure_dead`
additionally only SIGKILLs a still-live `tmux` process. So it can never reach the dev's
real server. Callers remove the dir only *after* `kill_server` returns, so a kill that
doesn't take can no longer orphan a daemon. Verified by `test/smoke/isolated_server_smoke_test.rb`
(unlink a live server's socket, assert it's still reaped by recorded pid), with the pure
pieces (`recorded_pid`, `tmux_comm?`, the recycle guard) unit-tested offline. `Sandbox` reuses `SandboxTest`'s **full** env wall-off — `sandbox_env`
redirects every `SWITCHBOARD_*`/`XDG_*`/`GIT_CONFIG_*`/`GH_*` path into the throwaway
tree (co-located **under** the socket dir, so one sweep reaps both), clears `TMUX`
(else a nested attach from inside your real tmux fails) and `GH_TOKEN`, and keeps
real `HOME` (the pane shell/tmux/ruby stay usable — safe because every state path is
redirected). The seeded config carries `base: main` + `projects:` + `auto_rename:
false` + `agent_state_hooks: false` (in the emitted YAML — without base the no-origin
repo defaults to `origin/main` and `n`/diff break; without `projects:` the tree is
empty). The `#64` lone-pane trap is avoided by always seeding a work-pane+sidebar
split, never touched.

Two operations would otherwise reach **outside** the isolated server, so the command
exports **`SWITCHBOARD_SANDBOX=1`** and switchboard's own code checks it: `prune`'s
`Reconcile.reap_sidebars` no-ops (its `ps`-based process list is machine-global, so
inside an isolated server every *real* sidebar would read as an orphan and get
SIGTERM'd), and the sidebar's background PR refresh (`maybe_refresh_prs`) skips its
spawn (the seeded repo has no origin, so a refresh would fetch `{}` and clobber the
badge you're dogfooding). A third escape isn't switchboard's to gate with its own flag:
Claude Code's self-updater would install under the redirected `XDG_DATA_HOME` yet repoint
the **global** `~/.local/bin/claude` symlink there, which teardown then deletes
(`command not found: claude` system-wide, #145) — so `sandbox_env` also passes claude its
own opt-outs, `DISABLE_UPDATES` + `DISABLE_AUTOUPDATER`=1 (the former is the documented
superset of the latter; both set as belt-and-suspenders). The checkout under test is
resolved from `sandbox.rb`'s own `__dir__` (NOT the symlink-resolved `SWITCHBOARD_BIN`)
and printed as a banner, so a PATH `switchboard sandbox` can't silently dogfood the
canonical checkout. Verified by `test/smoke/sandbox_smoke_test.rb` (seed renders +
view-state toggles land in the throwaway tree + the self-updater guards propagate to a
pane), with the pure pieces (`sandbox_env`, `isolated_socket?`, `stale_sock_dirs`, the
`SWITCHBOARD_SANDBOX` guards) unit-tested offline.


## Related

- [Explanation: agent presence](explanation-agent-presence.md) — the dots, sounds, and bold.
- [Explanation: sidebar lifecycle](explanation-sidebar-lifecycle.md) — per-session visibility and the orphan bug.
- [Reference: config](reference-config.md) — the registry this all reads.
