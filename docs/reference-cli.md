# Reference: the `switchboard` command

Every subcommand switchboard dispatches, its arguments, and what it does. The
binary is installed on PATH as both `switchboard` and the short alias `sb` (use
either). Run it from a clone as `bin/switchboard`.

Bare `switchboard` is context-aware: from a plain shell it bootstraps and
attaches the home session; inside tmux it toggles the sidebar. Everything else is
the config/worktree-management surface.

> Dispatch lives in `lib/switchboard/cli.rb`. An unknown subcommand prints the
> help and exits non-zero.

---

## User commands

### `switchboard`
Start or reach switchboard. Outside tmux: bootstrap + attach the home session
(`sb/home`). Inside tmux: toggle the sidebar (summon + focus when hidden, dismiss
session-wide when visible). The single command to launch from anywhere.

### `switchboard home`
Attach the persistent home session explicitly. Home maps to no worktree (it lives
in `$HOME`), carries its own sidebar, and is the stable launch + settings base.
When its sidebar starts, it also prunes orphaned `sb/` sessions unless `prune_on_launch: false`.

### `switchboard install [--no-tmux] [--print-tmux] [--tmux-conf PATH] [--codex-hooks] [--no-codex-hooks]`
Stand switchboard up from a fresh clone or a Homebrew install. Idempotent. Five steps:

1. Symlink `switchboard` (and the `sb` alias) into `~/.local/bin` (or
   `$SWITCHBOARD_BIN_DIR`). Skipped under Homebrew, which already put both on
   your PATH (reported as `on PATH via Homebrew`).
2. Add one marker-delimited line to the tmux.conf tmux actually loads, sourcing
   the self-locating `switchboard.tmux` fragment (binds the keys + sets the hooks).
3. Scaffold an annotated starter config if none exists.
4. Offer to install the global **Codex** agent-state hooks — a marker-delimited
   `[hooks]` block in `~/.codex/config.toml` (codex can't discover project-local
   hooks in linked worktrees, so its hooks are global, not per-worktree). Prompts
   for consent; default no on a non-tty. After installing, run `/hooks` in codex
   once to trust them (or start codex with `--dangerously-bypass-hook-trust`).
   If the block is already there, it's re-ensured without a prompt. Tables codex
   itself wrote inside the block (`[desktop]`, `[plugins."…"]`, …) are moved,
   unchanged and in order, to just above it, and your `/hooks` approvals are kept.
5. Update the Claude hooks in existing worktrees that already have them, as
   `switchboard upgrade` does (only when run as the `switchboard` on your PATH).

| Flag | Effect |
|------|--------|
| `--no-tmux` | Skip the tmux.conf edit; the other steps still run. |
| `--print-tmux` | Print the tmux line instead of writing it. |
| `--tmux-conf PATH` | Target a specific tmux.conf instead of the auto-detected one. |
| `--codex-hooks` | Install the global codex hooks block without prompting. Does nothing if codex isn't on PATH and `~/.codex` (or `$CODEX_HOME`) doesn't exist. |
| `--no-codex-hooks` | Skip the codex step entirely (no prompt). An existing block is left untouched, not re-ensured. |

If a codex write is attempted and refused or fails (your own `[hooks]` outside the
block, a block switchboard can't rewrite safely, codex writing the file mid-install,
or a file it can't write),
the other steps still run, the closing line reads `Done, except the codex hooks
(✗ above)`, and `install` exits 1. The ✗ line says what to fix.

If `config.yml` won't parse, or parses to something that isn't a map of settings,
`install` prints the parse error instead of refreshing your worktrees' hooks (it can't
list the projects), the closing line reads `Done, except the config (✗ above)`, and it
exits 1.

Backs up the target tmux.conf (and `~/.codex/config.toml`) to `.bak` before its
first edit. See [How-to: keybindings](howto-keybindings.md) for the wiring it
installs.

Under Homebrew, every path it writes uses the stable `<prefix>/opt/switchboard`
link rather than the versioned `Cellar` folder, so the wiring survives
`brew upgrade` + `brew cleanup` (see
[Explanation: distribution](explanation-distribution.md)).

### `switchboard upgrade`
Update switchboard and bring the setup up to date. First it checks for a newer
version: the newest release tag on GitHub for a Homebrew install, the upstream branch
for a clone. Then, if there is one, or it can't tell (a `--HEAD` install, offline, a
branch with no upstream):

1. Fetches it: `brew update` + `brew upgrade switchboard` (Homebrew), `brew upgrade
   --fetch-HEAD switchboard` (a `--HEAD` install), or `git fetch` + `git merge
   --no-overwrite-ignore --ff-only @{upstream}` (a clone; refused while tracked files
   have uncommitted changes, and git itself refuses an update that would overwrite an
   untracked or ignored file).
