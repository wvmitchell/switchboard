# Contributing to switchboard

Thanks for looking at switchboard. It's a small, deliberately constrained
codebase — the constraints are most of what makes it pleasant to work on. Read
this before your first change; it'll save a round-trip.

For the design rationale behind the structure, see
[docs/explanation-architecture.md](docs/explanation-architecture.md). For the
deepest internals (the multi-process sidebar), see
[docs/explanation-sidebar-lifecycle.md](docs/explanation-sidebar-lifecycle.md).
[CLAUDE.md](CLAUDE.md) is the agent-facing map: invariants, conventions, and which doc
holds each area's full detail.

## The hard constraints

These are not negotiable — they're the project's identity:

1. **Zero gem dependencies.** Stdlib only. No Gemfile, no `bundle install`, no
   build step. Everything is Ruby stdlib plus shelling out to `tmux`, `git`, and
   `gh`. If you reach for a gem, find another way.
2. **Ruby ≥ 3.3**, the oldest Ruby still getting security fixes upstream (#35).
   CI runs `3.3` and `4.0`. Don't use syntax newer than 3.3 supports.
3. **The UI degrades, it never crashes.** Every shell-out escapes its args with
   `Shellwords` and swallows stderr; every failure path returns `[]`/`{}`/`nil`
   rather than raising into the sidebar. A long-lived TUI with a person watching
   it can survive stale data; it can't survive a backtrace.

## Running the tests

The suite is stdlib Minitest (it ships with Ruby), so there's nothing to install.

```sh
bin/test                              # the whole suite
bin/test test/config_test.rb          # one file (or several)
bin/test --seed 123 -n /sanitize/     # minitest flags pass straight through
```

`bin/test` puts `test/` on the load path and loads the requested files; minitest's
`autorun` hook runs them and sets the exit status, so CI and `&&` chains see
failures.

### Tests run fully offline, against a sandbox

Every test that touches state extends `Switchboard::SandboxTest`
(`test/test_helper.rb`). Its `setup` walls off *all* real state into a fresh
tmpdir: the config, the PATH symlink dir, the agent-state / attention / collapse /
PR-cache dirs, the XDG roots, the git global/system config, `HOME`, `gh`'s config
dir, and tmux (`TMUX` unset *and* `TMUX_TMPDIR` redirected so no test can reach a
live tmux server). `teardown` restores `ENV` wholesale and removes the tmpdir.

It also drops every `SWITCHBOARD_*` variable your shell handed down before setting its
own. A suite run inside a dispatched workspace inherits `SWITCHBOARD_TASK` and
`SWITCHBOARD_BRIEF_FROM`, and one inside the sandbox inherits `SWITCHBOARD_SANDBOX`; any
of them would change what the code under test does. The one survivor is
`SWITCHBOARD_CODEX_SMOKE`, your opt-in to the real-codex smoke below.
`test/sandbox_env_test.rb` holds that wall.

So a test never reads or writes anything outside its sandbox, and never pokes your
real tmux. When you add state, resolve its location through `Paths`
(`lib/switchboard/paths.rb`; see how `AgentState.state_dir` and friends call it). It
reads `ENV` *per call*, so the sandbox can redirect it.

Helpers you'll use:

- `temp_git_repo(name, origin: false)` — a throwaway, hermetic git repo (fixed
  `main` branch, seeded commit, local identity; `origin: true` wires a bare remote
  with a real `origin/HEAD`).
- `stub_method(receiver, name, impl) { … }` — swap one method for a block
  (version-proof stand-in for minitest's stub). Use it to fake a single shell-out
  seam, e.g. `Git.branch_history`.
- `with_stdin(io) { … }` — swap `$stdin` to drive the sidebar's raw-mode reads.

Every scripted `tmux` call in `lib/` passes `-u`. Without it, tmux prints a format's tab as
`_` to a client under a C locale, and non-English names with it, so what we parse stops
matching. Interactive `attach` is the exception, because `-u` would change what your terminal
receives. A test in `test/tmux_test.rb` holds this. The shell in `switchboard.tmux` isn't
covered and doesn't need to be, since its `tmux` calls set hooks and read nothing back.

Pure decision logic is split out from its shell-out so it's unit-testable without
a subprocess (e.g. `Reconcile.orphans`, `Installer.rebind_ops`,
`Doctor.orphan_sidebar_count`). Follow that pattern: keep the decision pure, test it
directly, and stub the one I/O seam.

### The real-tmux smoke layer (issue #104)

The offline suite is the inner loop, but a stubbed tmux can't exercise the bugs
that actually bite — the lifecycle ones (pane recycling, hook firing, split/kill
timing, attach/detach). Those live in a separate **real-tmux smoke layer** under
`test/smoke/`, run by its own runner:

```sh
bin/test-smoke                 # boots a real tmux server, drives the real binary end-to-end
```

It's deliberately **out of `bin/test`** (which globs `test/*_test.rb`, non-recursive)
so the fast offline suite stays the inner loop, and it has its own **blocking** CI
job. `SmokeCase` (`test/smoke/smoke_helper.rb`) subclasses `SandboxTest` to reuse the
env wall-off verbatim, then boots an isolated server (a **short** `TMUX_TMPDIR` +
the default socket — macOS caps unix socket paths, and bare-`tmux` must reach the
same server inside panes and in subcommands), attaches a real client via the stdlib
`PTY` (so the sidebar actually renders — an unattached server reads
`session_attached=0` and stays dormant), and drives the real binary. Every assertion
polls via `wait_until` (never sleep-then-assert), the PTY master is drained (so
backpressure can't stall the client), and a socket-path guard refuses any destructive
op that isn't pointed at the throwaway socket. Needs a real `tmux`; it skips locally
when absent, but `SMOKE_REQUIRE_TMUX=1` (set in CI) makes a missing tmux a hard error
so the gate can't silently no-op.

A second opt-in smoke, `test/smoke/codex_hook_smoke_test.rb`
(`SWITCHBOARD_CODEX_SMOKE=1`), drives **real codex** through the delivery path no unit
test can reach: it installs the global `[hooks]` block into a sandbox `CODEX_HOME`
(auth borrowed from the real `~/.codex`, which it never touches), adds a **linked** git
worktree, runs `codex exec` headlessly there, and asserts the resting state lands where
`AgentState` reads it — the standing regression guard that codex's config-level hooks
still fire in a linked worktree (the bug per-worktree `.codex/hooks.json` couldn't
clear). That run passes `--dangerously-bypass-hook-trust`, so a second case runs
without it and asserts an untrusted block writes no state (the case behind `doctor`'s
`N/M trusted` warning). The #130 nested-agent guard is covered offline by
`codex_hook_test`'s runtime guard test. Needs `codex` on PATH + auth + network, and spends tokens.

## Code conventions

- Every file starts with `# frozen_string_literal: true`.
- **Stateless helpers are `module_function` modules** (`ClaudeHook`, `Tmux`,
  `Installer`, `Git`, `Pr`, `Reconcile`, `Creator`, `Registrar`, `Sound`,
  `Attention`, `Collapse`, …). Only `Model`, `Config`, `Sidebar` (plus its
  `Sidebar::Edges` collaborator, the #57 carve-out of the agent-edge fanout
  state, and `Sidebar::UpdateCue`, the update line's), and `AgentState` are classes — they
  hold state. Don't make a class for something that doesn't need instance state.
- **Every file under `lib/switchboard/` has a layer** (support, adapters, state,
  operations, interfaces) and may reference only its own layer or a lower one.
  `test/layers_test.rb` fails when a file has no layer, when a lower layer reaches up
  to a higher one, or when a file other than `lib/switchboard/root.rb` locates paths from
  its own `__dir__` or `__FILE__` (use `Switchboard::ROOT` instead).
  A new file goes into the test's `LAYERS` list; the
  [architecture doc's Layers section](docs/explanation-architecture.md#layers) explains
  which layer fits.
- **Comments explain *why*, not *what*.** The code is meant to be
  self-documenting; the existing comments are there for the non-obvious reason (a
  re-exec, a TTL, a capture-hash, a recycled pane id). Match that density — terse,
  only where the reason isn't on the surface. Don't narrate what the next line
  plainly does.
- Self-documenting names over abbreviations.

## Submitting a change

1. Branch off `main`.
2. Make the change with tests. New behavior gets a test; a bug fix gets a test
   that fails before and passes after.
3. `bin/test` is green locally.
4. Open a PR against `main`. CI (`.github/workflows/test.yml`) runs the suite on
   Ruby 3.3 and 4.0.

Keep changes focused. If you spot adjacent tech debt, note it in
[TODOS.md](TODOS.md) (which records *what*, *why*, and *where to start* for
deferred work) rather than expanding the PR.

## Releasing (maintainer)

Versions follow the `vX.Y.Z` prefixes in the git history. To cut one, in your PR:

1. Bump `Switchboard::VERSION` in `lib/switchboard/version.rb`.
2. Add a `## [X.Y.Z] — <summary> (<date>)` entry to
   [CHANGELOG.md](CHANGELOG.md), grouped into Added / Changed / Fixed. Write the
   entry as *why it matters*, in the project's voice — see the existing entries.
   The GitHub Release notes come from it, and `test/release_test.rb` fails if the
   current version has none.
3. Title the PR `vX.Y.Z type(scope): summary` (the squash commit becomes the
   format the git log already uses).

After merge, `.github/workflows/release.yml` tags `vX.Y.Z`, creates the GitHub
Release, and updates the Homebrew tap, once `test` and `formula` are green on
main. Never tag by hand. See [How to cut a release](docs/howto-release.md) and
[the release pipeline reference](docs/reference-release.md).

Users upgrade with `switchboard upgrade` (0.52.0+): it fetches the new version and has
the new binary re-wire tmux and every hooked worktree — the CHANGELOG header says so.
`switchboard install` is the manual repair (inside tmux, it also reloads the bindings).

## Where things live

| Area | File(s) |
|------|---------|
| Command dispatch | `lib/switchboard/cli.rb` |
| `switchboard doctor`'s checks | `lib/switchboard/doctor.rb` |
| Quitting and removing a workspace, for both front-ends | `lib/switchboard/workspaces.rb` |
| What the agent hooks print and record | `lib/switchboard/hook_commands.rb` (the decisions: `rename_nudge.rb`, `dispatch_nudge.rb`, `monitoring_nudge.rb`) |
| Config / registry | `lib/switchboard/config.rb` |
| The data model + tree | `lib/switchboard/model.rb`, `tree.rb` |
| The sidebar TUI | `lib/switchboard/sidebar.rb` (run-loop core) + `lib/switchboard/sidebar/{edges,update_cue,render,input,actions,prompt,rows}.rb` (its test files: `test/sidebar_*_test.rb`, sharing `test/support/sidebar_case.rb`) |
| tmux integration | `lib/switchboard/tmux.rb`, `lib/switchboard/tmux/`, `switchboard.tmux` |
| Install / keybindings | `lib/switchboard/installer.rb`, `lib/switchboard/installer/keybindings.rb`, `stable_path.rb` (Homebrew `opt/` paths) |
| Upgrade / release check | `lib/switchboard/upgrade.rb`, `latest_release.rb` |
| Packaging / releases | `packaging/homebrew/switchboard.rb` (formula), `packaging/release.rb`, `.github/workflows/{release,formula}.yml` |
| Marker-block surgery (tmux.conf + `~/.codex/config.toml`) | `lib/switchboard/marker_block.rb` |
| Agent state / hooks | `lib/switchboard/agent_state.rb`, `agents.rb`; adapters `claude_hook.rb` (Claude, per-worktree) + `codex_hook.rb` (Codex, global `~/.codex/config.toml` block) over shared base `hook_file.rb`, behind registry `agent_hooks.rb` |
| Sounds / bold / collapse | `lib/switchboard/sound.rb`, `attention.rb`, `collapse.rb` (shared base: `keyed_marker_store.rb`) |
| Git / PRs / reconcile | `lib/switchboard/git.rb`, `pr.rb`, `reconcile.rb` |
| State-file locations / on-off view flags | `lib/switchboard/paths.rb`, `view_flag.rb` |

See [docs/](docs/) for the full Diataxis documentation set.
