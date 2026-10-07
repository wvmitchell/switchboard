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
magenta waiting, `●` green done, `∞` green running a background monitor), the `»`
pointer for where you are now, the committed diff vs base (`+adds −dels`), and the
PR as a color-coded `#number`. When an agent finishes a turn you **hear a short
chime** and its name goes **bold** until you look — so a completion that lands
while you're heads-down elsewhere is still waiting for your eye.

An agent running a **background monitor or recurring loop** shows the steady `∞`
instead of reading as idle/done, so you don't mistake "watching in the background"
for "finished and abandoned" (and a looping agent won't chime on every tick). The
agent flags it with `switchboard monitoring on` (taught automatically via the
`background_presence` nudge; toggle off in config), or you can run it by hand. When one
of those quiet cycles actually **surfaces something** — the monitor found what it was
watching for — the agent runs `switchboard monitoring notify` and that workspace bolds
and plays a distinct **alert** sound, the one exception to the silent ticks, so a
background find still reaches you.

## Why

Coding agents pay off in parallel — several at once, each in its own worktree.
But past two or three you lose the thread: which one finished, which is blocked
on you, which is still grinding. Switchboard gives you one glanceable,
keyboard-driven view over all of them, and discovers worktrees straight from
`git`, so anything you create just shows up — nothing to sync.

## Quickstart

With Homebrew (installs tmux, git, gh, and Ruby for you):

```sh
brew tap wvmitchell/switchboard
brew trust wvmitchell/switchboard             # Homebrew 7+ asks you to trust a tap
brew install switchboard
switchboard install                          # tmux wiring + starter config (idempotent)
switchboard                                  # launch — drops you in the sidebar
```

Or from a clone (you'll need **tmux**, **git**, **gh**, and **Ruby ≥ 3.0**, no gems;
on macOS: `brew install tmux git gh`):

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

### Upgrading

`brew upgrade switchboard` (or `git pull` in your clone), then re-run
`switchboard install` or reload tmux so any new key bindings and hooks go live.
Moving a clone install to Homebrew, or uninstalling, is covered in
[How to install, upgrade, or move to Homebrew](docs/howto-install-and-upgrade.md).

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
open PR, resize, fold branches, jump to top/bottom, …). Don't like the defaults?
Remap any of them with [`sidebar_keys`](docs/reference-config.md#sidebar_keys).

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

## Making a new worktree usable

A fresh worktree has none of the untracked, git-ignored files your main checkout
picked up — no `.env`, no `node_modules`. `worktree_creation_command` is the setup
that fixes that. It runs **once, in the new worktree, before your agent**:

```yaml
worktree_creation_command:
  - cp "$SWITCHBOARD_PROJECT_PATH/.env" .
  - bundle install
```

A string works too (one line or a whole script), and a project can override it —
or set it to `false` to opt out. It's run with `sh -ec`, so it stops at the first
failing step, and a failed setup means your agent never starts: you land at a shell
with the error on screen instead of an agent working a broken checkout.

Every config knob is in the [config reference](docs/reference-config.md).

## Documentation

This README is the overview. The full set lives in [`docs/`](docs/README.md),
organized by the [Diataxis](https://diataxis.fr/) framework:

- **New here?** [Tutorial: getting started](docs/tutorial-getting-started.md) —
  install to your first worktree switch, with a live agent dot, in ~10 minutes.
- **How-to guides** — [install & upgrade](docs/howto-install-and-upgrade.md) ·
  [manage projects](docs/howto-manage-projects.md) ·
  [agent state & sounds](docs/howto-agent-state-and-sounds.md) ·
  [keybindings](docs/howto-keybindings.md) ·
  [housekeeping](docs/howto-housekeeping.md) ·
  [cutting a release](docs/howto-release.md).
- **Reference** — [CLI](docs/reference-cli.md) ·
  [config.yml](docs/reference-config.md) ·
  [keybindings](docs/reference-keybindings.md) ·
  [release pipeline](docs/reference-release.md).
- **Explanation** — [architecture](docs/explanation-architecture.md) ·
  [agent presence](docs/explanation-agent-presence.md) ·
  [sidebar lifecycle](docs/explanation-sidebar-lifecycle.md) ·
  [distribution](docs/explanation-distribution.md).

## Contributing

Contributions welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for the test,
zero-gem, and release conventions, and [AGENTS.md](AGENTS.md) if you're pointing
an AI coding agent at the repo. The test suite is stdlib Minitest with no build
step: `bin/test`.

Working on the sidebar UI? `bin/switchboard sandbox` boots **this checkout's**
sidebar in a throwaway, fully-isolated tmux — its own server, socket, and state,
seeded with a few worktrees (a PR badge, a big diff, an expanded multi-branch
workspace) so alignment/colors/spacing changes have something to render against.
Drive it by hand; detach (`prefix-d`) and it tears the whole thing down. Nothing
it does — `go_home`, a reconcile, even `quit` — can reach your real `sb/`
sessions, so you can dogfood an in-flight branch without eating your live
workspaces. It's the interactive twin of the real-tmux smoke layer
(`bin/test-smoke`).

Licensed under [MIT](LICENSE).