2. Hands off to the new binary, which:
   - refreshes the agent-state reporter script;
   - updates the Claude hooks in every worktree of the configured projects that
     already has them, when the hooks differ from this version's. It never adds hooks
     where there are none. A file Claude changed mid-update is skipped and reported, and
     so is a broken (unparseable) settings file holding switchboard's hooks, with the
     specific reason;
   - re-ensures the global codex block if it's installed (never adds one);
   - runs `switchboard.tmux` in the running tmux server, from any shell, when your
     tmux.conf sources this install;
   - reloads every running sidebar (only when the running binary is the `switchboard`
     on your PATH), like `switchboard reload-sidebars`, and prints what it reached.

   The first three run only when the running binary is the `switchboard` on your PATH,
   because the hooks and the reporter call back into whichever binary wrote them; from
   any other copy (a clone's `bin/switchboard`, say) the worktree hooks are skipped with
   a note, and the reporter and codex block are left as they are.

Already current, it prints `switchboard X is up to date` and exits 0, unless the setup
is stale (old worktree hooks, hook slots or the toggle key not live, a `tmux_keys`
change made by editing `config.yml` by hand, an old or missing reporter, or an old
codex block), in which case it runs step 2, except the sidebar reload, which needs new code
(under Homebrew each sidebar notices the new install itself; otherwise run
`switchboard reload-sidebars`). If `config.yml` won't parse, it finishes
whatever setup doesn't need the config, then prints the parse error and exits 1 rather
than reporting "up to date". Exits 1 if a fetch or setup step fails,
and also when `brew update` failed and nothing was upgraded (Homebrew may not have the
newest release, so it says so instead of "nothing newer"). A `brew update` failure is
only a note when the upgrade still lands.
A release tag Homebrew doesn't have yet is reported, not treated as an error, and so is
a fetch that brought nothing new ("Homebrew has nothing newer", "already the newest
commit on your branch"); as when already current, a stale setup still gets step 2.

### `switchboard uninstall [--tmux-conf PATH]`
Reverse `install`: remove both symlinks (under Homebrew it leaves PATH to
`brew uninstall switchboard` and says so), the tmux marker block, the bound keys,
the three hook slots, the `@switchboard-*` tmux options (in a running server too: a
binding switchboard displaced comes back, and one you've made on the key since stays),
and the global codex `[hooks]` block from `~/.codex/config.toml`
if present. Your config and agent state are left untouched.

The codex block goes **first**. Only switchboard's part of it is removed: tables
codex wrote inside it, and `/hooks` approvals for other hook files, stay (moved to
just above where the block was). If the block can't be removed safely, or codex
rewrites the file mid-run, `uninstall` stops before removing anything else and
exits 1; fix what the ✗ line names, then re-run it. If the removal itself fails to
write (or the codex config turns unreadable mid-run), the rest of the uninstall still runs, the
closing line reads `Done, except the codex hooks (✗ above)`, and it exits 1.

### `switchboard init`
Create an empty (annotated) config if none exists. No-op with a message if one
already exists. `install` runs this for you. Add your first project with `a` in
the sidebar or `switchboard add`.

### `switchboard config` (alias: `edit`)
Open `config.yml` in `$EDITOR` in the current terminal, scaffolding a stub first
so there's always a real file. On exit, re-applies `tmux_keys` immediately if
you're inside tmux. The sidebar's `e` does the same but in a dedicated pane beside
the home tree.

### `switchboard add <name> <path> [base-ref]`
Register an existing local git repo. `name` is the display/session name; `path`
is the repo working dir; `base-ref` (optional) overrides the global `base` for
that project. The repo on disk is untouched. Errors if the path isn't a git repo
or the name is taken.

### `switchboard remove <name>` (alias: `rm`)
Unregister a project from the config. The repo and its worktrees on disk stay;
re-add it any time. Unlike the sidebar's `d`, it does not tear down sessions, and `prune`
leaves them alone once the project is unregistered (unless another project's name maps to
the same `sb/<name>/` prefix). To close them, re-add the project and press `d` on its
header; `quit` closes them too, along with every other project's sessions.

### `switchboard clone <git-url> [name]`
Clone a repo under `projects_root`, then register it. `name` defaults to the
URL's basename (`git@host:org/repo.git` → `repo`). Errors if the name is taken or
the destination exists.

### `switchboard create <name>`
Create a brand-new empty repo under `projects_root`, then register it. It starts with an
empty initial commit, so `n` works in it right away. Errors if the name is taken, the
destination exists, or the name has anything but letters, digits, `.`, `_` and `-` (or
starts with `.`).

### `switchboard new <project|.> ["task" | -]`
Dispatch a new workspace the way the sidebar's `n` does: reserve a placeholder name,
build the worktree in the background, run its setup, then start the project's
`session_command` with the task. It returns as soon as the build is queued, well under a
second, and the sidebar shows the `◌` row and chimes when it's ready (or `✘` if it
fails). The chime comes from a visible sidebar, so with none open it waits until one is.
This is how an agent starts another workspace when you ask it to. It is separate from
the agent's own subagents.

- **The target is always explicit.** `.` means the project the current directory is in
  (a workspace or the main checkout). Anything else is a registered project name (see
  `switchboard projects`). It never guesses: `.` outside a project, or an unknown name,
  exits 1 and lists the registered names.
- **The task is one argument.** Quote it. More than one word after the target exits 1
  rather than joining words the shell may already have changed. No task is a bare
  create. `-` reads the task from stdin, for long briefs (`cat brief.md | switchboard new
  api -`). Stdin is refused on a terminal, and any pause over 5 seconds ends with an error,
  so a pipe that never closes can't hang the caller.
- **A task that would reach the agent wrong is refused** before anything is built: one
  starting with `-` (the agent would read it as an option), one over 64 KiB, one
  that isn't valid UTF-8, one containing a NUL byte, or one the project's `session_command` can't receive (no agent
  configured, or a command that needs `{task}`).
- **It always makes a new workspace.** It never starts an agent in an existing one,
  including the one you're in.
- **It needs tmux.** Outside tmux it exits 1, since the new session belongs to the tmux
  server you're on.

The first line of output says whether the workspace went into this project or
**another** one, judged by where you ran it (run from outside any project, it just names
the project). The path and record id follow.
`$SWITCHBOARD_TASK` is never read, so an agent's own task can't leak into a dispatch.

### `switchboard projects [--names]`
List the registered projects in config order: name, path and base ref, with `*` on the
project the current directory is in. `--names` prints just the names, one per line, for
scripts. With none registered it says how to add one.

### `switchboard refresh [name] [--poke PANE]`
Re-fetch PR badges from `gh` and merge the result onto the on-disk cache (a
cached badge persists even after its PR falls out of gh's query windows, and is
dropped only once its branch no longer exists locally or renders as a row).
With a project name, just that project; otherwise all. Normally you don't run this — the sidebar
refreshes badges automatically (on agent completion, on switch-in, and on an idle
backstop). Run it to catch a PR you merged or closed *on GitHub* (which fires no
local signal). `--poke PANE` is used internally by the sidebar to redraw a
specific pane.

### `switchboard enable-hooks [path]`
Wire exact agent-state hooks for the **Claude** worktree adapter
(`<worktree>/.claude/settings.local.json`) — scoped to that worktree, never your
global `~/.claude`. Defaults to the worktree you're standing in; pass a path to
target another. A running `claude` there picks them up on its own. Every worktree
switchboard creates gets this automatically.

Codex is **not** wired here: it can't discover project-local hooks in a linked
worktree, so its hooks ship as one global block in `~/.codex/config.toml`,
installed once via `switchboard install --codex-hooks` (or the install prompt).
`enable-hooks` re-ensures that global block if it's already present, and exits 1
if that codex write is refused (the Claude hooks are still wired). It also exits 1
when the Claude hooks couldn't be written (a settings file that isn't valid JSON or
UTF-8, has a malformed hooks section, can't be read, isn't a regular file under 4 MiB,
or can't be written: fix it, then re-run; `doctor` names the reason) or the reporter
script couldn't be.

### `switchboard disable-hooks [path]`
Remove switchboard's Claude hooks from a worktree, leaving any other settings
intact. Defaults to the current worktree. This is the opt-out: every worktree switchboard
creates gets the hooks, so this affects that worktree only, and the next one you create is
hooked again (run it from a project's setup script to keep a whole project free of Claude hooks).
Exits 1 when switchboard's hooks are still there afterwards: a settings file holding them
that isn't valid JSON or can't be read or written, or one reached through a symlink the
repo committed. A malformed file of your own with none of switchboard's hooks in it is
left alone and isn't an error. (The global codex block is deliberately left; it's
not per-worktree, and `switchboard uninstall` removes it.)

### `switchboard rename <name>`
Rename the workspace you're standing in. This is the verb for an **agent to name its own
live workspace** once it knows what the work actually is; the sidebar's `r` key does the
same from the tree. A rename changes what the workspace is called:

- its stored name, which the sidebar shows;
- its `sb/` tmux session, renamed in place, so a running agent and its conversation
  survive;
- its git branch, when that's safe (below);
- the live Claude session's title (below).

**The folder never moves.** It keeps the name it was created with, so Claude's and
Codex's conversation history (`claude --continue`, `/resume`, `codex resume`) keeps
working, and so does a shell or agent standing in it. That also makes renaming mid-task
safe: an agent should rename the moment it knows the name. Use
[`switchboard path`](#switchboard-path-name) to find a workspace's folder by its name.

On success it prints:

```
renamed to oauth-fix
folder (unchanged): /Users/you/worktrees/app/gentle-lantern-3f9a
```

or `already named <name>` when the name didn't change. Renaming back to the folder's own
name simply drops the stored name.

**It also renames the git branch** to match, `<branch_prefix>/<name>`, but only when
that's safe: the branch is still the auto-created one (its name still matches the
current name) **and** it hasn't been pushed. A **pushed** branch (one with a
remote-tracking ref or a configured upstream, i.e. a likely PR) or a branch you switched
yourself is left untouched, and only the name changes. So name a fresh workspace late and
you get a clean, convention-correct branch; rename one that's already on a PR and the
branch identity is preserved.

