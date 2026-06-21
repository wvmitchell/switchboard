# switchboard

A keyboard-only switcher and creator for git-worktree workspaces. No mouse, no
Electron — a persistent `tmux` sidebar for the tree, `git` for the truth, `gh`
for PR badges. A terminal-native alternative to Conductor/emdash that stands on
its own.

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
- **PR badges come from `gh`,** cached on disk so the sidebar never blocks on
  the network. `switchboard refresh` re-fetches.
- **Each worktree maps to a tmux session.** Selecting one (↵) creates the
  session (if needed) and switches to it. `n` creates a brand-new worktree +
  branch under `worktree_root` and drops you in.

## What it does

A persistent **sidebar** in a narrow tmux pane, rendered as a 3-level tree —
**project → workspace → branch**. It rides along beside every session, so the
tree is always a glance away and reloads itself as you switch. The canonical
trunk checkout is omitted (you never switch to it). A workspace that has spawned
more than one branch (derived from the worktree's HEAD reflog) expands into
**inline child rows** — the multiple-branches/PRs-per-workspace case that
otherwise lives only in your head and on GitHub.

Each row carries its signals inline: an agent-state dot (whether Claude is
thinking / done / waiting), the active branch marked with a dot, and the PR as a
color-coded `#number` flush right — green open, yellow draft, magenta merged,
red closed.

Keys (in the sidebar):

```
j/k ↑↓   move (projects, workspaces, and a workspace's branches)
↵        switch to the workspace's tmux session (or collapse a project header)
a        add a project (register a local repo or clone a URL)
n        create a new worktree in the highlighted project
o        open the highlighted PR in the browser (gh pr view --web)
r        rename a workspace
d        delete a workspace
e        edit config.yml in $EDITOR
q        hide the sidebar
```

## Usage

```sh
bin/switchboard init            # create config (imports projects from emdash once)
bin/switchboard config          # edit config.yml in $EDITOR (per-project settings)
bin/switchboard add N P [B]     # register an existing repo (name, path, base ref)
bin/switchboard clone U [N]     # clone a repo under projects_root, then register it
bin/switchboard                 # toggle the sidebar in the current tmux window
bin/switchboard refresh         # re-fetch PR badges from gh
bin/switchboard enable-hooks [P]  # exact agent-state dots in a worktree (see below)
bin/switchboard doctor          # check dependencies + config
```

You can also add a project without leaving the keyboard: press `a` in the
sidebar to register an existing local repo or clone one from a URL. This is the
keyboard path to your *first* project — `n` only creates worktrees inside a
project that already exists — so switchboard stands up on a fresh machine, off
emdash, entirely from the sidebar.

Bind the sidebar toggle to a tmux key for instant access, e.g. in `~/.tmux.conf`:

```tmux
bind-key s run-shell "/path/to/switchboard/bin/switchboard toggle-sidebar"
```

The sidebar also spawns automatically beside every session switchboard creates,
so the bound key is really just show/hide for the current window.

## Housekeeping

Every workspace switchboard touches is its own tmux session named
`sb/<project>/<leaf>`. To you it feels like one app, but under the hood it's many
sessions. To close them all in one go — handy before relaunching from a clean
slate, or to clear a stray session that's confusing the sidebar:

```sh
# Kill every switchboard session. Others first, then the one you're in last, so
# nothing is left behind when you run this from inside a session (works from a
# plain terminal too).
here=$(tmux display-message -p '#{session_name}' 2>/dev/null)
tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^sb/' | grep -vxF "$here" \
  | while read -r s; do tmux kill-session -t "=$s"; done
case "$here" in sb/*) tmux kill-session -t "=$here";; esac
```

## Config

`~/.config/switchboard/config.yml`:

```yaml
worktree_root: ~/switchboard/worktrees   # where `n` puts new worktrees
projects_root: ~/Programming             # where `a`/`clone` drop cloned repos
base: origin/main                        # default ref new worktrees branch from
branch_prefix: wvmitchell                # optional: new branches become wvmitchell/<name>
agent_state_hooks: true                  # optional: auto-wire agent-state dots on create (default true)
session_command: claude                  # optional: run this when a worktree's session is first created
projects:
  - name: myapp
    path: ~/code/myapp
    base: origin/main                    # optional: per-project override of the base
    session_command: claude --dangerously-skip-permissions  # optional: per-project override
```

Edit this file with `switchboard config` (or `e` in the sidebar) — both open it
in `$EDITOR` and reload on save, so a new project or a changed `session_command`
takes effect on the next switch.

`n` cuts a new branch from `base` (fetching its remote first, e.g. `origin`
for `origin/main`). `base` defaults to `origin/main`; set it globally or per
project. The branch is named `<name>` (or `<branch_prefix>/<name>`).

### Per-project settings

`session_command` is the first project-level setting: the command switchboard
types into a worktree's window the **first time** it creates that worktree's
tmux session — your way to say "how should an agent start here." Set it globally
and override it per project (per-project wins; an empty value falls back to the
global). Leave it unset and you land in a plain shell, exactly as before. It
only fires on session *creation*, never on a re-switch into a live session, so
your running agent is never disturbed.

```yaml
session_command: claude                                     # default: bare claude everywhere
projects:
  - name: myapp
    session_command: claude --dangerously-skip-permissions  # this repo: skip the prompts
  - name: client-work
    session_command: codex                                  # a different agent here
```

## Agent status

The persistent sidebar shows a dot next to each workspace that has a live agent
(Claude Code, Codex, Aider). The dot's colour tells you what the agent is doing,
so you can run several in parallel and glance over to see who needs you:

```
(blank)   no agent
● blue    thinking — working a turn (a slow breathe, so it reads as "alive")
● green   done — finished its turn (or just idle); ball's in your court
● magenta wants input — blocked on a question/permission it needs you to answer
```

Two ways the dot learns what the agent's doing:

- **Observation (default, zero-config).** Switchboard watches the agent's tmux
  pane and infers busy-vs-idle from whether it's changing. Works for any agent,
  installs nothing. It can't reliably tell "wants input" from "done", though.
- **Hooks (exact).** Claude Code reports its state precisely. Switchboard scopes
  this **per worktree** — it never touches your global `~/.claude`. New worktrees
  switchboard creates get it automatically; for an existing one, run
  `switchboard enable-hooks` from inside it (`disable-hooks` to undo).

How the hooks stay clean: switchboard writes `<worktree>/.claude/settings.local.json`
(merged on top of your own settings, and added to the worktree's local git
excludes so it never dirties `git status`). The hook command points at a small
reporter script switchboard materializes into its own data dir
(`~/.local/share/switchboard/`) — a path that survives reinstalls and
`brew upgrade`, so the wiring doesn't rot. The script only writes a state file;
switchboard never launches or wraps your agent. Set `agent_state_hooks: false`
in the config to stop auto-enabling on create.

## Dependencies

`ruby` `tmux` `git` `gh` (`gh` powers the PR badges and the `o` open action)

```sh
brew install gh
```

## Roadmap

- ~~v2 — clone a project from a git URL (not just register an existing one)~~ ✓
  (`a` in the sidebar, or `switchboard clone`)
- v3 — live diff + PR pane inside each workspace session
- richer fallback state for hook-less agents (Codex/Aider): detect "wants input"
  from the pane, not just busy/idle
