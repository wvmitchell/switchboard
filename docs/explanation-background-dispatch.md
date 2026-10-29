# Explanation: background dispatch

Press `n`, type a task, press ↵, and a new workspace builds itself in the background
with an agent already working on the task. The sidebar never freezes and you never get
moved. This explains how that works, and why a cancel or a failure never leaves an agent
running on a half-set-up tree, or throws away your work.

## The problem

Creating a workspace is slow and can fail in many ways. It fetches from the network,
runs `git worktree add`, wires hooks, runs your setup script (`bundle install` can take
minutes), and only then starts the agent. If the sidebar did all of that inline, every
pane would freeze until it finished. And because every window runs its own sidebar
process, two panes creating at once could collide on a name or claim each other's task.

Failure is the harder half. A build can die at any step, be canceled from another pane,
or be torn down by `quit`. Each time, the question is what to clean up, and the wrong
answer either starts an agent on a tree whose setup never ran, or deletes something that
isn't ours.

## Three processes and one record

The work is split across three processes that pass a single on-disk record between them.

**The sidebar only reserves.** `n` asks for a *task*, never a name; naming is deferred
(see [below](#deferred-naming)). `Sidebar#create` reserves a placeholder name and writes
a **`Creation`** record (`creation.rb`) claiming it, as one step (`Creator.dispatch`).
That step runs under `Creation.with_project_lock`, a per-project flock that the worker's
collision retry takes too, so two panes can never hand out the same name and have one
launcher claim the other's task. `Creator.reserve` skips names already taken by a
directory, a branch, a dangling rename bridge, or another in-flight record. Then the
sidebar spawns `switchboard create-workspace <id>` and goes back to drawing. Nothing on
the input loop builds anything or touches the network; reserve's local branch and
session lookups are its only shell-outs.

**The worker builds.** `Creator.work` runs as a daemon (via `CLI#create_workspace`, like
the reaper). It does a best-effort fetch, then `git worktree add --no-track`. On a
collision it retries with a fresh placeholder and relabels the record. Then it runs
`enable_hooks` and creates a *detached* tmux session whose one typed line is
`<abs bin> launch <dest>`.

**The launcher sets up and starts the agent.** `Creator.launch` claims the record, runs
the setup script, then runs the agent as its own child, through the pane's shell with
`-i -c`. That shell is the launcher's parent process, so your rc aliases resolve exactly
as if you'd typed the command. The record is marked `ready` only after a 5-second grace
period, so an agent that dies right away shows as a ✘ instead of a false "ready." A clean
exit 0 inside the grace counts as a hand-off, so that one is `ready`.

## How the task reaches the agent

The task travels in the environment variable `$SWITCHBOARD_TASK`. It's never
interpolated into a command string, where a quote in your task could break out. How it
gets onto the agent's command line depends on the command:

- **Plain commands get it appended.** When `session_command` is plain words starting
  with `claude` or `codex`, the task is appended as the last argument. `appendable?` is
  an allowlist: a trailing newline from a YAML block scalar, a `# comment`, a `&`, or any
  quoting would otherwise run the task as its own command or swallow it. Aider isn't
  appended to because its positional arguments are files.
- **Other commands opt in with `{task}`.** `substitute_task` replaces it quote-aware,
  whether it's bare, inside `"…"` or inside `'…'`, and it always lands as one argument
  to the pane shell's command. A command that hands the task to *another* shell
  (`bash -lc '…'`, `ssh`) must use `"$SWITCHBOARD_TASK"` itself, or that shell will parse
  the task as code.
- **Otherwise the pane tells you.** It shows "task not sent," or, when there's no agent
  command at all, that no `session_command` is set.

When you come back to the workspace later, a `{task}` template resolves to the bare
command, and a now-empty `'…'` is dropped.

The task prompt itself keeps non-ASCII text (read as raw bytes and decoded as UTF-8)
and turns on bracketed paste. So a paste that arrives over many reads stays text: it
can't submit on its first newline or reach `dispatch` as keystrokes. A paste marker split
across two reads is held for the next read; otherwise paste mode would never end and
would swallow ↵ and Esc. Input still in flight after you submit is drained.

## The record: many writers, one lock

`Creation` is the one piece of multi-process state here that several processes
*change*: the sidebar, the worker, the launcher, the Stop hook and GC. So every write
goes through `Creation.mutate`. It takes an exclusive flock on a *separate* `<id>.lock`
file (locking the data file itself would lock the inode that the atomic rename
replaces), then reads, changes, and writes temp+rename. Reads stay lock-free.

A few rules keep the writers from stepping on each other:

- **State changes are gated on the expected state.** A `transition` names the state it
  moves *from*. If a racing writer already advanced the record, that writer wins, and a
  no-op tells the worker to stop.
- **The newest record wins a lookup.** Every lookup by path (`for_path`, `repath`)
  takes the newest record, because a finished record can outlive its tree on a reused
  path.
- **The owner travels with the work.** The record's owner (pid plus start time,
  `ProcessIdentity`, shared with `IsolatedServer`) passes from worker to launcher at the
  claim. That lets GC tell a setup that's simply taking 15 seconds from a dead build,
  without a timeout. The worker waits up to 60 seconds for the claim, since a slow shell
  rc can delay it.
- **Teardown can't race a start.** The worker creates the session *under* the record
  lock, and `quit` and remove-project call `cancel_all` before killing sessions. So a
  teardown can't leave an agent starting after it.
- **`acked` is a flag, not a state.** Viewing the workspace (`locate`) sets it, and an
  acked record never pings.

## Hearing that it's done

You start a build and go do something else, so switchboard tells you when it's ready
or has failed. These pings are durable, recorded on the record, rather than detected
from a change in the dot. A fresh workspace's first `:done` is a first appearance that
`completion_edges` deliberately ignores, and sampling can miss a fast turn.

A ringing transition bumps `ring_gen` and bolds the row via Attention right away. The
ringing transitions are:

- **`ready`,** for a bare create or one without hooks. It plays your `done` sound.
- **`turn_done`,** for a hooked claude task. `CLI#rename_nudge_stop` stamps it, but only
  on its non-blocking path.
- **any failure.** It plays its own soft, falling `failed` built-in, not the notify
  `alert`.

Only an announcing, on-screen scan rings (`Sidebar#ring_creations`), and only if it wins
`claim_ring`'s compare-and-set on `rung_gen`. That means exactly one pane rings; a
silent reload (the C-w warm poke, a switch-in) can't use up the ping; and a respawned
sidebar can't replay it.

Which events ring, and how often:

- **One chime for the first turn.** While a record owns its first turn,
  `Edges#suppress_completion?` drops the normal `:done` edge for that row.
- **First-turn ownership has a time limit.** It lapses after `FIRST_TURN_CEILING` if the
  stamp never comes.
- **A Stop only counts once the agent has started.** `turn_done` is stamped only after
  that (`stamp_first_turn`), so a setup step that happens to run claude can't mark the
  build done and hide its own failure.
- **Whether the task is hooked is decided at launch.** `hooked` is settled at
  `authorize_launch` from the command that will actually run; the worker's value is
  only a first guess. A task that was never delivered is never hooked, so it pings at
  `ready`.
- **An early exit still pings.** A hooked task whose agent exits before its first Stop
  pings on that exit: a ✘ for non-zero, done for 0. A bare create never rings a second
  time.

## How it looks in the sidebar

A build that has no worktree yet still gets a row. These synthetic rows are spliced into
`@nodes` last in their project:

- **`◌` (yellow, steady, no pulse):** queued, building or launching.
- **`✘` (bold red):** failed. It outranks the agent dot. Once you've acked it, the
  agent's thinking and waiting dots show over it; at rest, the ✘ stays.
- **The task label:** dim, in the right-hand region, while the name is still a
  placeholder and there are no diff or PR cells. It's measured in display columns (wide
  characters count as two) and has invisible characters removed before it's drawn.
