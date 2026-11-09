# Reference: keybindings

Two key surfaces: the **tmux prefix keys** switchboard binds (to summon the
sidebar or jump home), and the **keys inside the sidebar** (to navigate and act
on the tree). Both are configurable: the tmux keys via
[`tmux_keys`](reference-config.md#tmux_keys), the sidebar keys via
[`sidebar_keys`](reference-config.md#sidebar_keys). A handful of
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
| `↑` / `↓` / `Ctrl-N` / `Ctrl-P` / `j` / `k` | `down` / `up` | Move the highlight down/up (across projects, workspaces, and a workspace's branch rows). Arrow, emacs, and vi spellings all work; only the `j`/`k` letters are remappable (the `↑`/`↓`/`Ctrl-N`/`Ctrl-P` aliases are fixed). Type a count first to move that many rows, as in vim: `3j` moves down three, `10k` up ten. The footer shows a count you've started (`3…`; [`count_indicator: false`](reference-config.md#top-level-keys) hides it), and any other key or leaving the pane drops it. A digit you've bound to an action in `sidebar_keys` keeps doing that action instead of counting. While you type a search, `j`/`k` go into the query instead. |
| `g` / `G` | `top` / `bottom` | Jump to the top / bottom of the tree. |
| `←` / `→` | _(fixed)_ | Narrow / widen the sidebar pane (2 cols per press; hold to resize smoothly). The width is shared across every window's sidebar and survives a restart. Inert while you type a search. |
| `/` | `filter` | Search the tree by name, highlighting matches. See [Search](#search) below. |
| `↵` (Enter) | _(fixed)_ | On a workspace/branch row: switch to its tmux session (creating it if needed). On a project header: collapse/expand it. |
| `a` | `add_project` | Add a project — register a local repo, clone a URL, or create a new repo (a small prompt). |
| `n` | `new_workspace` | Dispatch a new worktree + branch in the highlighted project, in the background: type a task for the agent (or `↵` for none, `Esc` to cancel). You stay put; the row shows `◌` while it builds and pings you when it's ready (`✘` if it fails). No name prompt — it gets a throwaway placeholder name you rename later with `r` (or let the agent name it). |
| `o` / `Ctrl-O` | `open_pr` | Open the highlighted PR in the browser (`gh pr view --web`). Only the `o` letter is remappable; `Ctrl-O` is a fixed alias. |
| `O` | `open_repo` | Open the highlighted row's repo in the browser (`gh browse`). Works on every row kind, including the project header. Opens the repo at the row's branch when it has an open PR, otherwise the repo home (default branch). |
| `p` | `phone_link` | On a row with a `⇅`, draw that session's phone link as a QR code to scan with your phone camera (`Tab` steps through several links, `←`/`→` resize, any other key closes). Does nothing on a row without a link. |
| `R` | `refresh_prs` | Refresh PR badges now (catch a PR merged/closed *on GitHub*). |
| `z` | `toggle_branch_fold` | Fold / unfold **every** workspace's branch-history rows at once — tree-wide, regardless of where the cursor is. A folded multi-branch workspace collapses to a single row that shows its own diff/PR badge plus a dim `▸N` cue (N branches tucked away). A shared on-disk view preference, so all sessions follow and it survives restarts. |
| `H` | `toggle_full_header` | Toggle the full header (wordmark + greeting + console + rule) on **every** session, not just home. A shared on-disk view preference, so all sessions follow and it survives restarts. |
| `r` | `rename` | Rename the highlighted workspace (moves the worktree dir, keeps branch + PR). |
| `d` | `delete` | Remove the highlighted row — delete a workspace and its local branches, or unregister a project (and close its sessions). Confirms first. On a `◌` row it cancels the build (after a confirm); on a `✘` row with no worktree yet it just dismisses it. |
| `e` | `edit_config` | Edit `config.yml` in `$EDITOR` (opens beside the home tree, returns you on quit). |
| `?` | `help` | Show the full key map overlay (nav + actions + search and prompt keys + the tmux keys that operate the sidebar). On a short pane it pages: `→`/`Space` next, `←` back. Any other key closes it. |
| `q` | `quit` | Quit switchboard — tear down every `sb/` session. Confirms first. |

A `sidebar_keys` value is a **single printable character**. That rule is what
keeps the structural keys reserved: `↵`, `Esc`, `Backspace`, the arrows, and the
`Ctrl-N`/`Ctrl-P`/`Ctrl-O` aliases are all non-printable, so a remap can never land
on one. `switchboard doctor` flags an invalid value or a clash (two actions on one
key) — the loser is left unbound, but any arrow/ctrl aliases it has still work, so you
can never lock yourself out of movement. See
[How-to: keybindings](howto-keybindings.md#change-the-in-sidebar-keys).

The footer shows only the row's nav verb and `? help`; the action keys, `g`/`G` and
the `Ctrl-N`/`Ctrl-P` movement aliases don't fit it — press `?` in the sidebar for
the complete key map, the in-app home for every shortcut.

Every name prompt (`a` add local/clone/new, `r` rename) edits in raw mode:
`Esc` (or `Ctrl-C`) cancels and returns to the tree with nothing created, `↵`
submits, `Backspace` edits, `Ctrl-U` clears the line. The prompt shows `(esc cancel)` until you start typing.

`↵` on a workspace **creates the session on first switch** and runs the project's
`session_command` then (only then — never on a re-switch into a live session). `n`
additionally runs the project's
[`worktree_creation_command`](reference-config.md#worktree_creation_command) — the
setup a brand-new worktree needs — *before* that agent command, and a failing setup
stops the agent starting. A
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

### Search

`/` searches the tree the way vim searches a buffer: matches are highlighted where they are,
and no row is hidden.

| Key | While typing the query |
|-----|------------------------|
| _(any printable key)_ | Add to the query. The cursor previews the first match from where you started. |
| `Backspace` | Delete the last character. Pressed on an empty query, it cancels. |
| `↵` (Enter) | With the cursor on the only match, a workspace: open it. A row that can't be opened yet shows why, and the search stays on. A workspace waiting on a prompt (`◆`) stops first, so a second `↵` can't land on that prompt. Otherwise, keep the search on and go back to the normal keys. With no matches, cancel. |
| `Tab` | Keep the search on and go back to the normal keys, even with one match. This is the way to use `o`, `r` or `d` on a unique name. With no matches, cancel. |
| `Esc` | Cancel and go back to where you started. |

The arrows, `Ctrl-N` and `Ctrl-P` do nothing while you type.

| Key | Once the search is on |
|-----|-----------------------|
| `n` / `N` | Next / previous match, wrapping at the ends. Takes a count, as in `3n`. These two aren't remappable, and they mean new workspace again once the search ends. A `filter` key bound to `n` or `N` won't start a new search until this one ends. |
| `Esc` | End the search and leave the cursor where it is. |
| `↵` (Enter) | On a workspace or branch: end the search and open it. A row that can't be opened yet shows why, and the search stays on. On a project header: end the search and stop; a further `↵` folds or unfolds as usual. |
| `/` | Start a new search from the current row. |
| _(everything else)_ | Works as usual, with the matches still highlighted. |

What it matches:

- **A literal, case-insensitive piece of a name:** a workspace's or a project's. Only ASCII
  characters can be typed into the query. Branch names, task notes and PR numbers aren't
  searched. Once the search is on, `j` and `k` still reach a branch row, and `o` there opens
  its PR.
- **Across the whole tree.** A project with a match inside unfolds while the search is on, in
  this sidebar only. When the search ends it folds again, except the project your cursor is
  in, which stays open until you fold it, press `Esc` on a search elsewhere or leave the
  pane. Your shared folds never change.

With no matches left, say because a workspace was renamed, the search stays on and `n`/`N`
do nothing until you press `Esc`, so `n` can't turn into new workspace behind your back.

The footer shows the query, your place among the matches (`[2/5]`, or `[-/5]` when the cursor
isn't on one) and the keys. A search belongs to one pane and ends when that pane leaves the
screen, though a quick switch away and back can find it still on. A sidebar hot reload also
ends it.

### How keys reach the sidebar

The sidebar reads keys in raw mode, one keypress at a time. Arrow keys arrive as
escape sequences (`Ctrl-N`/`Ctrl-P` are the single-byte equivalents). Three control
bytes are sent *to* the sidebar by tmux, not pressed by you:

- `C-l` — a "poke" to reload and redraw (sent on a session or window switch, and
  by background PR refreshes).
- `C-r` — the dedicated post-edit poke that re-reads config (sent after you edit
  config from the sidebar).
- `C-w` — a peer sidebar's broadcast to repaint now (sent after a fold or header toggle,
  a project-list change, or a workspace being dispatched or canceled).

These are internal; you never type them. See
[Explanation: sidebar lifecycle](explanation-sidebar-lifecycle.md).

---

## Related

- [Reference: reading the sidebar](reference-sidebar.md) — what every dot, badge, and mark these keys act on means.
- [Reference: config](reference-config.md#tmux_keys) — the `tmux_keys` and [`sidebar_keys`](reference-config.md#sidebar_keys) schemas.
- [How-to: keybindings](howto-keybindings.md) — change the toggle key, bind home, remap the sidebar keys.
- [Reference: CLI](reference-cli.md) — `doctor` reports a bad or clobbered binding, and a bad sidebar-key remap.
