# Reference: `config.yml`

The complete configuration reference for switchboard. The config is a plain YAML
file at `~/.config/switchboard/config.yml` (override with `$SWITCHBOARD_CONFIG`).
It's the only persistent file switchboard *requires* — a project registry plus a
handful of optional knobs. Git is the runtime source of truth; the config just
says which repos to scan.

`switchboard install` (or `init`) writes an annotated starter config; `a` in the
sidebar and `switchboard add` grow it. Edit it any time with `switchboard config`
or `e` in the sidebar — both reload on save.

> A malformed config never crashes switchboard. It degrades to an empty config,
> keeps the last-good values in a running sidebar, and `switchboard doctor`
> reports the parse error. See [Explanation: architecture](explanation-architecture.md).

---

## Top-level keys

| Key | Type | Default | Effect |
|-----|------|---------|--------|
| `worktree_root` | path | `~/switchboard/worktrees` | Where `n` creates new worktrees: `<root>/<project>/<name>`. |
| `projects_root` | path | `~` | Where `a`/`clone` drop fetched repos: `<root>/<name>`. |
| `base` | git ref | `origin/main` | Default ref new worktrees branch from. Per-project `base` overrides it. |
| `branch_prefix` | string | _(none)_ | New branches become `<prefix>/<name>`. Empty/unset ⇒ bare `<name>`. |
| `agent_state_hooks` | bool | `true` | Auto-wire the per-worktree Claude agent-state hook on worktree create. (Codex hooks are global — installed once via `install --codex-hooks`, not per worktree.) |
| `prune_on_launch` | bool | `true` | Prune orphaned `sb/` sessions when landing on the home session. |
| `auto_rename` | bool | `true` | Nudge the agent to `switchboard rename` a placeholder-named workspace once it knows the work (a `SessionStart` hook). `false` opts out. Per-project override wins. See [`auto_rename`](#auto_rename). |
| `diff_counts` | bool | `true` | Show the `+adds −dels` diff count on each workspace/branch row. `false` hides it and skips the per-worktree `git diff` entirely. |
| `prewarm` | bool | `true` | Keep off-screen sidebars warm so switching sessions doesn't flash a stale tree. `false` restores full dormancy (no off-screen work). See [`prewarm`](#prewarm). |
| `session_command` | string | _(none)_ | Command typed into a worktree's window the first time its session is created. Per-project override wins. |
| `sounds` | map or `false` | _(on, built-ins)_ | Completion sounds. See [`sounds`](#sounds). |
| `tmux_keys` | map | _(toggle `s`)_ | Which prefix keys switchboard binds. See [`tmux_keys`](#tmux_keys). |
| `sidebar_keys` | map | _(defaults)_ | Remap the keys *inside* the sidebar, by action name. See [`sidebar_keys`](#sidebar_keys). |
| `projects` | list | `[]` | The project registry. See [`projects`](#projects). |

Paths accept `~` and are expanded. Unknown keys are ignored.

### A complete example

```yaml
worktree_root: ~/switchboard/worktrees   # where `n` puts new worktrees
projects_root: ~/Programming             # where `a`/`clone` drop cloned repos
base: origin/main                        # default ref new worktrees branch from
branch_prefix: wvmitchell                # new branches become wvmitchell/<name>
agent_state_hooks: true                  # auto-wire agent-state dots on create
prune_on_launch: true                    # tidy orphaned sessions on landing home
auto_rename: true                        # let the agent name a placeholder workspace (on by default)
diff_counts: true                        # show +adds −dels on each row (false skips the git diff)
prewarm: true                            # keep off-screen sidebars warm (false = full dormancy)
session_command: claude                  # run this on a worktree's first session
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
name (e.g. `wandering-finch`); the moment it's named, the nudge stops. The instruction is
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

**Turning it on for worktrees you already have:** the nudge is wired into a worktree's
hooks at create time, so flip it on and run `switchboard enable-hooks` inside an
existing worktree to add it there (new worktrees get it automatically). Requires
`agent_state_hooks` OR `auto_rename` to be on for the hooks to wire at all.

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
switch in. A worktree added or removed in *another* session, and view-preference
toggles (collapse, full header, branch fold, width), refresh on switch-in rather
than via pre-warming.

Set `prewarm: false` to restore full off-screen dormancy (the flash returns). It's
a global knob — there's no per-project override. For the full mechanism see
`docs/explanation-sidebar-lifecycle.md`.

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
```

| Sub-key | Type | Default | Effect |
|---------|------|---------|--------|
| `enabled` | bool | `true` | `false` mutes all sounds (globally or per-project). |
| `done` | sound spec | `train` | Sound when a hooked agent reaches `:done`. |
| `waiting` | sound spec | `chime` | Sound when a hooked agent reaches `:waiting`. |
| `alert` | sound spec | `alert` | Sound for a declared `switchboard monitoring notify` — a monitored agent surfacing something. Distinct from `done` so a "come look" reads differently than a finish. |

**Sound spec** resolves in this order:

1. A built-in name — synthesized in pure Ruby, cached on first use. One of:
   `train`, `train_1`, `train_2`, `train_3`, `chime`, `chime_1`, `chime_2`, `chime_3`.
2. A path (contains `/` or starts with `~`) — a literal audio file, e.g. `~/horn.wav`.
3. A bare name — a macOS system sound at `/System/Library/Sounds/<name>.aiff`, e.g. `Glass`.

**Muting is only ever `enabled: false`** (or a bare `sounds: false`). A blank or
absent per-state key *inherits* the next level up — it never mutes. So you can't
accidentally silence `done` by leaving it empty.

**Resolution per state** (`done`/`waiting`), highest priority first:

1. The project's `sounds.<state>`, if present and non-empty.
2. The global `sounds.<state>`, if present and non-empty.
3. The built-in default (`train` for `done`, `chime` for `waiting`).

Sounds need a player on PATH (`afplay` on macOS; `paplay`/`aplay`/`ffplay` on
Linux). With none, sounds stay silent. `switchboard doctor` reports the player
and whether each spec resolves; `switchboard sound [done|waiting]` plays one.

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
a real key — an unusable one is caught at bind time.

If `home` resolves to the same key as `toggle`, `home` is dropped (one key can't
carry two actions; the toggle wins) and `doctor` reports the collision.

---

## `sidebar_keys`

Remap the keys you press *inside* the sidebar (issue #108), by **action name**
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

Each value is a **single printable character** (`0x20`–`0x7E`). That rule reserves
every structural key for free — `↵`, `Esc`, `Backspace`, the arrows, the resize
`←`/`→`, and the `Ctrl-N`/`Ctrl-P`/`Ctrl-O` aliases are non-printable, so a remap can
never shadow them. An invalid value (more than one char, a named key, a non-string)
falls back to the action's default, and `doctor` flags it.

If two actions resolve to the same key, the earlier one (in the table order above)
keeps it and the later is **left unbound** — but its fixed aliases still fire, so
you can't lose movement (`↓`/`↑`/`Ctrl-N`/`Ctrl-P` work even if `j`/`k` collide away).
`doctor` reports the clash. Everything degrades to defaults and keeps running;
nothing crashes.

Editing `sidebar_keys` from inside the sidebar (`e`) re-binds on save; the `?`
overlay then shows your actual keys (it always renders from the resolved map, so it
never drifts from a remap).

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
    sounds:                              # optional: override the global sounds
      enabled: false                     #   this repo stays quiet
```

| Key | Type | Required | Effect |
|-----|------|----------|--------|
| `name` | string | yes | Display name and the `sb/<name>/…` session prefix. |
| `path` | path | yes | The repo's working directory (the primary checkout). |
| `base` | git ref | no | Per-project base ref. Falls back to the global `base`. |
| `session_command` | string | no | Per-project session command. Empty/absent ⇒ inherit the global. |
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
| Project-collapse folds | `$XDG_STATE_HOME/switchboard/collapse` → `~/.local/state/switchboard/collapse` | `$SWITCHBOARD_COLLAPSE_DIR` |
| PR-badge cache | `$XDG_CACHE_HOME/switchboard/prs` → `~/.cache/switchboard/prs` | `$SWITCHBOARD_CACHE_DIR` |
| Agent-state reporter script | `$XDG_DATA_HOME/switchboard/sb-agent-hook` → `~/.local/share/switchboard/sb-agent-hook` | `$XDG_DATA_HOME` |
| Synthesized sound WAVs | `$XDG_DATA_HOME/switchboard/sounds` → `~/.local/share/switchboard/sounds` | `$XDG_DATA_HOME` |
| PATH symlinks (`switchboard`, `sb`) | `~/.local/bin` | `$SWITCHBOARD_BIN_DIR` |

The data-dir paths (reporter script, sound WAVs) are deliberately install-independent,
so they survive a `git pull` upgrade or a `brew upgrade`. Both self-heal, by
slightly different means: the reporter script is rewritten in place whenever it's
missing or its contents have drifted from the embedded version, while the sound
WAVs carry `ASSET_VERSION` in their filename — a version bump writes new files and
the stale ones are simply never referenced again.

These env overrides also make it safe to run switchboard locally against throwaway
state without touching your real config — the same walls the test suite uses (see
[CONTRIBUTING](../CONTRIBUTING.md)).

---

## Related

- [Reference: CLI](reference-cli.md) — every command that reads or writes this config.
- [Reference: keybindings](reference-keybindings.md) — `tmux_keys` and `sidebar_keys`, with the action names.
- [How-to: manage projects](howto-manage-projects.md) — grow the `projects` list.
- [Explanation: architecture](explanation-architecture.md) — why the config is just a registry.