- **A failure's reason:** up to 14 columns (`Creation::REASONS`). Failure details are
  stripped of control bytes before they're flashed or printed.

On a ✘ that never got a worktree, `↵` shows the failure and `d` dismisses it.

## Never an agent on an un-set-up tree

This is the core guarantee. The agent starts *only* through
`Creation.authorize_launch`: one locked step that checks the record is still
`launching`, and stamps `setup_ok` and `agent_started`. So a cancel during setup, a record
GC dropped in the meantime, or a failure all mean no agent. It never falls back to "no
record, so nothing told me to stop."

Everything around the launch respects it:

- **An unreadable config fails the build** (`config`) instead of certifying a setup it
  couldn't run.
- **Coming back to a workspace checks the record too.** `switch` starts the agent only
  on a `Creation.certified?` record: no record at all, or one with `setup_ok`. A failed,
  canceled or still-in-flight build whose session died opens a plain shell with the
  reason instead.
- **The worker won't open a session on a dead tmux server.** If the record's `server`
  socket is gone (someone ran `kill-server` mid-build), opening a session would start a
  new headless server and run the agent there.
- **A tree canceled before the launcher claimed it is discarded.**
- **Renaming waits for the agent.** `Rename.perform` refuses (`:building`) until the
  agent has started (`Creation.renamable?`).

