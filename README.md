# switchboard

A keyboard-only switcher over the git worktrees [emdash](https://github.com/) (and
plain `git`) create. No mouse, no Electron — `fzf` for the picker, `tmux` for the
sessions, `nvim` for the editing. A terminal-native alternative to the
Conductor/emdash workspace switcher.

## Why

Conductor and emdash give a great glanceable view of parallel agent workspaces,
but switching between them means reaching for the mouse or a command palette.
Switchboard is the same overview, driven entirely from the keyboard.

## How it works

- **Git is the source of truth.** Worktrees are discovered with `git worktree
  list`, so anything you (or emdash) create shows up — nothing to sync.
- **emdash's SQLite DB is read-only enrichment.** Friendly workspace names and
  PR badges come from `~/Library/Application Support/emdash/emdash*.db`.
  Switchboard never writes to it.
- **Each worktree maps to a tmux session.** Selecting one creates the session
  (if needed) and switches/attaches to it.

## v0 (this spike)

The cross-project switcher: one `fzf` list rendered as a 3-level tree —
**project → workspace → branch**. The canonical trunk checkout is omitted (you
never switch to it). A workspace that has spawned more than one branch (derived
from the worktree's HEAD reflog) expands into **inline child rows** — the
multiple-branches/PRs-per-workspace case that otherwise lives only in your head
and on GitHub. You cycle every level with the same arrow keys; the active
branch is marked with a dot. Fuzzy search still spans projects (the project
name is a hidden, searchable field).

Keys:

```
↑↓   move (workspaces, and a workspace's branches inline)
↵    switch to the highlighted worktree's tmux session
^o   open the highlighted branch's PR in the browser
^v   view the highlighted branch's PR in the terminal (gh pr view)
^r   reload the list
pgup/pgdn, shift-↑/↓   scroll the preview
esc  cancel
```

## Usage

```sh
bin/switchboard          # open the switcher
bin/switchboard doctor   # check dependencies
bin/switchboard help
```

Bind it to a tmux key for instant access, e.g. in `~/.tmux.conf`:

```tmux
bind-key s display-popup -E -w 90% -h 80% "/path/to/switchboard/bin/switchboard"
```

## Dependencies

`ruby` `fzf` `tmux` `git` `gh` (`gh` powers the PR view/open actions)

```sh
brew install fzf gh
```

## Roadmap

- v1 — create a worktree from the switcher (`^n`)
- v2 — clone / add a project (`^o`)
- v3 — live diff + PR pane inside each workspace session
