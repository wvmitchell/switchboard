# Tutorial: from install to your first worktree switch

By the end of this tutorial you'll have switchboard installed, one project
registered, a brand-new worktree created from the keyboard, and an agent session
running in it — with the sidebar showing a live status dot. About ten minutes,
all from the terminal.

This is the learning path. Once you're comfortable, the
[how-to guides](howto-manage-projects.md) cover specific tasks and the
[reference](reference-cli.md) has the full surface.

## What you'll need

- **tmux** ≥ 3.0, **git**, and **gh** (the GitHub CLI). On macOS:
  `brew install tmux git gh`.
- **Ruby ≥ 3.0** (`ruby -v` to check). No gems — switchboard is stdlib only.
- A local git repo with a GitHub remote to play with. Any repo works; PR badges
  need a GitHub `origin`.

Authenticate `gh` if you haven't (this powers the PR badges):

```sh
gh auth login
```

## Step 1: Install switchboard

Clone it and run the installer:

```sh
git clone https://github.com/wvmitchell/switchboard
cd switchboard && bin/switchboard install
```

You'll see it do three things: symlink `switchboard` (and the `sb` alias) onto
your PATH, add one line to your tmux.conf, and write a starter config. If it
warns that `~/.local/bin` isn't on your `$PATH`, add the line it prints to your
shell profile and open a new shell.

Confirm it's healthy:

```sh
switchboard doctor
```

You want green checks for `tmux`, `git`, `gh`, the config, and the PATH symlink.
A couple of items will be yellow notes (no projects yet, hooks not enabled here) —
that's expected on a fresh install.

## Step 2: Launch into the home session

Just run it:

```sh
switchboard
```

You land in the **home session** with the sidebar focused — a narrow pane on the
left titled `switchboard · home`. It's empty except for a hint to add a project.
This is your anchor: a stable base you can always get back to. The footer at the
bottom of the pane shows the keys that apply right now.

You've now seen the sidebar. Everything from here is keys inside it.

## Step 3: Add your first project

Press **`a`**. A prompt appears. You can either register a repo you already have
on disk or clone one from a URL. To register an existing repo, type its path
(e.g. `~/code/myapp`) and press Enter.

The project appears in the tree as a header row, with its existing worktrees
listed beneath it. (If the repo only has its main checkout, you'll see just the
header — the canonical trunk is never shown as a switch target.)

> Prefer the command line? `switchboard add myapp ~/code/myapp` does the same,
> and `switchboard clone <git-url>` clones then registers. See
> [How-to: manage projects](howto-manage-projects.md).

## Step 4: Create a new worktree

Highlight your project header with `j`/`k`, then press **`n`**. Type a name for
the new workspace — say `try-switchboard` — and press Enter.

Switchboard cuts a new branch from your base ref (`origin/main` by default,
fetching it first so it's current), creates a git worktree under
`~/switchboard/worktrees/<project>/try-switchboard`, and **switches you into a
fresh tmux session** for it. You're now sitting in the new worktree's shell.

That's the core loop: `n` makes work, `↵` switches between it.

## Step 5: See the status dot

Press `prefix-s` (your tmux prefix, then `s`) to bring the sidebar back if it
isn't showing, and look at your new workspace row. If you start Claude Code in the
session, a dot appears next to the workspace:

- `⠹` **blue** spinner — it's thinking.
- `◆` **magenta** diamond — it's waiting on you (a permission prompt or question).
- `●` **green** dot — it's done; your move.

Since switchboard created this worktree, it already wired the exact agent-state
hooks for you (that's the green "thinking/waiting/done" precision). For a worktree
you made *outside* switchboard, you'd run `switchboard enable-hooks` inside it
once. See [How-to: agent state & sounds](howto-agent-state-and-sounds.md).

Now switch away to the home session (`prefix-s`, or highlight `home`-adjacent rows
and navigate) and keep working elsewhere — when the agent finishes a turn you'll
**hear a short train horn** and its name in the sidebar goes **bold** until you
look. That's switchboard's whole reason to exist: run several agents at once and
let the dots, sounds, and bold names tell you who needs you.

## Step 6: Clean up

When you're done experimenting, delete the practice worktree: highlight its row
and press **`d`**, then confirm. That removes the worktree and closes its session.

To shut everything down at once:

```sh
switchboard quit
```

This closes every `sb/` session (the one you're in last) and clears agent state.
Your config and registered projects stay — `switchboard` brings it all back.

## What you built

You now have switchboard installed and wired into tmux, one project registered,
and the muscle memory for the core loop: `a` to add a project, `n` to create a
worktree, `↵` to switch, the dots/sounds/bold to know who needs you, `d` to clean
up. All without leaving the keyboard.

Where to go next:

- [How-to: manage projects](howto-manage-projects.md) — add, clone, rename, remove.
- [How-to: agent state & sounds](howto-agent-state-and-sounds.md) — tune the dots and sounds.
- [How-to: keybindings](howto-keybindings.md) — remap `prefix-s`, bind a home key.
- [How-to: housekeeping](howto-housekeeping.md) — `prune`, `quit`, and `doctor`.
- [Explanation: architecture](explanation-architecture.md) — why it works the way it does.
