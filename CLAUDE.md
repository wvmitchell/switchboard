# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Switchboard is a keyboard-only switcher/creator for git-worktree workspaces — a
terminal-native alternative to Conductor/emdash. It's pure Ruby with **zero gem
dependencies**: everything is stdlib plus shelling out to `tmux`, `git`, and
`gh`. There is no Gemfile and no build step. The test suite is stdlib Minitest
(no gems) under `test/` — run the whole thing with `bin/test`, or one file with
`bin/test test/installer_test.rb`. Every test runs **offline**: `SandboxTest`
(`test/test_helper.rb`) walls off real state — config, XDG dirs, git global,
`HOME`, `TMUX` — into a tmpdir, and its `temp_git_repo` helper spins up throwaway
repos for the git-backed tests (tmux/gh shell-outs are stubbed). A second,
opt-in **real-tmux smoke layer** (`test/smoke/`, run by `bin/test-smoke`, its own
blocking CI job — issue #104) boots an actual tmux server on an isolated socket and
drives the real binary through the create→switch→toggle→new-window→close-pane→quit
lifecycle — the bug class the stub can't reach (`SmokeCase` subclasses `SandboxTest`,
attaches a stdlib-`PTY` client so the sidebar renders, polls via `wait_until`); it's
kept OUT of `bin/test` so the offline suite stays the inner loop. See `README.md`
for the user-facing feature tour, and `docs/` for the full Diataxis documentation
set. The explanation docs (`docs/explanation-architecture.md`,
`explanation-agent-presence.md`, `explanation-sidebar-lifecycle.md`,
`explanation-distribution.md`) are the human-readable companions to this file; `CONTRIBUTING.md` collects the
test/zero-gem/release conventions; `AGENTS.md` is the tool-neutral pointer back
here.

## Commands

```sh
bin/switchboard            # start: attach home from a shell, or toggle the sidebar inside tmux (alias: sb)
bin/switchboard install    # symlinks (switchboard + sb) onto PATH (skipped under Homebrew) + wire tmux bindings + empty config (--no-tmux/--print-tmux/--tmux-conf)
bin/switchboard upgrade    # fetch the newest version the way it was installed (brew / brew --HEAD / clone fetch + ff-only merge), then exec the NEW binary's `upgrade --finish`: refresh reporter + stale worktree hooks + codex block, run the tmux fragment in the live server from any shell. Already current ⇒ says so, unless setup is stale (then finishes it)
bin/switchboard uninstall  # reverse install (both symlinks — left to `brew uninstall` under Homebrew — + tmux marker block + live unbind)
bin/switchboard doctor     # check that tmux/git/gh + config + install wiring exist
bin/switchboard init       # create ~/.config/switchboard/config.yml (empty; grown by the add-project flow)
bin/switchboard config     # open config.yml in $EDITOR (sidebar `e` does the same)
bin/switchboard sidebar    # run the persistent sidebar standalone (normally tmux-spawned)
bin/switchboard rename NAME # rename the current workspace from inside it (dir move + bridge + session rename + Claude `/resume` history carry + the git branch when safe — see #94); for the agent to (re)name its own live workspace (#42). No NAME prints usage + the current name (switchboard doesn't guess one)
bin/switchboard monitoring on|off # flag/unflag this workspace as running a background monitor/loop (steady ∞ dot; bare = status). Agent- or human-invoked; re-run `on` each cycle to keep it live (liveness = marker mtime within Monitoring::TTL). Layer-2 SessionStart/SessionEnd hooks (monitoring-nudge) clear it per-session + nudge, gated on config background_presence
bin/switchboard monitoring notify # (from a MONITORED workspace) declare "come look — this cycle surfaced something": bold + a distinct `alert` sound + sparkle, the one exception to the silent routine ticks. Gated to monitored; writes an Attention bold (direct) + a Notify mtime marker (the sidebar's announce-gated ring). See the ∞ section.
bin/switchboard prune      # kill orphaned sb/ sessions (reconcile vs git worktrees) + reap orphaned sidebar processes; --dry-run/-n previews
bin/switchboard sandbox    # dogfood THIS checkout's sidebar in a throwaway, fully-isolated tmux — auto-torn-down on detach (the interactive twin of bin/test-smoke, #126)
bin/switchboard quit       # close ALL sb/ sessions (full teardown; current session last; clears agent state)
bin/test                   # run the stdlib-Minitest suite (offline; bin/test <file> for one)
bin/test-smoke             # run the real-tmux smoke layer (boots a server; needs tmux; out of bin/test — #104)
```

Setup is one command: `git clone && bin/switchboard install` (or `brew tap
wvmitchell/switchboard && brew trust wvmitchell/switchboard && brew install switchboard &&
switchboard install`) (`Installer`, `installer.rb`). It symlinks `bin/switchboard` to `~/.local/bin` (plus a short
`sb` alias beside it; a collided `sb` is skipped, the real command still
installs), adds a
marker-delimited line to the tmux.conf tmux actually loads (found via
`#{config_files}`) that sources the self-locating `switchboard.tmux` fragment,
and scaffolds a config (an **annotated template** — `Config::SCAFFOLD_TEMPLATE`,
whose only **value-carrying** keys are `worktree_root` + `projects`, so its
*effective* config equals `default_data` while showing every optional knob. The
nested-map headers (`sounds`/`tmux_keys`/`sidebar_keys`) are uncommented but **empty**
— an empty map reads identically to absent (`@data["sounds"]` is nil either way), so
they change nothing, yet a child override is a single uncomment away with its parent
already in place (the anti-trap: a key can't get orphaned at the margin because its
header is never commented). Tests assert the effective shape via
`assert_effective_default_config` — the parse minus nil headers. Comments are stripped
on the first `add_project` YAML.dump rewrite, after the new user has read them.
Stray top-level keys (a misindented child) are caught by `Config#unknown_keys` →
`doctor`.) Finally it offers to install the **global codex hooks** block — opt-in,
prompted (`--codex-hooks` / `--no-codex-hooks` skip the prompt; default no on a
non-tty), since it writes the user's personal `~/.codex/config.toml` (see the
agent-state-dots section). The fragment runs `switchboard tmux-bind` (which
binds the configured keys — see keybindings below) and sets three indexed hooks:
`client-session-changed[99]` (poke the now-visible sidebar to reload on a session
switch), `after-new-window[99]` (give a new window its own sidebar when the session
is showing one — see per-session visibility below), and `session-window-changed[99]`
(poke the sidebar on a same-session *window* switch, which isn't a session change —
`poke-window`, gated to `sb/` sessions so the global hook no-ops elsewhere). All
steps are idempotent and reversed by `uninstall` (which clears all three hook slots
— `Installer::HOOK_SLOTS` — plus the bound keys, the `@switchboard-*` options, and the
global codex `[hooks]` block). `doctor` reports whether
those hooks are **live** in the running server, not just present in config (they
go stale after a `git pull` until tmux reloads). `doctor` also flags **orphaned
sidebar processes** — a `switchboard sidebar` that outlived its pane — by diffing
the running-process count (`pgrep`) against the sidebar-pane count
(`Tmux.sidebar_pane_count`); a straggler matters because tmux recycles pane ids,
so it can end up reading a different live pane and double-fire completion sounds.
`prune` **reaps** them (`Reconcile.reap_sidebars`): it pairs each running sidebar
with its tty (`Tmux.sidebar_processes`) and SIGTERMs any whose tty matches no live
pane (`Tmux.live_pane_ttys`) — so a sidebar that owns a pane is never touched, and
a nil/empty pane list (a flaky/garbled `tmux` read) reaps nothing rather than wipe
every sidebar. Crucially `Tmux.sidebar_processes` is **scoped to this server's own
children by parent pid** (`ppid == Tmux.server_pid`): a sidebar is a direct child of
the tmux server that split-window'd it, so this machine-global `ps` can only ever
reach sidebars *this* server owns — a **different** server's sidebar (the dev's real
one, when a throwaway smoke/sandbox server runs a prune) is structurally out of range,
not merely env-gated. That closes the bug where running the smoke suite SIGTERM'd the
developer's live sidebars: their tty is no pane on the isolated server, but they're
another server's children, so the ppid scope excludes them. It fails safe — a nil
server pid, or a wrong process-tree assumption, under-reaps (never over-reaps). The
`SWITCHBOARD_SANDBOX` env guard is the belt over that structural scope: inside a
throwaway server it skips the reap entirely (see the sandbox section). They accumulate
mostly from interrupted `bin/test-smoke` runs, whose daemon servers outlive the run;
the smoke harness now sweeps those before each run.

