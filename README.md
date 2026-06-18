# switchboard

A keyboard-only switcher and creator for git-worktree workspaces. No mouse, no
Electron — `fzf` for the picker, `tmux` for the sessions, `nvim` for the
editing. A terminal-native alternative to Conductor/emdash that stands on its
own.

## Why

Conductor and emdash give a great glanceable view of parallel agent workspaces,
but switching between them means reaching for the mouse or a command palette.
Switchboard is the same overview, driven entirely from the keyboard.

## How it works

- **Standalone, config-driven.** Projects live in `~/.config/switchboard/config.yml`
  (name, repo path, base ref). No emdash or Conductor database at runtime.
  `switchboard init` seeds the config from emdash's DB once, if present.
- **Git is the source of truth.** Worktrees are discovered with `git worktree
  list`, so anything you (or emdash, or Conductor) create shows up — nothing to
  sync.
- **PR badges come from `gh`,** cached on disk so the list never blocks on the
  network. `^r` (or `switchboard refresh`) re-fetches.
- **Each worktree maps to a tmux session.** Selecting one creates the session
  (if needed) and switches to it. `^n` creates a brand-new worktree + branch
  under `worktree_root` and drops you in.

## What it does

One `fzf` list rendered as a 3-level tree — **project → workspace → branch**.
The canonical trunk checkout is omitted (you never switch to it). A workspace
that has spawned more than one branch (derived from the worktree's HEAD reflog)
expands into **inline child rows** — the multiple-branches/PRs-per-workspace
case that otherwise lives only in your head and on GitHub. You cycle every
level with the same arrow keys; the active branch is marked with a dot.

Keys:

```
↑↓   move (projects, workspaces, and a workspace's branches)
↵    switch to the highlighted worktree's tmux session
^n   create a new worktree in the highlighted project
^o   open the highlighted branch's PR in the browser
^v   view the highlighted branch's PR in the terminal (gh pr view)
^r   refresh PR badges + reload
pgup/pgdn, shift-↑/↓   scroll the preview
esc  cancel
```

## Usage

```sh
bin/switchboard init            # create config (imports projects from emdash once)
bin/switchboard add N P [B]     # register a project (name, repo path, base ref)
bin/switchboard                 # open the switcher
bin/switchboard refresh         # re-fetch PR badges from gh
bin/switchboard doctor          # check dependencies + config
```

Bind it to a tmux key for instant access, e.g. in `~/.tmux.conf`:

```tmux
bind-key s display-popup -E -w 90% -h 80% "/path/to/switchboard/bin/switchboard"
```

## Config

`~/.config/switchboard/config.yml`:

```yaml
worktree_root: ~/switchboard/worktrees   # where ^n puts new worktrees
branch_prefix: wvmitchell                # optional: new branches become wvmitchell/<name>
projects:
  - name: myapp
    path: ~/code/myapp
    base: origin/main
```

## Dependencies

`ruby` `fzf` `tmux` `git` `gh` (`gh` powers PR badges and the view/open actions)

```sh
brew install fzf gh
```

## Roadmap

- v2 — clone a project from a git URL (not just register an existing one)
- v3 — live diff + PR pane inside each workspace session
- agent status (waiting/busy/idle) once switchboard launches the agents itself
