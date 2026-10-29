# Explanation: background dispatch

How `n` → task → ↵ builds a workspace without blocking the sidebar or moving you, and
why cancel and failure never leave an agent on an un-set-up tree or destroy work.
This is the full implementation detail [CLAUDE.md](../CLAUDE.md) summarizes; keep the two in step.

Creating a workspace never blocks and never moves you. `n` asks for a TASK (never a
name — deferred naming still holds: CLAUDE.md, "Workspace naming is deferred"), and `Sidebar#create` only reserves a
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
canceled before the launcher claimed it. A failed `worktree add` is a collision when
the dir or branch existed BEFORE it, or when git itself says "already exists" about OUR
branch or path, exactly (someone made it in between; a hook line naming anything else is
not git's): the build retries under a fresh placeholder (up to
`PLACEHOLDER_TRIES`; racers taking every one fail it with git's last error plus "gave
up after N tries", not "no free workspace name"), and any give-up afterwards moves the record to a fresh name or parks it (`move_off`/`park`,
`.unbuilt-<id>`), so a ✘ never sits on someone else's folder. git's "already exists"
means it made nothing, so if a tree on OUR branch sits at the destination anyway (a
workspace renamed onto the placeholder, or a failing hook printing git's words) the
two can't be told apart: nothing is removed or retried and the record stays to guard
it. Anything else is rolled back by `undo_add`, which removes only what it can PROVE
is this create's — the tree only when it's on our branch with no commits past the
base commit the add started from (`Git.rev_parse`, captured before), dirty only while
git's own `initializing` lock says the checkout never finished (past checkout the row is
enterable, so changes are kept like a commit, fail-closed `Git.clean?` counting untracked
files whatever the user's status config, and the removal unforced so git refuses anything
that appeared since), and a lock only when it's that `initializing` one from a killed add,
never someone else's; the branch only atomically at that commit (`Git.delete_branch_at`
= `update-ref --no-deref -d <ref> <sha>`, never a symref's target, then its
`branch.<name>` config, as `branch -D` would) and only when one
strict worktree read (`Git.worktrees(strict: true)`: nil on a failed run or a path it
can't decode; `keep_branch` also treats an empty list as a failure) proves no worktree
holds it. Whatever it keeps is
named, with why, in the ✘ detail. git runs with `LANGUAGE=en` so those messages stay
matchable. Cancels come from `quit`/remove-project
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

## The setup script, in detail

This is the full implementation detail [CLAUDE.md](../CLAUDE.md) points to; keep it current with the code.

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

## Deferred naming, in detail

This is the full implementation detail [CLAUDE.md](../CLAUDE.md) points to; keep it current with the code.

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


## Related

- [Explanation: architecture](explanation-architecture.md) — the worktree ⇆ session mapping this builds on.
- [How-to: manage projects](howto-manage-projects.md) — `worktree_creation_command` and `session_command`.
- [Reference: config](reference-config.md) — the setup and agent command knobs.
