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
  finishes a turn, when you switch in, and on a short idle timer — so badges stay
  fresh without anyone running `switchboard refresh`. A PR you merge or close
  *on GitHub* fires no local signal, so press `R` to refresh on demand.
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
↑↓ ^N/^P j/k move (projects, workspaces, and a workspace's branches; j/k move in the tree, type in the filter)
/        filter — type to jump straight to a workspace by name (Esc cancels)
↵        switch to the workspace's tmux session (or collapse a project header)
a        add a project (register a local repo or clone a URL)
n        create a new worktree in the highlighted project
o        open the highlighted PR in the browser (gh pr view --web)
O        open the highlighted row's repo in the browser (gh browse; works on every row kind)
R        refresh PR badges now (catch a PR merged/closed on GitHub)
r        rename a workspace
d        remove the highlighted row — delete a workspace, or unregister a project (closing its sessions)
e        edit config.yml ($EDITOR, full-size in the home session; returns you on quit)
q        quit switchboard — tear down every sb/ session (asks to confirm first)
```

Showing and hiding the sidebar is `prefix-s` — one verb, from any pane: hidden →
summon it and drop you in the tree, visible → dismiss it (session-wide).

The legend at the bottom of the pane is context-sensitive: it shows the keys
that apply to the highlighted row, so a project header foregrounds `d remove`
(unregister) while a workspace shows the per-workspace keys (`o` PR, `O` repo,
`r` rename, `d` delete).

Once the list gets long, `/` filters it — fzf-style, but **in the sidebar** (no
popup, no second tool). Type to narrow the rows to fuzzy matches on the project
and workspace/branch name (it reaches into collapsed projects too, and keeps
matches grouped under their project header). `↵` on a workspace switches to it; on
a project header it creates a new workspace there. `Esc` (or backspacing past the
start) restores the full tree. Like fzf, the printable keys are query input, so
navigate with `↑`/`↓` (or `Ctrl-N`/`Ctrl-P`).

## Documentation

This README is the overview. The full documentation set lives in
[`docs/`](docs/README.md), organized by the
[Diataxis](https://diataxis.fr/) framework:

- **New here?** [Tutorial: getting started](docs/tutorial-getting-started.md) —
  install to your first worktree switch in ~10 minutes.
- **How-to guides** — [manage projects](docs/howto-manage-projects.md) ·
  [agent state & sounds](docs/howto-agent-state-and-sounds.md) ·
  [keybindings](docs/howto-keybindings.md) ·
  [housekeeping](docs/howto-housekeeping.md).
- **Reference** — [CLI](docs/reference-cli.md) ·
  [config.yml](docs/reference-config.md) ·
  [keybindings](docs/reference-keybindings.md).
- **Explanation** — [architecture](docs/explanation-architecture.md) ·
  [agent presence](docs/explanation-agent-presence.md) ·
  [sidebar lifecycle](docs/explanation-sidebar-lifecycle.md).

Contributing or pointing an AI agent at the repo? See
[CONTRIBUTING.md](CONTRIBUTING.md) and [AGENTS.md](AGENTS.md).

## Install

```sh
git clone https://github.com/wvmitchell/switchboard
cd switchboard && bin/switchboard install
```

`install` is idempotent and does three things:

1. **Symlinks `switchboard` onto your PATH** (`~/.local/bin/switchboard`, or
   `$SWITCHBOARD_BIN_DIR`), plus a short `sb` alias beside it. If that dir isn't
   on `$PATH`, it tells you the line to add. (If something else already owns
   `sb`, the alias is skipped and the full command still installs.)
2. **Wires the tmux binding** by adding one marker-delimited line to your
   tmux.conf that sources the shipped `switchboard.tmux` fragment. The fragment
   is self-locating, so the binding keeps working wherever the repo lives, and
   it binds `prefix-s` to toggle the sidebar plus a session-switch refresh hook.
3. **Creates a starter config** if you don't have one yet — effectively empty
   (just `worktree_root` + `projects`), but annotated with every optional knob
   commented out so you can see what's configurable without leaving the file.

It finds the tmux.conf tmux actually loads (via `#{config_files}`) and backs it
up to `.bak` before the first edit. Flags: `--no-tmux` (skip the tmux edit),
`--print-tmux` (print the line instead of writing it), `--tmux-conf PATH` (target
a specific file). `switchboard uninstall` reverses all of it; your config and
agent state are left untouched. `switchboard doctor` reports what's wired.

Then start it: run `switchboard` (or `sb`) from any shell — it bootstraps and
drops you straight into the sidebar (the home session). Add your first project
there by pressing `a` (`n` only creates worktrees inside a project that already
exists), so switchboard stands up on a fresh machine, off emdash, entirely from
the keyboard.

## Upgrading

Pull the latest and re-run install:

```sh
cd switchboard && git pull && bin/switchboard install
```

The command itself updates the moment you `git pull` (the PATH symlink points
into the repo), but a running tmux server keeps the **old** bindings and hooks
until its config reloads — so the `install` re-run (idempotent; it repoints the
symlinks and re-sources the `switchboard.tmux` fragment in place) is what
activates any new tmux wiring. A bare `tmux source-file <your conf>` does the
same. `switchboard doctor` flags hooks that are wired in config but not yet live
in the server, so you can tell when a reload is needed. See `CHANGELOG.md` for
what changed between versions.

## Usage

```sh
bin/switchboard install         # symlinks (switchboard + sb) onto PATH + wire tmux bindings + empty config
bin/switchboard uninstall       # reverse install (both symlinks + tmux bindings)
bin/switchboard init            # create an empty config (no projects yet)
bin/switchboard home            # attach to the persistent home session (anchor + settings)
bin/switchboard config          # edit config.yml in $EDITOR (per-project settings)
bin/switchboard add N P [B]     # register an existing repo (name, path, base ref)
bin/switchboard remove N        # unregister a project (its repo on disk stays; alias: rm)
bin/switchboard clone U [N]     # clone a repo under projects_root, then register it
bin/switchboard                 # start: attach home from a shell, or toggle the sidebar inside tmux (alias: sb)
bin/switchboard refresh         # re-fetch PR badges from gh
bin/switchboard enable-hooks [P]  # exact agent-state dots in a worktree (see below)
bin/switchboard sound [done|waiting]  # play a state's sound (try audio / pick sounds)
bin/switchboard doctor          # check dependencies + config
```

The sidebar also spawns automatically beside every session switchboard creates,
so the bound `prefix-s` is switchboard's one sidebar verb: hidden → summon it and
drop you in the tree, visible → dismiss it (session-wide). Prefer to wire it by
hand instead of via `install`? Add this to `~/.tmux.conf`:

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
- **A stable launch + settings base.** Running bare `switchboard` (or `sb`) from
  any shell — not already in tmux — bootstraps and attaches home for you, so
  starting switchboard is a single command: no manual `tmux` first, no key to
  remember. (`switchboard home` does the same explicitly.) You land focused on
  the tree, ready to navigate. It's the obvious place to manage switchboard: `a`
  adds a project, `e` opens the config — the footer says so. Run bare
  `switchboard` again from *inside* tmux and it just toggles the sidebar.

Home is created lazily the moment it's needed, so there's nothing to set up.
`install` deliberately doesn't bind it (one less key taken). If you want one-key
access, set `tmux_keys.home` in your config (see [Keybindings](#keybindings-tmux_keys)
below) — e.g. `home: S` binds `prefix-S` (freed by switchboard) to jump home.

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
tmux_keys:                               # optional: which prefix keys switchboard binds (see below)
  toggle: s                              #   show/hide the sidebar (default s; e.g. set to b for prefix-b)
  home: S                                #   EXAMPLE — one-key jump to home; omit the line entirely to leave it unbound
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

### Keybindings (`tmux_keys`)

`prefix-s` (toggle the sidebar) collides with tmux's default `choose-tree`, so it's
remappable. `tmux_keys.toggle` is the key the sidebar toggle binds to; `tmux_keys.home`
is an optional one-key jump to the home session (unbound unless you set it). Use any
tmux key token — a single char, a named key (`Space`, `F1`, `BSpace`), or a modifier
combo (`C-s`, `M-x`). An unusable value falls back to the default; `switchboard doctor`
flags it (and a `home`/`toggle` collision, and a key that displaced a prior binding).

Editing `tmux_keys` with `switchboard config` (or `e`) takes effect on save like every
other knob — switchboard rebinds the key right away and flashes a confirmation. The one
exception is the very first `install` (or a key changed by hand-editing the file outside
switchboard, then reloading tmux): there, tmux only picks the key up when it re-sources
its config (`tmux source-file <your conf>`). Switchboard cleans up the key it bound last,
so changing the key never leaves the old one live.

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

**Bold until you look.** When a hooked agent finishes a turn or asks for input,
its workspace name goes **bold** and stays bold until you switch into it — so a
completion that lands while you're heads-down elsewhere is still waiting for your
eye when you glance back. Viewing it is enough; the bold clears the moment you're
in the session, no input required. The dot is the live state *now*; the bold is
the unviewed-since-it-finished flag (the visual twin of the completion sound).

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

A hooked agent's last reported state lingers briefly so a finished turn stays
visible, but `switchboard quit` (and the sidebar's `q`) tears down every session
*and* clears those states — so a torn-down agent doesn't come back showing as
still "working" when it would actually need a `/resume`.

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

`ruby` `tmux` `git` `gh` (`gh` powers the PR badges and the `o`/`O` open actions)

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