## Never destroying work

Cleanup removes only what it can prove belongs to this create. Everything else is kept,
and the ✘ detail names what was kept and why.

### Collisions retry under a new name

A failed `git worktree add` counts as a collision when the directory or branch existed
*before* the add, or when git itself says "already exists" about *our* branch or path,
exactly. (Someone made it in between. A hook's output line naming anything else isn't
git's.) The build retries under a fresh placeholder, up to `PLACEHOLDER_TRIES`. If racers
take every one, it fails with git's last error plus "gave up after N tries," not "no free
workspace name."

Any give-up after that moves the record to a fresh name or parks it (`move_off`, `park`,
as `.unbuilt-<id>`), so a ✘ never sits on someone else's folder.

### When ours and theirs can't be told apart, keep everything

git's "already exists" means git created nothing. So if a tree on our branch sits at the
destination anyway (a workspace renamed onto the placeholder, or a failing hook printing
git's words), there's no way to tell whose it is. Nothing is removed or retried, and the
record stays to guard it.

### Rolling back only what's provably ours

Any other failure is rolled back by `undo_add`, which removes only what it can prove:

- **The tree,** only when it's on our branch with no commits past the base commit the
  add started from (captured beforehand with `Git.rev_parse`). It may be dirty only while
  git's own `initializing` lock shows the checkout never finished. Past checkout, the
  row is enterable, so changes are kept just like a commit would be. That check is
  `Git.clean?`, which fails closed and counts untracked files whatever your status
  config says. The removal isn't forced, so git refuses anything that appeared since.
- **A lock,** only when it's that `initializing` lock from a killed add, never anyone
  else's.
- **The branch,** only atomically at that base commit: `Git.delete_branch_at`, which is
  `update-ref --no-deref -d <ref> <sha>` (never a symref's target), followed by its
  `branch.<name>` config, as `branch -D` would. And only when one strict worktree read
  (`Git.worktrees(strict: true)`, which returns nil on a failed run or a path it can't
  decode) proves no worktree holds it. `keep_branch` also treats an empty list as a
  failure.

git runs with `LANGUAGE=en` so these messages stay matchable.

### Cancels

Cancels come from three places:

- **`quit` and remove-project** call `cancel_all`, scoped to *this* tmux server through
  the record's `server` field (the `$TMUX` socket).
- **`d` on a `◌` row** calls `dismiss_dispatch`, which re-reads the record and tears down
  only if its cancel actually landed.
- **`d` on a real row mid-build** (`delete`) cancels before the kill.

Teardown force-removes a tree only once `Creator.untouched?` proves it clean with no
commits past its base. Anything else is kept: the sidebar flashes "kept …", coming back
opens a plain shell, and `d` on the row asks before forcing.

The worker re-checks for a cancel after its fetch. The fetch and `git worktree add` run
prompt-free in their own process group, with time limits (`FETCH_DEADLINE`,
`ADD_DEADLINE`, then `ProcessIdentity.terminate_group`).

### Keeping records while they guard something

A failed or canceled record without `setup_ok` that has a worktree
(`Creation.unfinished?`) is kept until that worktree is deleted. This is checked before
the drop for unconfigured projects. A canceled record also stays while its owner is
alive, because a worker still inside `worktree add` must find it to record a tree it
keeps.

## Garbage collection

GC cleans up finished and abandoned records, and it's careful in the same way:

- **It re-decides each drop under the record lock,** and never waits on a lock (the
  sidebar's background writers use `wait: false`).
- **It sweeps orphaned lock and temp files.**
- **It drops records of unconfigured projects** once they're out of flight, and only
  when the project list is non-empty.
- **It keeps an unfinished record while its tree is on disk.** `tree_on_disk?` checks
  for a `.git` there, not just the `worktree_added` flag, since a killed add or a refused
  rollback leaves a tree the flag never saw. GC then records the tree, so deleting it
  clears the row.
- **It force-deletes a canceled build's branch** only once the tree is proven untouched.
- **It reads records as UTF-8 whatever the locale.** Otherwise a C-locale tmux would fail
  to parse a task with a smart quote and lose the build.
- **It treats an empty start time as unknown.** Past `PID_ONLY_CEILING`, though, an owner
  known only by pid is treated as dead.
- **It skips its `ps` owner checks on an off-screen warm reload.**

`add_worktree` trusts git's exit status and reads git's text (any bytes) only on failure.

## The setup script

A fresh checkout doesn't have your untracked files (`.env`) or installed dependencies
(`bundle install`). `worktree_creation_command` (#83) is a script that sets those up.

It runs once per *worktree*, in the dispatch launcher (`Creator.run_setup`), and never
again when you come back: `switch` starts the bare `session_command`.

### One argument to `sh -ec`

The script is passed to `sh -ec` as a single argument
(`system(env, "sh", "-ec", script)`, with no shell string around it). So a multi-line
script, a trailing `# comment` and an apostrophe all survive verbatim, and `-e` stops at
the first failing step.

Because setup runs in Ruby and the agent starts only on success, a failed setup blocks
the agent for *any* `session_command`, including a compound one like
`export X=1; claude`. The older approach typed a `&&` chain into the pane, and that
leaked in exactly that case.

### Reading the config

- **Only strings count as an agent command.** `session_command: false` is the config's
  way to turn the agent off. YAML hands us the boolean, `Config#session_command` passes
  it through, and it means no agent, never the word `false`.
- **The setup setting has three states.** `Config#worktree_creation_command_for` reads
  absent as inherit, a value as an override, and `false`, empty or valueless as off. That's
  why it reads the raw project node, like `auto_rename_for`, instead of going through
  the `projects` map or the `project_key` helper. Both of those collapse "no key" into
  "key set to nil," so a project that opted out would silently inherit the global setting.
- **A broken list fails the build.** `setup_script` rejects a list with mixed types as a
  whole, since a partial setup is worse than none, and the launcher then fails that build
  (`config`, `Config#setup_invalid?`) instead of starting the agent with no setup. The
  usual cause is a list step YAML read as a map because of an unquoted `: `.

### The paths it gets

The script gets `$SWITCHBOARD_PROJECT_PATH` and `$SWITCHBOARD_WORKTREE_PATH`, passed to
the setup run alone (`run_setup`), plus `$SWITCHBOARD_TASK`. The task is the one the
launcher sets in its own environment, so setup and the agent both inherit it; the agent
doesn't see the two paths.

The paths aren't a convenience. A worktree lives at
`<worktree_root>/<project>/<leaf>`, while the project's checkout lives at its registered
`path`, so there's no relative path between the two. Without the exports, the main use
case (copy the untracked `.env` your new worktree didn't inherit) can't be written at
all. A plausible-looking `cp ../../main/.env .` fails, and because setup fails closed,
that blocks the agent on every create.

One thing a setup script must not do: copy `.claude/settings.local.json` wholesale. The
worker writes switchboard's hooks there *before* setup runs, so a broad
`cp -R .claude .` silently kills that worktree's agent dot.

### How it's tested

Stubs can only prove the call was made. The runtime contract is pinned by
`test/smoke/worktree_creation_command_smoke_test.rb` and `dispatch_smoke_test.rb`:
setup really runs in the new worktree, before the agent; a failure really blocks the
agent; and the exported path really reaches the script.

The fixtures are mutation-checked. The failure case fails on a real command rather than
`exit 1`, which aborts with or without `-e` and so would pin nothing. The happy case
carries a *quoted* trailing `#` comment, since YAML would eat an unquoted one.

## Deferred naming

Workspace naming is deferred (issues #94, #114). Neither `n` in the sidebar nor ↵ on a
project header in filter mode asks for a name. You get a **placeholder**, a throwaway
adjective-noun name from `Placeholder.generate` (`placeholder.rb`, a small in-repo word
list, no gem), and a matching branch. You start the work first and name it afterwards,
with `r`, `switchboard rename`, or the agent's nudge. Generated names retry past a
directory or branch collision.

The worker cuts the branch with `--no-track`, so a branch off `origin/main` doesn't
inherit it as an upstream. Otherwise the rename check below would read every fresh
worktree as already pushed.

`Rename.perform` renames both the directory (to the bare `<name>`) and the branch (to
`<branch_prefix>/<name>`), but it renames the branch only when that's safe:

- it's still the auto-created branch (its basename still equals the old name), and
- it hasn't been pushed. `Git.pushed?` means a remote-tracking ref exists, not that
  `@{upstream}` is set.

A pushed or diverged branch is left alone, and only the directory is renamed.

All the branch checks (`valid_branch_name?`, and `branch_exists?` giving the
`:branch_exists` result) run before anything moves, and the branch is renamed first. So
a collision fails cleanly with nothing moved, and the agent retries with another name.

## Related

- [Explanation: architecture](explanation-architecture.md) — the worktree ⇆ session mapping this builds on.
- [How-to: manage projects](howto-manage-projects.md) — `worktree_creation_command` and `session_command`.
- [Reference: config](reference-config.md) — the setup and agent command knobs.
