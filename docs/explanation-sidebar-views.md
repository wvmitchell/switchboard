# Explanation: the sidebar's views and keys

The view state the sidebar's panes share on disk (folds, the full header, width), the
per-process views (diff counts, the filter, the `?` overlay), and the configurable keys.
This is the full implementation detail [CLAUDE.md](../CLAUDE.md) points to; keep it current with the code.

## Shared project collapse (the same multi-process trick)

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

## Full header on every session (the same trick, one global flag)

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

## Global branch fold (issue #107 — the project-fold trick, one level down)

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

## Sidebar width (the same trick, holding a number)

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

## Workspace diff counts (off-paint, per-process, mtime-gated)

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

## Type-to-filter (the deliberately un-shared one)

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

## The `?` help overlay (issue #62 — the discoverable home for the keys)

`?` paints a full-pane key map over the tree (`render_help`); any real keystroke
dismisses it (except `→`/Space/`←`, which turn a multi-page overlay — see below).
`@help` is the flag — transient and per-process like `@filter`, NOT
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
focus in/out (`POKE_BYTES`) — must NOT dismiss it, or a background PR
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
no-flash paint as `render` (no full `\e[2J`), with a hint pinned to the bottom row.

**A short pane pages, it never cuts.** The map outgrew a normal pane (the tail it used
to drop was the tmux section — the one answer to "how do I hide this?"), so the body is
the pure `help_pages(rows, cols)`: `help_sections` (the head block, then one group per
`["", heading]` row of `Keymap.help_rows` + `tmux_help_rows` — grouped from the ROWS,
never by re-splitting drawn text; `help_lines` is just its flatten) packed greedily into
pages of `rows - 1` lines. A section that fits a page is never split (one taller than a
page splits by line, so nothing is lost), a separator landing at a page top is dropped,
and `rows < 2` is `[[]]` (hint only — a 0-line page would never fill). One page reads
`any key to close`, exactly as before; several read `1/2 · → more · other keys close` / `2/2 · ← back · other keys close`.
`→`/`Space` turn forward and `←` back (`HELP_PAGE_STEPS`), clamped at both ends so a
double-tap can't close it; any other real key still closes. `help_key` computes the page
count from `winsize` on every keypress rather than caching it from render: `handle`
dispatches a whole read before the next render, so a fast `?→` would see no count and
close. The flip side (both adversarial reviewers reproduced it): help repaints only every
`REFRESH`, so the pane can grow to one page between a paint of `2/2` and the next `→`,
which would dismiss and hand the rest of a held-arrow burst to the tree's resize — a
persisted width. So `@help_paged` makes the paging keys **sticky**: once an overlay has
shown more than one page (painted in `render_help` or keyed in `help_key`), `→`/Space/`←`
stay paging keys until it closes, and a regrown single page reads `1/1 · other keys close`.
`@help_page`/`@help_paged` are reset by `show_help`/`dismiss_help`, and the page is clamped
in `render_help` (the pane can shrink while help is open). `help_sections` truncs the PLAIN string
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

## Configurable in-sidebar keys (issue #108 — extending #15 to the TUI keys)

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

## Related

- [Explanation: the sidebar's lifecycle](explanation-sidebar-lifecycle.md) — why view state lives on disk.
- [Reference: reading the sidebar](reference-sidebar.md) — what each row shows.
- [Reference: keybindings](reference-keybindings.md) — every key, and how to remap it.
