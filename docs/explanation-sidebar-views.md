# Explanation: the sidebar's views and keys

How the sidebar decides what to show: folds, the full header and the pane width, which
every window's sidebar shares, and the diff counts, the filter and the `?` overlay,
which each sidebar keeps to itself. It also covers how the in-sidebar keys are remapped.

## Shared view state lives on disk

Every window's sidebar is its own process (see
[the sidebar's lifecycle](explanation-sidebar-lifecycle.md)). A fold or a width kept in
one process's memory would leave every other pane, and every respawn (toggling the
sidebar off and on, a new window, a reconcile), showing the old view. So the view
preferences you'd expect to stick are files on disk, the same way the agent dots and
bold names are.

Four pieces of view state work this way: project folds, the full header, the branch
fold and the width. They share one pattern:

- **Hydrated on every rebuild.** `rebuild` reads the value from disk on every reload,
  so a change made in one window shows up in the others on their next switch-in poke or
  while-visible scan.
- **Written through, and applied at once.** The toggle writes the file *and* updates the
  in-memory copy, so the pane you pressed the key in redraws in the same frame. (Width
  batches the write: see [below](#the-width-a-file-holding-a-number).)
- **Durable.** These are view preferences, not alerts, so `quit` doesn't clear them. A
  folded project stays folded across restarts.
- **Located by env var or `XDG_STATE_HOME`.** Each store has its own override variable,
  named below.

What differs is the shape of the file, and that decides how careful the write has to be.

### Project folds: one file per project

Pressing ↵ on a project header folds it (▸/▾), hiding its workspace rows. `Collapse`
(`collapse.rb`) keeps one file per collapsed project, named by a digest of the project
name and holding the name (`SWITCHBOARD_COLLAPSE_DIR`). A fold or unfold is then a single
atomic create or delete (`collapse` / `expand`), with no read-modify-write race. It's
built on the shared `KeyedMarkerStore`, like `Attention`.

`toggle_collapse` writes through and updates `@collapsed`.

`collapsed` cleans up a fold whose project is no longer configured, but only when it's
handed a non-empty project list. The key is a name, not a path it could check, so a
config that's briefly empty or fails to load can't wipe your folds.

### The full header: a file whose existence is the flag

The home session's sidebar always shows the full brand header: the wordmark, greeting,
console and rule (`Sidebar#header`). Every other session shows just the wordmark. `H`
puts the full header on *all* sessions.

`FullHeader` (`full_header.rb`) is a single marker file whose existence is the flag
(`SWITCHBOARD_FULL_HEADER_FILE`). A toggle is one idempotent create or delete. Since only
existence is ever read, never the contents, it doesn't need the temp+rename write that
`Collapse` uses for names.

`toggle_full_header` writes through and flips `@full_header`.

### The branch fold: one flag for the whole tree

A workspace that has held several branches expands into inline branch rows
(`Tree.nodes` / `Git.branch_history`), which covers the case of several PRs from one
workspace. Those rows are useful now and then and noise most of the time. `z` (issue #107)
folds *every* workspace's branch rows at once, wherever the cursor is; the ask was one
"toggle branches" key, not a per-row fold.

So it's modeled like `FullHeader`, not like `Collapse`: a single global existence flag
(`BranchFold`, `branch_fold.rb`, `SWITCHBOARD_BRANCH_FOLD_FILE`). It defaults to off,
so branches show, exactly as before #107, until you press `z`.

`toggle_branch_fold` writes through, flips `@fold_branches`, then puts the cursor back on
the row it was on, by path. Folding from a branch row lands you on its workspace.

**The fold is a row transform, not a rebuild.** It happens in `recompute_rows`
(`visible_tree`), so `z` is instant, and the delicate logic in `Tree`, the console and
the #90 diff suppression stays untouched. When folded, `visible_tree` drops every `br`
row and replaces each expanded `ws` row with a shallow clone marked `expanded: false`.
The clone carries its active branch's PR (precomputed in `fold_lookup` from the branch
rows it's hiding) and a `folded:` count.

That clone renders through the existing code with no special cases:

- `expanded: false` un-suppresses its own diff and PR badge, since the #90 suppression
  only applies while the branches are visible;
- the restored `pr` shows the badge;
- the diff cache hits the same `[path, branch, "ws"]` entry `refresh_diffs` already
  computes.

`@nodes` is left intact. `rebuild` reuses it, and `console` and `refresh_diffs` still
walk the original tree, so the PR count and the diff cache don't change; the clone lives
only in `@rows`.

The dim `▸N` cue (`fold_cue`) trails the folded workspace's name in both `plain` and
`colored`. Its width is taken from the name's budget, so the two render paths stay the
same visible width, which the `line` and right-region alignment depend on. Filter mode is
unaffected, since it already leaves out branch rows.

### The width: a file holding a number

The sidebar used to be a fixed 40 columns (`Tmux::SIDEBAR_WIDTH`), and `pin_if_resized`
re-asserted that on every paint, so a plain `resize-pane` was undone by the next pin. Now
`←`/`→` in the tree step the width by `WIDTH_STEP` columns per press (issue #78), and the
pin *respects* the width you chose.

`Width` (`width.rb`) is a single global file like `FullHeader` (`SWITCHBOARD_WIDTH_FILE`),
but it holds an integer. That value is *read*, so a torn write could misread, which is why
it uses `Collapse`'s atomic temp+rename. `resolved` clamps it to `[MIN, MAX]` and falls back
to `DEFAULT` (40) on a missing, garbled or torn file, so a bad read just sizes the pane
normally.

Where the width gets applied:

- **`Tmux.pin(pane, width = Width.resolved)`** defaults to it, so every cross-session
  caller pins to the saved width with no flash.
- **The sidebar's per-tick `pin_width`** passes its hydrated `@width`, to skip a disk read
  in the hot loop.
- **`spawn_sidebar`'s `-l`** uses the saved width too, but clamped by `fit_width` to the
  target window's `window_cols`, keeping `RESERVE_COLS` for the work pane. Otherwise a
  width chosen on a wide client would make `split-window` fail and leave a narrow client
  with no sidebar at all.

When the hydrated width has *changed*, `rebuild` clears `@geom` so the next
`pin_if_resized` actually re-pins. Otherwise that throttle would compare against the peer
pane's unchanged geometry, skip the pin, and leave the pane at the old width until some
cross-session re-pin.

**Holding an arrow key resizes smoothly.** `resize` only sets flags: it clamps `@width`
and sets `@resized`, with no I/O. `handle` drains a whole autorepeat burst, calling it
once per key, and then the run loop calls `commit_resize` *once* (one `Width.set` and one
`resize-pane`). `render` reflows to the new `winsize` on the next pass. So holding `←`/`→`
doesn't spawn a subprocess and write the disk on every repeat. `@geom` fixes itself on the
next `pin_if_resized`, which pins to the same `@width` and so never fights the resize.

In `/` filter mode, `←`/`→` do nothing. Their escape sequences aren't printable, so
`filter_key` ignores them; like `j`/`k`, they don't move anything there.

## Workspace diff counts

Each workspace and branch row shows `+adds −dels` for its branch against its base, just
left of the PR badge (issue #79). It's the committed difference, `base...HEAD`, not your
working tree.

### Why they're computed off the paint loop

A `git diff` per worktree is too slow to run while drawing, for the same reason the model
skips a per-worktree `git status` (`with_dirty: false`). So diff counts get the same
treatment as the agent dots and PR badges: a per-process `@diffs` cache, keyed
`[path, branch] => [logs/HEAD mtime, adds, dels]`, refreshed by `Sidebar#refresh_diffs`
outside the paint loop.

The cache isn't shared on disk, since a count isn't a view preference. And it isn't on
the every-3-second scan. It refreshes on exactly two triggers:

- **`reload`:** a switch-in, idle, or a tree tick;
- **the agent edge:** a finished turn has likely just committed.

`Git.diff_counts` uses `--numstat` rather than `--shortstat`, whose summary is localized
and would slip past a word regex on a non-English git. It uses `Git.range(base, ref)`, so
an inline branch row diffs its *own* ref, not HEAD.

### When the cache is trusted

The cache is keyed on the worktree's `logs/HEAD` mtime, stat'd fresh in `refresh_diffs`.
It deliberately doesn't reuse `@branch_cache[path][1]`, which refreshes only on
`rebuild`. The agent-edge caller has no rebuild, so a cached mtime would compare stale to
stale and miss the commit that just landed. Only the gitdir (`@branch_cache[path][0]`) is
reused; it's stable and already absolute. (A relative `.git` path is the bug that once
blanked the tree.)

`refresh_diffs` computes a value or nil, and deletes the entry on nil, so a row that
loses its cache slot, its base or its ability to diff clears instead of painting a ghost
count.

Two cases bypass the cache:

- **A merged or closed PR's row skips the mtime check.** When origin fast-forwards past a
  merged branch, `base...HEAD` drops to zero without `logs/HEAD` moving, which is a blind
  spot the PR badge has too.
- **`R` (`refresh_prs_now`) clears `@diffs`** as the manual catch-all.

### Drawing the counts

`View.diff_label` (plain, for width math) and `diff_tag` (green adds, red dels) mirror
the `pr_*` pair. They abbreviate counts of 1000 or more (`1.5k`), so a huge diff can't
swallow the name in a narrow pane.

**The counts and badges line up in fixed columns** (issue #118). Alignment is a property
of all the visible rows, not one row, so `line` can't size it alone. It used to
flush-right one `[diff, id]` block per row, which made the `+/−` and `#n` numbers
staircase. Now `Sidebar#column_widths(@rows)` measures three widths once per `render`:

- the `+adds` sub-column,
- the `−dels` sub-column,
- the `#pr` column.

It measures over the full `@rows`, which respects folds and the filter, not just the
rows on screen, so columns hold steady while you scroll; folding a noisy project tightens
them. The widths are passed into every `line`. Each cell right-justifies (`rjust`) into its column
(`right_region` → `diff_cell` / `pad_cell`), padding by the *plain* width and then
wrapping the ANSI, the same split `line` uses. The `+adds`, `−dels` and `#n` columns stay
flush to the right edge as before.

A missing cell becomes aligned blanks, not a gap that shifts its neighbor, so the #90
expanded-workspace suppression reads as clean empty columns. Single-row callers (tests)
don't pass the widths and fall back to the row's own, so a one-row column equals the row
and the output is unchanged.

On a narrow pane, the whole diff column is dropped first, keeping `MIN_NAME_COLS` for the
name. The decision is the same for every row, since `cols` and the widths are shared, so
columns can never split. `←`/`→` (#78) change `cols` live, so the columns are recomputed
on every render. Nothing here is shared on disk: each pane measures its own `@rows`,
which is all that matters, since you look at one pane at a time.

### When a row shows a count at all

One predicate decides, `Sidebar#diff_visible?`, which combines two gates `line` reads:

- **The `diff_counts` setting** (`Config#diff_counts?`, on by default, shaped like
  `agent_state_hooks?`; issue #88). When it's off, `refresh_diffs` returns early with
  `@diffs.clear`, so there are no `git diff` shell-outs at all, not just a hidden label.
  Turning it off live drops the cached counts on the next reload.
- **Expanded workspaces** (issue #90). When a workspace expands into per-branch rows, the
  `ws` row's count would just repeat its active branch row right below it, since the
  `ws` row diffs HEAD, which is the active branch. So `diff_visible?` drops it on the
  `ws` row, using the same `expanded` condition (carried on the `Tree::Node`) that
  already drops the PR badge there.

The redundant `git diff` for an expanded workspace is still *computed*, just never shown.
That was the deliberate trade in #90: gate it at render, and leave the mtime-checked
cache logic alone.

## Type-to-filter

`/` starts an incremental filter inside the sidebar (issue #60). It works like fzf, but
it isn't the external `fzf` popup that was removed; it's the same navigator, made
searchable.

`@filter` is `nil` when off, or the query string. `recompute_rows` switches on it to
`filtered_rows`, which keeps each project's matching workspace and branch rows *under
their header*, so the grouping you navigate by stays visible. A header with no matches is
dropped. Matching is the pure `Sidebar.fuzzy_match?` (a case-insensitive subsequence
match) over `filter_text` (the project plus the name or branch). The filter covers the
whole tree and ignores folds, since the point is to reach any workspace fast, folded or
not.

How it behaves:

- **The cursor jumps to the first match.** Starting the filter (`start_filter`) leaves the
  cursor on the first row, and each query keystroke moves it to the first matching
  workspace, so typing then pressing `↵` jumps straight there.
- **↵ depends on the row.** Headers are still selectable, and `↵`
  (`switch_to_filtered`) does the row's main action: a workspace switches, and a project
  header *creates a new workspace there* (`create(node)`). Folding means nothing mid-filter,
  so that's the useful project-level action.
- **Leaving is easy.** Backspacing past an empty query exits, like Esc.
- **Nothing destructive fires mid-search.** While `@filter` is set, `dispatch` sends every
  key to `filter_key`: printable keys extend the query, `↵` opens or creates, `Esc` cancels,
  and `d` and `q` are just letters.
- **The footer shows the search.** `footer` swaps to `filter_footer`: the live query, a
  `↵` label that follows the selected row, and a count of matching workspaces. The normal
  footer is the one-line `nav · ? help`; the `/` key itself is taught in the `?` overlay.

Movement in the tree is the arrows, `^N`/`^P`, or `j`/`k` (vi-style down and up). In
filter mode `j` and `k` are query letters, so movement there is the arrows and `^N`/`^P`
only, and any name stays reachable by typing (#60).

**The filter is deliberately not shared.** A search is something you're doing right now,
not a view preference, so it's a plain per-process variable. A background reload
re-applies it (recompute is filter-aware), but it's never saved, cleaned up, or seen by
another window's pane.

## The `?` help overlay

`?` draws a full-pane key map over the tree (`render_help`, issue #62). Any real
keystroke closes it, except `→`, Space and `←`, which turn pages when the map doesn't fit
(below). The `@help` flag is per-process and short-lived, like `@filter`, because opening
help is an action, not a preference.

It exists because the footer is limited by the pane's width. A *daily* user never found
`g`/`G`, because the old three-line legend had no room to teach them. Every key the footer
can't fit now lives in the overlay: `g`/`G`, `←`/`→`, the `^N`/`^P` aliases, the keys for
the filter and prompt modes, what the diff counts mean, and the tmux keys that operate the
sidebar.

### The footer points to it, in one line

Help you have to already know about isn't help, so `footer` always ends with `? help`.
And since the overlay holds the full reference, the footer dropped its two lines of
action keys. It's one line that changes with context (`nav · ? help`, where the nav verb
swaps between open, collapse and switch; on the home sidebar, the title; in an empty tree,
the invitation to add a first project; while you type a movement count, `3…`), which gives the tree two more rows. The old
`/ filter` and `+/− vs base` hints moved into the overlay. `filter_footer` keeps its three
lines, since it shows the live query, not key hints.

### Real keys close it; background pokes don't

While `@help` is set, `dispatch` sends every key to `help_key`. A real keystroke, even
`q`, only closes the overlay; it never passes through to an action.

The input loop also receives bytes that aren't keystrokes (`POKE_BYTES`): the `C-l` poke
for a switch or background refresh, the `C-r` config poke, and focus in and out. Those
must *not* close the overlay, or a background PR refresh would close it while you're
reading. (`filter_key` is robust against non-printables the same way.) Ignoring them is
safe:

- **`C-l`:** its reload and visibility update fix themselves through the `tick` backstop
  within `REFRESH`, and tick keeps running while help is open.
- **`C-r`:** can't coincide with help. You can't open the config editor with help up
  (`e` closes help first), and `C-r` isn't broadcast.
- **Focus:** cosmetic under a full-pane overlay.

`?` can't open mid-filter (there it's a query letter), so `@help` and `@filter` are never
both set.

### It doesn't animate

`pulsing?` returns false while `@help` is set, since a static screen shouldn't repaint on
the `PULSE` cadence. Closing isn't slowed: dismissal is input-driven, so the keypress wakes
`IO.select` at once and the next pass renders the tree. The gate only lengthens the idle
wake while help is up. `render_help` uses the same cursor-addressed, no-flash paint as
`render` (`\e[K` and `\e[0J`, never a full `\e[2J`), with a hint pinned to the bottom row.

### A short pane pages; it never cuts

The map outgrew a normal pane, and the part it used to cut off was the tmux section, the
one that answers "how do I hide this?". So the body comes from the pure
`help_pages(rows, cols)`, which packs `help_sections` greedily into pages of `rows - 1`
lines. `help_sections` is the head block, then one group per `["", heading]` row of
`Keymap.help_rows` plus `tmux_help_rows`. It groups from those rows, never by re-splitting
drawn text; `help_lines` is just its flattened form.

The packing rules:

- **Sections stay whole.** A section that fits on one page is never split. One taller
  than a page splits by line, so nothing is lost.
- **No blank tops.** A separator that would land at the top of a page is dropped.
- **Tiny panes still work.** With `rows < 2` the result is `[[]]`: just the hint, since a
  zero-line page would never fill.
- **The hint says what to do.** One page reads `any key to close`, as before. Several read
  `1/2 · → more · other keys close` / `2/2 · ← back · other keys close`.

`→` and Space go forward, `←` goes back (`HELP_PAGE_STEPS`). Paging stops at both ends,
so a double-tap can't close it. Any other real key still closes.

`help_key` computes the page count from `winsize` on every keypress instead of caching it
from the last render. `handle` processes a whole read before the next render, so a fast
`?` then `→` would otherwise see no page count and close the overlay.

That opened another hole, which both adversarial reviewers reproduced. Help only repaints
every `REFRESH`, so the pane can grow to fit one page between a paint of `2/2` and your
next `→`. That `→` would then close the overlay, and the rest of a held-arrow burst would
go to the tree's resize, changing your saved width. So `@help_paged` makes the paging keys
sticky: once an overlay has shown more than one page (painted in `render_help` or keyed in
`help_key`), `→`, Space and `←` stay paging keys until it closes, and a page that has grown
back to one reads `1/1 · other keys close`. `show_help` and `dismiss_help` reset
`@help_page` and `@help_paged`, and `render_help` clamps the page, since the pane can also
shrink while help is open.

`help_sections` truncates the *plain* string before wrapping it in ANSI (the `line()`
pattern), so truncation can never cut through an escape sequence.

### It shows your keys, not the defaults

`tmux_help_rows` works out, at render time, the tmux keys that operate the sidebar:

- **the toggle and home keys,** via `Config#tmux_key`;
- **your own pane-movement keys,** via `Tmux.pane_switch_keys`. switchboard splits the
  sidebar into your window but deliberately never binds a key to move between panes, so
  this is the step you'd otherwise have to know already.

`Tmux.pane_switch_keys` parses `tmux list-keys -T prefix` for `select-pane` bindings that
*move* (directional or `-t`, leaving out the mark flags `-m`/`-M`). It draws arrow names as
glyphs, collapses a full set of arrows or `hjkl` into one token, and memoizes the result
once, so the paint loop never asks tmux again.

It's best-effort, and either right or absent. It only reads the prefix table and a
literal `select-pane`, and it leaves out unusual setups (bindings wrapped in `if-shell`,
the root table) rather than show a key it made up. If it finds nothing, the row is dropped.
It runs `String#scrub` on tmux's output first, because a non-ASCII binding in a
non-UTF-8 locale could otherwise raise mid-regex and crash the render.

## Remapping the in-sidebar keys

The keys the sidebar's own input loop handles (`j`/`k`, `n`, `d`, `/`, `?` and so on) can
be remapped with a `sidebar_keys:` config map (issue #108). It's the in-pane sibling of
`tmux_keys:` from #15.

### One table drives everything

`Keymap` (`keymap.rb`, a `module_function` module) is the single source of truth. Its
ordered `ACTIONS` list has one `Action` per command, each carrying its name, its
remappable `default` key, and its fixed structural aliases (arrows, `^N`/`^P`, `^O`) that
always trigger it too. That one list feeds all three places keys show up, so they can't
drift apart:

- `Sidebar#dispatch`, from key to action;
- the `?` overlay (`Keymap.help_rows`), from action to the key it shows;
- `doctor`.

### Only printable single characters

The rule that took the most work to get right: **only a printable single character can be
configured.** `Config#valid_sidebar_key?` accepts one byte in `0x20–0x7E`. It's stricter
than `valid_tmux_key?` on purpose, because here switchboard, not tmux, interprets the key,
and it compares raw stdin bytes.

That one rule reserves every structural key for free. `↵` (the row's action), `Esc`,
`Backspace`, the resize arrows `←`/`→`, the `C-l`/`C-r` pokes, and focus in and out are all
non-printable. A remap can't shadow them, and `dispatch` handles them ahead of the keymap
lookup: the pokes and focus reports go to `poke` before a digit can start a count, and `↵`
and the resize arrows are a literal `case`. It also means a configured key can never collide with a fixed
alias (printable and non-printable never overlap), so the only possible collisions are
between two printable keys.

### Resolving collisions

`Keymap.resolve_with_collisions`, shared by `bindings`, `dispatch_map` and `collisions`,
resolves keys in `ACTIONS` order, and the first action to claim a key keeps it. A later
action whose key is already taken becomes unbound (nil) and `doctor` reports it. A key is
never bound twice.

The structural aliases are added to `dispatch_map` unconditionally, outside that contest,
so a letter lost to a collision still leaves movement working (`↓` and `^N` work whatever
`j` is bound to). You can't lock yourself out.

Bad config degrades the same way as everywhere else: an invalid value falls back to the
default, and a malformed file falls back to all defaults plus a `load_error`.

`Sidebar` builds `@keymap` (key to action, for dispatch) and `@bindings` (action to key,
for the overlay and footer hints) in `initialize`, and rebuilds them on every `rebuild`. So
editing the config with `e` (`reload_config_and_rebuild` → `reload` → `rebuild`) re-binds
the keys live.

### Digits: a count, unless you've bound them

Digits have one job in the tree, vim's movement count: `3j` moves down three rows. No
default action uses a digit, but `valid_sidebar_key?` lets you bind one, so the count only
claims a digit nothing is bound to. If you've put `toggle_branch_fold: "3"` in your config,
`3` keeps folding branches and never starts a count. For the same reason the `?` overlay's
move row says "takes a count" rather than showing `3j`: with digits remappable, a literal
example could point at a key that does something else.

A count lives in the sidebar process between keystrokes, since `3` and `j` often arrive in
separate reads. Every real key uses it up, whether it moves or not, so `3` then `z` folds
branches and leaves nothing behind for the next `j`. The tmux pokes are the exception: a
switch-in `C-l` or a peer's warm broadcast can land between your `3` and your `j`, so they
leave the count alone. Focus leaving the pane does clear it. That can't split a count
you're typing, and it keeps a forgotten digit from turning your next `j`, an hour later,
into a jump.

## Related

- [Explanation: the sidebar's lifecycle](explanation-sidebar-lifecycle.md) — why view state lives on disk.
- [Reference: reading the sidebar](reference-sidebar.md) — what each row shows.
- [Reference: keybindings](reference-keybindings.md) — every key, and how to remap it.
