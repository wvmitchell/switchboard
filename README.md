# switchboard

**Run a dozen coding agents at once and always know who needs you — without touching the mouse.**

Switchboard is a keyboard-only `tmux` sidebar for git-worktree workspaces. Every
workspace shows up as a row with a live dot telling you whether its agent is thinking,
done, or waiting on you; one keystroke switches to it. Worktrees are discovered straight
from `git`, so anything you create just shows up. Pure Ruby, zero gem dependencies.

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

`⠹` thinking · `◆` waiting on you · `●` done · `◷` finishing handed-off work ·
`∞` running a background monitor. Each row also shows its diff against base and its PR.
When an agent finishes you hear a chime and its name stays **bold** until you look.
What every glyph and color means: [sidebar reference](docs/reference-sidebar.md).

## Quickstart

With Homebrew (brings tmux, git, gh, and Ruby along):

```sh
brew tap wvmitchell/switchboard
brew trust wvmitchell/switchboard   # Homebrew 7+ asks you to trust a tap
brew install switchboard
switchboard install                 # tmux wiring + starter config
switchboard                         # launch
```

Or from a clone (needs tmux, git, gh, and Ruby ≥ 3.3):

```sh
git clone https://github.com/wvmitchell/switchboard
cd switchboard && bin/switchboard install
switchboard
```

Inside tmux, `prefix-s` toggles the sidebar from any pane. `switchboard doctor` checks
your setup, and `switchboard upgrade` keeps it current — running sidebars pick up the
new code without a restart. More in
[How to install, upgrade, or move to Homebrew](docs/howto-install-and-upgrade.md).

## The keys you need

| Key | Does |
| --- | ---- |
| `a` | add a project (a local repo or a URL to clone) |
| `n` | new workspace — type a task for the agent, `↵`, and it builds in the background |
| `↵` | switch to a workspace (or fold a project) |
| `/` | filter by name |
| `?` | every other key |

The rest are in the [key map](docs/reference-keybindings.md), and any of them can be
remapped with [`sidebar_keys`](docs/reference-config.md#sidebar_keys).

## Start your agent automatically

Tell switchboard what to run in a new workspace, and optionally how to set it up first:

```yaml
# ~/.config/switchboard/config.yml
session_command: claude --dangerously-skip-permissions

worktree_creation_command:   # runs once in the new worktree, before the agent
  - cp "$SWITCHBOARD_PROJECT_PATH/.env" .
  - bundle install
```

The task you type after `n` becomes the agent's first prompt (use `{task}` to place it
for agents other than `claude` and `codex`). If setup fails, the agent never starts and
the workspace shows `✘`. Both keys can be overridden per project; every option is in
the [config reference](docs/reference-config.md).

## Documentation

The full set lives in [`docs/`](docs/README.md):

- **New here?** [Tutorial: getting started](docs/tutorial-getting-started.md) —
  from install to your first switch in about ten minutes.
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
  [distribution](docs/explanation-distribution.md) ·
  [background dispatch](docs/explanation-background-dispatch.md) ·
  [session-name sync](docs/explanation-session-name-sync.md) ·
  [sidebar views](docs/explanation-sidebar-views.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) (and [AGENTS.md](AGENTS.md) for AI coding agents).
Tests are stdlib Minitest: `bin/test`. `bin/switchboard sandbox` runs your checkout's
sidebar in a throwaway tmux that can't touch your real sessions.

Licensed under [MIT](LICENSE).
