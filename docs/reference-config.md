# Reference: `config.yml`

The complete configuration reference for switchboard. The config is a plain YAML
file at `~/.config/switchboard/config.yml` (override with `$SWITCHBOARD_CONFIG`).
It's the only persistent file switchboard *requires* — a project registry plus a
handful of optional knobs. Git is the runtime source of truth; the config just
says which repos to scan.

`switchboard install` (or `init`) writes an annotated starter config; `a` in the
sidebar and `switchboard add` grow it. Edit it any time with `switchboard config`
or `e` in the sidebar — both reload on save.

> A malformed config never crashes switchboard, and it's never silent. It degrades to
> an empty config and a running sidebar keeps its last-good values, while
> `switchboard doctor` shows a red config row with the parse error, and `install` and
> `upgrade` print it and exit 1. A file that parses but isn't a map of settings (a
> dropped colon turns it into one string; a bare `false`; a list) counts as malformed;
> an empty or comment-only file doesn't. See
> [Explanation: architecture](explanation-architecture.md).

---

## Top-level keys

| Key | Type | Default | Effect |
|-----|------|---------|--------|
| `worktree_root` | path | `~/switchboard/worktrees` | Where `n` creates new worktrees: `<root>/<project>/<name>`. |
| `projects_root` | path | `~` | Where `a`/`clone` drop fetched repos: `<root>/<name>`. |
| `base` | git ref | `origin/main` | Default ref new worktrees branch from. Per-project `base` overrides it. |
| `branch_prefix` | string | _(none)_ | New branches become `<prefix>/<name>`. Empty/unset ⇒ bare `<name>`. |
| `prune_on_launch` | bool | `true` | Prune orphaned `sb/` sessions once, when the home session's sidebar starts (not on a code reload). |
| `auto_rename` | bool | `true` | Nudge the agent to `switchboard rename` a placeholder-named workspace once it knows the work (a `SessionStart` hook). `false` opts out. Per-project override wins. See [`auto_rename`](#auto_rename). |
| `agent_dispatch` | bool | `true` | Tell agents (a `SessionStart` hook) that `switchboard new` can start another workspace, here or in another registered project, when you ask. `false` drops the instruction; the command still works. Per-project override wins. See [`agent_dispatch`](#agent_dispatch). |
| `background_presence` | bool | `true` | Tell agents (a `SessionStart` hook) to declare background monitors and loops with `switchboard monitoring on`, so the sidebar shows a `∞`, and clear that declaration at session boundaries. `false` drops the instruction and the clears; `switchboard monitoring` still works by hand. Per-project override wins. See [background monitors](explanation-agent-presence.md#background-monitors-the-). |
| `diff_counts` | bool | `true` | Show the `+adds −dels` diff count on each workspace/branch row. `false` hides it and skips the per-worktree `git diff` entirely. |
| `count_indicator` | bool | `true` | Show a half-typed movement count (the `3` of `3j`) in the sidebar footer. `false` hides it; counts still work. Global only. |
| `max_branch_history` | whole number | `10` | How many branch rows a workspace that has held several branches shows. Older rows drop off the list; the branches stay. Global only. See [`max_branch_history`](#max_branch_history). |
| `prewarm` | bool | `true` | Keep off-screen sidebars warm so switching sessions doesn't flash a stale tree. `false` restores full dormancy (no off-screen work). See [`prewarm`](#prewarm). |
| `remote_link_stale_after` | minutes or `false` | `120` | How long a `/remote-control`-linked Claude session can sit idle before its `⇅` turns grey and it counts as an **idle link**. `false` or `0` turns that off; anything else invalid uses 120. Global only. See [`remote_link_stale_after`](#remote_link_stale_after). |
| `update_check` | bool | `true` | Homebrew installs: check for a newer release in the background (one `git ls-remote` of switchboard's public release tags every 4 hours, nothing else sent) and show `↑ 0.58.0 available · switchboard upgrade` under the wordmark. `false` stops the check and hides the line; `SWITCHBOARD_NO_UPDATE_CHECK=1` in the environment stops the check too. Clone and `--HEAD` installs never check. Global only. |
| `sync_session_name` | bool | `true` | After a rename, give the workspace's live Claude session the new name too (what the phone's session list and the resume picker show). Per-project override wins. See [`sync_session_name`](#sync_session_name). |
| `session_command` | string | _(none)_ | The agent a new workspace runs, after its setup. The task typed after `n` is appended when the command is plain words starting with `claude`/`codex` (no quotes, `#`, `&`, `;`, `|` or redirects); anywhere else, write `{task}` where it goes — bare, in quotes, or inside a quoted string (`aider --message {task}`, `claude "fix: {task}"`) — and it arrives as one argument, byte-exact. Inside a command that hands its text to another shell (`bash -c '…'`, `ssh host …`), use `"$SWITCHBOARD_TASK"` directly instead: that inner shell would read a substituted task as code. Otherwise the pane says "task not sent". `false` turns it off. Per-project override wins. |
| `worktree_creation_command` | string or list | _(none)_ | Setup script run **once in a new worktree**, before `session_command` — the `.env` / `bundle install` a fresh checkout needs. Per-project override wins; a per-project `false` turns it off. See [`worktree_creation_command`](#worktree_creation_command). |
| `sounds` | map or `false` | _(on, built-ins)_ | Completion sounds. See [`sounds`](#sounds). |
| `tmux_keys` | map | _(toggle `s`)_ | Which prefix keys switchboard binds. See [`tmux_keys`](#tmux_keys). |
| `sidebar_keys` | map | _(defaults)_ | Remap the keys *inside* the sidebar, by action name. See [`sidebar_keys`](#sidebar_keys). |
| `projects` | list | `[]` | The project registry. See [`projects`](#projects). |

**Retired: `agent_state_hooks`.** Every worktree switchboard creates gets its hooks: the
agent dots, the done chime and the instructions above all ride them, and switchboard isn't
much use without them. A config that still has the key keeps working; `doctor` names it as
retired. To keep a worktree hook-free, run `switchboard disable-hooks` in it, or put that
line in a project's setup script to keep the whole project free of Claude hooks from the
first session ([how-to](howto-agent-state-and-sounds.md#keep-a-worktree-or-project-hook-free)).
Codex hooks are one global block, which only `switchboard uninstall` removes.

Paths accept `~` and are expanded. Unknown keys are ignored.

### A complete example

```yaml
worktree_root: ~/switchboard/worktrees   # where `n` puts new worktrees
projects_root: ~/Programming             # where `a`/`clone` drop cloned repos
base: origin/main                        # default ref new worktrees branch from
branch_prefix: sam                       # new branches become sam/<name>
prune_on_launch: true                    # tidy orphaned sessions when the home sidebar starts
auto_rename: true                        # let the agent name a placeholder workspace (on by default)
agent_dispatch: true                     # tell agents `switchboard new` exists (on by default)
diff_counts: true                        # show +adds −dels on each row (false skips the git diff)
count_indicator: true                    # show a half-typed count (the 3 of 3j) in the footer
max_branch_history: 10                   # branch rows per workspace; older rows drop off the list
prewarm: true                            # keep off-screen sidebars warm (false = full dormancy)
remote_link_stale_after: 120             # minutes before an idle /rc link's ⇅ turns grey
update_check: true                       # Homebrew: a line under the wordmark when a newer release is out
sync_session_name: true                  # a rename renames the live Claude session too
session_command: claude                  # run this on a worktree's first session
worktree_creation_command:               # run ONCE in a new worktree, before the agent
  - cp "$SWITCHBOARD_PROJECT_PATH/.env" .
  - bundle install
sounds:
  enabled: true
  done: train
  waiting: chime
tmux_keys:
  toggle: s                              # prefix-s shows/hides the sidebar
  home: S                                # prefix-S jumps to the home session
sidebar_keys:
  new_workspace: c                       # press c (not n) to create a workspace
  delete: x                              # press x (not d) to remove a row
projects:
  - name: myapp
    path: ~/code/myapp
    base: origin/main                                       # per-project base
    session_command: claude --dangerously-skip-permissions  # per-project command
    worktree_creation_command: bin/setup                    # per-project setup script
    sounds:
      done: ~/sounds/celebrate.wav                          # per-project sound
```

---

## `auto_rename`

On by default. switchboard plants a `SessionStart` instruction (plus a `Stop` backstop)
in each worktree's Claude hooks telling a running agent to `switchboard rename <name>`
once it understands the work — naming the workspace **and** its branch. This completes
deferred naming: since `n` only ever creates placeholders, the agent names them so you
don't have to. It only fires while the workspace still has its generated **placeholder**
name (e.g. `wandering-finch-3f9a`); the moment it's named, the nudge stops. The instruction is
advisory (the agent renames when it's ready, or ignores it) — it never renames on its own.
Set `auto_rename: false` to opt out; the placeholder then stays until you rename it with `r`.

It's a global bool with a per-project override (like `session_command`): a per-project
`auto_rename` wins over the global one, in either direction.

```yaml
auto_rename: true            # global default
projects:
  - name: myapp
    path: ~/code/myapp
    auto_rename: false       # ...but off for this one
```

**Worktrees you already have:** the setting is read each time an agent starts, so
flipping it reaches every hooked worktree on its next session. A worktree without
switchboard's hooks (one made outside switchboard, or one you ran `disable-hooks` in)
needs `switchboard enable-hooks` first. Every worktree switchboard creates gets the
hooks; this setting only decides whether the naming instruction rides them.

---

## `agent_dispatch`

On by default. Each agent session in a switchboard workspace gets a short instruction
saying that `switchboard new` can start another workspace with its own agent, in this
project or another registered one, and that it should do so **only when you explicitly
ask**. The instruction also says this is separate from subagents: an agent keeps using
its own subagent tools for its own work. It rides the same `SessionStart` hook as the
self-naming nudge, so it re-appears after `/clear` and compaction.

Set `agent_dispatch: false` to drop the instruction, globally or for one project (a
per-project value wins in either direction). The `switchboard new` command itself keeps
working; agents just aren't told about it.

The instruction rides switchboard's hooks, which every new worktree gets; this setting
only decides whether the instruction is planted, never whether hooks are installed.

```yaml
agent_dispatch: true         # global default
projects:
  - name: scratch
    path: ~/code/scratch
    agent_dispatch: false    # ...but quiet in this one
```

---

## `prewarm`

```yaml
prewarm: true    # default
```

Each window's sidebar is its own process, and while off screen it sleeps to stay
cheap. Without pre-warming, switching into a session briefly shows that pane's
*last* render (possibly minutes old) until the switch-in poke reloads it — a
visible flash. With `prewarm: true` (the default), an off-screen sidebar keeps its
pane buffer fresh in the background, so switch-in shows correct content (agent
dots, diff counts, PR badges, bold) immediately, for any way you switch (the tree,
native tmux, a bare attach).

It stays cheap by design: the background refresh only runs when a stats-only check
sees that something it draws actually changed, and it's rate-limited, so a fully
idle pane costs about what it did before. It never rings completion sounds and
never kicks off background PR fetches off screen — those still happen when you
switch in. View-preference toggles (collapse, full header, branch fold) reach the other
sidebars right away, through a repaint broadcast. A worktree added or removed in
*another* session, and the pane width, settle on switch-in instead.

Set `prewarm: false` to restore full off-screen dormancy (the flash returns). It's
a global knob — there's no per-project override. For the full mechanism see
`docs/explanation-sidebar-lifecycle.md`.

---

## `max_branch_history`

```yaml
max_branch_history: 10    # default
```

A workspace that has held several branches expands into one row per branch, newest first.
This sets how many of those rows it shows, so a workspace running a long series of PRs may
want it higher. When a branch passes the limit, its row drops off the list with no marker;
the branch itself isn't touched, and deleting the workspace still offers it. The value also
decides which branches get their own PR lookup when the regular PR queries miss them.

Any whole number above 0 works, and there's no upper limit. Anything else (`0`, a negative
number, `10.5`, `"10"`, `true`, `false`) uses 10, and `switchboard doctor` names the bad
value. A limit of 1 shows no branch rows, just the workspace; to hide them for the moment,
press `z`. A change reaches running sidebars without a restart. New rows usually have their badges straight away, but a large jump can take
several refreshes to fill in, since each refresh looks up at most 10 branches per project.

The count is of names in the workspace's HEAD reflog, and it isn't always exact:

- Every name counts, including a deleted branch, the old name of a renamed branch, and
  `main` if you check it out between PRs.
- The branch you're on always shows, so it can add one row beyond the limit.

**A high limit has a cost.** Each row runs one `git diff` on the sidebar's main loop. A
sidebar recomputes every row of a workspace when its reflog moves, and every row in the tree
when it starts or you press `R`. At roughly 20 ms a diff, a workspace with 50 branches and a
limit to match would stall each sidebar for about a second per commit. This only applies to
workspaces with that much history. `diff_counts: false` removes the cost.

---

## `remote_link_stale_after`

```yaml
remote_link_stale_after: 120    # default, in minutes
```

A workspace whose Claude session has `/remote-control` (`/rc`) on shows `⇅` after its
name: you can reach it from your phone. switchboard reads this from the session file
Claude already writes, so there's nothing to set up. A link whose session has sat
**idle** longer than this many minutes turns its `⇅` grey and is counted in the home
header as an **idle link**: likely a door you opened and forgot. Background Claude
jobs never count as idle. `false` (or `0`) turns the idle check off; the `⇅` still
shows. Global only. If the glyph never appears, `switchboard doctor`'s "remote links"
row says whether Claude's session files moved or changed shape.
If you set `CLAUDE_CONFIG_DIR`, export it where tmux sees it (`.zshenv`, or
`tmux set-environment -g CLAUDE_CONFIG_DIR …`): sidebars are started by tmux, which
never reads your `.zshrc`. `doctor` warns when the two disagree.

---

## `sync_session_name`

```yaml
sync_session_name: true    # default
```

Claude names a session after the workspace's **first** name and never follows a
rename, so after `r` or `switchboard rename` the phone's session list and the resume
picker would still show the old one. With this on, a rename also gives every live
Claude session in that workspace the new name. Claude has no rename API, so a
background worker types `/rename <name>` into the agent's pane, under a strict rule:

- only between turns (Claude's status is idle, or shell: the turn is over with a
  background shell still running), never mid-turn, so the Enter can't answer a
  permission prompt;
- only while no tmux client has the pane focused (it can be in view: after the
  sidebar's `r` your keyboard is on the sidebar, not on the agent) and no tmux client
  anywhere has had keyboard or mouse input in the last 2 seconds (a click or scroll lands on
  the pane under the pointer; a `send-keys` binding can type in from another session), never
  while a client that can type into any pane (`tmux -CC`, or one with its own active pane) is
  attached to its session, not scrolled into tmux copy mode, not
  in a `synchronize-panes` window, and only while Claude itself owns the terminal (not
  suspended with `^Z`);
- only into an empty prompt, so your draft is never touched (and not in vim mode);
- Enter only if the prompt then reads exactly `/rename <name>`; otherwise it removes what it
  typed only if nobody has touched a key since (the pane isn't focused, and no tmux client had
  input), or leaves it and says so on the status line right away;
- at most one Enter per session: if Claude never shows the new name, or text was
  left behind, it stops and `doctor` says why. Running the same `switchboard rename`
  again is the retry (clear any leftover text in the prompt first).

It waits up to an hour for that moment (only inside tmux; sessions started later name
themselves). The rename output tells the agent that the "session renamed" note it's
about to see came from switchboard. Anything it couldn't do shows up in
`switchboard doctor` with the retry: run the same `switchboard rename` again. Codex
sessions aren't renamed yet. `false` (globally or per project) leaves Claude's own name.

---

## `sounds`

Completion sounds, on by default. A built-in name, a file path, or a macOS
system-sound name. See [How-to: agent state & sounds](howto-agent-state-and-sounds.md)
and [Explanation: agent presence](explanation-agent-presence.md).

```yaml
sounds:
  enabled: true        # false mutes EVERY sound
  done: train          # played when an agent finishes a turn
  waiting: chime       # played when an agent asks for input
  alert: alert         # played on a declared `monitoring notify`
  failed: failed       # played when a workspace dispatched with `n` fails (✘)
```

| Sub-key | Type | Default | Effect |
|---------|------|---------|--------|
| `enabled` | bool | `true` | `false` mutes all sounds (globally or per-project). |
| `done` | sound spec | `train` | Sound when a hooked agent reaches `:done`. A Claude turn that handed work to a background agent (`◷`) plays it once that work finishes. |
| `waiting` | sound spec | `chime` | Sound when a hooked agent reaches `:waiting`. |
| `alert` | sound spec | `alert` | Sound for a declared `switchboard monitoring notify` — a monitored agent surfacing something. Distinct from `done` so a "come look" reads differently than a finish. |
| `failed` | sound spec | `failed` | Sound when a workspace dispatched with `n` fails to build, set up, or launch its agent (`✘`) — a soft falling two-note, the opposite shape of the rising chimes. A dispatch becoming ready plays `done`. |

**Sound spec** resolves in this order:

1. A built-in name — synthesized in pure Ruby, cached on first use. One of:
   `train`, `train_1`, `train_2`, `train_3`, `chime`, `chime_1`, `chime_2`, `chime_3`,
   `alert`, `failed`.
2. A path (contains `/` or starts with `~`) — a literal audio file, e.g. `~/horn.wav`.
3. A bare name — a macOS system sound at `/System/Library/Sounds/<name>.aiff`, e.g. `Glass`.

**Muting is only ever `enabled: false`** (or a bare `sounds: false`). A blank or
absent per-state key *inherits* the next level up — it never mutes. So you can't
accidentally silence `done` by leaving it empty.

**Resolution per state** (`done`/`waiting`/`alert`/`failed`), highest priority first:

1. The project's `sounds.<state>`, if present and non-empty.
2. The global `sounds.<state>`, if present and non-empty.
3. The built-in default (`train` for `done`, `chime` for `waiting`, `alert` for
   `alert`, `failed` for `failed`).

Sounds need a player on PATH (`afplay` on macOS; `paplay`/`aplay`/`ffplay` on
Linux). With none, sounds stay silent. `switchboard doctor` reports the player
and whether each spec resolves; `switchboard sound [done|waiting|alert|failed]` plays one.

---

## `tmux_keys`

Which tmux prefix keys switchboard binds. See
[Reference: keybindings](reference-keybindings.md) and
[How-to: keybindings](howto-keybindings.md).

```yaml
tmux_keys:
  toggle: s   # show/hide the sidebar (default)
  home: S     # optional one-key jump to the home session (unbound by default)
```

| Role | Default | Effect |
|------|---------|--------|
| `toggle` | `s` | Binds `prefix-<key>` to show/hide the sidebar. |
| `home` | _(unbound)_ | Binds `prefix-<key>` to jump to the home session. Omit to leave unbound. |

A **key token** is a single char (`s`), a named key (`Space`, `F1`, `BSpace`),
or a modifier combo (`C-s`, `M-x`). A usable token is a non-empty string with no
whitespace, quotes, or control chars; anything else falls back to the role
default and `doctor` flags it. tmux is the final authority on whether a token is
a real key — an unusable one is caught at bind time. A key ending in `;` works
(`C-;`); the tmux.conf spelling `C-\;` means the same key.

If `home` resolves to the same key as `toggle`, `home` is dropped (one key can't
carry two actions; the toggle wins) and `doctor` reports the collision.

---

## `sidebar_keys`

Remap the keys you press *inside* the sidebar, by **action name**
rather than raw key — the config records intent, not bytes. Omit an action to keep
its default. See [Reference: keybindings](reference-keybindings.md#sidebar-keys)
for the full action list and [How-to: keybindings](howto-keybindings.md#change-the-in-sidebar-keys).

```yaml
sidebar_keys:
  new_workspace: c   # press c (not n) to create a workspace
  delete: x          # press x (not d) to remove a row
  down: j            # (default; shown only as an example)
```

`sidebar_keys` is a **YAML map**, so each override must stay **indented two spaces
under the `sidebar_keys:` header**. The common mistake when uncommenting it from the
scaffolded config is to strip the indentation and leave the header commented, so the
override lands at the top level — where switchboard never reads it and the remap
silently does nothing. The same applies to `sounds` and `tmux_keys`. `switchboard
doctor` flags any such stray top-level key (e.g. `config key "new_workspace" at the
top level does nothing`) and names the parent it belongs under.

| Action | Default | Action | Default |
|--------|---------|--------|---------|
| `down` | `j` | `open_repo` | `O` |
| `up` | `k` | `rename` | `r` |
| `top` | `g` | `delete` | `d` |
| `bottom` | `G` | `edit_config` | `e` |
| `filter` | `/` | `refresh_prs` | `R` |
| `add_project` | `a` | `toggle_branch_fold` | `z` |
| `new_workspace` | `n` | `toggle_full_header` | `H` |
| `open_pr` | `o` | `help` | `?` |
| | | `quit` | `q` |
| | | `phone_link` | `p` |

Each value is a **single printable character** (`0x20`–`0x7E`). That rule reserves
every structural key for free — `↵`, `Esc`, `Backspace`, the arrows, the resize
`←`/`→`, and the `Ctrl-N`/`Ctrl-P`/`Ctrl-O` aliases are non-printable, so a remap can
never shadow them. An invalid value (more than one char, a named key, a non-string)
falls back to the action's default, and `doctor` flags it.

If two actions resolve to the same key, the earlier one (in the table order above)
keeps it and the later is **left unbound** — but any fixed aliases it has still fire, so
you can't lose movement (`↓`/`↑`/`Ctrl-N`/`Ctrl-P` work even if `j`/`k` collide away).
`doctor` reports the clash. Everything degrades to defaults and keeps running;
nothing crashes.

Editing `sidebar_keys` from inside the sidebar (`e`) re-binds on save; the `?`
overlay then shows your actual keys (it always renders from the resolved map, so it
never drifts from a remap).

---

## `worktree_creation_command`

A freshly created worktree has **none** of the untracked, git-ignored files your
main checkout accumulated — no `.env`, no `node_modules`, no build cache. This is
the script that makes a new checkout usable. It runs **once, in the new worktree,
before `session_command`**, so your agent never opens on a half-built tree.

The value is a shell script (one line, or a whole multi-line script), or a list of
steps:

```yaml
worktree_creation_command:               # global default
  - cp "$SWITCHBOARD_PROJECT_PATH/.env" .
  - bundle install

projects:
  - name: myapp
    path: ~/code/myapp
    worktree_creation_command: bin/setup # override for this project
  - name: scratch
    path: ~/scratch
    worktree_creation_command: false     # no setup for this one
```

The script is handed to `sh -ec`, which means:

- **A multi-line script stays a script.** `if` blocks, loops, heredocs, and
  comments all work; nothing is reformatted or spliced.
- **It stops at the first failing step** (`set -e`), and a failed setup **stops the
  agent from starting** — the workspace turns `✘` with the soft `failed` sound, and switching in
  shows the error still on screen, rather than an agent working in a broken checkout. A step that's *allowed* to
  fail should say so: `cp "$SWITCHBOARD_PROJECT_PATH/.env" . || true`.
- **It runs in the new worktree**, so relative paths are relative to it.
- **A value it can't run fails the build** (`✘ config error`) instead of skipping
  setup. The usual cause is a list step with an unquoted `: ` — YAML reads
  `- echo Setup: done` as a map, not a string — so quote such a step.

### The two paths it gets

A new worktree lives under `worktree_root`, while the project's canonical checkout
lives wherever you registered its `path:` — two unrelated trees. So there is **no
relative path** from the worktree back to the checkout you want to copy your
untracked files out of. Switchboard exports both, so one *global* setup script can
serve every project:

| Variable | Is |
|---|---|
| `$SWITCHBOARD_PROJECT_PATH` | the project's canonical checkout (its registered `path`) |
| `$SWITCHBOARD_WORKTREE_PATH` | the new worktree (also just `.`, the cwd) |
| `$SWITCHBOARD_TASK` | the task typed after `n` or passed to `switchboard new` (empty for a bare create) — the agent gets it too |

```yaml
worktree_creation_command: cp "$SWITCHBOARD_PROJECT_PATH/.env" .
```

> **Don't copy `.claude/settings.local.json`.** Switchboard writes that file into
> each new worktree (the agent-state hooks, the rename nudge) *before* your setup
> script runs, so a broad `cp -R "$SWITCHBOARD_PROJECT_PATH/.claude" .` will clobber
> it and the workspace's agent dot will silently stop moving. Copy the files you
> want individually, or re-wire afterwards with `switchboard enable-hooks`.

Resolution is three-state, unlike `session_command`: an **absent** per-project key
inherits the global, a **value** overrides it, and **`false`** (or an empty value)
turns setup off for that project without falling back to the global.

Two limits worth knowing:

- It fires **at most once**, when the worktree is first built — not on a re-switch.
  There's no retry: fix the cause, then `d` the `✘` workspace and press `n` again.
- The agent runs in the pane's own interactive shell, so a `session_command` that's
  an alias or shell function from your rc works as it would typed by hand. A failed
  setup blocks it whatever its shape — a compound `export X=1; claude` included.

---

## `projects`

The registry: which repos switchboard scans for worktrees. A project needs only
`name` and `path`; the rest override the globals for that project.

```yaml
projects:
  - name: myapp
    path: ~/code/myapp
    base: origin/develop                 # optional: override the global base
    session_command: codex               # optional: override the global command
    worktree_creation_command: bin/setup # optional: override the global setup script
    sounds:                              # optional: override the global sounds
      enabled: false                     #   this repo stays quiet
```

| Key | Type | Required | Effect |
|-----|------|----------|--------|
| `name` | string | yes | Display name and the `sb/<name>/…` session prefix. |
| `path` | path | yes | The repo's working directory (the primary checkout). |
| `base` | git ref | no | Per-project base ref. Falls back to the global `base`. |
| `session_command` | string | no | Per-project session command. Empty/absent ⇒ inherit the global. |
| `auto_rename`, `agent_dispatch`, `background_presence`, `sync_session_name` | bool | no | Per-project overrides of the global settings. Absent ⇒ inherit the global; a value wins in either direction. |
| `worktree_creation_command` | string, list, or `false` | no | Per-project setup script. **Absent** ⇒ inherit the global; a value ⇒ override; **`false`** ⇒ off for this project (does *not* inherit). |
| `sounds` | map or `false` | no | Per-project sound overrides (same shape as the global). Per-state keys inherit the global when absent. |

A project entry missing `name` or `path` is silently skipped. A project whose
`path` doesn't exist on disk is dropped from the tree (so a moved repo never
breaks the sidebar — but its orphaned sessions are then left alone by `prune`;
see [How-to: housekeeping](howto-housekeeping.md)).

---

## Filesystem locations

Everything switchboard writes, and how to redirect it. State dirs follow XDG.

| What | Default location | Override |
|------|------------------|----------|
| Config | `~/.config/switchboard/config.yml` | `$SWITCHBOARD_CONFIG` |
| Agent-state files | `$XDG_STATE_HOME/switchboard/agents` → `~/.local/state/switchboard/agents` | `$SWITCHBOARD_STATE_DIR` |
| Attention markers (bold-until-viewed) | `$XDG_STATE_HOME/switchboard/attention` → `~/.local/state/switchboard/attention` | `$SWITCHBOARD_ATTENTION_DIR` |
| Monitoring markers (the `∞` dot) | `$XDG_STATE_HOME/switchboard/monitoring` → `~/.local/state/switchboard/monitoring` | `$SWITCHBOARD_MONITORING_DIR` |
| Notify markers (`monitoring notify`) | `$XDG_STATE_HOME/switchboard/notify` → `~/.local/state/switchboard/notify` | `$SWITCHBOARD_NOTIFY_DIR` |
| Held `◷` chimes (waiting on a background agent) | `$XDG_STATE_HOME/switchboard/offstage_hold` → `~/.local/state/switchboard/offstage_hold` | `$SWITCHBOARD_OFFSTAGE_HOLD_DIR` |
| In-flight delete markers | `$XDG_STATE_HOME/switchboard/pending-delete` → `~/.local/state/switchboard/pending-delete` | `$SWITCHBOARD_PENDING_DELETE_DIR` |
| Project-collapse folds | `$XDG_STATE_HOME/switchboard/collapse` → `~/.local/state/switchboard/collapse` | `$SWITCHBOARD_COLLAPSE_DIR` |
| Full-header toggle (`H`) | `$XDG_STATE_HOME/switchboard/full_header` → `~/.local/state/switchboard/full_header` | `$SWITCHBOARD_FULL_HEADER_FILE` (a file path) |
| Branch-fold toggle (`z`) | `$XDG_STATE_HOME/switchboard/branch_fold` → `~/.local/state/switchboard/branch_fold` | `$SWITCHBOARD_BRANCH_FOLD_FILE` (a file path) |
| Sidebar width (`←`/`→`) | `$XDG_STATE_HOME/switchboard/width` → `~/.local/state/switchboard/width` | `$SWITCHBOARD_WIDTH_FILE` (a file path) |
| Workspace names (what you renamed each workspace to; **back this up**) | `$XDG_STATE_HOME/switchboard/names` → `~/.local/state/switchboard/names` | `$SWITCHBOARD_NAMES_DIR` |
| Session-name sync outcomes (what `doctor` lists) | `$XDG_STATE_HOME/switchboard/session-name` → `~/.local/state/switchboard/session-name` | `$SWITCHBOARD_SESSION_NAME_DIR` |
| Background-create records (`n` and `switchboard new` dispatches) | `$XDG_STATE_HOME/switchboard/creation` → `~/.local/state/switchboard/creation` | `$SWITCHBOARD_CREATION_DIR` |
| PR-badge cache | `$XDG_CACHE_HOME/switchboard/prs` → `~/.cache/switchboard/prs` | `$SWITCHBOARD_CACHE_DIR` |
| Agent-state reporter script | `$XDG_DATA_HOME/switchboard/sb-agent-hook` → `~/.local/share/switchboard/sb-agent-hook` | `$XDG_DATA_HOME` |
| Synthesized sound WAVs | `$XDG_DATA_HOME/switchboard/sounds` → `~/.local/share/switchboard/sounds` | `$XDG_DATA_HOME` |
| PATH symlinks (`switchboard`, `sb`) | `~/.local/bin` | `$SWITCHBOARD_BIN_DIR` |

The data-dir paths (reporter script, sound WAVs) are deliberately install-independent,
so they survive a `git pull` upgrade or a `brew upgrade`. Both self-heal, by
slightly different means: the reporter script is rewritten whenever it's missing or
its contents have drifted from the embedded version (atomically, so a hook running it
at that moment isn't broken), while the sound
WAVs carry `ASSET_VERSION` in their filename — a version bump writes new files and
the stale ones are simply never referenced again.

The workspace-names store is the one file in the state folder that holds your own data
rather than a cache or a view setting. Each entry records the name you gave a workspace,
keyed by its folder. Lose it and every renamed workspace goes back to showing its
placeholder folder name (nothing else breaks, and you can rename them again), so include
it if you back up your dotfiles.

A few more files and behaviors can be redirected the same way:

| What | Default | Override |
|------|---------|----------|
| Update-line cache (its `latest.attempt` stamp sits beside it) | `$XDG_CACHE_HOME/switchboard/latest.json` → `~/.cache/switchboard/latest.json` | `$SWITCHBOARD_UPDATE_CACHE` (a file path) |
| Global codex config (the codex hooks block) | `~/.codex/config.toml` | `$CODEX_HOME` |
| Where release tags are read from | the switchboard GitHub repo | `$SWITCHBOARD_RELEASES_URL` (the test suite points it at a dead path, so nothing reaches GitHub) |
| Background update check | on, for a Homebrew install | `$SWITCHBOARD_NO_UPDATE_CHECK` set to anything but empty or `0` turns it off (the test suite, smoke runs and the sandbox set it) |
| How long an off-screen sidebar may wait before a code reload | up to 30 seconds | `$SWITCHBOARD_RELOAD_SPREAD` (seconds; the reload smoke test sets 0) |

An exported-but-empty variable counts as unset for every file and folder location above.
That covers the `$XDG_*` roots, each store's own override, `$SWITCHBOARD_CONFIG`,
`$SWITCHBOARD_BIN_DIR` and `$CODEX_HOME`, so `SWITCHBOARD_STATE_DIR=` means the default
location, not the current directory. It also means a redirect whose value came out empty,
such as `SWITCHBOARD_CONFIG="$SCRATCH"` with `SCRATCH` unset, reaches your real files, so
check a script's variable is set before relying on it for throwaway state.

These env overrides also make it safe to run switchboard locally against throwaway
state without touching your real config — the same walls the test suite uses (see
[CONTRIBUTING](../CONTRIBUTING.md)).

---

## Related

- [Reference: CLI](reference-cli.md) — every command that reads or writes this config.
- [Reference: keybindings](reference-keybindings.md) — `tmux_keys` and `sidebar_keys`, with the action names.
- [How-to: manage projects](howto-manage-projects.md) — grow the `projects` list.
- [Explanation: architecture](explanation-architecture.md) — why the config is just a registry.
