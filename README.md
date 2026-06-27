# switchboard

**Run a dozen coding agents at once and always know who needs you — without touching the mouse.**

Switchboard is a keyboard-only switcher and creator for git-worktree workspaces.
A persistent `tmux` sidebar shows every workspace as a tree, with a live dot
beside each one telling you whether its agent is thinking, done, or waiting on
you. Switch between them with a keystroke. It's terminal-native — no Electron,
no mouse, no database. Pure Ruby, **zero gem dependencies**.

```
switchboard · home
──────────────────────────────────────────
▾ api
» ⠹ rate-limiter            +56  −3    #485
  ● new-auth-flow          +124 −18    #482
    ◆ retry-backoff         +12  −0   draft
▾ web
  ● dark-mode               +89 −44    #211
    checkout-redesign      +203  −9    #214
▸ infra
──────────────────────────────────────────
↑↓ move · ↵ open · ? help
```

Each row shows its work at a glance: an **agent dot** (`⠹` blue thinking, `◆`
magenta waiting, `●` green done), the `»` pointer for where you are now, the
committed diff vs base (`+adds −dels`), and the PR as a color-coded `#number`.
When an agent finishes a turn you **hear a short chime** and its name goes
**bold** until you look — so a completion that lands while you're heads-down
elsewhere is still waiting for your eye.

## Why

Coding agents pay off in parallel — several at once, each in its own worktree.
But past two or three you lose the thread: which one finished, which is blocked
on you, which is still grinding. Switchboard gives you one glanceable,
keyboard-driven view over all of them, and discovers worktrees straight from
`git`, so anything you create just shows up — nothing to sync.

## Quickstart

You'll need **tmux**, **git**, **gh**, and **Ruby ≥ 3.0** (no gems). On macOS:
`brew install tmux git gh`.

```sh
git clone https://github.com/wvmitchell/switchboard
cd switchboard && bin/switchboard install   # symlinks + tmux wiring + starter config (idempotent)
switchboard                                  # launch — drops you in the sidebar
```

That's it. `switchboard install` puts `switchboard` (and a short `sb` alias) on
your PATH, adds one line to your tmux config, and writes a starter config;
`switchboard doctor` confirms everything's wired. From a plain shell,
`switchboard` bootstraps and attaches the home session; inside tmux, `prefix-s`
toggles the sidebar from any pane.

## The core loop

Everything happens from inside the sidebar:

| Key | Does |
| --- | ---- |
| `a` | add a project — register a local repo or clone a URL |
| `n` | create a new worktree + branch in the highlighted project |
| `↵` | switch to a workspace (or expand/collapse a project) |
| `/` | filter — type a few letters to jump straight to a workspace |
| `?` | the full key map — every shortcut, any key closes it |

`a` to make a project, `n` to make work, `↵` to move between it — all without
leaving the keyboard. Forgot a key? Press `?`. That's the whole muscle memory;
the [full key map](docs/reference-keybindings.md) has the rest (rename, delete,
open PR, resize, jump to top/bottom, …).

## Launching your agent

The point of all this is that a new workspace comes up *already running your
agent*. That's the `session_command` — what switchboard types into a worktree's
window the first time it creates that session:

```yaml
# ~/.config/switchboard/config.yml
session_command: claude --dangerously-skip-permissions
```

Set it globally or override it per project (a different agent, different flags).
It fires only on session *creation*, never on a re-switch, so a running agent is
never disturbed — and leave it unset and `n` just drops you in a plain shell.
Every config knob is in the [config reference](docs/reference-config.md).

## Documentation

This README is the overview. The full set lives in [`docs/`](docs/README.md),
organized by the [Diataxis](https://diataxis.fr/) framework:

- **New here?** [Tutorial: getting started](docs/tutorial-getting-started.md) —
  install to your first worktree switch, with a live agent dot, in ~10 minutes.
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

## Contributing

Contributions welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for the test,
zero-gem, and release conventions, and [AGENTS.md](AGENTS.md) if you're pointing
an AI coding agent at the repo. The test suite is stdlib Minitest with no build
step: `bin/test`.

Licensed under [MIT](LICENSE).