**Configurable keybindings (issue #15).** The fragment delegates binding to
`switchboard tmux-bind` (`Installer.apply_keybindings`), which reads `tmux_keys:`
from config (`Config#tmux_key` — global, resolve-with-default like `sound_for`;
`toggle` defaults to `s`, `home` is unbound). Cleanup tracks the key it bound last
in tmux options (`@switchboard-toggle-key` / `@switchboard-home-key`) and unbinds
exactly that — never a scan of `list-keys`, so it can't clobber a user's own
`switchboard` binding and survives a repo move (tmux key bindings and `@options`
share a lifetime: both die on server restart). It binds before it unbinds, so a
key tmux rejects falls back to the default without stranding the recovery key, and
records a displaced foreign binding in `@switchboard-*-clobbered` for `doctor` to
warn about. The decision is the pure `Installer.rebind_ops` (unit-tested via the
`run_tmux` seam); validation is a **minimal denylist** (`Config#valid_tmux_key?`) —
tmux is the authority on real keys. Editing `tmux_keys` via `e`/`switchboard config`
re-applies immediately (`reload_config_poke` / `edit_config` call `apply_keybindings`,
`announce: true` flashing the result); a from-scratch `install` still needs a tmux
reload. A malformed config no longer crashes anything — `Config#initialize` rescues
the parse error to `{}` + `load_error` (the sidebar keeps its last-good config; the
`tmux-bind` path falls back to defaults; `doctor` reports it).

Ruby **>= 3.0** is required (`Config` uses `YAML.safe_load_file`, added in Psych
3.3 / Ruby 3.0). `bin/switchboard` re-execs itself under a modern ruby if launched
on macOS system Ruby 2.6 — relevant because tmux panes run a non-interactive shell
that skips rbenv.

**Baked paths must survive `brew upgrade`** (issue #9). The install path gets
written into long-lived wiring — the tmux.conf marker line, the tmux hooks/bindings,
per-worktree Claude hooks, the global codex block. A clone's realpath is stable; a
Homebrew keg's (`<prefix>/Cellar/switchboard/<ver>/…`) is deleted by upgrade+cleanup,
and a changed path also re-hashes the codex commands, voiding their `/hooks` trust.
So both sources of that path — `SWITCHBOARD_BIN` (`bin/switchboard`) and
`Installer.repo_root` — run through `StablePath.resolve` (`stable_path.rb`), which
rewrites a switchboard keg path to its `opt/switchboard` twin (fails safe to the
realpath when no opt link exists). Under brew (`Installer.homebrew?`) install/uninstall
skip the `~/.local/bin` symlinks and `doctor` checks the brew PATH entry instead.

**Releases are automated after merge** (`.github/workflows/release.yml`; issue #9 —
#8, assigning the version after merge, is still open). The PR still picks the version (`version.rb` + CHANGELOG entry, `vX.Y.Z` title);
once `test` AND `formula` (macOS: formula installed from a local tap, `brew audit
--strict` + `brew test`) are green on main, a `workflow_run` job tags it, creates the
GitHub Release from the CHANGELOG entry, and pushes the formula to
`wvmitchell/homebrew-switchboard`. Every run judges main's CURRENT tip (GitHub keeps one
pending run per group, and gates finish out of order), never moves the tap backwards,
trusts an existing tag only if its exact ref's commit passed the gates and carries the version, pins that commit so later steps fail if the tag moves, renders the formula from it, and fails loudly on any lookup error (a
missing `actions: read` once made every run a silent no-op). All decisions live in the
pure, table-tested `Release.plan` (`packaging/release.rb`); the YAML only gathers facts.
The tap step skips while the repo is private or `HOMEBREW_TAP_TOKEN` is unset. Full
detail: `docs/reference-release.md`, `docs/howto-release.md`.

Useful env overrides when running locally without disturbing real state:
`SWITCHBOARD_CONFIG` (config path), `SWITCHBOARD_STATE_DIR` (agent-state files),
`SWITCHBOARD_ATTENTION_DIR` (bold "needs attention" markers),
`SWITCHBOARD_RELEASES_URL` (where `LatestRelease` reads release tags — the suite points
it at a dead path so nothing reaches GitHub),
`XDG_DATA_HOME`/`XDG_STATE_HOME` (reporter script + state dirs), `CODEX_HOME` (the
global codex `config.toml` the codex hooks block is written into — sandboxed in tests).

## Architecture

**Git is the source of truth at runtime; the config is just a project registry.**
Worktrees are discovered live via `git worktree list`; the config
(`~/.config/switchboard/config.yml`) only lists which repos to scan. emdash and
Conductor are peer tools whose worktrees still show up (git finds them), but
there's **no database coupling** — `install`/`init` write an empty config and
the add-project flow grows it (the old emdash SQLite seed import was removed in
issue #3). PR badges come from `gh`, cached on disk (`~/.cache/switchboard/prs`)
so the UI never blocks on the network. The cache is **sticky** (`Pr.refresh`
merges each fetch ONTO the previous map, never replaces): gh's queries are
windows — the 200 most recently *updated* PRs (`--search sort:updated-desc`,
falling back to the plain creation-ordered list if the search API fails) plus
every open PR up to `OPEN_LIMIT` — so a long-quiet merged PR falls out of both,
but its badge must outlive that for as long as its row renders (you remove a
workspace or branch, never a badge). Rendered branches the windows never saw get
a capped per-branch `--head` backfill (`rendered_branches` = each non-primary
worktree's reflog lineage; no-PR branches are negative-cached as null so they're
asked once); a cached OPEN badge absent from a *non-full* open query is provably
stale and re-queried; a `//repo` identity marker keeps a project name reused for
a different repo from inheriting the old badges; and the write rides
`MarkerBlock.atomic_write` because concurrent sidebar refreshers share the file.

The **add-project flow** (`Registrar`, `registrar.rb`; sidebar `a`, CLI
`add`/`clone`/`create`) has **three modes** that all funnel through one
`Config.add_project` write so the CLI and sidebar never drift: **register** a repo
already on disk, **clone** one from a URL under `projects_root`, or **create** a
brand-new empty one there. The subtle one is create (`Git.init`): a bare `git init`
leaves an **unborn HEAD**, and `Creator`'s `git worktree add … <base>` (what `n`
runs) fails `invalid reference` against it — so `Git.init` makes an **empty initial
commit** to birth the repo, immediately worktree-able. No `-b`: it honors the user's
`init.defaultBranch` and `register` derives the base from `current_branch`.
`--no-gpg-sign`/`--no-verify` keep a global signing key or pre-commit hook from
failing the synthetic commit, and it removes `dest` on any failure so a same-name
retry isn't blocked by a half-made repo. The name is free user input, so
`Registrar.create` rejects anything not sanitize-stable (`\A[\w.-]+\z`, no leading
dot) — keeping the source dir, the project name, and Creator's worktree segment
identical (no `my repo` vs `my-repo` divergence).

**One data model, one front-end.** `Model` (`model.rb`) assembles the
`project → worktree` tree from `Config` + `Git` + cached `Pr` data. `Tree.nodes`
(`tree.rb`) turns that into ordered `Node` structs, which the **persistent
sidebar** (`sidebar.rb` — the run-loop core; #57 split the rest into `sidebar/`
concern files: `edges.rb`, a collaborator class owning the agent-edge fanout
state, plus the `render`/`input`/`actions`/`prompt`/`rows` concern mixins — one
class in several files, each with its own `test/sidebar_*_test.rb` over the
shared `test/support/sidebar_case.rb`) draws as a hand-rolled ANSI TUI in a narrow tmux pane
(no fzf). It's the only navigator. The bound tmux key toggles it; bare
`bin/switchboard` is context-aware (`CLI#start`) — inside tmux it toggles the
sidebar like the key, from a plain shell it bootstraps and attaches the home
session (`Tmux.go_home`), so launching switchboard is a single command.
`view.rb` is now reduced to the
compact PR-badge helpers the sidebar uses (`pr_identifier` / `pr_tag`: state via
color, just the `#number` to fit the ~40-col pane).

> Until recently there was a second front-end — an `fzf` popup picker
> (`picker.rb`, `Tree.lines`, the `view.rb` preview functions, and `_`-prefixed
> fzf-callback subcommands in `cli.rb`). It was removed so the sidebar is the
> single source of truth; if you see references to it in old commits or issues,
> that's why it's gone.

The sidebar expands a workspace that has multiple branches in its HEAD-reflog
history into inline child rows (`Git.branch_history`) — the
multiple-PRs-per-workspace case. The canonical trunk checkout (`primary`) is
always filtered out as a switch target.

**The binary re-invokes itself to spawn the sidebar.** `bin/switchboard` exports
its own absolute path as `SWITCHBOARD_BIN`; `tmux.rb` uses it to `split-window`
a pane running `switchboard sidebar` beside each session. `cli.rb` dispatches the
user-facing commands plus the tmux-internal `toggle-sidebar` / `poke-sidebar`.

**tmux mapping** (`tmux.rb`): each worktree ⇆ one session named
`sb/<project>/<leaf>`. Switching creates the session on demand and attaches a
fixed-width sidebar pane. The sidebar reloads on session-change via a tmux hook
that "pokes" it with `C-l` (`poke-sidebar`). On the *creation* of a session
(only — never a re-switch), `Tmux.ensure_session` types its `start` line into the
window. For a re-switch into a workspace whose session died, that's the project's
resolved `session_command` (`Config#session_command_for`, global default +
per-project override) — the "how the agent starts" knob, e.g. `claude
--dangerously-skip-permissions`; for a NEW workspace it's the dispatch launcher (see
Background dispatch below). Empty ⇒ a plain shell. `ensure_session` returns whether
THIS call created the session (false if it existed or new-session failed).

