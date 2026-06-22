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
  (name, repo path, base ref). No emdash or Conductor database at runtime —
  `switchboard install` writes an empty config and you grow it from the sidebar.
- **Git is the source of truth.** Worktrees are discovered with `git worktree
  list`, so anything you (or emdash, or Conductor) create shows up — nothing to
  sync.
- **PR badges come from `gh`,** cached on disk so the sidebar never blocks on
  the network. The cache refreshes itself in the background — when an agent
  finishes a turn, when you switch in, and on an idle timer — so badges stay
  fresh without anyone running `switchboard refresh`.
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
e        edit config.yml ($EDITOR, full-size in the home session; returns you on quit)
q        hide the sidebar
```

## Install

```sh
git clone https://github.com/wvmitchell/switchboard
cd switchboard && bin/switchboard install
```

`install` is idempotent and does three things:

1. **Symlinks `switchboard` onto your PATH** (`~/.local/bin/switchboard`, or
   `$SWITCHBOARD_BIN_DIR`). If that dir isn't on `$PATH`, it tells you the line
   to add.
2. **Wires the tmux binding** by adding one marker-delimited line to your
   tmux.conf that sources the shipped `switchboard.tmux` fragment. The fragment
   is self-locating, so the binding keeps working wherever the repo lives, and
   it binds `prefix-s` to toggle the sidebar plus a session-switch refresh hook.
3. **Creates an empty config** if you don't have one yet.

It finds the tmux.conf tmux actually loads (via `#{config_files}`) and backs it
up to `.bak` before the first edit. Flags: `--no-tmux` (skip the tmux edit),
`--print-tmux` (print the line instead of writing it), `--tmux-conf PATH` (target
a specific file). `switchboard uninstall` reverses all of it; your config and
agent state are left untouched. `switchboard doctor` reports what's wired.

Then add your first project: press `a` in the sidebar (`n` only creates
worktrees inside a project that already exists), so switchboard stands up on a
fresh machine, off emdash, entirely from the keyboard.

## Usage

```sh
bin/switchboard install         # symlink onto PATH + wire tmux bindings + empty config
bin/switchboard uninstall       # reverse install (symlink + tmux bindings)
bin/switchboard init            # create an empty config (no projects yet)
bin/switchboard home            # attach to the persistent home session (anchor + settings)
bin/switchboard config          # edit config.yml in $EDITOR (per-project settings)
bin/switchboard add N P [B]     # register an existing repo (name, path, base ref)
bin/switchboard clone U [N]     # clone a repo under projects_root, then register it
bin/switchboard                 # toggle the sidebar in the current tmux window
bin/switchboard refresh         # re-fetch PR badges from gh
bin/switchboard enable-hooks [P]  # exact agent-state dots in a worktree (see below)
bin/switchboard sound [done|waiting]  # play a state's sound (try audio / pick sounds)
bin/switchboard doctor          # check dependencies + config
```

The sidebar also spawns automatically beside every session switchboard creates,
so the bound `prefix-s` is really just show/hide for the current window. Prefer
to wire it by hand instead of via `install`? Add this to `~/.tmux.conf`:

```tmux
run-shell "/path/to/switchboard/switchboard.tmux"
```

## Home session

Switchboard keeps a single persistent **home** session, `sb/home`, as its anchor.
Unlike a workspace session it maps to no worktree — it lives in `$HOME`, so it
never shows up in the tree as a switch target — and it carries its own sidebar,
so it's a usable base you can navigate the whole tree from. It exists for two
reasons:

- **A safe fallback.** Deleting the workspace you're *currently in* used to eject
  you from switchboard, because the sidebar you're driving lives inside that
  session. Now switchboard switches you to home first, *then* kills the
  workspace — you land back on the full tree, not a bare shell.
- **A stable launch + settings base.** `switchboard home` attaches you to it
  (land focused on the tree, ready to navigate). It's the obvious place to manage
  switchboard: `a` adds a project, `e` opens the config — the footer says so.

Home is created lazily the moment it's needed, so there's nothing to set up.
`install` deliberately doesn't bind it (one less key taken). If you want one-key
access, add a bind on a key that's free in your config — `prefix-S` is freed by
switchboard, while `prefix-h` is a common pane-nav key, so pick what fits:

```tmux
bind-key S run-shell "/path/to/switchboard/bin/switchboard home"
```

## Housekeeping

Every workspace switchboard touches is its own tmux session named
`sb/<project>/<leaf>`. To you it feels like one app, but under the hood it's many
sessions. A worktree deleted, moved, or renamed *outside* switchboard (or a crash)
leaves its session behind — a stray that can confuse the switcher on relaunch. Two
commands keep sessions and worktrees in sync:

```sh
switchboard prune            # kill orphaned sb/ sessions (worktree is gone)
switchboard prune --dry-run  # ...or just show what would be killed (-n works too)
switchboard quit             # close ALL sb/ sessions (full teardown; current last)
```

`prune` reconciles against `git worktree list`. A dry run shows you the orphans
and the next step:

```
$ switchboard prune --dry-run
would kill 2 orphaned session(s):
  sb/app/old-feature
  sb/api/spike
run `switchboard prune` to remove these
```

