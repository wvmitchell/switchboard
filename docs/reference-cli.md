# Reference: the `switchboard` command

Every subcommand switchboard dispatches, its arguments, and what it does. The
binary is installed on PATH as both `switchboard` and the short alias `sb` (use
either). Run it from a clone as `bin/switchboard`.

Bare `switchboard` is context-aware: from a plain shell it bootstraps and
attaches the home session; inside tmux it toggles the sidebar. Everything else is
the config/worktree-management surface.

> Dispatch lives in `lib/switchboard/cli.rb`. An unknown subcommand prints the
> help and exits non-zero.

---

## User commands

### `switchboard`
Start or reach switchboard. Outside tmux: bootstrap + attach the home session
(`sb/home`). Inside tmux: toggle the sidebar (summon + focus when hidden, dismiss
session-wide when visible). The single command to launch from anywhere.

### `switchboard home`
Attach the persistent home session explicitly. Home maps to no worktree (it lives
in `$HOME`), carries its own sidebar, and is the stable launch + settings base.
Landing here also prunes orphaned `sb/` sessions unless `prune_on_launch: false`.

### `switchboard install [--no-tmux] [--print-tmux] [--tmux-conf PATH] [--codex-hooks] [--no-codex-hooks]`
Stand switchboard up from a fresh clone or a Homebrew install. Idempotent. Five steps:

1. Symlink `switchboard` (and the `sb` alias) into `~/.local/bin` (or
   `$SWITCHBOARD_BIN_DIR`). Skipped under Homebrew, which already put both on
   your PATH (reported as `on PATH via Homebrew`).
2. Add one marker-delimited line to the tmux.conf tmux actually loads, sourcing
   the self-locating `switchboard.tmux` fragment (binds the keys + sets the hooks).
3. Scaffold an annotated starter config if none exists.
4. Offer to install the global **Codex** agent-state hooks — a marker-delimited
   `[hooks]` block in `~/.codex/config.toml` (codex can't discover project-local
   hooks in linked worktrees, so its hooks are global, not per-worktree). Prompts
   for consent; default no on a non-tty. After installing, run `/hooks` in codex
   once to trust them (or start codex with `--dangerously-bypass-hook-trust`).
   If the block is already there, it's re-ensured without a prompt. Tables codex
   itself wrote inside the block (`[desktop]`, `[plugins."…"]`, …) are moved,
   unchanged and in order, to just above it, and your `/hooks` approvals are kept.
5. Update the Claude hooks in existing worktrees that already have them, as
   `switchboard upgrade` does (only when run as the `switchboard` on your PATH).

| Flag | Effect |
|------|--------|
| `--no-tmux` | Skip the tmux.conf edit (symlink + config only). |
| `--print-tmux` | Print the tmux line instead of writing it. |
| `--tmux-conf PATH` | Target a specific tmux.conf instead of the auto-detected one. |
| `--codex-hooks` | Install the global codex hooks block without prompting. |
| `--no-codex-hooks` | Skip the codex step entirely (no prompt). An existing block is left untouched, not re-ensured. |

If a codex write is attempted and refused or fails (your own `[hooks]` outside the
block, a block switchboard can't rewrite safely, codex writing the file mid-install,
or a file it can't write),
the other steps still run, the closing line reads `Done, except the codex hooks
(✗ above)`, and `install` exits 1. The ✗ line says what to fix.

If `config.yml` won't parse, or parses to something that isn't a map of settings,
`install` prints the parse error instead of refreshing your worktrees' hooks (it can't
list the projects), the closing line reads `Done, except the config (✗ above)`, and it
exits 1.

Backs up the target tmux.conf (and `~/.codex/config.toml`) to `.bak` before its
first edit. See [How-to: keybindings](howto-keybindings.md) for the wiring it
installs.

Under Homebrew, every path it writes uses the stable `<prefix>/opt/switchboard`
link rather than the versioned `Cellar` folder, so the wiring survives
`brew upgrade` + `brew cleanup` (see
[Explanation: distribution](explanation-distribution.md)).