It refuses to rename the primary checkout. Run with **no name** and it prints usage plus
the current workspace name and exits non-zero; switchboard doesn't guess a name.

#### Rename failures

Every other failure is one line on stderr, led by a stable token, and exits 1, so
`switchboard rename x && …` is safe to chain. The line says what was changed (usually
nothing) and what to do next.

| Token | Meaning |
|---|---|
| `[exists]` | Another workspace, folder, build in progress or live session in this project already uses the name. Names are compared as tmux would spell them, so `foo.bar` and `foo-bar` clash. Nothing changed; pick another name. |
| `[branch-exists]` | A branch with the target name already exists (often a leftover from a deleted workspace). Nothing changed; pick another name. |
| `[invalid]` | The name sanitizes to nothing usable, contains `/`, or isn't a valid git branch name. |
| `[building]` | The workspace is still being created in the background. Rename it once it's ready. |
| `[stale-peers]` | A sidebar pane is running code that doesn't read stored names. Run `switchboard reload-sidebars`, then retry. `switchboard upgrade` reloads sidebars, so this clears on its own after an upgrade. |
| `[panes-unknown]` | tmux is running but couldn't list its panes, so switchboard can't tell whether an older sidebar is running. Nothing changed; retry, and if it keeps happening check `tmux list-panes -a`. |
| `[names-unreadable]` | The names store can't be read. Fix its permissions and retry. |
| `[listing-failed]` | git couldn't list the project's worktrees. Nothing changed. |
| `[failed]` | The name couldn't be saved (or the branch couldn't be renamed). The branch is unchanged or was put back. |
| `[rollback-failed]` | The name couldn't be saved, and the branch couldn't be put back either. The line prints the `git branch -m` to run. |
| `[partial]` | The name was saved, but the tmux session kept its old name. Nothing else to do: switching to the workspace renames the session. |

