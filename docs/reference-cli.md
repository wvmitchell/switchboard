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

### `switchboard install [--no-tmux] [--print-tmux] [--tmux-conf PATH]`
Stand switchboard up from a fresh clone. Idempotent. Three steps:

1. Symlink `switchboard` (and the `sb` alias) into `~/.local/bin` (or
   `$SWITCHBOARD_BIN_DIR`).
2. Add one marker-delimited line to the tmux.conf tmux actually loads, sourcing
   the self-locating `switchboard.tmux` fragment (binds the keys + sets the hooks).
3. Scaffold an annotated starter config if none exists.

| Flag | Effect |
|------|--------|
| `--no-tmux` | Skip the tmux.conf edit (symlink + config only). |
| `--print-tmux` | Print the tmux line instead of writing it. |
| `--tmux-conf PATH` | Target a specific tmux.conf instead of the auto-detected one. |

Backs up the target tmux.conf to `.bak` before its first edit. See
[How-to: keybindings](howto-keybindings.md) for the wiring it installs.

### `switchboard uninstall [--tmux-conf PATH]`
Reverse `install`: remove both symlinks, the tmux marker block, the bound keys,
the three hook slots, and the `@switchboard-*` tmux options (also live-unbinds in
a running server). Your config and agent state are left untouched.

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
Re-fetch PR badges from `gh` and rewrite the on-disk cache. With a project name,
just that project; otherwise all. Normally you don't run this — the sidebar
refreshes badges automatically (on agent completion, on switch-in, and on an idle
backstop). Run it to catch a PR you merged or closed *on GitHub* (which fires no
local signal). `--poke PANE` is used internally by the sidebar to redraw a
specific pane.

### `switchboard enable-hooks [path]`
Wire exact agent-state hooks into a single worktree's local settings
(`<worktree>/.claude/settings.local.json`), scoped to that worktree — never your
global `~/.claude`. Defaults to the worktree you're standing in; pass a path to
target another. Restart `claude` there (or `/hooks`) to pick them up. New
switchboard-created worktrees get this automatically.

### `switchboard disable-hooks [path]`
Remove switchboard's hooks from a worktree's local settings (leaving any other
settings intact). Defaults to the current worktree.

### `switchboard rename <name>`
Rename the workspace you're standing in: moves the worktree directory to `<name>`
(the display leaf) and renames its `sb/` tmux session in place, so a running agent
and its conversation survive. This is the verb for an **agent to (re)name its own
live workspace** once it knows what the work actually is — the sidebar's `r` key
does the same from the tree.

**It also renames the git branch** to match — `<branch_prefix>/<name>` (the dir
stays the bare `<name>`) — but only when that's safe: the branch is still the
auto-created one (its name still matches the old leaf) **and** it hasn't been
pushed. A **pushed** branch (one with a remote-tracking ref, i.e. a likely PR) or
a branch you switched yourself is left untouched and only the dir moves. So name a
fresh workspace late and you get a clean, convention-correct branch; rename one
that's already on a PR and the branch identity is preserved.

It refuses to rename the primary/trunk checkout, a name that collapses to empty, a
name containing `/` (the leaf must be flat), or a name git won't accept as a
branch. If a branch by the target name **already exists** (a leftover from a
deleted workspace) it stops with that message and moves nothing — pick another
name. It exits non-zero on any failure so `switchboard rename x && cd …` is safe to
chain.

Run with **no name** and it prints usage plus the current workspace name and exits
non-zero — switchboard doesn't guess a name; you (or the agent) supply it.

> **New workspaces start with a placeholder name.** Create one from the sidebar
> (`n`) without typing a name and switchboard gives it a throwaway
> *adjective-noun* name (e.g. `wandering-finch`) and a matching branch — so you can
> start working before you've decided what it is, then `rename` it (dir + branch)
> once you know.

> **After a rename, `cd` into the new path.** The move leaves a symlink bridge at
> the old path (so a running agent's hooks keep resolving), but your interactive
> shell's `pwd` still reports the old name. The command prints the exact `cd` to
> run — into the same subdir you were in, under the new path.

### `switchboard sound [done|waiting]`
Play a state's configured sound, for trying audio out or auditioning sounds.
Defaults to `done`. Uses the global sound config, blocks until it finishes, and
reports *why* nothing played (muted / no player / unresolvable spec) so a silent
run is never mistaken for success.

### `switchboard prune [--dry-run] [-n]`
Kill orphaned `sb/` sessions — ones whose worktree git no longer has (deleted,
moved, or crashed). Reconciles against `git worktree list`. `--dry-run`/`-n` only
reports. Works outside tmux (it talks to the tmux server). Only touches projects
it can *verify* (configured + git-readable), so a moved repo's sessions are left
alone. See [How-to: housekeeping](howto-housekeeping.md).

### `switchboard quit`
Close *all* `sb/` sessions — full teardown, the one you're in killed last. Also
clears every agent-state file (so a torn-down agent doesn't read as still
working). Works outside tmux. The sidebar's `q` does the same (with a confirm).

### `switchboard doctor`
Check the install and report anything off: `tmux`/`git`/`gh` on PATH, config
present + parseable, PATH symlinks, tmux wiring (bound keys + hooks, and whether
they're *live* in the running server vs only in config), `gh` auth + per-project
badge staleness, audio player + sound resolution, orphaned sessions, and orphaned
sidebar processes. Read-only. The first place to look when something's off.

### `switchboard version` (aliases: `-v`, `--version`)
Print the version (`switchboard X.Y.Z`).

### `switchboard help` (aliases: `-h`, `--help`)
Print a usage summary — the main user commands plus the common sidebar keys. It's
a curated subset, not exhaustive: it omits `version`, the `edit`/`rm` aliases, the
internal tmux subcommands, and the power-user sidebar keys (`g`/`G`, the `Ctrl-`
movement aliases).

---

## Internal subcommands

These are invoked by tmux (via the `switchboard.tmux` fragment and its hooks), not
typed by hand. Documented for completeness — running them manually is usually a
no-op outside the right tmux context.

| Subcommand | Invoked by | Purpose |
|------------|-----------|---------|
| `sidebar` | tmux `split-window` | Run a sidebar pane (one process per window). |
| `toggle-sidebar` | the bound toggle key | Summon/dismiss the sidebar session-wide. |
| `poke-sidebar` | `client-session-changed` hook | Redraw the now-visible sidebar on a session switch. |
| `poke-window <window>` | `session-window-changed` hook | Redraw the sidebar on a same-session window switch (gated to `sb/` sessions). |
| `sidebar-sync <window>` | `after-new-window` hook | Give a new window its own sidebar iff the session opts in. |
| `reload-config [origin]` | the post-edit Ctrl-R poke | Re-read config and redraw after editing it from the sidebar. |
| `tmux-bind` | the `switchboard.tmux` fragment | (Re)bind the configured `tmux_keys`, cleaning up the previously-bound key. |

See [Explanation: sidebar lifecycle](explanation-sidebar-lifecycle.md) for how
these hooks keep each window's sidebar fresh without it scanning while off screen.

---

## Related

- [Reference: config](reference-config.md) — what `add`/`config`/`init` read and write.
- [Reference: keybindings](reference-keybindings.md) — the sidebar keys `help` lists.
- [How-to: housekeeping](howto-housekeeping.md) — `prune`, `quit`, and `doctor` in practice.