**A NEW worktree also gets a setup script** (`worktree_creation_command`, #83) —
the `.env` / `bundle install` a fresh checkout never inherits. It runs once per
*worktree*, in the dispatch launcher (`Creator.run_setup`), never again on re-entry:
`switch` starts the bare `session_command`. The script goes to **`sh -ec` as ONE
argument** (`system(env, "sh", "-ec", script)`, no shell string at all), so a
multi-line script, a trailing `# comment` and an apostrophe all survive verbatim and
`-e` stops at the first failing step. Only **Strings** count as an agent command —
`session_command: false` (the config's disable idiom; YAML hands us the boolean,
`Config#session_command` passes it through) means no agent, never the word `false`.
`Config#worktree_creation_command_for` is **three-state** (absent ⇒ inherit,
value ⇒ override, `false`/empty/valueless ⇒ OFF), which is why it reads the raw project
node like `auto_rename_for` instead of riding the `projects` map OR the `project_key`
helper: both collapse "no key" into "key set to nil", so an opted-out project would
silently inherit the global. `setup_script` rejects a mixed list wholesale (a partial
setup is worse than none), and the launcher then FAILS that build (`config`,
`Config#setup_invalid?`) instead of starting the agent with no setup — a list step YAML
read as a map (an unquoted `: `) is the usual way to get one.

**The script gets `$SWITCHBOARD_PROJECT_PATH` + `$SWITCHBOARD_WORKTREE_PATH`**
(and `$SWITCHBOARD_TASK`, the dispatched task — the launcher sets it in its own ENV,
so setup and agent both inherit it). The paths are not a convenience: a worktree lives at `<worktree_root>/<project>/<leaf>` while the project's
checkout lives at its registered `path`, so there is **no relative path** between them
— without the export, the feature's whole headline use case (`cp` the untracked `.env`
your new worktree didn't inherit) is *inexpressible*, and a plausible-looking
`cp ../../main/.env .` fails, which (setup is fail-closed) blocks the agent on every
create. A setup script must NOT copy `.claude/settings.local.json` wholesale — the
worker writes switchboard's hooks there *before* setup runs, so a broad `cp -R .claude .`
silently kills that worktree's agent dot.

The runtime contract — setup really runs in the new worktree, before the agent, a
failure really blocks it, and the exported path really reaches the script — is pinned by
`test/smoke/worktree_creation_command_smoke_test.rb` and `dispatch_smoke_test.rb`
(stubs prove only the call). The fixtures are **mutation-checked**: the failure case
fails on a real command (not `exit 1`, which aborts with or without `-e`, pinning
nothing), and the happy case carries a *quoted* trailing `#` comment (unquoted, YAML eats
it). Because setup runs in Ruby and the agent only starts on success, fail-closed now
holds for ANY `session_command`, compound `export X=1; claude` included (the old typed
`&&` chain leaked there).

### Background dispatch (`n` → task → ↵)

Creating a workspace never blocks and never moves you. `n` asks for a TASK (never a
name — deferred naming below still holds), and `Sidebar#create` only reserves a
placeholder and writes the **`Creation`** record (`creation.rb`) that claims it as ONE
step (`Creator.dispatch`, under `Creation.with_project_lock` — a per-project flock the
worker's collision retry takes too, so two panes can never hand out one name and have
the launcher claim the other's task; `Creator.reserve` skips dirs, branches, dangling
rename bridges AND in-flight records), then spawns `switchboard create-workspace <id>` —
nothing on the input loop builds anything or touches the network (reserve's local
branch/session lookups are its only shell-outs). The
**worker** (`Creator.work`, daemonized via `CLI#create_workspace` like the reaper) does
the best-effort fetch, `git worktree add --no-track` (retrying a collision with a fresh
placeholder, relabeling the record), `enable_hooks`, then a DETACHED session whose one
typed line is `<abs bin> launch <dest>`. The **launcher** (`Creator.launch`) claims the
record, runs setup, then runs the agent as its CHILD via the pane's own shell `-i -c`
(the launcher's parent process, so rc aliases resolve as when the command was typed) and
writes `ready` only after a 5s grace — an agent that dies sooner is a ✘, not a false
"ready" (a clean exit 0 inside the grace is a hand-off, so `ready`). The task travels in
`$SWITCHBOARD_TASK`, never interpolated: auto-appended only when the command is PLAIN
WORDS (`appendable?` is an allowlist — a trailing newline from a YAML block scalar, a
`# comment`, `&` or quoting would otherwise run the task as its own command or swallow
it) starting with `claude`/`codex` (aider's positional args are FILES); else `{task}`
opts in, substituted quote-aware (`substitute_task`: bare, in `"…"`, in `'…'` — always
one argument to the pane shell's command; a command that hands it to ANOTHER shell —
`bash -lc '…'`, `ssh` — must use `"$SWITCHBOARD_TASK"` itself, or that shell parses the
task as code); else the pane says "task not sent" (or, with no agent at all, that no
session_command is set). Re-entry resolves a `{task}` template to the bare command,
dropping a now-empty `'…'`. The task PROMPT keeps non-ASCII (raw bytes, decoded UTF-8) and
turns on bracketed paste, so a paste spread over many reads stays text — it can't
submit on its first newline or reach `dispatch` as keys; a marker split across two reads
is held back for the next one (else paste mode never ends and swallows ↵/Esc), and input
left in flight after the submit is drained. Every lookup by path (`for_path`, `repath`)
takes the NEWEST record: a finished one can outlive its tree on a reused path.

`Creation` is the one multi-process thing here that's MUTATED by several writers
(sidebar, worker, launcher, Stop hook, GC), so every write is `Creation.mutate`: an
exclusive flock on a SEPARATE `<id>.lock` (locking the data file would lock the inode the
atomic rename replaces), read, change, temp+rename; reads stay lock-free. `transition` is
from-gated (a racing writer that already advanced wins; a no-op tells the worker to
stop). `acked` is a sticky flag, not a state — viewing the workspace (`locate`) means no
ping ever fires for it. The record's OWNER (pid + start time, `ProcessIdentity`, shared
with `IsolatedServer`) passes worker → launcher at the claim, so GC can tell a 15s setup
from a dead build without a TTL; the worker waits ≤60s for the claim (slow shell rc). The
worker creates the session UNDER the record lock, and `quit` / remove-project
`cancel_all` before killing sessions, so a teardown can't leave an agent starting after it.

Pings are durable, not edge-driven: a fresh workspace's first `:done` is a first
appearance `completion_edges` deliberately ignores, and sampling can miss a fast turn.
A ringing transition (ready for a bare or hook-less create, which plays your `done` sound; `turn_done` for a hooked
claude task — stamped by `CLI#rename_nudge_stop` on its NON-blocking path only — and any
failure, which plays its own soft falling `failed` built-in, NOT the notify `alert`) bumps `ring_gen` and bolds via Attention right there. Only an announcing,
ON-SCREEN scan rings (`Sidebar#ring_creations`), and only if it wins `claim_ring`'s
compare-and-set on `rung_gen` — so exactly one pane rings, a silent reload (C-w warm
poke, switch-in) can't consume the ping, and a respawn can't replay it. While a record
owns its first turn, `Edges#suppress_completion?` drops the normal `:done` edge for that
row so you hear one chime. Render: synthetic rows (no worktree yet) are spliced into
`@nodes` LAST in their project; `◌` (yellow, steady — no pulse) for queued/building/
launching, `✘` (bold red) for failed, which outranks the agent dot; the dim task label
sits in the right region while the leaf is still a placeholder and there are no diff/PR
cells, a failure shows its ≤14-col reason (`Creation::REASONS`).

**Cancel and failure never leave an agent on an un-set-up tree — or destroy work.**
The agent starts ONLY through `Creation.authorize_launch`: one locked step, gated on the
record still being `launching`, that stamps `setup_ok` + `agent_started` — so a cancel
during setup, a record GC dropped meanwhile, or a failure all mean no agent (never "no
record, nothing said stop"). A config the launcher can't read fails the build (`config`)
rather than certify a setup it couldn't run. A failed OR canceled record WITHOUT
`setup_ok` that has a worktree (`Creation.unfinished?`) is kept until the worktree is
deleted — checked before the unconfigured-project drop — and a canceled record also
stays while its owner lives (a worker still inside `worktree add` must find it to record
a tree it keeps). `switch` (D12) starts the agent only on a `Creation.certified?`
record — no record, or `setup_ok` — so a failed, canceled, OR still-in-flight build
whose session died opens a plain shell with the reason instead. The worker never opens
a session on a dead server (the record's `server` socket gone: a `kill-server` mid-build
would otherwise start a headless server and run the agent there), and it discards a tree
canceled before the launcher claimed it. A failed `worktree add` is a collision only if
the dir or branch existed BEFORE it (git cuts the branch before checkout, and a failing
post-checkout hook leaves a full tree); anything else is undone (`undo_add`) and fails
once with git's message. Cancels come from `quit`/remove-project
(`cancel_all`, scoped to THIS tmux server via the record's `server` = `$TMUX` socket),
`d` on a `◌` row (`dismiss_dispatch`: re-reads the record, tears down only if its cancel
actually landed), and `d` on a real row mid-build (`delete` cancels before the kill).
Teardown force-removes a tree only once `Creator.untouched?` proves it clean with no
commits past its base; anything else is kept (flashed "kept …", re-entry stays a plain
shell) for `d` on its row, which asks before forcing. The worker re-checks after its
fetch; fetch and `git worktree add` run prompt-free in their own process group, bounded
(`FETCH_DEADLINE`/`ADD_DEADLINE`, then `ProcessIdentity.terminate_group`). A Stop stamps
`turn_done` only once the agent has started (`stamp_first_turn`: a setup step running
claude can't stamp the build done and hide its own failure), and `Rename.perform` refuses
(`:building`) until then (`Creation.renamable?`). `hooked` is settled at
`authorize_launch` from the command that will actually run (the worker's value is a
first guess), and an undelivered task is never hooked, so it pings at ready. A hooked
task whose agent exits before its first Stop pings on that exit (✘ non-zero, done on 0);
a bare create never stamps a second ring. First-turn ownership lapses after
`FIRST_TURN_CEILING` if the stamp never comes. Once a ✘ is acked, the agent's
thinking/waiting show over it (at rest the ✘ stays). The task label is measured in
display columns (wide chars count two) and loses invisible characters before it's drawn. GC re-decides each drop under the record
lock, never waits on a lock (the sidebar's background writers use `wait: false`), sweeps
orphan lock/temp files, drops records of unconfigured projects once they're out of
flight (non-empty list only), keeps an unfinished record while its tree is ON DISK
(`tree_on_disk?`: a `.git` there, not just `worktree_added` — a killed add or a refused
rollback leaves a tree the flag never saw; GC then records it so its deletion clears the
row), force-deletes a canceled build's branch only once the tree is proven untouched,
reads records as UTF-8 whatever the locale (a C-locale tmux would otherwise fail to parse
a task with a smart quote and lose the build), and `add_worktree` trusts git's exit
status, reading its text (any bytes) only on failure,
reads an empty start time as unknown (but past `PID_ONLY_CEILING` a pid-only owner is
dead), and skips its `ps` owner checks on an off-screen warm reload. Failure details are
stripped of control bytes before they're flashed or printed. `↵`/`d` on a pre-worktree ✘
shows / dismisses it. Design + review record: `thoughts/background-workspace-create.md`
(hardening: `thoughts/background-workspace-create-hardening.md`).

**Workspace naming is deferred** (issues #94, #114). `n` in the sidebar (and
filter-mode ↵ on a project header) never asks for a **name** (it asks for a task —
see Background dispatch). It gets a **placeholder** — a throwaway
adjective-noun leaf from `Placeholder.generate` (`placeholder.rb`, a tiny in-repo
word list, no gem) — and a matching branch, so you start work before naming it
(naming happens *after* creation — `r`, `switchboard rename`, or the agent nudge).
The worker cuts the branch with `--no-track` so a branch off `origin/main` doesn't inherit it
as an upstream (else the rename gate below would misread every fresh worktree as
"pushed"); generated names retry past a dir/branch collision. `Rename.perform` then
renames **both** the dir (bare `<name>`) and the branch (`<branch_prefix>/<name>`) —
but only when the branch is **unsynced-safe**: still the auto-created branch (its
basename still equals the old leaf) AND not pushed (`Git.pushed?` = a
remote-tracking ref exists, NOT `@{upstream}`). A pushed/diverged branch is left
intact (dir-only rename). All branch checks (`valid_branch_name?`, `branch_exists?`
⇒ the `:branch_exists` result) run BEFORE any move, and the branch is renamed first,
so a collision fails clean (nothing moved) and the agent retries with another name.

**Sidebar visibility is per-session, applied to every window** (issue #24). The
intent lives on the session as a tmux option (`@sb_sidebar` on/off; unset reads
as on, preserving auto-show). `Tmux.reconcile_sidebars` is the one primitive that
spawns-or-kills each window's sidebar to match: `prefix-s` (`Tmux.toggle_sidebar`,
switchboard's one summon/dismiss verb — visible ⇒ dismiss session-wide, hidden ⇒
summon every window AND focus the tree) flips the flag and reconciles every window;
`ensure_session` stamps `on` on first creation; `go`/`go_home` reconcile to the
saved flag on switch-in (and `go_home` always restores the navigator). New
windows are covered by the `after-new-window[99]` hook → `sidebar-sync <window>`,
which spawns one iff the session opts in. No spawn recursion: the sidebar is a
`split-window`, which fires `after-split-window`, not the hooked `after-new-window`.

**A *shown* sidebar still goes dormant while off screen.** Every window keeps its
own sidebar process, so at any moment most of them are on inactive windows. Each
caches whether it's currently on screen in `@visible` (the single flag, mutated
only via `set_visible`); `render` and the spinner/blink (`pulsing?`) are gated on
it, and `frame_timeout` drops an off-screen sidebar from the `REFRESH` cadence to
a long `IDLE` backstop. So an off-screen sidebar does essentially nothing — no
paint, no agent scan, just one cheap visibility check per `IDLE` — until a poke
wakes it: a session switch (`client-session-changed` → C-l) or a same-session
window switch (`session-window-changed` → `poke-window` → C-l). The C-l handler
`reload_and_refresh` **re-samples** `Tmux.visible?` rather than assuming the poke
means on-screen, because the same C-l is also sent by background PR-refresh
children (`maybe_refresh_prs --poke`) to a pane you may have navigated away from —
marking that hidden pane visible would re-wake it. An un-poked reappearance (a
window switch on a tmux too old for the hook, a bare `tmux attach`) is caught by
the off→on `reappeared` branch in `tick` within `IDLE`.

**Pre-warming keeps an off-screen sidebar's buffer fresh so switch-in doesn't
flash a stale tree** (`prewarm?`, default on; `prewarm: false` restores full
dormancy). Without it, switching into a session shows that pane's *last* render
(possibly minutes old) until the switch-in poke reloads — a visible flash. A tmux
pane buffers writes even while off screen (its grid persists; `render` doesn't
gate on `@visible`, the caller does), so the fix is to paint it *before* you
arrive. The off-screen branch of `tick` does a **change-gated, `WARM_TTL`-bounded,
visibility-safe** warm: when `prewarm?` AND `WARM_TTL` has elapsed (`@last_warm`)
AND a cheap `warm_fingerprint` differs from the `@warm_fp` baseline, it runs
`warm_reload` + `render`. The gates are cheapest-first, so a fully idle pane still
costs ~one `Tmux.visible?` call per `IDLE` (today's dormancy). `warm_fingerprint`
is stats only — a `dir_fingerprint` (name+mtime per file) over the agent-state,
attention, PR-cache, and **collapse** dirs, the **full-header / branch-fold /
width** marker files, the **config file** (`Config.path`) mtime, plus each tracked
worktree's `logs/HEAD` mtime — so it sees agent dots, bold, badges, commits, the
**project registry** (a project added/removed in another session), **and the
shared view-state** move without a git/process shell-out. It deliberately does NOT
cover a *worktree* added/removed in **another** session; that refreshes on the
switch-in reload as before.

**A project added/removed in another session propagates like shared view-state.**
`@config` is cached per sidebar process (git is the runtime truth; the config is
just the project registry), so a project registered elsewhere used to stay
invisible until the pane's process was respawned. `rebuild` — the one chokepoint
every reload path funnels through (switch-in poke, the ~15s tree-tick, the
off-screen warm) — now calls `refresh_config` (`sidebar/actions.rb`): an
**mtime-gated** re-read that costs one `stat` when the file is unchanged and a
`Config.new` only when it actually changed (keeping the last-good `@config` on a
parse error, like `reload_config`, which shares the same `@config_mtime` baseline).
So the frequent `C-l` reload stays as cheap as when it never re-read config, yet a
changed registry lands on the next reload. The config-mutating verbs
(`add_local`/`add_clone`/`add_create`/`remove_project`, and the `e`/CLI `reload-config` path)
also `Tmux.broadcast_warm` so every *other* sidebar re-reads immediately, and the
config mtime rides `warm_fingerprint` as the lazy backstop — the same
broadcast-plus-fingerprint shape as the shared view-state. Because peers now read
the config concurrently with a writer, `Config.add_project`/`remove_project`/
`scaffold` write **atomically** (`MarkerBlock.atomic_write`, temp+rename, symlink-
and mode-aware) — the same invariant the marker stores / `HookFile` / `MarkerBlock`
already hold: a plain `File.write`'s `O_TRUNC` window would let a peer read the
empty file, which is *valid YAML* (`load_error` wouldn't catch it), and adopt a
zero-project config that blanks its whole tree.

**Shared view-state propagates instantly via a broadcast, not just the lazy
fingerprint.** A collapse/branch-fold/full-header toggle in one sidebar is a user
action that writes a shared on-disk store; the toggling sidebar then
`Tmux.broadcast_warm`s a `C-w` "repaint now" poke (`WARM_POKE_BYTE`) to every
*other* sidebar pane (`all_sidebar_panes`, except itself). Each handles it in
`warm_poke`: off screen → `warm_reload` + render (paint the new view-state into the
buffer); on screen → a silent `reload` + render. So an off-screen sidebar reflects
the fold within ~0.2s — before you can switch to it — instead of lagging until its
~`IDLE` warm tick (the bug where "collapse then switch still flashed"). The
broadcast is event-driven (fires only on the rare toggle, zero steady-state cost,
so dormancy is preserved); the view-state entries in `warm_fingerprint` are the
lazy backstop if a broadcast is missed. The earlier `prewarm` shipped WITHOUT
this — its fingerprint omitted view-state, so a collapse never warmed off-screen
panes and every switch-in repainted the fold = a flash on exactly the case folks
test with. Width is the one view-state that still defers to switch-in: changing it
*resizes* the pane (a `pin`, not just a render), so a warm repaint can't apply it
off screen — the fingerprint tracks it as a backstop but the resize lands on the
switch-in `pin`.

`warm_reload` is **not** `reload` with flags — reusing `reload` off screen caused
two real bugs (caught in review): `reload`→`locate` clears `Attention` for
`@current_path`, so an off-screen warm would erase the bold the on-screen sidebar
just set for that workspace's completion *before you saw it*; and `reload` stamps
`@last_reload`, so a warm within `POKE_TTL` of a switch would make
`reload_and_refresh` skip its PR refresh. So `warm_reload` **skips `locate`
entirely** (an off-screen pane's `@current_path` can't change while you're away)
and stamps only `@last_warm` (never `@last_reload`, so switch-in still does its
full reload + PR refresh). It also passes `refresh_prs: false` (no off-screen
PR-spawn fan-out — the edge fanout (`Edges#on_scan`) still marks + advances the baseline, only the
spawn is gated) and `hooks_only: true` to `AgentState.scan` (skip the
tmux/pgrep/lsof `Agents.active` fallback — which otherwise fires whenever *any*
worktree lacks a live hook, i.e. almost always — so an off-screen scan stays
cheap; hook-less/activity dots just defer their freshness to switch-in). Sounds
are never rung off screen (`announce_sounds: false`). Honest scope: this
*drastically reduces* the flash, it doesn't kill it — a change in the last
`~IDLE+WARM_TTL` before a switch can still be caught mid-warm. One limitation:
the warm frame is drawn at the off-screen pane's size, which is correct for a
single client at a stable size (the dominant case) but may be briefly mis-sized
under multiple clients of different sizes until the switch-in poke re-renders
(self-heals via the poke we already have, never worse than today). The hook
reporter writes atomically (temp+rename, `hook_file.rb`; the reporter script itself too, since sh
reads a running script as it goes) so the warm fingerprint
can never catch — and stamp-as-clean — a torn state file.

### Upgrading (`switchboard upgrade`, #10)

`Upgrade` (`upgrade.rb`) fetches the newest version the way switchboard was installed —
the install method IS the channel: Homebrew (`brew update` + `brew upgrade`), a `--HEAD`
keg (`brew upgrade --fetch-HEAD`), or a clone (`Upgrade.clone_pull`: refused over tracked
changes, then `git fetch` + `git merge --no-overwrite-ignore --ff-only @{upstream}`, so
git itself refuses an update that would overwrite an untracked OR ignored local file —
a plain pull silently overwrites ignored ones). A failed `brew update` is only a note,
unless nothing moved: then `update_blocked` exits 1 instead of claiming "nothing newer"
(switchboard's own tap may be the one that failed). "Up to date" is per method: the
newest release tag for brew (`LatestRelease`, `latest_release.rb`: one `git ls-remote`
bounded to 5s, with the user's global/system git config AND any repo config kept OUT —
`GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CONFIG_NOSYSTEM`, run from the tmpdir — so an
`insteadOf` can't hijack it), HEAD vs its upstream
for a clone (bounded `Git.fetch_base`, ssh in BatchMode). A stamp (keg realpath / HEAD
commit) taken before and after decides whether anything moved. Then it **execs the new
binary** with `upgrade --finish <old>` — the old process has the old code loaded — and
clears `SB_REEXEC` so a clone's new binary can still re-exec under a modern Ruby. Finish
= `Installer.refresh_wiring` (the reporter + every hooked worktree of every configured
project, primaries too, via `HookFile.refresh`) + the codex block if installed + running
the tmux fragment in the live server from any shell (`reload_fragment`, only when
tmux.conf sources THIS install). An up-to-date run still finishes leftover setup
(`leftovers?`), so re-running repairs an interrupted upgrade.

Two guards carry the design. **Only the installed binary rewrites anything shared**
(`Installer.installed_bin?`: the running `SWITCHBOARD_BIN` is the `switchboard` on PATH):
hook commands, the reporter and the codex block all call back into whichever binary wrote
them, so a dogfood checkout would otherwise repoint every worktree at a path that
vanishes. **`HookFile.refresh` only updates, never adds or clobbers**: it skips a file
without our hooks, compares order-insensitively (`same_hooks?` / `canonical`), re-reads
before the atomic write and returns `:conflict` if Claude saved the file meanwhile, and
treats an unparseable file as ours (`:corrupt`, reported with `HookFile.corrupt_reason`'s
specific cause — invalid JSON/UTF-8, a malformed hooks section, unreadable, not a regular
file under 4 MiB — as `doctor` does) only when it carries one of our
marks — an unreadable or foreign file is never touched. `install` runs the same
`refresh_wiring`, so the manual route converges too.

### Agent-state dots (the subtle part)

Hook contract last verified live against **Claude Code 2.1.301–2.1.303** and **codex-cli
0.163.0** (v0.51.1): payload fields, linked-worktree delivery, the nesting-guard env, and a
silent PermissionRequest hook leaving the prompt to the user.

The dot beside each workspace shows whether an agent (Claude/Codex/Aider) is
thinking / done / waiting. `AgentState.scan` (`agent_state.rb`) merges **two
presence signals** per worktree:

1. **Hook state (exact).** Claude Code *and Codex* report state by running a tiny
   POSIX-sh reporter that writes `<state>\t<cwd>\t<epoch>` files into the state dir. A
   fresh file (within `PRESENCE_TTL`) *is* presence — no process check needed.
   The flip side: because a fresh file is trusted without a liveness check, a
   `quit` that kills every agent leaves their last states stale (a lingering
   `:thinking` would read as a live, working agent for up to the TTL). So both
   quit paths (`Sidebar#quit`, `CLI#quit`) call `AgentState.clear_all` to wipe
   the state dir before tearing down; a restarted agent re-reports on SessionStart.
2. **Process/activity (coarse fallback).** For hook-less agents, `Agents.active`
   finds agent CLIs via tmux panes + `pgrep`/`lsof`, and busy-vs-idle is inferred
   by hashing `tmux capture-pane` between scans. This can't distinguish
   "waiting" from "done".

Hooks reach each agent through a **per-agent adapter** registry `AgentHooks`
(`agent_hooks.rb`): `ClaudeHook` (`claude_hook.rb`) and `CodexHook` (`codex_hook.rb`).
Both agents read the SAME hook-config shape, so the command STRINGS, the reporter, and
the rename-nudge/Stop wiring live once in the shared engine `HookFile` (`hook_file.rb`,
`command_entries`). What **differs is the delivery target**, and the two agents land on
opposite sides of it — the subtle, hard-won part:

- **Claude is per-worktree.** `ClaudeHook` merges into
  `<worktree>/.claude/settings.local.json` (declaring its `SETTINGS_REL` + `EVENTS`),
  on top of your settings, adding the file to the worktree's git excludes so it never
  dirties `git status`; global `~/.claude` is untouched. This is the only entry in
  `AgentHooks::ADAPTERS`, so `enable`/`disable` and the dispatch worker fan out over it.
- **Codex is global.** Codex (verified 0.142 through 0.163) deliberately does NOT load a
  *linked* git worktree's own `<worktree>/.codex/hooks.json`: it redirects a linked
  worktree's project hooks to the MAIN checkout's `.codex/` (and only when the worktree
  has a `.codex/` dir and is trusted — `config/src/loader/mod.rs`). Switchboard is nothing
  but linked worktrees, so the per-worktree file was **dead on arrival** (v0.39.0's codex
  feature never fired in practice). A CONFIG-level hook isn't project-discovered,
  so it fires everywhere. So `CodexHook` writes ONE marker-delimited `[hooks]` block into
  `~/.codex/config.toml` (`CODEX_HOME`-aware) via the shared `MarkerBlock`
  (`marker_block.rb`, extracted from the tmux.conf surgery — atomic temp+rename,
  symlink-aware, first-write `.bak`, the same `# >>> … >>>` markers). The block is
  emitted as TOML **basic** strings (double-quote, escape `\`/`"`; literal single-quote
  strings would break on an apostrophe path). It covers every worktree at once, so
  there's nothing per-worktree to wire; `AgentState` only renders tracked worktrees, so
  the block firing for non-switchboard codex sessions is inert (an **age-based GC**,
  `AgentState::STALE_GC`, reaps the resulting stray state files the dir-exists GC alone
  would keep forever).

Because the codex block lives in the user's personal global config, `Installer`
writes it **only with consent** (`step_codex_hooks`): `install` prompts (default NO on a
non-tty, so a scripted install never silently touches it), `--codex-hooks` /
`--no-codex-hooks` decide up front (`--no-codex-hooks` leaves even an installed block
untouched; a plain `install` re-ensures one). `uninstall` strips the block; the per-worktree
`disable-hooks` deliberately leaves it. `AgentHooks.enabled?` / `enabled_adapters` fold
in `CodexHook.installed?` so the global block counts as "on" for every worktree, and
`doctor` reports Claude per-worktree + the global codex block + the trust note.

Two consequences of codex being global:
- **Trust.** Codex runs no hook until `/hooks`-approved (or `--dangerously-bypass-hook-trust`).
  Codex records each approval in `config.toml` itself, as `[hooks.state."<file>:<event>:…"]`
  tables holding the command's `trusted_hash`, appended right after our `[hooks]` table —
  i.e. INSIDE our markers. So `install_global` carries those tables into the rewritten
  block, and trust survives a re-install (run after every upgrade) AS LONG AS the commands
  stay byte-stable (deterministic paths + fixed event order; why `command_entries` is
  centralized). A command that DID change (another checkout's bin path) keeps its old approval
  (codex re-asks in `/hooks`; it's valid again once the command changes back, and an `enabled = false`
  stays put), so doctor's count credits presence, not a matching hash (dec-455f3bf8); `remove_global` drops OUR approvals with the block (approvals for other hook
  files stay — see below). A present block isn't proof the
  dot moves: `doctor` counts approvals (`CodexHook.trust_status` → `N/M trusted`, keys
  matched to our file by realpath, `enabled = false` not counted) and warns below M — unless
  EVERY codex-launching `session_command` (global + per-project) passes
  `--dangerously-bypass-hook-trust`, where 0/M is expected (one bypassing project can't hide it).
  The count only means something for a block install would leave as-is, so doctor first checks
  `CodexHook.block_state` (read-only, running install's own `planned_install`, so the two can't
  disagree): a `:stale` block (an older release, or another checkout's
  bin path) or an `:unsafe` one (install would refuse) gets "re-run `switchboard install`" instead
  — approving it in `/hooks` would bless the wrong commands (counts are by position, not
  command) — and a user's own `[hooks]` outside the block reads `:collision` and gets "merge
  yours into one place" (an `:unsafe` block outranks it: install's own check order). The
  real-Codex smoke can't see this (it passes `--dangerously-bypass-hook-trust`), so its
  second case runs WITHOUT the bypass and asserts an untrusted block writes no state.
  `MarkerBlock` accepts trailing text on a marker line (older releases wrote `# >>> … >>>
  (managed by …)`), and `remove_global` returns whether it changed anything, so uninstall
  never reports a removal that didn't happen.
- **Codex writes its OWN tables into our block.** Codex edits `config.toml` with toml_edit,
  which renders every NEW top-level table after the document's last table but BEFORE its
  trailing comments — and our block sits at EOF with a comment for an end marker. So
  `[desktop]`, `[marketplaces.*]`, `[plugins."…"]` land inside our markers (v0.50.1 and
  earlier silently dropped them on install and deleted them on uninstall). `install_global`
  / `remove_global` now split the region (`movable_parts`): ours (note + any `hooks` table,
  regenerated), trust (carried), foreign (moved verbatim, in order, to just ABOVE the block,
  which stays last where `MarkerBlock.build` appends it). With no foreign tables the output
  is byte-identical to before (trust hashes stay valid). There's no TOML parser (zero gems),
  so a line-based move refuses (`:unsafe`, file untouched) whenever it could change meaning
  or drop data: a multi-line string, a `[[…]]` array-of-tables, key lines before the
  region's first table / right after the end marker (a comment doesn't end a table, so they
  belong to a neighboring table), anything in OUR `[hooks]` chunk besides one-line
  `<Event> = [...]` arrays (a key codex or the user added there would be regenerated away),
  a `[hooks.<x>]` table, or a second marker region. Only a whole TOML header line
  (`HEADER`) at bracket depth 0 (`scan_lines`, strings/comments ignored) opens a table, so a
  multi-line array's `[1, 2]` / `["hooks"]` elements never split a chunk or read as a hooks
  table; the collision guard fails closed both ways (an unindented `[hooks…]` line collides
  even inside an open bracket, and brackets left open at EOF count as a collision), and
  `hooks` is matched bare, "double"- or 'single'-quoted (`HOOKS_KEY`). A line-conservation
  check is the belt over the splitter (it discounts one copy per generated line, so a pasted
  note line outside still counts as kept), and stray marker lines are counted and refused
  outright. The file is always read as UTF-8 with a leading BOM dropped (`read_config`): under
  `LC_ALL=C` a default read is US-ASCII and every check on it misfires, and a BOM defeats the
  `\A\s*` anchors (a user's line-1 `[hooks]` would slip past the collision guard). For a block
  missing its end line the `:unsafe` advice says to put the end marker back — never delete our
  `# >>>` line, which would orphan our `[hooks]`. Codex files approvals for OTHER hook files (a project
  `.codex/hooks.json`, plugins) under the same `[hooks.state]`, so uninstall keeps those
  (moved out with the foreign tables) and drops only ours; a `[hooks.state…]` table outside
  the block is codex's, not a competing hooks config (`[[hooks.state]]` still collides). Codex can
  also write the file at any moment (the desktop app does), so both verbs re-read before
  writing and return `:conflict` rather than ever restoring a snapshot over a newer write —
  which replaced the old `:corrupt` torn-write rollback (temp+rename can't tear, so a
  read-back mismatch means someone else wrote). Not a lock: a write in the last instant
  before our rename can't be seen. `Installer` reports `:unsafe`/`:conflict` as failures and
  never advises deleting the block by hand (that would take codex's tables with it) — the
  block's own note says so too. Dropping one of our approvals keeps the comments trailing it
  outside the block (they head the next table); comments INSIDE the managed block are regenerated
  away (dec-3417a712). A refusal also fails the command (exit 1: `install` after
  its other steps, `uninstall` before any, `enable-hooks`). `uninstall` runs the codex step FIRST and stops on a refusal,
  so its "re-run uninstall" advice can't point at a command it already unlinked. A begin
  marker without its end line is refused as `:unsafe` (checked before the collision guard,
  which would otherwise misread our own `[hooks]` as foreign).
- **Nesting (#130).** A global hook fires for EVERY codex, including a nested `codex exec`
  (a `/codex` under Claude). A `GUARD` (`[ -n "$CLAUDECODE" ] || [ -n
  "$CLAUDE_CODE_SESSION_ID" ] && exit 0`, equal-precedence left-assoc sh) prefixes every
  command and suppresses the reporter when a Claude-Code parent is detected; a top-level
  codex switchboard launches into a plain tmux shell carries neither marker, so it fires.
  Since Codex 0.149 (#39314) a hook's env is a snapshot taken at session start (minus a
  few credential vars), not the live env — the two Claude markers aren't stripped, so the
  guard still sees them (verified live: both are set in Claude 2.1.301's hook env).

Both agents report `waiting` on `PermissionRequest`, the moment the prompt opens (a silent
hook leaves the answer to the user). Claude also keeps `Notification` (`notify`) for
elicitation / `agent_needs_input` / idle; its accepted cost is a dot that stays magenta
until an approved tool finishes (or, after an Esc rejection, until the next prompt). Codex
has no `Notification` event, so `PermissionRequest` is its only `waiting` (best-effort —
suppressed by a session command that bypasses *all* approval gates). New worktrees get the Claude hook automatically
(`Creator.work` → `enable_hooks` → `AgentHooks.enable`, gated on `agent_state_hooks?` **or**
`auto_rename_for(project)` — so a project opting into `auto_rename` with the global off
still gets the hook the runtime nudge needs); existing ones via `switchboard
enable-hooks`. Codex needs no per-worktree step. The runtime contract — the global block
fires in a LINKED worktree (the bug-fix crux), the `PreToolUse`→`PostToolUse` ordering,
the nesting guard's direction — is verified against real Codex by the opt-in
`test/smoke/codex_hook_smoke_test.rb` (`SWITCHBOARD_CODEX_SMOKE=1`); the guard's sh
precedence is pinned offline by `codex_hook_test`'s runtime guard test.

### Agent self-naming nudge (issue #92)

`HookFile.enable` also wires the nudge into the agent-state hooks, re-invoking the binary (so
the commands carry `NUDGE_MARK` and `HookFile.ours?` recognizes them for idempotent merge /
clean disable) and `command -v`-guarding the baked bin path so a stale path after a repo
move degrades cleanly instead of erroring "command not found":

- a **`SessionStart` command** (`rename-nudge`) — the **soft plant**, riding *beside* the
  sh state reporter (`… && … rename-nudge || true`): when `auto_rename` is on
  (`Config#auto_rename?` / `auto_rename_for`, global + per-project, default on since #114
  made placeholders the only create path),
  `CLI#rename_nudge` injects a `SessionStart` `additionalContext` instruction telling the
  agent to `switchboard rename` the workspace once it understands the work — which
  (post-#94) names the dir and its branch. `RenameNudge.decide` is the pure gate (fires on
  `source ∈ {startup,resume,fork,clear,compact}` when on + placeholder — `clear` because /clear
  wipes the earlier plant from context, like compaction).
- the **`Stop` command** — the **backstop**, and (deliberately) the Stop **state reporter
  itself**. A SessionStart plant fires *before* the agent knows anything and then never
  again, so the moment of maximum understanding (work done, about to walk away) has no
  reminder — exactly how a real session here shipped a fix and left the workspace on its
  placeholder. The Stop hook catches that moment. But Stop is kept **off the `EVENTS`
  reporter list** on purpose: Stop hooks run in **parallel with no ordering**, so a plain
  sh `done` reporter racing the block could record a blocked (still-working) agent as
  `done` and ring a **false completion** (chime + attention-bold). So ONE command owns the
  event — `if command -v switchboard; then switchboard rename-nudge --stop; else
  <sh-reporter> done; fi` — and `CLI#rename_nudge_stop` reports the state ITSELF:
  `thinking` when it blocks (accurate — the agent is about to keep going), `done` otherwise
  (the normal completion), via the same sh reporter (`report_stop_state` →
  `HookFile.script_path`; the child inherits the hook's cwd so its cksum key matches the file
  the other events write). State is reported for **every** hooked worktree (even
  non-placeholder / `auto_rename`-off — the dot depends on it); only the block is gated.
  The `else` fallback keeps `done` flowing if the binary is stale (the script path doesn't
  need PATH); `if/then/else` not `&& ||` so a Ruby-side non-zero can't *also* fire the
  fallback (double-write). The block payload is `RenameNudge.stop_json` (`decision: block`
  + an imperative reason); `RenameNudge.decide_stop` gates it on an explicit
  `stop_hook_active == false` — Claude's own loop guard — so it blocks **once per
  stop-chain** (nudge, don't nag): the agent renames (then it never fires again) or, if it
  genuinely can't yet, the second stop passes through. The `== false` is fail-closed: a
  missing/garbled flag does NOT block, since a block on an absent flag would never see a
  `true` to release it and could trap the agent unable to stop.

Both self-clear the instant the workspace is renamed — "still unnamed" is **derived, not
stored**: `Placeholder.generated?(leaf)` (the leaf is a generated `adjective-noun`) is the
signal, no marker file. The subcommand resolves the worktree from the hook's stdin `cwd`
(via `current_worktree`), and **always exits 0 with only the JSON or nothing on stdout**
(a stray byte poisons Claude even at exit 0; the whole body is rescued to silence).

### Completion sounds (the audible twin)

`Sound` (`sound.rb`) plays a short sound when a worktree's hook state newly
enters a resting state — the same `Sidebar::Edges.completion_edges` the PR
refresh rides. Both consumers live in `Sidebar::Edges#on_scan` (`sidebar/edges.rb`,
the #57 collaborator that owns the edge state): it computes the edges once, runs
the PR refresh **first**, then `play_sounds_for` (fully rescued), and advances
`@prev_hook_states` in an `ensure` — so a sound fault can never starve the PR
trigger, blank the dots (the broad `refresh_agents` rescue), or corrupt the next
edge diff; the returned edge list is what `refresh_agents` rides for the diff
refresh. Hook-only states, like the PR trigger, so observation-only
agents make no sound. Deduped per `[worktree, state]`: every distinct worktree's
completion is heard, but one worktree can't double-fire in a scan. Since v0.51.1 a Claude
permission prompt enters `waiting` the instant it opens (`PermissionRequest`, not the ~6s
`permission_prompt` Notification), so `waiting` rings once per prompt still open at the next
scan — the workspace you're viewing included, like every other sound. Deliberate: an open prompt is what the
chime exists to surface; a viewed-workspace mute would be a separate sound rule.

Each window's sidebar is its own process with its own `@prev_hook_states`, frozen
while off-screen — so a naive scan on switch-in would re-ring every completion
that finished while that sidebar slept (already heard from the sidebar on screen
then), spraying duplicates as you move between sessions. Catch-up scans (the
switch poke `reload_and_refresh`, and the off→on `reappeared` branch in `tick`)
therefore reload with `announce_sounds: false`: they re-baseline and still
refresh PRs, but ring nothing. Only continuous while-visible scans announce — so a
completion is heard once, from wherever you're watching when it lands.

That "one visible sidebar at a time" guarantee assumes a dead sidebar process
actually exits — and one almost didn't. A sidebar whose pane closed used to keep
looping: `read_key` swallowed the stdin `EOFError`, and nothing checked that the
pane still existed. Because tmux **recycles `%pane-id`s**, the orphan's frozen
`ENV["TMUX_PANE"]` would later name a *different, live* pane; when that pane was
on the attached/active window the orphan's `Tmux.visible?` read true, so it ran
announcing scans and rang completions **in parallel with the real owner** —
duplicate (sometimes triple) sounds, intermittent because it depended on which
recycled id currently mapped to the visible pane. Two guards close it:
`read_key` now returns `:eof` (the run loop exits on it) for the clean
pane-close, and `owns_pane?` compares the pane's current `#{pane_tty}`
(`Tmux.pane_tty`) against the pty captured at startup — tmux keeps a pane's pty
stable for its whole life but recycles ids, so a **confirmed** different tty
means our id was handed to another pane, and `tick` returns false to exit. A
`nil` reply is deliberately *not* treated as disownership: it can't be told
apart from a transient `display-message` failure, and self-terminating a healthy
sidebar on a flaky shell-out is worse than the leak it would prevent — every
other tmux call here degrades rather than acts on a transient miss. A genuinely
dead pane reads `visible?`=false (silent, never rings) and is reaped the instant
its id is recycled onto a live pane — exactly when it could otherwise turn
harmful. So the recycled-id orphan, the one that rings duplicates, stops within
one `IDLE` tick before it can ring.

The two defaults are **synthesized** (16-bit PCM WAV via `Array#pack`) and
materialized into the XDG data dir on first use (atomic temp+rename, so racing
sidebar processes never read a half-written file) — same self-healing trick as
`HookFile.ensure_script`, no shipped binary assets. Config resolves a state to a
built-in name (`train`/`chime`, plus the variants `train_1..3` / `chime_1..3`), a
file path, or a bare macOS system-sound name,
via `Config#sound_for` (global default + per-project override, like
`session_command_for`; mute only via `enabled: false`). Bump
`Sound::ASSET_VERSION` to regenerate the cached WAVs.

### Bold until viewed (the visual twin)

`Attention` (`attention.rb`) bolds a workspace's name in the sidebar from the
moment its hooked agent finishes a turn (`:done`) or asks for input
(`:waiting`) until you actually look at it — so a completion you weren't
watching can't slip past unnoticed. It rides the **same `completion_edges`** as
the sound/PR triggers (the third consumer in `Sidebar::Edges#on_scan`), but with
two deliberate differences from the sound: (1) it is **persistent on-disk
state**, one marker file per worktree in a `switchboard/attention` sibling of the
agent-state dir — because every window's sidebar is its own process, only a
shared file renders bold consistently across all of them (same reasoning as the
hook-file dots); and (2) it is **not gated by `announce_sounds`** — which process
writes the marker doesn't matter (idempotent create/delete, GC'd like the hook
files), so catch-up scans mark too. The workspace you're *currently in* is never
marked (`viewing?` skips it on the edge, and `locate` clears the marker the
instant you switch in — bold gone on view, no input required). To keep that
clearing correct, `reload` runs `locate` **before** `refresh_agents`.

The atomic temp+rename write, the crc32 filename key, the XDG `state_dir`, and the
`scan`-with-GC are not Attention's own machinery: they're the shared
**`KeyedMarkerStore`** (`keyed_marker_store.rb`, issue #95) that both `Attention` and
`Collapse` delegate to. Each caller supplies only its *domain* — Attention a
canonicalized-realpath value and a `Dir.exist?` GC predicate, Collapse a project name
and a config-membership predicate — as a `scan(dir) { |content| keep? }` block (a falsy
return GCs that marker; `dir` is total so a state-path failure degrades, never crashes).
`FullHeader`/`Width` deliberately stay **off** this base — single flag / single int,
they'd only share "an XDG dir."

### Background-agent presence (the ∞ dot — declared, not detected)

A workspace where an agent is running a **background monitor / recurring loop /
scheduled tick** (a `/loop`, a self-paced wakeup, the Monitor tool, a background bash)
looked identical to a finished-and-idle one — both a resting `●`. The dot couldn't
tell them apart because **hooks can't**: a background loop fires the same
`SessionStart`/`Stop` events as an interactive turn, and there is no
`source: routine` / `is_autonomous` signal (cloud routines never touch the local
reporter at all). So presence here is **declared, not detected**: `switchboard
monitoring on|off` (agent- or human-invoked; `Monitoring`, `monitoring.rb`) writes a
per-worktree marker on the shared `KeyedMarkerStore` — a twin of `Attention`, keyed by
realpath, `Dir.exist?` GC — and the sidebar draws a **steady green ∞** for that
workspace at rest. The dot is a render overlay, not a fourth `@agents` value: a single
`render_state` resolver (used by BOTH paint paths, so precedence can't drift) yields
`thinking`/`waiting > monitoring > done/idle` — you still see live work and input
requests; only the *resting* dot becomes ∞ (idle-between-ticks reads as *watching*, not
*finished*). Steady, deliberately: an animated ∞ would keep `pulsing?` true for every
monitored pane and defeat the off-screen dormancy budget.

**"The dot is up" must mean "monitoring is happening right now."** The trap: a marker
only proves an agent *declared* monitoring, and a liveness gate can only prove an agent
is *alive* — neither proves it's *still* monitoring. So liveness is **marker-mtime +
per-cycle re-affirmation**, NOT a hook heartbeat: `monitoring on` (re)writes the marker
(fresh mtime), the agent re-runs it each cycle, and `Monitoring.monitored` shows a
worktree only while `now - mtime <= TTL` (`Monitoring::TTL`, ~10 min) — GC'ing the stale
file. Re-affirmation is the *precise* still-monitoring signal a generic heartbeat can't
produce: a stopped/crashed/resumed-into-other-work agent stops re-affirming, so its dot
ages out on its own (a heartbeat would keep it falsely lit from unrelated activity).
This is why Option A beat the heartbeat — see `thoughts/` and the three
thought-experiment tests (resume, user-stops, agent-stops).

The **routine `:done` per tick is suppressed** from the completion sound AND the
attention-bold (`suppress_completion?`, the one predicate both `play_sounds_for` and
`mark_attention_for` consult) — a background loop must not chime/bold every tick — but
`:waiting` still surfaces (it wants input) and the PR/diff refresh still rides every
edge. `@monitoring` is hydrated (in `refresh_agents`, before `Edges#on_scan`) so the
suppression is live on the scan that fires the edge; the monitoring dir joins
`warm_fingerprint` so a toggle warms off-screen panes.

**The one exception is a DECLARED notify** (`switchboard monitoring notify`, `notify.rb`)
— the agent's "come look, this cycle surfaced something" for the case that routine
suppression would otherwise swallow. Same "declared, not detected" wall: switchboard
can't tell a "found it" tick from a "nothing new" tick (both are byte-identical `:done`
Stops), so the agent declares the one that matters. It's an **independent alert channel**,
not a hook edge — it may fire mid-`:thinking`. `Notify` is a `KeyedMarkerStore` twin of
`Attention` (content = realpath, like Attention) read by **mtime**: `monitoring notify`
re-touches the marker (fresh mtime), and each sidebar's `Edges#@prev_notify` cursor rings
once per advance (the completion-sound "compare-to-your-own-cursor" trick, so only the
on-screen pane rings and catch-up scans re-baseline silently — no delete race, no TTL).
The **bold** is written **directly by the CLI** into `Attention` (so it persists even
when no sidebar is on screen — the away-user case), so the edge's `mark_attention_for`
sees only the un-suppressed *completions*; the forced alert drives only the announce-gated
sound + sparkle. `:alert` (the sound state + `alert` built-in, distinct from `done`/
`waiting` — NOT `:notify`, which the Notification hook owns) stays **strictly local** to
sound/sparkle: a throwaway `states` map, never merged into `now`/`@prev_hook_states`, the
returned `edges` (so the diff refresh still rides real `:done`s), or `render_state`. The
verb is **gated to a monitored workspace** (it's the exception to monitoring's
suppression) and `Notify.clear_all` rides `quit` beside `Monitoring.clear_all`. The nudge
teaches it: fire *after* a cycle's output exists, not before. `Notify.pending` needs no
`warm_fingerprint` entry — its only shared render effect is the Attention bold, already
covered there.

**Clears, fastest to slowest (defense in depth):** explicit `off` and `quit`
(`Monitoring.clear_all`, beside `AgentState.clear_all` — a teardown kills every agent)
are instant; `Dir`-GC reaps a deleted worktree; the mtime **TTL** is the floor for a
crash with no clean exit. Two **session-boundary clears** (Layer 2, `MonitoringNudge` +
`CLI#monitoring_nudge`, wired into the Claude hook by `HookFile.command_entries` as
matcher-less `SessionStart`/`SessionEnd` commands — `MONITOR_MARK` so `ours?` dedups/
strips them) tighten those windows to instant: **clear-on-SessionStart** makes
monitoring a per-session declaration (a resumed agent, its old loop dead, re-declares) —
and **SessionEnd auto-off** (the agent's gone, so it can't still be monitoring). The
clear and the nudge have **different source gates** (the compaction split): the clear
fires on `startup`/`resume`/`fork` only (a fork is a new process — Claude ≥ 2.1.214 and
Codex ≥ 0.155 report it as `fork`, where they used to say resume/startup), NEVER
`compact` (same process continues, a live monitor's marker must survive) or `clear` (its
SessionEnd already dropped the marker; the re-planted nudge is what gets a still-running
monitor re-declared); the
**nudge** re-plants on `startup`/`resume`/`fork`/`clear`/`compact` (matching
`RenameNudge`), because compaction and `/clear` both drop the original instruction out of
context and SessionStart re-fires on them precisely so a hook can re-inject it — so an
agent that sets a monitor *after* either still knows the `monitoring on` convention (`MonitoringNudge.clears_on?` vs `nudges_on?`). Both rename-safe: `Rename.perform` carries the marker via the shared
`KeyedMarkerStore.carry` (capture the old realpath BEFORE `move_worktree` — the bridge
symlink resolves it to the new dir after), which also fixes the pre-existing bug where a
rename silently dropped `Attention`'s bold. The whole Layer-2 behavior (nudge + session
clears) is gated on the `background_presence` config knob (global + per-project, default
**on**, like `auto_rename`); the worker's hook-enable gate now includes it, so a
project using only monitoring still gets the hook wired. Cloud routines remain invisible
(they never reach the local reporter) — a hard limit stated, not worked around.

### Remote-link glyph (the ⇅ — observed, not declared)

A workspace reachable from the phone — a Claude session with `/remote-control` (`/rc`)
on — shows `⇅` right after its name (`⇅2` for several links; before any `▸N`, folded or
expanded; workspace rows only). Unlike the ∞ there is nothing to declare: Claude
already writes the truth. Every live Claude session has `<claude dir>/sessions/<pid>.json`
(`ClaudeHistory.claude_root`, shared with the transcript reader; test seam
`SWITCHBOARD_CLAUDE_SESSIONS_DIR`), and `/rc` adds a `bridgeSessionId` (removed on
disconnect, a NEW id on reconnect; the link is `https://claude.ai/code/<id>`). Verified
live on Claude Code 2.1.308; no hook or env exposes it. `RemoteLink` (`remote_link.rb`)
reads it, and because the file is **undocumented**, everything fails closed — an
unrecognized shape is no link, never a wrong one, and `scan` is total (the sidebar
hydrates `@links` LAST in `refresh_agents` behind its own rescue: a raise reaching
`refresh_agents`' rescue would blank every agent dot). Files are read as UTF-8 whatever
the locale (a smart-quoted session name would otherwise fail to parse).

Three hard-won rules:
- **Liveness is `ProcessIdentity.same?(pid, procStart)`.** Claude writes `procStart`
  byte-identical to `LC_ALL=C TZ=UTC ps -o lstart=` (double-space day padding kept), so
  no parsing; a crashed session's leftover file or a recycled pid shows nothing. Claude
  removes its file on clean exit. `kill(0)` runs first, so a dead leftover never forks a
  `ps` (the files can sit there forever).
- **Place a session by its KERNEL cwd, not the file's `cwd`.** `cwd` and `tmux` are
  startup stamps. After `rename A→B` the bridge keeps `realpath(A)` correct — until
  another workspace is renamed ONTO `A` (`Rename.perform` clears a dead bridge), when
  `realpath(A)` names the wrong tree. One batched `lsof -a -d cwd` (`Agents.cwds_of`,
  shared with `Agents.process_cwds`; ~27 ms for 4 pids, only when ≥1 link is live)
  follows the moved dir; the recorded `cwd` is only the fallback. (The agent dots may
  share this flaw — a verify-first TODO.)
- **The warm gate fingerprints the linked SET, not dir mtimes.** Claude rewrites EVERY
  session's file on each busy/idle flip, hooked or not, inside switchboard or not, so a
  `dir_fingerprint` would wake every hidden sidebar for unrelated work.
  `RemoteLink.fingerprint` keeps a per-file (mtime, size, inode) stamp cache
  (`@link_fp_cache` — a same-tick `/rc` toggle still changes the size), re-parses only
  changed files (no `ps`, no lsof), and moves only when a link appears, ends, or
  crosses the stale line.

An OFF-SCREEN pane runs the cheap scan (`cheap: !@visible`): `kill(0)` liveness and the
recorded `cwd`, no `ps`/lsof — hidden panes warm whenever anything in the fingerprint
moves. Its rare misses (a recycled pid, a rename onto an old name) last until the pane's
next visible scan, within `REFRESH`. It follows `@visible`, not `hooks_only`: the
on-screen post-delete reload passes `hooks_only` too. Paths are compared as bytes — under
tmux's C locale git's paths arrive US-ASCII and the JSON's UTF-8, and a non-ASCII pair
would raise.

All of a worktree's links are kept (`{path => [Link, …]}`, newest first by `startedAt`
→ parsed `procStart` → pid; a bad ordering field only demotes). A link idle past
`remote_link_stale_after` (minutes, default 120, global; `false`/0 off; invalid → 120)
renders its `⇅` **grey** (`LINK_STALE_FG`, `\e[90m`) — bold read identical in Will's
terminal — and ANY stale link greys the row, so an old forgotten link can't hide behind
a newer busy one. A live link is **green** (`LINK_LIVE_FG`, `\e[32m`): the default fg read
too close to the grey. Background jobs (`kind: "bg"`, apparently always bridged) show the
glyph but are never stale. Under the reverse-video cursor bar the `⇅` is uncolored like
the dots: a color code inside `\e[7m` paints the cell's BACKGROUND (fg/bg swap), an
off-shade block in the bar (keeping colors there is a TODOS.md item). Truncation: `fit_plain` gives up NAME columns, never the trailing cues
(the old `trunc(plain(node))` cut `⇅`/`▸N` first, so they vanished under the cursor bar
on a long name); the cues drop only when no name column would remain. The home
`console` adds `N idle links` and `N linked`, and given `cols` drops WHOLE clauses
(`linked` → `PRs` → `active`) before it would cut mid-word — the idle-link warning
always seats at 40 cols. `doctor` is the canary (`RemoteLink.health`): 0 files while a
Claude process runs (the dir moved — 0 with nothing open is normal, since Claude removes
its file on exit), files but none in the expected shape (format changed), or EVERY live
Claude pid failing the start-time match (`procStart` format drifted; a single drift is a
recycled pid). Only pids whose process IS Claude count (`claude_pids`: argv[0] or the
node script named `claude`, not a substring), and it warns when this shell's
`CLAUDE_CONFIG_DIR` differs from tmux's (sidebars never read your rc). A
RENAMED `bridgeSessionId` key is undetectable — it reads as "nothing linked". The
sandbox seeds a link on `quiet-cleanup` (`Sandbox.seed_link`: a `sleep` parked in the
worktree in a detached non-`sb/` session, so its kernel cwd is right and it dies with the
server); a real `claude /rc` inside the sandbox writes the real `~/.claude` and isn't
shown. Codex has no per-session equivalent (`codex remote-control` is a separate
app-server process). Proven end to end by `test/smoke/remote_link_smoke_test.rb`.

### Shared project collapse (the same multi-process trick)

Folding a project header (▸/▾ on ↵) hides its workspace rows. `Collapse`
(`collapse.rb`) keeps that fold **on disk, not in a sidebar ivar**, for the exact
reason the dots and bold do: every window's sidebar is its own process, so a fold
held in one process's `@collapsed` would leave every other pane — and every
respawn (toggle off/on, a new window, a reconcile) — showing the project expanded.
One file per collapsed project (name digest → name, `SWITCHBOARD_COLLAPSE_DIR` /
`XDG_STATE_HOME`), so a toggle is a single atomic create/delete (`collapse` /
`expand`) with no read-modify-write race, mirroring `Attention` (both on the shared
`KeyedMarkerStore` — see above). `rebuild`
**hydrates** `@collapsed` from the store every reload (so a fold made in one window
lands in the others on their next switch-in poke or while-visible scan);
`toggle_collapse` writes through *and* updates the in-memory set for same-frame
feedback. Unlike the attention markers it is a **durable view preference** — NOT
cleared on `quit`; a folded project stays folded across restarts. `collapsed`
GCs a fold whose project is no longer configured, but only when handed a
non-empty project list (the key is a name, not a checkable path, so a transient
empty/failed config can't wipe a user's folds).

### Full header on every session (the same trick, one global flag)

The home sidebar always seats the full brand header — wordmark + greeting +
console + rule (`Sidebar#header`); every other session shows just the wordmark.
`H` toggles that full header onto **all** sessions. `FullHeader` (`full_header.rb`)
keeps the flag **on disk, not in a sidebar ivar**, for the same multi-process
reason as `Collapse`/`Attention`/the dots: only a shared flag renders the same
header in every window's pane (and survives a respawn). It's a **single** marker
file whose mere existence is the flag (`SWITCHBOARD_FULL_HEADER_FILE` /
`XDG_STATE_HOME`), so a toggle is one idempotent create/delete — and because only
existence is read (never the contents), no temp+rename dance is needed (unlike
`Collapse`, which reads names). `rebuild` **hydrates** `@full_header` every reload
(so a flip in one window lands in the others on their next poke/scan);
`toggle_full_header` writes through *and* flips the in-memory flag for same-frame
feedback. Like the folds it is a **durable view preference** — NOT cleared on
`quit`.

### Global branch fold (issue #107 — the project-fold trick, one level down)

A workspace that has held multiple branches expands into inline branch rows
(`Tree.nodes` / `Git.branch_history` — the multiple-PRs-per-workspace case). Those
rows are useful occasionally and noise usually, so `z` folds **every** workspace's
branch rows at once — tree-wide, regardless of the cursor (the user wanted one
"toggle branches" key, not a per-row fold). It is therefore modeled like
`FullHeader`, NOT like `Collapse`: a **single global existence-flag** marker file
(`BranchFold`, `branch_fold.rb`; `SWITCHBOARD_BRANCH_FOLD_FILE` / `XDG_STATE_HOME`),
**on disk** for the same multi-process reason — only a shared flag folds every
window's pane alike (and survives a respawn). Default **off** ⇒ branches show, as
before #107, so nothing changes until you press `z`. `rebuild` **hydrates**
`@fold_branches` every reload; `toggle_branch_fold` writes through *and* flips the
in-memory flag for same-frame feedback, then re-anchors the cursor onto the row it
was on by path (folding from a branch row lands you on its workspace). Like the
other folds it is a **durable view preference** — NOT cleared on `quit`.

The fold itself is a cheap **`recompute_rows` row transform** (`visible_tree`), NOT
a rebuild — so `z` is instant and, crucially, the delicate `Tree` / console / #90
diff-suppression logic stays **untouched**. When folded, `visible_tree` drops every
`br` row and replaces each expanded ws row with a shallow **clone** marked
`expanded: false` carrying its **active branch's PR** (precomputed in `fold_lookup`
from the branch rows it's hiding) and a `folded:` count. That clone renders through
the *existing* gates with no special-casing: `expanded: false` un-suppresses its own
diff/PR badge (the #90 suppression only bites while the branches are visible), the
restored `pr` shows the badge, and the diff cache hits the same `[path, branch,
"ws"]` entry `refresh_diffs` already computes. `@nodes` is left intact (rebuild
reuses it; `console`/`refresh_diffs` still iterate the original tree, so the PR
count and diff cache are unchanged — the clone lives only in `@rows`). The dim `▸N`
cue (`fold_cue`) trails the folded ws name in both `plain` and `colored`, its width
reserved off the name budget so the two render paths stay the same visible width
(the `line`/right-region alignment depends on it). Filter mode is unaffected — it
already excludes branch rows.

### Sidebar width (the same trick, holding a number)

The sidebar pane was a hardcoded 40 cols (`Tmux::SIDEBAR_WIDTH`) that
`pin_if_resized` re-asserted every paint — so a naive `resize-pane` was clobbered
by the next pin. `←`/`→` in the tree now step the width (`WIDTH_STEP` cols/press,
issue #78), and the chosen width is the value the pin **respects**. `Width`
(`width.rb`) keeps it **on disk, not in a sidebar ivar**, for the same
multi-process reason as `Collapse`/`FullHeader`/the dots: only a shared value sizes
every window's pane alike (and survives a respawn). A **single global** file
(`SWITCHBOARD_WIDTH_FILE` / `XDG_STATE_HOME`) like `FullHeader`, but holding an
**integer** — so unlike the existence-only flag the value is *read*, which means a
torn write could misread; hence `Collapse`'s atomic temp+rename. `resolved` clamps
to `[MIN, MAX]` and degrades to `DEFAULT` (40) on a missing/garbage/torn file, so a
bad read just sizes the pane normally. `Tmux.pin(pane, width = Width.resolved)`
defaults to it (every cross-session caller pins to the saved width, no flash); the
sidebar's per-tick `pin_width` passes its hydrated `@width` to skip a disk read in
the hot loop. `spawn_sidebar`'s `-l` uses the saved width too, but clamped through
`fit_width` against the target window's `window_cols` (keeping `RESERVE_COLS` for the
work pane) — else a width chosen on a wide client would make `split-window` fail and
leave a narrow client with no sidebar at all. `rebuild` **hydrates** `@width` every
reload (a resize in one window lands in the others on their next poke/scan) — and
when the hydrated width *changed*, it nils `@geom` so the next `pin_if_resized`
actually re-pins; otherwise that throttle would short-circuit on the peer pane's
still-unchanged geometry and leave it stuck at the old width until a cross-session
re-pin. Like the folds it is a **durable view preference** — NOT cleared on `quit`.

The held-key detail: `resize` is **flag-only** (clamp `@width`, set `@resized`) —
no I/O. `handle` drains a whole autorepeat burst calling it per token, then the run
loop fires `commit_resize` **once** (one `Width.set` + one `resize-pane`), and
`render` reflows to the new `winsize` next iteration. So holding `←`/`→` resizes
smoothly instead of flooding one subprocess + disk write per repeat; `@geom`
self-heals on the next `pin_if_resized` (it pins to the same `@width`, never
fighting the resize). In `/` filter mode `←`/`→` are inert (the escapes aren't
printable, so `filter_key` ignores them) — movement-free there like `j`/`k`.

### Workspace diff counts (off-paint, per-process, mtime-gated)

Each ws/br row shows `+adds −dels` of its branch vs base (`base...HEAD`, committed
— not the working tree) just left of the PR badge (issue #79). Like the per-worktree
`git status` the model skips (`with_dirty: false`), a `git diff` per worktree can't
ride the synchronous paint, so it gets the **agent-dot / PR-badge treatment**: a
per-process `@diffs` cache (`[path, branch] => [logs/HEAD mtime, adds, dels]`)
refreshed by `Sidebar#refresh_diffs` off the paint loop. NOT shared on disk (a count
isn't a view preference) and NOT on the every-3s scan — it rides exactly the issue's
triggers: `reload` (switch-in / idle / tree-tick) and the agent edge (a finished
turn likely just committed). `Git.diff_counts` uses `--numstat` (the localized
`--shortstat` summary would slip past a word regex on a non-English git) and
`Git.range(base, ref)` so an inline branch row diffs its *own* ref, not HEAD.

The cache key is the worktree's `logs/HEAD` mtime, **stat'd fresh** in `refresh_diffs`
— NOT reused from `@branch_cache[path][1]`, which only refreshes on `rebuild`; the
edge-riding caller has no rebuild, so a cached mtime would compare stale-to-stale
and skip the just-landed commit. Only the gitdir (`@branch_cache[path][0]`, stable +
already absolute — the relative-`.git` bug that once blanked the tree) is reused.
`refresh_diffs` computes **value-or-nil** and `delete`s on nil, so a row that loses
its cache slot, base, or diffability clears instead of painting a ghost count. A
**MERGED/CLOSED** PR row bypasses the mtime gate: origin fast-forwarding past a merged
branch zeroes `base...HEAD` without moving `logs/HEAD` (the PR badge's blind spot),
and `R` (`refresh_prs_now`) clears `@diffs` as the manual catch-all. `View.diff_label`
(plain, for width math) / `diff_tag` (green adds / red dels) mirror the `pr_*` pair and
abbreviate counts ≥1000 (`1.5k`) so a huge diff can't swallow the name in the pane.

**The counts and badges align into fixed columns** (issue #118). Column alignment is a
property of the whole visible row set, not one row, so `line` can't size it alone — it
used to flush-right a single `[diff, id]` block per node, which made the `+/−` and `#n`
numbers staircase. `Sidebar#column_widths(@rows)` now measures three widths once per
`render` — the `+adds` sub-column, the `−dels` sub-column, and the `#pr` column — over
the **full `@rows`** (collapse-/filter-aware, NOT the on-screen slice, so columns hold
while you scroll; folding a noisy project tightens them) and threads them into every
`line`. Each cell `rjust`s into its column (`right_region` → `diff_cell` / `pad_cell`,
padding off the *plain* width then wrapping ANSI, the `line` split): the `+adds` stack,
the `−dels` stack, and the `#n` stay right-flush to the pane edge exactly as before. An
absent cell becomes aligned blanks, not a gap that shifts its neighbor — so the #90
expanded-ws suppression reads as clean empty columns. Single-row callers (tests) omit
the threaded widths and fall back to the row's own widths, so a one-row column equals
the row and the output is unchanged. The narrow-pane backstop still drops the *whole*
diff column first (uniformly — `cols`/widths are shared across rows, so the decision is
identical per row and the columns can never split), keeping `MIN_NAME_COLS` for the
name; `←`/`→` (#78) change `cols` live, so the columns recompute each render. No on-disk
shared state — each pane measures its own `@rows`, which is all that matters since you
look at one pane at a time.

Whether a row shows a count at all is the one predicate `Sidebar#diff_visible?`, which
folds two gates the render reads (`line`): the global **`diff_counts`** config knob
(`Config#diff_counts?`, default on, the `agent_state_hooks?` shape — issue #88) and the
**expanded-workspace** suppression (issue #90). When off, `refresh_diffs` early-returns
`@diffs.clear` — no `git diff` shell-outs at all, not just a hidden label, and a live
flip drops cached counts on the next reload. When a workspace expands into per-branch
rows, the `ws` row's count would duplicate its active branch row right below it (the ws
diffs HEAD == the active branch), so `diff_visible?` drops it on the `ws` row — the same
`expanded` condition (now carried on the `Tree::Node`) that already drops the PR badge
there. The redundant expanded-ws `git diff` is *computed* but never shown — keeping the
mtime-gated cache logic untouched was the deliberate trade (issue #90, render-gate only).

### Type-to-filter (the deliberately un-shared one)

`/` enters an in-sidebar incremental filter (issue #60) — fzf-style, but NOT the
removed external `fzf` popup: it's the same single navigator, just searchable.
`@filter` is `nil` (off) or a query string; `recompute_rows` branches on it to
`filtered_rows`, which keeps each project's matching ws/br rows **under their
header** (the grouping you navigate by stays visible) — a header with no match is
dropped. Matching is the pure `Sidebar.fuzzy_match?` (case-insensitive
subsequence) over `filter_text` (project + name/branch). Filtering spans the
**whole tree, collapse ignored** — the point is reaching any workspace fast, even
a folded one. Entry (`start_filter`) leaves the cursor on the first row; a query
keystroke then snaps it to the first workspace match (so type-then-`↵` jumps),
but headers ARE selectable — `↵` (`switch_to_filtered`) is
context-sensitive: a workspace switches, a **project header creates a new
workspace there** (`create(node)`; collapse is meaningless mid-filter, so
`↵`-on-project becomes the project-level action). Backspacing past an empty query
exits, like Esc. `dispatch` routes every key to `filter_key` while `@filter` is
set: printables extend the query, `↵`/`Esc` open-or-create/cancel, and crucially
no destructive key (`d`/`q`) can fire mid-search. `footer` swaps to
`filter_footer` (live query + a `↵`-label that tracks the row + a workspace-only
match count); the normal footer is the one-line `nav · ? help` (the `/` filter key
is taught in the `?` overlay now — see below).

Movement in the tree is **arrows / `^N`/`^P` / `j`/`k`** (vi-style down/up). In
filter mode `j`/`k` are query input instead — there movement is arrows / `^N`/`^P`
only, so any name stays reachable by typing (see #60).

Unlike `Collapse`/`Attention`/the dots, this is **deliberately NOT shared on
disk** — a search is a transient act, not a view preference, so it's a plain
per-process ivar. A background reload re-applies it (recompute is filter-aware),
but it's never persisted, GC'd, or seen by another window's pane.

### The `?` help overlay (issue #62 — the discoverable home for the keys)

`?` paints a full-pane key map over the tree (`render_help`); any real keystroke
dismisses it. `@help` is the flag — transient and per-process like `@filter`, NOT
shared on disk (opening help is an act, not a view preference). It exists because
the footer is width-bound: a *daily* user never found `g`/`G` because the old 3-line
legend had no room to teach them. The overlay is where every key the footer can't
fit now lives — `g`/`G`, `←`/`→`, the `^N`/`^P` aliases, the filter/prompt sub-mode
keys, the diff-count meaning, and the tmux keys that operate the sidebar.

**The footer is the gateway, and it's now ONE line.** A help you must already know
`?` to find is circular, so `footer` always ends with a persistent `? help`. And
because the overlay holds the complete reference, the footer sheds its two
action-key lines entirely — one context-sensitive line (`nav · ? help`, the nav
verb swapping open/collapse/switch; the home title or the empty-tree first-project
invite in its place), handing the tree two more rows. The former `/ filter` and
`+/− vs base` hints moved INTO the overlay. `filter_footer` keeps its three lines:
it's live query state, not key-teaching.

**A real key dismisses; the synthetic pokes are ignored.** `dispatch` routes every
key to `help_key` while `@help` is set. A genuine keystroke (even `q`) only closes
the overlay — no passthrough into an action. But the non-keystroke bytes the loop
also receives — the `C-l` switch/background-refresh poke, the `C-r` config poke,
focus in/out (`HELP_IGNORED_BYTES`) — must NOT dismiss it, or a background PR
refresh would close it out from under the reader (the same robustness `filter_key`
has against non-printables). Dropping their side effects is safe: `C-l`'s
reload/visibility self-heals via the `tick` backstop within `REFRESH` (tick runs
while help is open); `C-r` can't coincide with help (you can't open the editor with
help up — `e` dismisses first — and `C-r` isn't broadcast); focus is cosmetic under
a full-pane overlay. `?` can't open mid-filter (there it's a query char), so `@help`
and `@filter` are never both set.

**Static overlay, so it's off the animation cadence.** `pulsing?` returns false
while `@help` — a non-animating screen shouldn't ride the `PULSE` repaint. Close
latency is unaffected: dismissal is input-driven, so the keypress wakes `IO.select`
at once and the next iteration renders the tree; the gate only lengthens the idle
wake while help is up. `render_help` uses the same cursor-addressed `\e[K`/`\e[0J`
no-flash paint as `render` (no full `\e[2J`), with an "any key to close" hint pinned
to the bottom row. The body is the pure `help_body(rows, cols)` =
`help_lines(cols).first(rows - 1)` — the hint always seats, and a short pane drops
the tail (HELP is top-loaded with nav), never the top; extracted pure so the
height-cap is unit-testable without raw I/O. `help_lines` truncs the PLAIN string
before wrapping ANSI (the `line()` pattern), so truncation can't cut an escape.

**The magic row: the keys it shows are YOUR keys.** `tmux_help_rows` resolves the
tmux-layer keys that operate the sidebar at render time — the toggle/home keys via
`Config#tmux_key`, and (the implicit step switchboard splits the sidebar but
deliberately never binds) the user's OWN pane-movement keys via
`Tmux.pane_switch_keys`. That parses `tmux list-keys -T prefix` for `select-pane`
*movement* binds (directional / `-t`, excluding mark `-m`/`-M`), renders arrow names
as glyphs, collapses the full arrow / `hjkl` clusters to one token, and memoizes
once so the paint loop never re-queries. Best-effort and correct-or-absent: it reads
the prefix table and a literal `select-pane`, omits exotic idioms (if-shell-wrapped,
root-table) rather than show a fabricated key, and the row drops entirely when
nothing's detected. It `String#scrub`s the raw output first — a non-ASCII binding in
a non-UTF-8 locale could otherwise raise mid-regex and crash the render (degrade,
never crash).

### Configurable in-sidebar keys (issue #108 — extending #15 to the TUI keys)

The keys the sidebar's own input loop handles (`j`/`k`, `n`, `d`, `/`, `?`, …) are
user-remappable via a `sidebar_keys:` config map — the in-pane sibling of #15's
`tmux_keys:`. The single source of truth is `Keymap` (`keymap.rb`, a
`module_function` module): an ordered `ACTIONS` enum where each `Action` carries its
symbol name, its remappable `default` key, and the **fixed structural aliases**
(arrows / `^N`/`^P` / `^O`) that always also trigger it. ONE enum feeds three
consumers so they can never drift: `Sidebar#dispatch` (key→action), the `?` overlay
(`Keymap.help_rows`, action→shown-key), and `doctor`.

The hard-won split: **only printable single chars are configurable**
(`Config#valid_sidebar_key?` = one byte `0x20–0x7E`, *not* the permissive
`valid_tmux_key?` — here switchboard, not tmux, is the authority, and it compares raw
stdin bytes). That one rule **reserves every structural sequence for free** — `↵` (the
context action), `Esc`, `Backspace`, the resize `←`/`→`, the C-l/C-r pokes, focus
in/out are all non-printable, so a remap can't shadow them and they stay a literal
`case` in `dispatch` ahead of the keymap lookup. It also means a configured key can
never collide with a fixed alias (printable vs non-printable are disjoint), so
collisions are only ever printable-vs-printable.

Resolution (`Keymap.resolve_with_collisions`, the shared core of `bindings` /
`dispatch_map` / `collisions`) is deterministic by ACTIONS order, **first-claim-wins**:
a later action whose resolved key is already taken drops to **unbound** (nil) +
a `doctor` report — never a double-bind. Because the structural aliases are added to
`dispatch_map` unconditionally and outside that contest, a collided-away letter still
leaves movement working (`↓`/`^N` regardless of `j`) — you can't lock yourself out.
Same graceful-degrade posture as the rest of config: an invalid value falls back to
the default, a malformed file falls back to all defaults + `load_error`. `Sidebar`
hydrates `@keymap` (key→action, for dispatch) and `@bindings` (action→key, for the
overlay + footer hints) in `initialize` and re-resolves them every `rebuild`, so an
`e` config edit (`reload_config_and_rebuild` → `reload` → `rebuild`) re-binds live.

### The sandbox command (issue #126 — the interactive dogfooding twin)

The sidebar is the whole UX but it's a live tmux TUI the offline suite can't show
you, so verifying a UI change means *looking* at it — and running an in-flight
branch inside your real tmux lets its self-actions (`go_home`, a reconcile, a
`quit`) land on your real `sb/` sessions. `switchboard sandbox` (`sandbox.rb`) is
**"the smoke harness, but you're the client":** it boots a throwaway tmux server on
an isolated socket, seeds a hermetic repo with worktrees in varied visual states (a
`#12` PR badge, a big `+/−` diff, a no-PR row, an expanded multi-branch workspace,
agent dots), points the integration at **this** checkout, drops you into an attached
home session you drive by hand, and tears the whole server + state down on detach.

The isolated-server scaffolding is **shared** with the smoke layer: `IsolatedServer`
(`isolated_server.rb`) owns the socket lifecycle — `make_socket_dir` (short `0700`,
unpredictable suffix, symlink-safe), the dead-pid-gated `sweep_stale` (prefix-
parameterized: smoke uses `sbk`, the sandbox `sbx`), and the boundary-aware
`isolated_socket?` guard. `SmokeCase` delegates to it, so the guard that stops
teardown from reaching a real server is single-source and can't drift.

Teardown/sweep go through one primitive, `IsolatedServer.kill_server(sock_dir)`,
which is why a throwaway server can't leak. The subtle bug it closes: a tmux daemon
**outlives its socket** — once the socket file is unlinked, `tmux kill-server` (path-
based) can never reach it, so the old socket-only teardown, which removed the dir
after a merely-*attempted* kill, stranded a live daemon where `sweep_stale` (dir-keyed)
could never find it (~15 such zombies had accumulated). So `kill_server` does BOTH:
`kill-server` (confined by `kill_env` — the clean path while the socket is live) AND a
**pid-kill guarantee** — `ensure_dead` SIGKILLs the server's pid, which is the only
thing that reaches a socketless daemon. The pid comes only from THIS throwaway server
(a read through the server's own confined socket, or a `server.pid` file
`record_server_pid` writes at boot). That recorded pid is **identity-checked** — the file
stores `pid<TAB>start-time`, and `recorded_pid` returns it only when the live process's
start-time still matches, so a pid that went stale and was **recycled** to another live
process (even the dev's real tmux server) mismatches → nil → never killed; `ensure_dead`
additionally only SIGKILLs a still-live `tmux` process. So it can never reach the dev's
real server. Callers remove the dir only *after* `kill_server` returns, so a kill that
doesn't take can no longer orphan a daemon. Verified by `test/smoke/isolated_server_smoke_test.rb`
(unlink a live server's socket, assert it's still reaped by recorded pid), with the pure
pieces (`recorded_pid`, `tmux_comm?`, the recycle guard) unit-tested offline. `Sandbox` reuses `SandboxTest`'s **full** env wall-off — `sandbox_env`
redirects every `SWITCHBOARD_*`/`XDG_*`/`GIT_CONFIG_*`/`GH_*` path into the throwaway
tree (co-located **under** the socket dir, so one sweep reaps both), clears `TMUX`
(else a nested attach from inside your real tmux fails) and `GH_TOKEN`, and keeps
real `HOME` (the pane shell/tmux/ruby stay usable — safe because every state path is
redirected). The seeded config carries `base: main` + `projects:` + `auto_rename:
false` + `agent_state_hooks: false` (in the emitted YAML — without base the no-origin
repo defaults to `origin/main` and `n`/diff break; without `projects:` the tree is
empty). The `#64` lone-pane trap is avoided by always seeding a work-pane+sidebar
split, never touched.

Two operations would otherwise reach **outside** the isolated server, so the command
exports **`SWITCHBOARD_SANDBOX=1`** and switchboard's own code checks it: `prune`'s
`Reconcile.reap_sidebars` no-ops (its `ps`-based process list is machine-global, so
inside an isolated server every *real* sidebar would read as an orphan and get
SIGTERM'd), and the sidebar's background PR refresh (`maybe_refresh_prs`) skips its
spawn (the seeded repo has no origin, so a refresh would fetch `{}` and clobber the
badge you're dogfooding). A third escape isn't switchboard's to gate with its own flag:
Claude Code's self-updater would install under the redirected `XDG_DATA_HOME` yet repoint
the **global** `~/.local/bin/claude` symlink there, which teardown then deletes
(`command not found: claude` system-wide, #145) — so `sandbox_env` also passes claude its
own opt-outs, `DISABLE_UPDATES` + `DISABLE_AUTOUPDATER`=1 (the former is the documented
superset of the latter; both set as belt-and-suspenders). The checkout under test is
resolved from `sandbox.rb`'s own `__dir__` (NOT the symlink-resolved `SWITCHBOARD_BIN`)
and printed as a banner, so a PATH `switchboard sandbox` can't silently dogfood the
canonical checkout. Verified by `test/smoke/sandbox_smoke_test.rb` (seed renders +
view-state toggles land in the throwaway tree + the self-updater guards propagate to a
pane), with the pure pieces (`sandbox_env`, `isolated_socket?`, `stale_sock_dirs`, the
`SWITCHBOARD_SANDBOX` guards) unit-tested offline.

### Conventions

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
