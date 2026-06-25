# Reference: keybindings

Two key surfaces: the **tmux prefix keys** switchboard binds (to summon the
sidebar or jump home), and the **keys inside the sidebar** (to navigate and act
on the tree). The tmux keys are configurable via `tmux_keys`; the sidebar keys
are fixed.

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
workspace, or branch). The legend at the bottom of the pane is context-sensitive —
it shows the keys that apply to the current row.

| Key | Action |
|-----|--------|
| `j` / `k` / `↑` / `↓` / `Ctrl-N` / `Ctrl-P` | Move the highlight down/up (across projects, workspaces, and a workspace's branch rows). vi, arrow, and emacs spellings all work. |
| `g` / `G` | Jump to the top / bottom of the tree. |
| `↵` (Enter) | On a workspace/branch row: switch to its tmux session (creating it if needed). On a project header: collapse/expand it. |
| `a` | Add a project — register a local repo or clone a URL (a small prompt). |
| `n` | Create a new worktree + branch in the highlighted project, and drop you in. |
| `o` / `Ctrl-O` | Open the highlighted PR in the browser (`gh pr view --web`). |
| `R` | Refresh PR badges now (catch a PR merged/closed *on GitHub*). |
| `r` | Rename the highlighted workspace (moves the worktree dir, keeps branch + PR). |
| `d` | Remove the highlighted row — delete a workspace, or unregister a project (and close its sessions). Confirms first. |
| `e` | Edit `config.yml` in `$EDITOR` (opens beside the home tree, returns you on quit). |
| `q` | Quit switchboard — tear down every `sb/` session. Confirms first. |

The footer legend shows only the common keys for the highlighted row; `g`/`G` and
the `Ctrl-` movement aliases are unshown power-user shortcuts.

`↵` on a workspace **creates the session on first switch** and runs the project's
`session_command` then (only then — never on a re-switch into a live session). A
workspace that has held more than one branch expands into inline branch rows
(read from its HEAD reflog) you move between with the same `j`/`k`. Those rows are
history with their PR badges — `↵` on any of them switches to that one worktree's
session (they all share it); switchboard doesn't check the branch out for you.

The canonical trunk checkout (the project's primary worktree) is never shown as a
switch target.

### How keys reach the sidebar

The sidebar reads keys in raw mode, one keypress at a time. Arrow keys arrive as
escape sequences and are mapped to `j`/`k`. Two control bytes are sent *to* the
sidebar by tmux, not pressed by you:

- `C-l` — a "poke" to reload and redraw (sent on a session or window switch, and
  by background PR refreshes).
- `C-r` — the dedicated post-edit poke that re-reads config (sent after you edit
  config from the sidebar).

These are internal; you never type them. See
[Explanation: sidebar lifecycle](explanation-sidebar-lifecycle.md).

---

## Related

- [Reference: config](reference-config.md#tmux_keys) — the `tmux_keys` schema.
- [How-to: keybindings](howto-keybindings.md) — change the toggle key, bind home.
- [Reference: CLI](reference-cli.md) — `doctor` reports a bad or clobbered binding.
