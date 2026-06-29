# Reference: reading the sidebar

Everything the sidebar draws and what each mark means. The pane is narrow (~40
cols), so it leans on **glyphs and color** instead of words — this is the key to
those glyphs. For *why* the agent dots work the way they do, see
[Explanation: agent presence](explanation-agent-presence.md); for the keys that
act on what you see here, see [Reference: keybindings](reference-keybindings.md).

---

## Anatomy

```
 ◖═◗ Switchboard                 ← header: the wordmark, on every session.
 good evening, will                Home (or H everywhere) adds the dim
 4 worktrees · 2 active            greeting + console + rule below it.
 ─────────────────────

 ▾ myapp                         ← project header (▾ expanded / ▸ folded)
   ● oauth-refresh     +42 −7  #128     dot · name · diff count · PR badge
 » ⠹ snug-thistle      +5       #131    » = the session you're in (cyan name)
   ◆ flaky-tests       +18 −3           ◆ magenta = waiting on you
   ● api-rework                         expanded ↓ — its own diff + PR move
     ├ spike                    #61       down onto the branch-history rows
     └●main-path        +9      #74     ● before a branch = checked out now
 ▸ personal-site                 ← folded project (children hidden)

 nav · ? help                    ← footer (one line; ? opens the full map)
```

Left to right, a **workspace row** is four parts: the *gutter pointer* (`»` or
blank), the *agent dot*, the *name*, then two right-flushed columns — the *diff
count* and the *PR badge*. The diff and PR columns align across every visible row
so the numbers stack instead of staircasing.

---

## The header

| Form | Shown | Contains |
|------|-------|----------|
| **Wordmark** | every non-home session | just `◖═◗ Switchboard` (bold cyan) |
| **Full header** | the home session always; every session when toggled with `H` | wordmark + a time-of-day greeting (`good evening, will`) + a one-line console (`4 worktrees · 2 active · 3 PRs open`, zero clauses dropped) + a rule |

`H` toggles the full header onto **all** sessions at once. It's a shared on-disk
view preference, so every window follows and it survives a restart. See
[`H` in the keybindings](reference-keybindings.md) and
[`FullHeader`](explanation-sidebar-lifecycle.md).

---

## The tree

Three row kinds, indented by depth:

- **Project header** — `▾ name` when expanded, `▸ name` when folded (its
  workspaces hidden). Rendered **bold**. `↵` on it folds/unfolds; `n` creates a
  workspace in it. The fold is shared on disk and durable across restarts.
- **Workspace row** — one per worktree git reports, minus the project's primary
  (trunk) checkout, which is never a switch target. This is the row you act on.
- **Branch-history row** — when a workspace has held more than one branch over
  its life (you `git checkout -b` in place), it expands into inline child rows
  read from its HEAD reflog. Drawn with a `├`/`└` tree connector; a filled `●`
  before the branch name marks the branch **checked out right now**. `↵` on any
  of them switches to that one shared session — switchboard navigates you there,
  it doesn't check the branch out. Press [`z`](reference-keybindings.md) to fold
  these rows away tree-wide: each multi-branch workspace then shows just its own
  row, its diff/PR badge restored and a dim `▸N` marking the N hidden branches.
  `z` again unfolds. The fold is shared on disk and durable across restarts.

---

## The agent dot

The leftmost glyph after the pointer. Shape **and** color both carry the state,
so it reads on any terminal theme (the colors are plain ANSI palette entries, so
they follow your light/dark background).

| Glyph | Color | State | Motion |
|-------|-------|-------|--------|
| _(blank)_ | — | no agent / idle | — |
| `⠹` | blue | **thinking** — working a turn | braille spinner cycles |
| `◆` / `◇` | magenta | **waiting** — blocked on a permission prompt or question | blinks filled/hollow |
| `●` | green | **done** — finished its turn (your move) | steady |
| `✦` / `✧` | bright green | **just completed** — the completion sparkle | shimmers for ~3s, then settles to the steady `●` |

The sparkle is the visual twin of the completion sound: the instant an agent
reaches `:done`, its dot twinkles `✦`/`✧` for three seconds, then becomes the
steady green `●`. Only `:done` sparkles — `:waiting` already blinks for
attention.

Exact `thinking`/`waiting`/`done` needs the per-worktree hooks (automatic on
switchboard-created worktrees, or `switchboard enable-hooks`). A hook-less agent
(Codex, Aider, un-hooked Claude) still gets a coarser busy/idle dot, but never
the magenta `waiting`. See
[How-to: agent state & sounds](howto-agent-state-and-sounds.md) and
[Explanation: agent presence](explanation-agent-presence.md).