> **New workspaces start with a placeholder name.** Create one from the sidebar
> (`n`), with no name prompt, and switchboard gives it a random
> *adjective-noun-hex* name (e.g. `wandering-finch-3f9a`) and a matching branch, so you can
> start working before you've decided what it is, then `rename` it once you know. The
> placeholder stays the folder's name for good.

> **The agent names it (on by default).** With [`auto_rename`](reference-config.md#auto_rename)
> on — the default — a `SessionStart` hook tells the running agent to `switchboard rename` a
> placeholder-named workspace once it understands the work, so you never name it by
> hand. Set `auto_rename: false` to opt out. (`switchboard rename-nudge` is the internal
> subcommand that hook runs; not for direct use.)

> **The Claude session gets the name too.** Inside tmux, a rename starts a background
> worker that types `/rename <name>` into the workspace's live Claude session once it's
> between turns and nobody is at its pane (not focused, untouched for a couple of seconds), so the phone's session list and the resume picker follow. Renaming
> to the current name retries it. See [`sync_session_name`](reference-config.md#sync_session_name).
> (`switchboard sync-session-name` is that worker; not for direct use.)

### `switchboard path <name>`
Print the folder of the workspace called `<name>`. Since a rename never moves the folder,
a renamed workspace's folder still has its placeholder name; this maps one to the other.
`<name>` can also be `<project>/<name>` (when two projects use the same name) or a
folder name.

It prints exactly one absolute path on stdout and exits 0, so it's safe in a script:

```sh
p=$(switchboard path oauth-fix) && cd -- "$p"
```

On failure stdout is empty and stderr carries one of these:

| Token | Exit | Meaning |
|---|---|---|
| `[not-found]` | 1 | No workspace by that name. |
| `[ambiguous]` | 2 | The name is in several projects; the candidates follow as `<project>/<name>` lines. |
| `[names-unreadable]` | 3 | The names store can't be read. |

### `switchboard delete <name> | <project>/<name> [--creation <id>] [--force] [-n]`
Delete a workspace from a shell: its session, its folder, the branches that are its alone,
and everything switchboard kept for it (its stored name, its dispatch record, and every
marker), leaving nothing switchboard owns behind. Built for an agent cleaning up a
workspace it dispatched, so it refuses anything that could lose work.

- **Which workspace:** `<name>` resolves like `switchboard path` (a stored name or a folder
  name, optionally `<project>/<name>`), but from git's full worktree lists: if any project's
  list can't be read, it refuses rather than guess.
- **`--creation <id>`** (the `id:` line `switchboard new` printed): the workspace must be
  the very tree that record built, proven by a token `new` wrote into the tree's git admin
  folder. Alone, the record names the target; with a name, the two must agree. `new` prints
  the whole command for you as its `delete:` line.
- **Checks, before anything changes:** not the project's own checkout, not where you are,
  not still building, not already being deleted, not locked by you, no uncommitted or
  untracked changes, no commits that are on neither its base nor a remote (including ones
  only its own history log reaches, and its submodules' commits), and nobody using it,
  including any process whose working folder is in it outside its tmux session (a dev
  server left running in the background).
  After a rebase or amend, the commits you replaced still count until you push or
  `--force`. The last three are re-checked after its session closes, and git itself refuses a
  file written after that.
- **`--force`** is for a human: it overrides `[dirty]`, `[unpushed]`, `[branches-unknown]`
  and `[busy]` (exit 5) and nothing else. Once the session is closed it stops each process
  still running in the folder that has no terminal, is yours, and is the same process the
  check saw (TERM, then KILL after 5 seconds), and reports it as `stopped: process <pid>
  (<name>)`. It never signals a process with a terminal (someone's shell in the folder) or
  another user's: those refuse [`[process-alive]`](#delete-process-alive).
- **`-n` / `--dry-run`** runs every check and prints the plan (folder, session, branches
  with ✓ or !, record, stored name, markers, ignored files, history kept), and exits as
  the real run would. With `--force` it also lists each process it would stop (`would stop:`)
  or refuse over (`would refuse:`). It changes nothing.
- **Ignored files go with the folder**, as with `git worktree remove`: build output, a
  `.env`, notes in a gitignored folder. `-n` lists them first.
- **Agent history stays.** Claude's transcripts and Codex's sessions aren't switchboard's,
  and they're the record of what the agent did. Claude's folder is named in a `kept:` line.

On success it prints stable lines a script can read, and exits 0:

```
removed: folder /Users/you/worktrees/app/quiet-otter
removed: session sb/app/quiet-otter
removed: branch oauth-fix
kept: branch shared-fix (another workspace uses it)
removed: record 20261116135217-a1b2c3
removed: name oauth-fix
removed: markers (attention 1, agents 1, session locks 1)
kept: history /Users/you/.claude/projects/-Users-you-worktrees-app-quiet-otter (Claude's own)
```

The report has one line for every line of the dry run's plan, in the same order: the
folder, each session, each branch, the record, the stored name, the markers (a count per
store), any ignored files, and Claude's history. Each line starts with one prefix:

- `removed:` this run removed it.
- `kept:` left on purpose, with the reason in parentheses: a branch another workspace
  uses or that moved since the check, every branch when a `--force` delete can't tell
  which are its own, Claude's history, the typing lock of a Claude
  that may still be running, or, when finishing an interrupted delete, a session it can't
  confirm closed or a folder git no longer lists but whose files are left.
- `already gone:` the plan named it, but it was gone before this run reached it: a branch
  someone deleted, a session that had exited, or anything an interrupted delete finished
  before this one took over.
- `no session`, `no stored name`, `no markers`: there was nothing of that kind, in the
  plan and the report alike.

Anything that failed isn't a line here: it's listed under `[partial]`.

Every failure is one stderr line, `[token] <what>; changed: <none or what>; fix: <what to
do> (reference-cli.md#delete-<token>)`, then up to 20 indented detail lines. Exit 5 is the
"a human's `--force` would proceed" class; its fix never tells an agent to add `--force`.

| Token | Exit |
|---|---|
| [`[not-found]`](#delete-not-found) | 1 |
| [`[ambiguous]`](#delete-ambiguous) | 2 |
| [`[names-unreadable]`](#delete-names-unreadable) | 3 |
| [`[primary]`](#delete-primary) | 4 |
| [`[inside]`](#delete-inside) | 4 |
| [`[not-yours]`](#delete-not-yours) | 4 |
| [`[building]`](#delete-building) | 4 |
| [`[locked]`](#delete-locked) | 4 |
| [`[deleting]`](#delete-deleting) | 4 |
| [`[listing-failed]`](#delete-listing-failed) | 4 |
| [`[other-server]`](#delete-other-server) | 4 |
| [`[tmux-unknown]`](#delete-tmux-unknown) | 4 |
| [`[dirty]`](#delete-dirty) | 5 |
| [`[unpushed]`](#delete-unpushed) | 5 |
| [`[branches-unknown]`](#delete-branches-unknown) | 5 |
| [`[busy]`](#delete-busy) | 5 |
| [`[remove-failed]`](#delete-remove-failed) | 6 |
| [`[partial]`](#delete-partial) | 7 |
| [`[session-alive]`](#delete-session-alive) | 8 |
| [`[process-alive]`](#delete-process-alive) | 8 |
| [`[changed-during-delete]`](#delete-changed-during-delete) | 8 |
| [`[usage]`](#delete-usage) | 64 |
| [`[failed]`](#delete-failed) | 70 |

An interrupted delete leaves a receipt: the next `delete` of the same workspace (or
`switchboard prune`, once git no longer lists it and no files are left in its folder)
finishes it, and `doctor` names one that stopped while git still lists the workspace. Files
git left in the folder are yours to remove: `doctor` names that folder with the `rm -rf`
to run, then `switchboard prune`.

A `--force` delete moves anyone else attached to the session to `sb/home` before closing
it, so they land back in switchboard instead of being detached (an unforced delete refuses
`[busy]` while anyone is attached). The sidebar's `d` does the same. After upgrading, run `switchboard reload-sidebars` before
relying on `--creation`: an older sidebar can still collect a `new` record you've looked at.

#### delete: not-found
`[not-found]`, exit 1. No workspace by that name. Fix: check `switchboard path <project>/<name>`.

#### delete: ambiguous
`[ambiguous]`, exit 2. The name is in several projects; the candidates follow. Fix: name it as `<project>/<name>`.

#### delete: names-unreadable
`[names-unreadable]`, exit 3. The names store can't be read. Fix: fix that folder's permissions, then retry.

#### delete: primary
`[primary]`, exit 4. That's the project's own checkout, not a workspace. Fix: ask a human.

#### delete: inside
`[inside]`, exit 4. You're inside it: your current directory, your tmux pane's session, or a parent process that's one of its panes. Fix: run it from another workspace or a shell outside this one, or press `d` in the sidebar.

#### delete: not-yours
`[not-yours]`, exit 4. The `--creation` record is missing, built a different folder or project, isn't for this tree (a tree re-created at the same path), or predates `delete --creation`. Fix: never fall back to deleting by name; ask a human.

#### delete: building
`[building]`, exit 4. Its build is still in flight. Fix: retry at the next check; still building after 10 minutes, ask a human.

#### delete: locked
`[locked]`, exit 4. You locked it with `git worktree lock`. `--force` doesn't override your lock. Fix: `git worktree unlock <path>` if you're done with it, else leave it.

#### delete: deleting
`[deleting]`, exit 4. Another delete of it is running (its receipt's owner is alive). A dead owner's delete is taken over automatically. Fix: retry at the next check.

#### delete: listing-failed
`[listing-failed]`, exit 4. A project's worktree list couldn't be read, so the name can't be resolved safely. Fix: run `git worktree list` in that project to see why, then retry.

#### delete: other-server
`[other-server]`, exit 4. Its record was made on another tmux server, which this command can't see. Fix: run the same command from a shell inside that server.

#### delete: tmux-unknown
`[tmux-unknown]`, exit 4. tmux is running but couldn't be asked about sessions, panes or clients. Nothing changed. Fix: check `tmux ls`, then retry.

#### delete: dirty
`[dirty]`, exit 5. Uncommitted or untracked changes, listed below the line (or status couldn't be read). Fix: commit or stash them, or ask a human.

#### delete: unpushed
`[unpushed]`, exit 5. A branch it would delete (or a detached HEAD, a commit only its history log reaches, or a submodule) has commits on neither its base nor any remote. With no base and no remotes, every commit counts. Fix: push it, or ask a human.

#### delete: branches-unknown
`[branches-unknown]`, exit 5. It can't tell which branches are its own, or git couldn't count their commits. Fix: ask a human. With `--force` the workspace goes and every branch stays.

#### delete: busy
`[busy]`, exit 5. Someone may still be using it: an agent thinking or waiting, a live agent process with no idle report since it started, a Claude session with a dialog open, background work still running, or an idle only a moment old (found by its command line or session file, however it was launched), a live ∞ monitor, a ◷ hold, another tmux client attached, or a process running in it outside its tmux session (named with its pid). A process inside one of the session's panes doesn't count: closing the session stops it. Only a process's working folder counts; one that merely has a file open in it isn't found, and another user's process can't be seen at all. A process scan that fails, or a Claude session it can't read, counts as busy. An agent idle at its prompt doesn't, however long ago it finished: the newest hook report is `done` and was written after every agent in it started (an agent a wrapper script restarted counts on its own). An agent whose hooks never report (Codex with its global block untrusted, or Claude with hooks off) has no such report, so it needs `--force`. Fix: wait for it and retry at the next check, or ask a human.

#### delete: remove-failed
`[remove-failed]`, exit 6. Git refused or failed, or the folder's removal couldn't be confirmed. The session is closed. Fix: retry the same command once; fails again, ask a human with git's message.

#### delete: partial
`[partial]`, exit 7. The folder is gone but something listed below was left. The receipt is kept. Fix: `switchboard prune` finishes it, or remove each item. Files git left in the folder come first: remove them with the `rm -rf` their line names, then prune.

#### delete: session-alive
`[session-alive]`, exit 8. Its session didn't close. The record is acknowledged; the folder wasn't touched. Fix: `tmux kill-session -t =<name>`, then retry.

#### delete: process-alive
`[process-alive]`, exit 8. A forced delete closed the session, but a process it won't stop is still running in the folder: one with a terminal, another user's, one it couldn't confirm is the process the check saw, or one that outlived KILL. A failed process scan refuses the same way. The session is closed and the record acknowledged; the folder wasn't touched. Fix: close that terminal or `cd` out of the folder, or stop the process, then retry.

#### delete: changed-during-delete
`[changed-during-delete]`, exit 8. The re-check after its session closed found new changes, commits or a busy signal, or git refused an unforced removal. The session is closed and the record acknowledged; the workspace still shows. Fix: open it to see what changed (`claude --continue` there resumes the agent), then retry or ask a human.

#### delete: usage
`[usage]`, exit 64. No target, an unknown flag, or `--creation` without a valid id. Fix: see the synopsis above.

#### delete: failed
`[failed]`, exit 70. An unexpected error. The line says how far it got and where its trace file is. Fix: run `switchboard doctor`.

### `switchboard monitoring on [secs] | off | notify` (bare = status)
Declare (or clear) that this workspace is running a **background monitor / recurring
loop**, so the sidebar shows a steady `∞` instead of reading as idle/done. `on`
re-affirms liveness — re-run it each cycle (optional `secs` sizes the window for a slow
loop); `off` clears it; a bare `monitoring` prints the status. Agent- or human-invoked.

`monitoring notify` (from a **monitored** workspace) declares "come look — this cycle
surfaced something": the workspace bolds and plays a distinct **`alert`** sound, the one
exception to the otherwise-silent routine ticks. It no-ops with a hint if the workspace
isn't monitoring. See [agent presence](explanation-agent-presence.md#the-declared-alert--monitoring-notify).

### `switchboard sound [done|waiting|alert|failed]`
Play a state's configured sound, for trying audio out or auditioning sounds.
Defaults to `done`. Uses the global sound config, blocks until it finishes, and
reports *why* nothing played (muted / no player / unresolvable spec) so a silent
run is never mistaken for success.

### `switchboard prune [--dry-run] [-n]`
Kill orphaned `sb/` sessions — ones whose worktree git no longer has (deleted,
moved, or crashed). Reconciles against `git worktree list`. `--dry-run`/`-n` only
reports. Works outside tmux (it talks to the tmux server). Only touches projects
it can *verify* (configured + git-readable), so a moved repo's sessions are left
alone, as are those of a project whose folder is missing, even under a session prefix
another project shares. It also reaps orphaned sidebar processes: a
`switchboard sidebar` whose pane is gone.

A session belongs to the workspace whose folder it was created in, whatever it's
called, so a renamed workspace's session is never taken for an orphan.

It also forgets stored names for workspaces that are gone: a name whose folder has been
missing for 30 days is dropped, reported as `dropped N stored name(s) for workspaces gone
30 days`. This part runs even with no tmux server.

Last, it clears files deleted workspaces left in switchboard's own stores (the markers,
agent states and records `doctor` counts as leftovers), reported as
`cleared N leftover file(s) from deleted workspaces (<store> N, …)`. This also runs with no
tmux server, and a dry run reports `would clear` instead. See
[How-to: housekeeping](howto-housekeeping.md).

### `switchboard quit`
Close *all* `sb/` sessions — full teardown, the one you're in killed last. Also
clears every agent-state file (so a torn-down agent doesn't read as still
working), and first cancels any workspace still being built in the background, so
no agent starts after it. Works outside tmux. The sidebar's `q` does the same (with a confirm).

### `switchboard doctor`
Check the install and report anything off: `tmux`/`git`/`gh` on PATH, config
present + parseable, unrecognized top-level config keys (the misindented-nested-key
trap), PATH symlinks (under Homebrew: that `switchboard` and `sb` on PATH are this install, not
missing or shadowed by an old clone's link, a clone's `bin/` directory, or another program), which install tmux.conf is wired to (this
one ✓, another that still exists –, or one that's gone ✗), tmux wiring (bound keys +
hooks, and whether they're *live* in the running server vs only in config; a `tmux_keys` key
edited by hand that tmux hasn't applied, or one tmux refused), a bad or clashing `sidebar_keys` remap, a bad `max_branch_history` value,
whether a newer release is out (Homebrew installs: a `git ls-remote` to GitHub, bounded
to 5s, and it says so when it can't check; a clone or `--HEAD` install says which branch
it follows instead), the Claude hooks in the worktree you're standing in (missing,
unreadable, out of date because an older release wrote them, or unparseable, naming why), the global codex block from any shell (how many
of its hooks codex has approved, `N/M trusted`, or a fix when the block is stale, can't
be rewritten safely, or collides with your own `[hooks]`), `gh`
auth + per-project badge staleness, audio player +
sound resolution, orphaned sessions, stored workspace names (a name whose folder is gone,
with the `rename` to run if the worktree looks like it moved; an unusable entry; a name
that clashes and falls back to the folder name; a session or unpushed branch whose name
disagrees with the workspace's; an unreadable names store; sidebars that don't read stored
names, or a tmux that can't list its panes), files deleted workspaces left in its stores
(counted once they're an hour old, with `prune` as the fix) and folders under the worktree
root that git no longer lists (one a delete left files in says so, with the `rm -rf` and
then `prune`, and a process still running in one is named first, with the `kill`), the remote links (`⇅`) it sees (or a warning
when Claude is running but its session files are missing, none are in the shape
switchboard reads, or every live one fails the start-time check, i.e. a Claude update
moved or reshaped them), a `CLAUDE_CONFIG_DIR` that differs between your shell and tmux
(inside tmux only), orphaned sidebar processes, a rename's session-name sync that failed
(with the retry), and sidebars left on old code by a failed reload. Read-only. Its
network calls are the release check (Homebrew only) and `gh`'s auth check. Hook staleness is judged
only from the installed `switchboard`; run from another copy, doctor just reports the
hooks as present.
The first place to look when something's off.

### `switchboard sandbox`
Dogfood **this checkout's** sidebar in a throwaway, fully-isolated tmux — a hermetic
repo seeded with worktrees in varied visual states (an open-PR badge, a big `+/−` diff,
a no-PR row, a multi-branch workspace, a monitored `∞` row, a phone-linked `⇅` row, a
`◷` row waiting on background work), on its own tmux server and
socket, torn down automatically on detach. The interactive twin of `bin/test-smoke`;
nothing it does touches your real sessions or state. It also disables Claude
Code's self-updater inside the sandbox (`DISABLE_UPDATES` + `DISABLE_AUTOUPDATER`), so an
update firing in the throwaway can't repoint your global `~/.local/bin/claude` symlink
into the tree teardown deletes. If an older sandbox already dangled your launcher
(`command not found: claude`), repoint it:
`ln -sf ~/.local/share/claude/versions/<latest> ~/.local/bin/claude`.

### `switchboard reload-sidebars`
Every running sidebar on the tmux server swaps in its switchboard's current code, in
its own pane. `upgrade` does this itself. Use it by hand after a clone's `git pull`, or
inside `switchboard sandbox` to see a sidebar code edit without detaching.

- A sidebar from 0.59.0 on gets a signal (`SIGUSR1`). It waits for its next safe moment
  (no prompt, `?` overlay or QR code open, and no search being typed). Then it test-runs the new code
  (`switchboard sidebar --check`, which builds a sidebar off screen and applies the reload's
  payload, 3 seconds
  at most) and execs it in place, keeping its pid, cursor and agent state.
  - One that's on screen goes at once. The rest are spread over 30 seconds
    (`SWITCHBOARD_RELOAD_SPREAD`), or go when you switch to them.
  - If the test run fails, the sidebar stays on its old code and marks its pane;
    `switchboard doctor` lists it. A test run that timed out counts as failed; run
    `reload-sidebars` again to retry it.
  - The test run and the exec use the same file: the one the sidebar's binary resolves
    to when the reload starts (under Homebrew, the keg `opt/` points at). If it can't
    resolve (brew mid-relink, a deleted checkout), that reload is skipped and the pane is
    marked the same way, until a later reload lands.
- An older sidebar is restarted with `tmux respawn-pane`, rerunning the command that
  started it, after a test run of that binary: `sidebar --check` for 0.59 and later,
  `version` alone for older releases. If brew repoints the binary after the test run, that
  sidebar is left for the next reload. Only a pane started as
  `<…/switchboard> sidebar` is restarted: a respawn kills whatever runs in the pane.
- A sidebar whose binary is missing, isn't switchboard (its `version` doesn't print
  `switchboard X.Y.Z`), or fails the test run is left as it is.

Each sidebar reloads its OWN binary, so running this from another checkout never
repoints a sidebar. Prints `sidebars: N asked to reload in place, M restarted`, plus a line
for any left running, any that closed before the reload reached them, and any whose last
reload failed that were asked again now (or are already mid-reload), or `no sidebars
running`. Exits 0.

### `switchboard version` (aliases: `-v`, `--version`)
Print the version (`switchboard X.Y.Z`).

### `switchboard help` (aliases: `-h`, `--help`)
Print a usage summary — the main user commands plus the common sidebar keys. It's
a curated subset, not exhaustive: it omits `version`, the `edit` alias, the
internal subcommands, and the less common sidebar keys (`j`/`k`, `g`/`G`, `←`/`→`, `O`,
`p`, `z`, `H`, `?`).

---

## Internal subcommands

These are invoked by tmux (via the `switchboard.tmux` fragment and its hooks) or by
switchboard itself, not typed by hand. Documented for completeness — running them manually is usually a
no-op outside the right tmux context.

| Subcommand | Invoked by | Purpose |
|------------|-----------|---------|
| `sidebar [--check]` | tmux `split-window` | Run a sidebar pane (one process per window). `--check` is a code reload's test run. |
| `toggle-sidebar` | the bound toggle key | Summon/dismiss the sidebar session-wide. |
| `poke-sidebar` | `client-session-changed` hook | Redraw the now-visible sidebar on a session switch. |
| `poke-window <window>` | `session-window-changed` hook | Redraw the sidebar on a same-session window switch (gated to `sb/` sessions). |
| `sidebar-sync <window>` | `after-new-window` hook | Give a new window its own sidebar iff the session opts in. |
| `reload-config [origin]` | the post-edit Ctrl-R poke | Re-read config and redraw after editing it from the sidebar. |
| `tmux-bind` | the `switchboard.tmux` fragment | (Re)bind the configured `tmux_keys`, letting go of the previously-bound key and giving back what it displaced. A `config.yml` that won't parse re-binds the keys already bound (the defaults only if none were). An install path containing a quote or control character binds nothing, as `install` refuses it. |
| `check-update` | a visible sidebar, at most every 4 hours (spawned detached) | Homebrew installs: reads the newest release tag and caches it for the update line under the wordmark. Does nothing under `SWITCHBOARD_NO_UPDATE_CHECK`. |
| `create-workspace <id>` | the sidebar's `n` or `switchboard new` (spawned detached) | Background worker for a dispatched workspace: fetch, `git worktree add`, wire hooks, open the session. |
| `launch <dest>` | the line the worker types into the new pane | Run the setup script, then start the agent with the task. |
| `reap-worktree <repo> <path> <branch> …` | the sidebar's `d` (spawned detached) | Remove a workspace's worktree and branches in the background, so the input loop never waits on it. |
| `sync-session-name <dest> <name>` | a rename (spawned detached) | Type `/rename <name>` into the workspace's live Claude sessions when it's safe. |
| `rename-nudge [--stop]` | the Claude `SessionStart` and `Stop` hooks, and Codex's | Print the agent's naming and dispatch instructions; on `--stop`, report the turn's state too. |
| `monitoring-nudge [--end]` | the Claude `SessionStart` and `SessionEnd` hooks, and Codex's | Teach the agent to declare a monitor, and clear stale declarations at a session boundary. |

See [Explanation: sidebar lifecycle](explanation-sidebar-lifecycle.md) for how
these hooks keep each window's sidebar fresh without it scanning while off screen.

---

## Related

- [Reference: config](reference-config.md) — what `add`/`config`/`init` read and write.
- [Reference: keybindings](reference-keybindings.md) — the sidebar keys `help` lists.
- [How-to: housekeeping](howto-housekeeping.md) — `prune`, `quit`, and `doctor` in practice.
