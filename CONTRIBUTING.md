# Contributing to switchboard

Thanks for looking at switchboard. It's a small, deliberately constrained
codebase — the constraints are most of what makes it pleasant to work on. Read
this before your first change; it'll save a round-trip.

For the design rationale behind the structure, see
[docs/explanation-architecture.md](docs/explanation-architecture.md). For the
deepest internals (the multi-process sidebar), see
[docs/explanation-sidebar-lifecycle.md](docs/explanation-sidebar-lifecycle.md).
[CLAUDE.md](CLAUDE.md) is the dense, agent-facing map of the whole thing.

## The hard constraints

These are not negotiable — they're the project's identity:

1. **Zero gem dependencies.** Stdlib only. No Gemfile, no `bundle install`, no
   build step. Everything is Ruby stdlib plus shelling out to `tmux`, `git`, and
   `gh`. If you reach for a gem, find another way.
2. **Ruby ≥ 3.0.** `Config` uses `YAML.safe_load_file` (Psych 3.3 / Ruby 3.0).
   CI runs `3.0` and `3.3`. Don't use syntax newer than 3.0 supports.
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

So a test never reads or writes anything outside its sandbox, and never pokes your
real tmux. When you add state, route it through an env-overridable path (see how
`AgentState.state_dir` and friends read `ENV` *per call*) so the sandbox can
redirect it.

Helpers you'll use:

- `temp_git_repo(name, origin: false)` — a throwaway, hermetic git repo (fixed
  `main` branch, seeded commit, local identity; `origin: true` wires a bare remote
  with a real `origin/HEAD`).
- `stub_method(receiver, name, impl) { … }` — swap one method for a block
  (version-proof stand-in for minitest's stub). Use it to fake a single shell-out
  seam, e.g. `Git.branch_history`.
- `with_stdin(io) { … }` — swap `$stdin` to drive the sidebar's raw-mode reads.

Pure decision logic is split out from its shell-out so it's unit-testable without
a subprocess (e.g. `Reconcile.orphans`, `Installer.rebind_ops`,
`CLI.orphan_sidebar_count`). Follow that pattern: keep the decision pure, test it
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

## Code conventions

- Every file starts with `# frozen_string_literal: true`.
- **Stateless helpers are `module_function` modules** (`ClaudeHook`, `Tmux`,
  `Installer`, `Git`, `Pr`, `Reconcile`, `Creator`, `Registrar`, `Sound`,
  `Attention`, `Collapse`, …). Only `Model`, `Config`, `Sidebar`, and
  `AgentState` are classes — they hold state. Don't make a class for something
  that doesn't need instance state.
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
   Ruby 3.0 and 3.3.

Keep changes focused. If you spot adjacent tech debt, note it in
[TODOS.md](TODOS.md) (which records *what*, *why*, and *where to start* for
deferred work) rather than expanding the PR.

## Releasing (maintainer)

Versions follow the `vX.Y.Z` prefixes in the git history. To cut one:

1. Bump `Switchboard::VERSION` in `lib/switchboard/version.rb`.
2. Add a `## [X.Y.Z] — <summary> (<date>)` entry to
   [CHANGELOG.md](CHANGELOG.md), grouped into Added / Changed / Fixed. Write the
   entry as *why it matters*, in the project's voice — see the existing entries.
3. Commit with a `vX.Y.Z type(scope): summary (#PR)` subject (the format the git
   log already uses).

After upgrading, users re-run `bin/switchboard install` (or reload tmux) so new
tmux bindings/hooks go live — the CHANGELOG header says so.

## Where things live

| Area | File(s) |
|------|---------|
| Command dispatch | `lib/switchboard/cli.rb` |
| Config / registry | `lib/switchboard/config.rb` |
| The data model + tree | `lib/switchboard/model.rb`, `tree.rb` |
| The sidebar TUI | `lib/switchboard/sidebar.rb` |
| tmux integration | `lib/switchboard/tmux.rb`, `switchboard.tmux` |
| Install / keybindings | `lib/switchboard/installer.rb` |
| Agent state / hooks | `lib/switchboard/agent_state.rb`, `agents.rb`; per-agent adapters `claude_hook.rb` (Claude) + `codex_hook.rb` (Codex) over shared base `hook_file.rb`, behind registry `agent_hooks.rb` |
| Sounds / bold / collapse | `lib/switchboard/sound.rb`, `attention.rb`, `collapse.rb` (shared base: `keyed_marker_store.rb`) |
| Git / PRs / reconcile | `lib/switchboard/git.rb`, `pr.rb`, `reconcile.rb` |

See [docs/](docs/) for the full Diataxis documentation set.