### `switchboard upgrade`
Update switchboard and bring the setup up to date. First it checks for a newer
version: the newest release tag on GitHub for a Homebrew install, the upstream branch
for a clone. Then, if there is one, or it can't tell (a `--HEAD` install, offline, a
branch with no upstream):

1. Fetches it: `brew update` + `brew upgrade switchboard` (Homebrew), `brew upgrade
   --fetch-HEAD switchboard` (a `--HEAD` install), or `git fetch` + `git merge
   --no-overwrite-ignore --ff-only @{upstream}` (a clone; refused while tracked files
   have uncommitted changes, and git itself refuses an update that would overwrite an
   untracked or ignored file).
2. Hands off to the new binary, which:
   - refreshes the agent-state reporter script;
   - updates the Claude hooks in every worktree of the configured projects that
     already has them, when the hooks differ from this version's. It never adds hooks
     where there are none. A file Claude changed mid-update is skipped and reported, and
     so is a broken (unparseable) settings file holding switchboard's hooks, with the
     specific reason;
   - re-ensures the global codex block if it's installed (never adds one);
   - runs `switchboard.tmux` in the running tmux server, from any shell, when your
     tmux.conf sources this install.

   The first three run only when the running binary is the `switchboard` on your PATH,
   because the hooks and the reporter call back into whichever binary wrote them; from
   any other copy (a clone's `bin/switchboard`, say) the worktree hooks are skipped with
   a note, and the reporter and codex block are left as they are.

Already current, it prints `switchboard X is up to date` and exits 0, unless the setup
is stale (old worktree hooks, hook slots or the toggle key not live, a `tmux_keys`
change made by editing `config.yml` by hand, an old or missing reporter, or an old
codex block), in which case it runs step 2. If `config.yml` won't parse, it finishes
whatever setup doesn't need the config, then prints the parse error and exits 1 rather
than reporting "up to date". Exits 1 if a fetch or setup step fails,
and also when `brew update` failed and nothing was upgraded (Homebrew may not have the
newest release, so it says so instead of "nothing newer"). A `brew update` failure is
only a note when the upgrade still lands.
A release tag Homebrew doesn't have yet is reported, not treated as an error, and so is
a fetch that brought nothing new ("Homebrew has nothing newer", "already the newest
commit on your branch"); as when already current, a stale setup still gets step 2.

### `switchboard uninstall [--tmux-conf PATH]`
Reverse `install`: remove both symlinks (under Homebrew it leaves PATH to
`brew uninstall switchboard` and says so), the tmux marker block, the bound keys,
the three hook slots, the `@switchboard-*` tmux options (also live-unbinds in
a running server), and the global codex `[hooks]` block from `~/.codex/config.toml`
if present. Your config and agent state are left untouched.

The codex block goes **first**. Only switchboard's part of it is removed: tables
codex wrote inside it, and `/hooks` approvals for other hook files, stay (moved to
just above where the block was). If the block can't be removed safely, or codex
rewrites the file mid-run, `uninstall` stops before removing anything else and
exits 1; fix what the ✗ line names, then re-run it. If the removal itself fails to
write (or the codex config turns unreadable mid-run), the rest of the uninstall still runs, the
closing line reads `Done, except the codex hooks (✗ above)`, and it exits 1.

### `switchboard init`
Create an empty (annotated) config if none exists. No-op with a message if one
already exists. `install` runs this for you. Add your first project with `a` in
the sidebar or `switchboard add`.

### `switchboard config` (alias: `edit`)
Open `config.yml` in `$EDITOR` in the current terminal, scaffolding a stub first
so there's always a real file. On exit, re-applies `tmux_keys` immediately if
you're inside tmux. The sidebar's `e` does the same but in a dedicated pane beside
the home tree.

### `switchboard add <name> <path> [base-ref]`
Register an existing local git repo. `name` is the display/session name; `path`
is the repo working dir; `base-ref` (optional) overrides the global `base` for
that project. The repo on disk is untouched. Errors if the path isn't a git repo
or the name is taken.

### `switchboard remove <name>` (alias: `rm`)
Unregister a project from the config. The repo and its worktrees on disk stay;
re-add it any time. Unlike the sidebar's `d`, it does not tear down sessions
(`prune` cleans those up).

### `switchboard clone <git-url> [name]`
Clone a repo under `projects_root`, then register it. `name` defaults to the
URL's basename (`git@host:org/repo.git` → `repo`). Errors if the name is taken or
the destination exists.

### `switchboard refresh [name] [--poke PANE]`
Re-fetch PR badges from `gh` and merge the result onto the on-disk cache (a
cached badge is only ever updated, never dropped — it persists even after its
PR falls out of gh's query windows, until the branch or workspace goes away).
With a project name, just that project; otherwise all. Normally you don't run this — the sidebar
refreshes badges automatically (on agent completion, on switch-in, and on an idle
backstop). Run it to catch a PR you merged or closed *on GitHub* (which fires no
local signal). `--poke PANE` is used internally by the sidebar to redraw a
specific pane.

### `switchboard enable-hooks [path]`
Wire exact agent-state hooks for the **Claude** worktree adapter
(`<worktree>/.claude/settings.local.json`) — scoped to that worktree, never your
global `~/.claude`. Defaults to the worktree you're standing in; pass a path to
target another. A running `claude` there picks them up on its own. New switchboard-created
worktrees get this automatically.

Codex is **not** wired here: it can't discover project-local hooks in a linked
worktree, so its hooks ship as one global block in `~/.codex/config.toml`,
installed once via `switchboard install --codex-hooks` (or the install prompt).
`enable-hooks` re-ensures that global block if it's already present, and exits 1
if that codex write is refused (the Claude hooks are still wired). It also exits 1
when the Claude hooks couldn't be written (a settings file that isn't valid JSON or
UTF-8, has a malformed hooks section, can't be read, isn't a regular file under 4 MiB,
or can't be written: fix it, then re-run; `doctor` names the reason) or the reporter
script couldn't be.

### `switchboard disable-hooks [path]`
Remove switchboard's Claude hooks from a worktree, leaving any other settings
intact. Defaults to the current worktree. (The global codex block is deliberately
left — it's not per-worktree; `switchboard uninstall` removes it.)

### `switchboard rename <name>`
Rename the workspace you're standing in: moves the worktree directory to `<name>`
(the display leaf) and renames its `sb/` tmux session in place, so a running agent
and its conversation survive. This is the verb for an **agent to (re)name its own
live workspace** once it knows what the work actually is — the sidebar's `r` key
does the same from the tree.

**Renaming mid-task is safe** — the dir move doesn't strand your running shell. The
move leaves a symlink bridge at the old path (below), so a frozen cwd keeps
resolving and the session is renamed in place, never restarted. So an agent should
rename the moment it knows the name, not defer to the end to avoid moving its own
directory.

**It also renames the git branch** to match — `<branch_prefix>/<name>` (the dir
stays the bare `<name>`) — but only when that's safe: the branch is still the
auto-created one (its name still matches the old leaf) **and** it hasn't been
pushed. A **pushed** branch (one with a remote-tracking ref, i.e. a likely PR) or
a branch you switched yourself is left untouched and only the dir moves. So name a
fresh workspace late and you get a clean, convention-correct branch; rename one
that's already on a PR and the branch identity is preserved.

It refuses to rename the primary/trunk checkout, a name that collapses to empty, a
name containing `/` (the leaf must be flat), a name git won't accept as a
branch, or a workspace still being created in the background (retry once it's ready). If a branch by the target name **already exists** (a leftover from a
deleted workspace) it stops with that message and moves nothing — pick another
name. It exits non-zero on any failure so `switchboard rename x && cd …` is safe to
chain.

Run with **no name** and it prints usage plus the current workspace name and exits
non-zero — switchboard doesn't guess a name; you (or the agent) supply it.

> **New workspaces start with a placeholder name.** Create one from the sidebar
> (`n`) — no name prompt — and switchboard gives it a throwaway
> *adjective-noun* name (e.g. `wandering-finch`) and a matching branch, so you can
> start working before you've decided what it is, then `rename` it (dir + branch)
> once you know.

> **The agent names it (on by default).** With [`auto_rename`](reference-config.md#auto_rename)
> on — the default — a `SessionStart` hook tells the running agent to `switchboard rename` a
> placeholder-named workspace once it understands the work, so you never name it by
> hand. Set `auto_rename: false` to opt out. (`switchboard rename-nudge` is the internal
> subcommand that hook runs; not for direct use.)

> **The Claude session gets the name too.** Inside tmux, a rename starts a background
> worker that types `/rename <name>` into the workspace's live Claude session once it's
> idle and off screen, so the phone's session list and the resume picker follow. Renaming
> to the current name retries it. See [`sync_session_name`](reference-config.md#sync_session_name).
> (`switchboard sync-session-name` is that worker; not for direct use.)

> **After a rename, `cd` into the new path.** The move leaves a symlink bridge at
> the old path (so a running agent's hooks keep resolving), but your interactive
> shell's `pwd` still reports the old name. The command prints the exact `cd` to
> run — into the same subdir you were in, under the new path.

### `switchboard monitoring on [secs] | off | notify` (bare = status)
Declare (or clear) that this workspace is running a **background monitor / recurring
loop**, so the sidebar shows a steady `∞` instead of reading as idle/done. `on`
re-affirms liveness — re-run it each cycle (optional `secs` sizes the window for a slow
loop); `off` clears it; a bare `monitoring` prints the status. Agent- or human-invoked.

`monitoring notify` (from a **monitored** workspace) declares "come look — this cycle
surfaced something": the workspace bolds and plays a distinct **`alert`** sound, the one
exception to the otherwise-silent routine ticks. It no-ops with a hint if the workspace
isn't monitoring. See [agent presence](explanation-agent-presence.md#the-declared-alert--monitoring-notify).

### `switchboard sound [done|waiting|alert|failed]`
Play a state's configured sound, for trying audio out or auditioning sounds.
Defaults to `done`. Uses the global sound config, blocks until it finishes, and
reports *why* nothing played (muted / no player / unresolvable spec) so a silent
run is never mistaken for success.

### `switchboard prune [--dry-run] [-n]`
Kill orphaned `sb/` sessions — ones whose worktree git no longer has (deleted,
moved, or crashed). Reconciles against `git worktree list`. `--dry-run`/`-n` only
reports. Works outside tmux (it talks to the tmux server). Only touches projects
it can *verify* (configured + git-readable), so a moved repo's sessions are left
alone, as are those of a project whose folder is missing, even under a session prefix
another project shares. See [How-to: housekeeping](howto-housekeeping.md).

### `switchboard quit`
Close *all* `sb/` sessions — full teardown, the one you're in killed last. Also
clears every agent-state file (so a torn-down agent doesn't read as still
working), and first cancels any workspace still being built in the background, so
no agent starts after it. Works outside tmux. The sidebar's `q` does the same (with a confirm).

### `switchboard doctor`
Check the install and report anything off: `tmux`/`git`/`gh` on PATH, config
present + parseable, unrecognized top-level config keys (the misindented-nested-key
trap), PATH symlinks (under Homebrew: that `switchboard` and `sb` on PATH are this install, not
missing or shadowed by an old clone's link, a clone's `bin/` directory, or another program), which install tmux.conf is wired to (this
one ✓, another that still exists –, or one that's gone ✗), tmux wiring (bound keys +
hooks, and whether they're *live* in the running server vs only in config; a `tmux_keys` key
edited by hand that tmux hasn't applied, or one tmux refused), a bad or clashing `sidebar_keys` remap,
whether a newer release is out (Homebrew installs: a `git ls-remote` to GitHub, bounded
to 5s, and it says so when it can't check; a clone or `--HEAD` install says which branch
it follows instead), the Claude hooks in the worktree you're standing in (missing,
unreadable, out of date because an older release wrote them, or unparseable, naming why), the global codex block from any shell (how many
of its hooks codex has approved, `N/M trusted`, or a fix when the block is stale, can't
be rewritten safely, or collides with your own `[hooks]`), `gh`
auth + per-project badge staleness, audio player +
sound resolution, orphaned sessions, the remote links (`⇅`) it sees (or a warning
when Claude is running but its session files are missing, none are in the shape
switchboard reads, or every live one fails the start-time check, i.e. a Claude update
moved or reshaped them), a `CLAUDE_CONFIG_DIR` that differs between your shell and tmux
(inside tmux only), and orphaned sidebar processes. Read-only. Its
network calls are the release check (Homebrew only) and `gh`'s auth check. Hook staleness is judged
only from the installed `switchboard`; run from another copy, doctor just reports the
hooks as present.
The first place to look when something's off.

### `switchboard sandbox`
Dogfood **this checkout's** sidebar in a throwaway, fully-isolated tmux — a hermetic
repo seeded with worktrees in varied visual states (an open-PR badge, a big `+/−` diff,
a no-PR row, a multi-branch workspace, a monitored `∞` row, a phone-linked `⇅` row, a
`◷` row waiting on background work), on its own tmux server and
socket, torn down automatically on detach. The interactive twin of `bin/test-smoke`
(#126); nothing it does touches your real sessions or state. It also disables Claude
Code's self-updater inside the sandbox (`DISABLE_UPDATES` + `DISABLE_AUTOUPDATER`), so an
update firing in the throwaway can't repoint your global `~/.local/bin/claude` symlink
into the tree teardown deletes (#145). If an older sandbox already dangled your launcher
(`command not found: claude`), repoint it:
`ln -sf ~/.local/share/claude/versions/<latest> ~/.local/bin/claude`.

### `switchboard version` (aliases: `-v`, `--version`)
Print the version (`switchboard X.Y.Z`).

### `switchboard help` (aliases: `-h`, `--help`)
Print a usage summary — the main user commands plus the common sidebar keys. It's
a curated subset, not exhaustive: it omits `version`, the `edit`/`rm` aliases, the
internal tmux subcommands, and the power-user sidebar keys (`g`/`G`, the `Ctrl-`
movement aliases).

---

## Internal subcommands

These are invoked by tmux (via the `switchboard.tmux` fragment and its hooks) or by
switchboard itself, not typed by hand. Documented for completeness — running them manually is usually a
no-op outside the right tmux context.

| Subcommand | Invoked by | Purpose |
|------------|-----------|---------|
| `sidebar` | tmux `split-window` | Run a sidebar pane (one process per window). |
| `toggle-sidebar` | the bound toggle key | Summon/dismiss the sidebar session-wide. |
| `poke-sidebar` | `client-session-changed` hook | Redraw the now-visible sidebar on a session switch. |
| `poke-window <window>` | `session-window-changed` hook | Redraw the sidebar on a same-session window switch (gated to `sb/` sessions). |
| `sidebar-sync <window>` | `after-new-window` hook | Give a new window its own sidebar iff the session opts in. |
| `reload-config [origin]` | the post-edit Ctrl-R poke | Re-read config and redraw after editing it from the sidebar. |
| `tmux-bind` | the `switchboard.tmux` fragment | (Re)bind the configured `tmux_keys`, cleaning up the previously-bound key. A `config.yml` that won't parse re-binds the keys already bound (the defaults only if none were). |
| `check-update` | a visible sidebar, at most every 4 hours (spawned detached) | Homebrew installs: reads the newest release tag and caches it for the update line under the wordmark (#47). Does nothing under `SWITCHBOARD_NO_UPDATE_CHECK`. |
| `create-workspace <id>` | the sidebar's `n` (spawned detached) | Background worker for a dispatched workspace: fetch, `git worktree add`, wire hooks, open the session. |
| `launch <dest>` | the line the worker types into the new pane | Run the setup script, then start the agent with the task. |

See [Explanation: sidebar lifecycle](explanation-sidebar-lifecycle.md) for how
these hooks keep each window's sidebar fresh without it scanning while off screen.

---

## Related

- [Reference: config](reference-config.md) — what `add`/`config`/`init` read and write.
- [Reference: keybindings](reference-keybindings.md) — the sidebar keys `help` lists.
- [How-to: housekeeping](howto-housekeeping.md) — `prune`, `quit`, and `doctor` in practice.
