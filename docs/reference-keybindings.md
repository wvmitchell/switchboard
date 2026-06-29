# Reference: keybindings

Two key surfaces: the **tmux prefix keys** switchboard binds (to summon the
sidebar or jump home), and the **keys inside the sidebar** (to navigate and act
on the tree). Both are configurable: the tmux keys via
[`tmux_keys`](reference-config.md#tmux_keys), the sidebar keys via
[`sidebar_keys`](reference-config.md#sidebar_keys) (issue #108). A handful of
structural keys inside the sidebar stay fixed — see [Sidebar keys](#sidebar-keys).

---

## tmux prefix keys

Bound by the `switchboard.tmux` fragment that `install` wires into your
tmux.conf. Configure which keys via [`tmux_keys`](reference-config.md#tmux_keys).
Press your tmux **prefix** (default `C-b`) first, then the key.

| Default | Role | Action | Configurable via |
|---------|------|--------|------------------|
| `prefix-s` | `toggle` | Show/hide the sidebar. Hidden ⇒ summon it on every window of the session and focus the tree. Visible ⇒ dismiss it session-wide. | `tmux_keys.toggle` |
| _(unbound)_ | `home` | Jump to the home session (`sb/home`). | `tmux_keys.home` |

`prefix-s` is the one sidebar verb — one key, summon or dismiss, from any pane.
It defaults to `s` because that's switchboard's historical binding; it collides
with tmux's built-in `choose-tree`, which is why it's remappable. `home` is
unbound by default (one less key taken); set `tmux_keys.home` to opt in.

**Key tokens** accepted by `tmux_keys`: a single char (`s`), a named key
(`Space`, `F1`, `BSpace`, `Enter`), or a modifier combo (`C-s`, `M-x`). See
[How-to: keybindings](howto-keybindings.md) to change them.

---

## Sidebar keys

Active when the sidebar pane is focused. Navigation works on whatever row is
highlighted; the action keys apply to the highlighted row's kind (project,
workspace, or branch). The one-line footer shows the row's nav verb and the
`?` gateway; press `?` for the full key map (the action keys live there).

The **Default** column is what ships; the **Action** column is the name you put
under [`sidebar_keys`](reference-config.md#sidebar_keys) to remap it (e.g.
`new_workspace: c`). The `?` overlay always shows your *actual* keys, so it never
drifts from a remap.

| Default | Action | What it does |
|---------|--------|--------------|
| `↑` / `↓` / `Ctrl-N` / `Ctrl-P` / `j` / `k` | `down` / `up` | Move the highlight down/up (across projects, workspaces, and a workspace's branch rows). Arrow, emacs, and vi spellings all work; only the `j`/`k` letters are remappable (the `↑`/`↓`/`Ctrl-N`/`Ctrl-P` aliases are fixed). In filter mode `j`/`k` type into the query instead. |
| `g` / `G` | `top` / `bottom` | Jump to the top / bottom of the tree. |
| `←` / `→` | _(fixed)_ | Narrow / widen the sidebar pane (2 cols per press; hold to resize smoothly). The width is shared across every window's sidebar and survives a restart. Inert in filter mode. |
| `/` | `filter` | Filter the tree — type to jump straight to a workspace by name. See [Filter mode](#filter-mode) below. |
| `↵` (Enter) | _(fixed)_ | On a workspace/branch row: switch to its tmux session (creating it if needed). On a project header: collapse/expand it. |
| `a` | `add_project` | Add a project — register a local repo or clone a URL (a small prompt). |
| `n` | `new_workspace` | Create a new worktree + branch in the highlighted project, and drop you in. No name prompt — it gets a throwaway placeholder name you rename later with `r` (or let the agent name it). |
| `o` / `Ctrl-O` | `open_pr` | Open the highlighted PR in the browser (`gh pr view --web`). Only the `o` letter is remappable; `Ctrl-O` is a fixed alias. |
| `O` | `open_repo` | Open the highlighted row's repo in the browser (`gh browse`). Works on every row kind, including the project header. Opens the repo at the row's branch when it has an open PR, otherwise the repo home (default branch). |
| `R` | `refresh_prs` | Refresh PR badges now (catch a PR merged/closed *on GitHub*). |
| `z` | `toggle_branch_fold` | Fold / unfold **every** workspace's branch-history rows at once — tree-wide, regardless of where the cursor is. A folded multi-branch workspace collapses to a single row that shows its own diff/PR badge plus a dim `▸N` cue (N branches tucked away). A shared on-disk view preference, so all sessions follow and it survives restarts. |
| `H` | `toggle_full_header` | Toggle the full header (wordmark + greeting + console + rule) on **every** session, not just home. A shared on-disk view preference, so all sessions follow and it survives restarts. |
| `r` | `rename` | Rename the highlighted workspace (moves the worktree dir, keeps branch + PR). |
| `d` | `delete` | Remove the highlighted row — delete a workspace, or unregister a project (and close its sessions). Confirms first. |
| `e` | `edit_config` | Edit `config.yml` in `$EDITOR` (opens beside the home tree, returns you on quit). |
| `?` | `help` | Show the full key map overlay (nav + actions + filter/prompt modes + the tmux keys that operate the sidebar). Any key closes it. |
| `q` | `quit` | Quit switchboard — tear down every `sb/` session. Confirms first. |

A `sidebar_keys` value is a **single printable character**. That rule is what
keeps the structural keys reserved: `↵`, `Esc`, `Backspace`, the arrows, and the
`Ctrl-N`/`Ctrl-P`/`Ctrl-O` aliases are all non-printable, so a remap can never land
on one. `switchboard doctor` flags an invalid value or a clash (two actions on one
key) — the loser is left unbound, but its arrow/ctrl aliases still work, so you can
never lock yourself out of movement. See
[How-to: keybindings](howto-keybindings.md#change-the-in-sidebar-keys).

The footer legend shows only the common keys for the highlighted row; `g`/`G` and
the `Ctrl-N`/`Ctrl-P` movement aliases don't fit it — press `?` in the sidebar for
the complete key map, the in-app home for every shortcut.

Every name prompt (`a` add local/clone, `r` rename) edits in raw mode:
`Esc` (or `Ctrl-C`) cancels and returns to the tree with nothing created, `↵`
submits, `Backspace` edits. The prompt shows `(esc cancel)` until you start typing.

`↵` on a workspace **creates the session on first switch** and runs the project's
`session_command` then (only then — never on a re-switch into a live session). A
workspace that has held more than one branch expands into inline branch rows
(read from its HEAD reflog) you move between with the same `↑`/`↓`. Those rows are
history with their PR badges — `↵` on any of them switches to that one worktree's
session (they all share it); switchboard doesn't check the branch out for you.

When those branch rows pile up, `z` folds them: one keypress collapses **every**
workspace's branches at once (the whole tree, wherever the cursor sits), and `z`
again brings them back. It's the "usually I don't want to see all the branches,
occasionally I do" switch — a folded workspace shows just its own row, its diff/PR
badge restored and a dim `▸N` marking how many branches are hidden. The fold is a
durable, shared-on-disk view preference (like the full header and the pane width),
so every window agrees and it survives restarts; it is *not* cleared on `q`.

The canonical trunk checkout (the project's primary worktree) is never shown as a
switch target.

### Filter mode

`/` turns the sidebar into an incremental filter — fzf-style, but **in the
sidebar** (no popup, no external `fzf`; it's plain string matching). Useful once
you have enough workspaces that scrolling to one is slow.

| Key | Action while filtering |
|-----|------------------------|
| _(any printable key)_ | Append to the query. The rows narrow to fuzzy matches. |
| `Backspace` | Delete the last query character — and backspacing past an empty query exits filter mode (same as `Esc`). |
| `↑` / `↓` / `Ctrl-N` / `Ctrl-P` | Move the highlight (over matching workspaces *and* their project headers). |
| `↵` (Enter) | On a **workspace**: switch to it. On a **project header**: create a new workspace there (auto-named, no prompt). Either way, leave filter mode. |
| `Esc` | Cancel — restore the full tree, no switch. |

What it matches:

- **Fuzzy (subsequence), case-insensitive** — `afb` finds `app-feat-branch`.
- Against the **project name + each workspace's name** (and its current branch),
  so typing a project name narrows to its workspaces and typing a workspace name
  jumps straight to it. A project also matches on its name *alone*, so one with no
  workspaces yet still appears — that's how you reach it to create its first.
  (A workspace's older branch-history rows aren't separate matches — you reach the
  workspace, and its branches are there in the full tree.)
- Across the **whole tree, collapsed projects included** — the point is reaching
  *any* workspace fast, even one folded away. Matches stay grouped **under their
  project header** so you can see which project each belongs to. You enter on the
  first row (the top header) and the cursor snaps to the first workspace match as
  soon as you type, so type-then-`↵` jumps. Headers are selectable too: arrow up
  onto one and `↵` creates a new workspace in that project (the project-level
  action, since collapsing makes no sense while filtering).

The footer swaps to the filter legend (`↵ open · esc cancel`) and echoes your
live query plus a match count. Every printable key feeds the query (just like
fzf), so `j`/`k` type rather than move here — unlike the tree, where they're vi
movers; in filter mode navigation is the arrows or `Ctrl-N`/`Ctrl-P`. A welcome
side effect: no destructive key (`d`, `q`) can fire
by accident mid-search. The query is per-pane and transient — it isn't shared
across windows or remembered after you switch.

### How keys reach the sidebar

The sidebar reads keys in raw mode, one keypress at a time. Arrow keys arrive as
escape sequences (`Ctrl-N`/`Ctrl-P` are the single-byte equivalents). Two control
bytes are sent *to* the sidebar by tmux, not pressed by you:

- `C-l` — a "poke" to reload and redraw (sent on a session or window switch, and
  by background PR refreshes).
- `C-r` — the dedicated post-edit poke that re-reads config (sent after you edit
  config from the sidebar).

These are internal; you never type them. See
[Explanation: sidebar lifecycle](explanation-sidebar-lifecycle.md).

---

## Related

- [Reference: reading the sidebar](reference-sidebar.md) — what every dot, badge, and mark these keys act on means.
- [Reference: config](reference-config.md#tmux_keys) — the `tmux_keys` and [`sidebar_keys`](reference-config.md#sidebar_keys) schemas.
- [How-to: keybindings](howto-keybindings.md) — change the toggle key, bind home, remap the sidebar keys.
- [Reference: CLI](reference-cli.md) — `doctor` reports a bad or clobbered binding, and a bad sidebar-key remap.
