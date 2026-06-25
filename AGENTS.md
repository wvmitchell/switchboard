# AGENTS.md

Guidance for AI coding agents working in this repository. This is the
tool-neutral entry point ([agents.md](https://agents.md) convention);
[CLAUDE.md](CLAUDE.md) is the canonical, in-depth version and the two are kept in
sync. **Read CLAUDE.md before making changes** — it holds the full architecture,
the subtle invariants (agent-state TTLs, the recycled-pane-id orphan bug,
multi-process state), and the conventions. This file is the short orientation.

## What this is

Switchboard is a keyboard-only switcher/creator for git-worktree workspaces — a
terminal-native alternative to Conductor/emdash. Pure Ruby, **zero gem
dependencies**: stdlib plus shelling out to `tmux`, `git`, and `gh`. No Gemfile,
no build step.

## Non-negotiable constraints

1. **Zero gems, stdlib only.** No Gemfile, no `bundle`. If you want a gem, don't.
2. **Ruby ≥ 3.0.** CI runs 3.0 and 3.3. No newer syntax.
3. **Degrade, never crash.** Every shell-out escapes args with `Shellwords` and
   swallows stderr; failures return `[]`/`{}`/`nil`, never a backtrace into the
   TUI.
4. **Every file starts with `# frozen_string_literal: true`.**
5. **Comments explain *why*, not *what*.** Match the existing terse density.

## Before you start

- Run the suite: `bin/test` (stdlib Minitest, fully offline). One file:
  `bin/test test/foo_test.rb`.
- Tests extend `SandboxTest` (`test/test_helper.rb`), which walls all real state
  (config, XDG, git global, `HOME`, tmux) into a tmpdir. New state must route
  through an env-overridable path so the sandbox can redirect it.
- Keep decision logic pure and split from its shell-out (e.g. `Reconcile.orphans`,
  `Installer.rebind_ops`); test the pure part directly, stub the one I/O seam with
  `stub_method`.

## Map

- **Dispatch:** `lib/switchboard/cli.rb`
- **Data model → tree → TUI:** `model.rb` → `tree.rb` → `sidebar.rb`
- **Config / registry:** `config.rb`
- **tmux:** `tmux.rb`, `switchboard.tmux` · **install/keys:** `installer.rb`
- **Agent presence:** `agent_state.rb`, `hook.rb`, `agents.rb`
- **Sounds / bold / collapse:** `sound.rb`, `attention.rb`, `collapse.rb`
- **Git / PRs / reconcile:** `git.rb`, `pr.rb`, `reconcile.rb`

## Conventions

- Stateless helpers are `module_function` modules; only `Model`, `Config`,
  `Sidebar`, `AgentState` are classes (they hold state).
- New worktree state belongs on disk (one file per item, atomic temp+rename, GC'd)
  because every window's sidebar is a separate process — see
  [docs/explanation-sidebar-lifecycle.md](docs/explanation-sidebar-lifecycle.md).

## Further reading

- [CLAUDE.md](CLAUDE.md) — the canonical deep map (read this first).
- [CONTRIBUTING.md](CONTRIBUTING.md) — tests, conventions, release process.
- [docs/](docs/) — the full documentation set (tutorial, how-tos, reference, explanation).
- [docs/explanation-architecture.md](docs/explanation-architecture.md) — the design rationale.
