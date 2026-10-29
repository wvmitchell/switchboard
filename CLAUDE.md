# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Switchboard is a keyboard-only switcher/creator for git-worktree workspaces — a
terminal-native alternative to Conductor/emdash. It's pure Ruby with **zero gem
dependencies**: everything is stdlib plus shelling out to `tmux`, `git`, and `gh`. There
is no Gemfile and no build step. Ruby **>= 3.3** is required (#35; CI runs 3.3 and 4.0);
`bin/switchboard` re-execs itself under a modern Ruby when launched on macOS system Ruby,
because tmux panes run a non-interactive shell that skips rbenv.

**This file is a map, not the manual.** The full detail lives in `docs/` (a complete
Diataxis set). Before you change an area, read the doc the table below names for it, and
keep that doc current in the same PR. Don't grow this file back into a manual: new detail
goes in the docs, and this file gets at most a pointer or a one-line invariant.

## Commands

```sh
bin/test                   # the offline stdlib-Minitest suite (bin/test <file> for one)
bin/test-smoke             # the real-tmux smoke layer (boots its own server; needs tmux)
bin/switchboard sandbox    # dogfood THIS checkout's sidebar in a throwaway tmux, torn down on detach
bin/switchboard doctor     # check tmux/git/gh, config, install wiring, hooks, links
bin/switchboard reload-sidebars # swap every running sidebar to its own binary's current code
```

Every command and flag: [docs/reference-cli.md](docs/reference-cli.md) (and the annotated
command map in [docs/explanation-architecture.md](docs/explanation-architecture.md#the-command-map-in-detail)).

**Tests.** Every `bin/test` test runs **offline**: `SandboxTest` (`test/test_helper.rb`)
walls off config, XDG dirs, git global, `HOME` and `TMUX` into a tmpdir, and
`temp_git_repo` makes throwaway repos (tmux/gh shell-outs are stubbed). The smoke layer
(`test/smoke/`, `SmokeCase`, its own blocking CI job, #104) drives the real binary on an
isolated tmux socket through a PTY client — the bug class the stubs can't reach. It stays
out of `bin/test` so the offline suite is the inner loop. Env overrides for running
locally without touching real state:
[docs/explanation-architecture.md](docs/explanation-architecture.md#environment-overrides-for-local-runs).

## Where the detail lives

| Area | Read |
|---|---|
| Git as runtime truth, the model/tree, the worktree ⇆ `sb/` session mapping, `session_command` | [explanation-architecture](docs/explanation-architecture.md) (§ The runtime model, in detail) |
| `install` / `uninstall` / `doctor` / `prune`, the tmux fragment and its three hooks | [explanation-architecture](docs/explanation-architecture.md) (§ Install, doctor and prune) |
| Configurable tmux keys (`tmux_keys`, #15) | [explanation-architecture](docs/explanation-architecture.md) (§ Configurable tmux keys), [howto-keybindings](docs/howto-keybindings.md) |
| `switchboard sandbox`, `IsolatedServer` | [explanation-architecture](docs/explanation-architecture.md) (§ The sandbox) |
| `n` → task → ↵ background dispatch, `Creation` records, the setup script, deferred naming | [explanation-background-dispatch](docs/explanation-background-dispatch.md) |
| Per-session visibility, off-screen dormancy, pre-warming, warm broadcasts, recycled pane ids | [explanation-sidebar-lifecycle](docs/explanation-sidebar-lifecycle.md) |
| Hot reload of running sidebars (#48), the resume payload | [explanation-sidebar-lifecycle](docs/explanation-sidebar-lifecycle.md) (§ The code reload, in detail) |
| Agent-state dots, Claude/Codex hook delivery, the global codex block | [explanation-agent-presence](docs/explanation-agent-presence.md) |
| The rename nudge, completion sounds, bold until viewed, `KeyedMarkerStore` | [explanation-agent-presence](docs/explanation-agent-presence.md) (§ Implementation detail) |
| ∞ monitoring + `monitoring notify`, ⇅ remote links + QR, ◷ background work | [explanation-agent-presence](docs/explanation-agent-presence.md) (§ Implementation detail) |
| Session-name sync (typing `/rename` into Claude's pane) | [explanation-session-name-sync](docs/explanation-session-name-sync.md) |
| Folds, full header, width, diff counts, `/` filter, `?` overlay, `sidebar_keys` | [explanation-sidebar-views](docs/explanation-sidebar-views.md) |
| Baked paths (`StablePath`), releases, the update line, `switchboard upgrade` | [explanation-distribution](docs/explanation-distribution.md), [reference-release](docs/reference-release.md) |
| Config keys | [reference-config](docs/reference-config.md) |
| What each sidebar row shows | [reference-sidebar](docs/reference-sidebar.md) |

## Invariants that bite

The ones that broke something before. Each doc above explains why.

- **Git is the source of truth at runtime; the config is only a project registry.**
- **Multi-process state lives on disk, written atomically.** Every window's sidebar is its
  own process, so shared state (dots, bold, folds, width, the config) is files written by
  temp+rename (`KeyedMarkerStore`, `MarkerBlock.atomic_write`). A plain `File.write`
  truncates first, and a peer reading the empty file gets valid empty YAML (zero projects),
  not an error.
- **Never touch the developer's real tmux server** from tests, smoke runs or the sandbox:
  `SandboxTest`, `IsolatedServer`, the ppid-scoped sidebar reap and `SWITCHBOARD_SANDBOX`.
- **Only announcing, on-screen scans ring.** Catch-up and off-screen scans re-baseline
  silently, so a completion is heard once. `warm_reload` is not `reload` with flags.
- **Only the installed binary rewrites shared wiring** (`Installer.installed_bin?`), and
  `HookFile.refresh` only updates, never adds or clobbers.
- **The global codex block is consent-only.** Codex writes its trust approvals and its own
  tables inside our markers: carry them, refuse (`:unsafe`) what a line move could change,
  and never advise deleting the block by hand.
- **Undocumented upstream files fail closed** (Claude's sessions file): an unrecognized
  shape is no signal, never a wrong one.
- **Dispatch never starts an agent on an un-set-up tree, and never destroys work**: the
  agent starts only through `Creation.authorize_launch`, and rollback removes only what it
  can prove is its own.
- **Session-name sync: at most one Enter per session per worker.** Don't add a retry.
- **Hook commands print only JSON or nothing, and exit 0** (`rename-nudge`): a stray byte
  poisons Claude.
- **Cross-version contracts**: a newer sidebar accepts every older resume payload;
  `@sb_reload`, `@sb_reload_failed` and `SIGUSR1` never change meaning; `Creation`
  records stay readable by older launchers. New `Keymap::ACTIONS` go LAST.

## Upstream contracts, last verified

The security monitor ([docs/howto-security-monitor.md](docs/howto-security-monitor.md))
tracks these lines; update them when you re-verify one.

- **Hooks:** last verified live against **Claude Code 2.1.301–2.1.303** and **codex-cli
  0.163.0** (v0.51.1): payload fields, linked-worktree delivery, the nesting-guard env, and
  a silent PermissionRequest hook leaving the prompt to the user. **codex-cli 0.164.0**
  (v0.55.2) and **0.165.0** (v0.60.7) re-passed the real-Codex smoke only: linked-worktree
  delivery, hook ordering, untrusted-block silence.
- **Codex is global:** Codex (verified 0.142 through 0.165) doesn't load a *linked*
  worktree's own hooks, so switchboard writes one `[hooks]` block into
  `~/.codex/config.toml`.
- **⇅ remote link** (`bridgeSessionId`, `procStart` in `~/.claude/sessions/<pid>.json`):
  verified live on Claude Code 2.1.308 (`doctor`'s canary still clean on 2.1.312).
- **◷ sessions-file `status`:** last verified live against **Claude Code 2.1.308–2.1.310**
  (v0.56.0), re-checked live on 2.1.311–2.1.312 (a background agent's hand-off held its
  chime).
- **Session-name sync** (Claude's screen and `/rename`): pinned by real 2.1.310 captures in
  `test/fixtures/session_name` and confirmed live on 2.1.312 (the sidebar's `r`, the pane
  in view).

## Conventions

- Issue/PR numbers in comments and docs from before v0.50.0 (e.g. `#57`, `#94`)
  refer to the private `switchboard-archive` repo; the public tracker restarted at #1
  (#8 = assign versions after merge, #9 = open-source readiness tracking).
- Every file starts with `# frozen_string_literal: true`.
- Stateless helpers are `module_function` modules (`ClaudeHook`, `CodexHook`,
  `MarkerBlock`, `Tmux`, `Installer`, …); only `Model`, `Config`, `Sidebar`, and
  `AgentState` are classes (they hold state).
- One stateful class may split across **concern files** when it outgrows a
  single one (#57: `Sidebar` + `lib/switchboard/sidebar/*`): nested modules
  `include`d into the class, state ownership staying in the class; a cohesive
  state-owning cluster becomes a collaborator class instead (`Sidebar::Edges`).
  The load-order rule that keeps it safe: a file's constant initializers only
  reference same-file constants, and the parts are required at the BOTTOM of
  the core file. Genuinely stateless pieces remain `module_function`.
- All shell-outs escape args with `Shellwords` and swallow stderr; failures
  degrade gracefully (return `[]`/`{}`/`nil`) rather than crash the UI.
- Code is meant to be self-documenting; the existing comments explain *why* a
  non-obvious thing is done (the re-exec, the TTL, the capture-hash). Match that
  density — terse, only where the reason isn't on the surface.
- Formal implementation plans live in `thoughts/` (one markdown file per effort,
  e.g. `thoughts/126-sandbox-command.md`). The directory is **gitignored** — plans
  are local working notes, drafted before the code and reviewed there, never
  committed.
