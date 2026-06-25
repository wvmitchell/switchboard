# How to manage projects and worktrees

Add projects, clone new ones, create and rename worktrees, and remove what you're
done with — from the sidebar or the command line. A *project* is a registered
repo; a *worktree* (or workspace) is a branch checkout under it that you switch
between.

## Prerequisites

- switchboard installed (`switchboard doctor` is green). See the
  [tutorial](tutorial-getting-started.md).
- For PR badges and `clone`: `gh` authenticated and a GitHub remote.

## Register a repo you already have

From the sidebar: press `a`, choose to register a local repo, type its path.

From the shell:

```sh
switchboard add <name> <path> [base-ref]
```

- `name` — what shows in the tree and prefixes its sessions (`sb/<name>/…`).
- `path` — the repo's working directory.
- `base-ref` — optional; the ref new worktrees branch from. Omit to use the
  global `base` (default `origin/main`).

```sh
switchboard add myapp ~/code/myapp
switchboard add api ~/code/api origin/develop   # this repo branches from develop
```

If you omit `base-ref`, switchboard picks a sensible one: the remote's default
branch (from `origin/HEAD`), or the local HEAD for a repo with no origin — and
drops it entirely if it just echoes the global default, so the config stays clean.

**Verify:** the project appears as a header in the sidebar, or run
`switchboard doctor` and check the config path it reports.

## Clone a repo and register it in one step

```sh
switchboard clone <git-url> [name]
```

Clones under `projects_root` (default `~/Programming`) as `<projects_root>/<name>`,
then registers it. `name` defaults to the URL's basename.

```sh
switchboard clone git@github.com:me/myapp.git
switchboard clone https://github.com/me/api.git my-api
```

The sidebar's `a` offers the same clone path interactively.

## Create a new worktree

From the sidebar: highlight the project header, press `n`, type a workspace name.

Switchboard fetches the base ref, cuts a new branch from it, creates the worktree
under `<worktree_root>/<project>/<name>`, and switches you in. The branch is named
`<name>`, or `<branch_prefix>/<name>` if you set `branch_prefix` in config.

The new session runs the project's `session_command` (e.g. `claude`) on creation
if you've set one — see [How-to: agent state & sounds](howto-agent-state-and-sounds.md)
for that and the auto-wired hooks.

**Verify:** you're dropped into the new worktree's shell; `git worktree list` in
the project shows the new path.

## Switch between worktrees

Highlight any workspace row and press `↵`. First switch creates the session;
later switches just attach. A workspace that has held more than one branch expands
into inline branch rows (its HEAD-reflog history, each with its PR badge) — `↵` on
any of them switches to that one worktree's session; they all share it, so this
navigates you there rather than checking the branch out.

`prefix-s` shows/hides the sidebar from any pane, so the tree is always a keypress
away.

## Rename a workspace

Highlight a workspace, press `r`, type the new name. Switchboard moves the
worktree directory (keeping the branch and PR intact) and leaves a temporary
bridge symlink behind so a *running* agent in that worktree keeps reporting state
through the move. The bridge is reaped automatically once it's no longer needed.

## Remove a workspace or unregister a project

From the sidebar, press `d` on the highlighted row (confirms first):

- On a **workspace** row: deletes the worktree and closes its session.
- On a **project** header: unregisters the project *and* closes its sessions. The
  repo on disk is untouched.

From the shell, to unregister a project without touching sessions:

```sh
switchboard remove <name>     # alias: rm
```

The repo and worktrees on disk stay; re-add it any time. Leftover sessions are
cleaned by `switchboard prune` — see [How-to: housekeeping](howto-housekeeping.md).

## Troubleshooting

- **Project doesn't appear in the tree.** Its `path` must exist and be a git repo.
  A project whose path is missing is dropped from the tree on purpose (so a moved
  repo can't break the sidebar). Fix the `path` in `config.yml` (`e` or
  `switchboard config`) or re-`add` it.
- **"name taken".** Project names must be unique. Pick another, or `remove` the
  old one first.
- **`n` says "already exists".** A directory (or a stale rename bridge) is already
  at that worktree path. Choose a different name, or remove the directory.
- **PR badge missing for a worktree.** Badges come from `gh` and are cached. Press
  `R` to force a refresh; run `switchboard doctor` to check `gh` auth and cache
  age. A PR merged/closed *on GitHub* needs an explicit `R` (no local signal
  fires).
- **Created a worktree outside switchboard and want exact dots.** Run
  `switchboard enable-hooks` inside it once.

## Related

- [Reference: CLI](reference-cli.md) — `add`, `clone`, `remove`, `refresh`.
- [Reference: config](reference-config.md) — `worktree_root`, `projects_root`, `base`, `branch_prefix`.
- [How-to: housekeeping](howto-housekeeping.md) — prune orphaned sessions after removal.