Both commands work **outside tmux** too (they talk to the tmux server), so you can
clean up from a plain shell after a crash. `prune` only touches projects it can
**verify** — it's in your config and git can read it — so a project whose repo you
moved or unregistered is left alone (its sessions survive; use `quit` for a full
teardown). `switchboard doctor` flags orphans and points you at `prune`.

**Auto-reconcile (on by default).** Since 0.8.0, landing on the home session
(`switchboard home`) prunes orphaned `sb/` sessions for you, so stray sessions
don't pile up. To turn it off, set `prune_on_launch: false` in your config.

> **Upgrading to 0.8.0:** auto-reconcile is **on by default** — the first time you
> hit `switchboard home` after upgrading, orphaned sessions get cleaned
> automatically. That's intentional; opt out with `prune_on_launch: false`.

If switchboard isn't on your `PATH`, the raw equivalent of `quit`:

```sh
# Kill every switchboard session. Others first, then the one you're in last, so
# nothing is left behind when you run this from inside a session (works from a
# plain terminal too).
here=$(tmux display-message -p '#{session_name}' 2>/dev/null)
tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^sb/' | grep -vxF "$here" \
  | while read -r s; do tmux kill-session -t "=$s"; done
case "$here" in sb/*) tmux kill-session -t "=$here";; esac
```

This sweeps `sb/home` too; that's fine — it's recreated lazily the next time
switchboard needs it.

## Config

`~/.config/switchboard/config.yml`:

```yaml
worktree_root: ~/switchboard/worktrees   # where `n` puts new worktrees
projects_root: ~/Programming             # where `a`/`clone` drop cloned repos
base: origin/main                        # default ref new worktrees branch from
branch_prefix: wvmitchell                # optional: new branches become wvmitchell/<name>
agent_state_hooks: true                  # optional: auto-wire agent-state dots on create (default true)
session_command: claude                  # optional: run this when a worktree's session is first created
sounds:                                  # optional: completion sounds (on by default — see below)
  enabled: true                          #   set false to mute everything
  done: train                            #   built-in (train/chime, or train_1..3 / chime_1..3), a file path, or a macOS sound name
  waiting: chime
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

The persistent sidebar shows an animated icon next to each workspace that has a
live agent (Claude Code, Codex, Aider). The icon's shape *and* colour tell you
what the agent is doing, so you can run several in parallel and glance over to
see who needs you:

```
(blank)    no agent
⠹ blue     thinking — a braille spinner cycles while it works a turn
◆ magenta  wants input — a blinking diamond; blocked on a question/permission
● green    done — a steady dot; it finished its turn (or is idle), ball's in your court
```

The colours are plain terminal-palette entries (ANSI blue / magenta / green), so
they follow your terminal's light/dark theme automatically — nothing to configure.
The motion lives in the glyph, not a brightness ramp, so the spinner reads the
same on any background. (Branch rows use the palette's dim grey for the same
reason.)

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

## Sound effects

The audible twin of the dots: when a hooked agent finishes a turn or asks for
input, switchboard plays a short sound — so you can switch away to another
workspace and still hear when one is **done** (a two-blast train horn) or
**waiting** on you (a soft two-note chime). On by default, gentle by default.
Each theme also ships three numbered variations — `train_1`/`train_2`/`train_3`
and `chime_1`/`chime_2`/`chime_3` — selectable per state or project when you want
a different timbre (e.g. a distinct horn per repo).

The sounds are *synthesized* in pure Ruby and cached under
`~/.local/share/switchboard/sounds/` on first use — nothing is shipped or
downloaded, and there's no asset to license. Playback shells out to whatever's on
PATH (`afplay` on macOS; `paplay`/`aplay`/`ffplay` on Linux); with no player they
simply stay silent.

Configure globally or per project — the same shape as `session_command`:

```yaml
sounds:
  enabled: true        # false mutes everything
  done: train          # built-in (train/chime, or train_1..3 / chime_1..3), a file path (~/horn.wav), or a macOS system sound (Glass)
  waiting: chime
projects:
  - name: myapp
    sounds:
      enabled: false   # this repo stays quiet
  - name: client-work
    sounds:
      done: ~/sounds/celebrate.wav  # per-project override; omit a key to inherit the global one
```

Try them (or audition replacements) with `switchboard sound [done|waiting]`, and
`switchboard doctor` reports whether a player is on PATH and each sound resolves.
Sound rides the same **per-worktree hooks** as the exact dots, so a worktree
needs hooks enabled to make sound — automatic on switchboard-created worktrees,
or run `switchboard enable-hooks` in an existing one.

## Dependencies

`ruby` `tmux` `git` `gh` (`gh` powers the PR badges and the `o` open action)

```sh
brew install gh
```

Ruby **3.0+** (no gems — stdlib only). There's a test suite (stdlib Minitest, no
build step): run it with `bin/test`.

## Roadmap

- ~~v2 — clone a project from a git URL (not just register an existing one)~~ ✓
  (`a` in the sidebar, or `switchboard clone`)
- v3 — live diff + PR pane inside each workspace session
- richer fallback state for hook-less agents (Codex/Aider): detect "wants input"
  from the pane, not just busy/idle