---

## The name

The workspace name, with two color states layered on top:

- **`»` + cyan name** — the workspace whose session **you're in right now**. The
  `»` gutter pointer is bold cyan (switchboard's signature accent) and the name
  is cyan, matching your shell prompt's directory color. The pointer is its own
  column, so "you are here" reads even where color is stripped (the highlighted
  row's reverse-video bar). One marker per pane.
- **Bold yellow name** — an **unviewed completion**: the agent there finished a
  turn (`:done`) or asked for input (`:waiting`) while you were looking
  elsewhere. It stays bold yellow until you actually look — switching into its
  session clears it, no input required. The workspace you're *currently in* is
  never marked (you're already watching it). This "bold until viewed" state is
  shared on disk so every window's sidebar bolds it consistently.

A normal, looked-at workspace with no running agent is plain text.

---

## Diff counts

Just left of the PR badge, each workspace/branch row shows how far its branch has
moved from base:

```
+42 −7      42 lines added, 7 deleted, vs the base ref
+5          only additions
−3          only deletions
(blank)     no diff, no base, or a clean 0/0 branch
```

- **`+adds` is green, `−dels` is red** — switchboard's palette (green = open/done,
  red = closed) and the universal diff convention.
- It counts **committed** work — `base...HEAD` (the merge-base range), not the
  working tree. An inline branch-history row diffs its *own* ref, not the
  workspace's HEAD.
- Counts of 1000+ abbreviate: `1.5k` (one decimal under 10k), `12k` (whole
  thereafter), so a huge diff can't swallow the name.
- The `+adds` and `−dels` sub-columns align across all visible rows.

**When a count is hidden:** the global [`diff_counts`](reference-config.md#top-level-keys)
config knob off (it then skips the `git diff` entirely, not just the label), or
on a workspace that's expanded into branch rows (the workspace's own count would
just duplicate its active branch row right below it). A merged/closed PR's row
still recomputes — `R` forces a refresh if origin fast-forwarded past it.

The counts refresh off the paint loop (on switch-in, idle, and right after an
agent finishes a turn — a finished turn likely just committed), never blocking
the render. See [issue #79 / #118 in CLAUDE.md](../CLAUDE.md) for the column math.

---

## PR badges

The rightmost column. The pane has no room for a state word, so a PR shows just
its **`#number`, colored by state**:

| Badge | Color | State |
|-------|-------|-------|
| `#128` | green | **open** |
| `#128` | yellow | **draft** |
| `#128` | magenta | **merged** |
| `#128` | red | **closed** |
| _(blank)_ | — | no PR |

Badges come from `gh`, cached on disk so the UI never blocks on the network. They
refresh automatically (on agent completion, on switch-in, and on a ~2-minute idle
backstop). A PR you merged or closed **on GitHub** fires no local signal — press
`R` to catch it. On a workspace expanded into branch rows, the badge moves to each
branch row (the active branch's own PR), so the workspace row leaves the column
blank. See [Explanation: architecture](explanation-architecture.md) on why PRs are
the one cached signal.

---

## The footer

One line, always ending in the `? help` gateway:

- **Normal:** the highlighted row's nav verb + `? help` — e.g. `open · ? help` on
  a workspace, `collapse · ? help` on a project. On the home session it shows the
  title; on an empty tree, the "press `a` to add a project" invite.
- **Filter mode (`/`):** three lines — your live query, an `↵ open · esc cancel`
  legend that tracks the highlighted row, and a workspace match count.

The footer only has room for the common keys. Everything else — `g`/`G`, `←`/`→`
resize, the `Ctrl-N`/`Ctrl-P` movement aliases, the filter and prompt sub-modes,
the diff-count meaning, and the tmux keys that operate the sidebar — lives in the
`?` overlay. Press `?` for the full key map; any key closes it.

---

## Related

- [Reference: keybindings](reference-keybindings.md) — the keys that act on every row here.
- [Explanation: agent presence](explanation-agent-presence.md) — why the dot, sound, and bold all ride one signal.
- [Explanation: sidebar lifecycle](explanation-sidebar-lifecycle.md) — why the view preferences (fold, full header, width) live on disk.
- [Reference: config](reference-config.md) — `diff_counts`, `sounds`, and the rest.
