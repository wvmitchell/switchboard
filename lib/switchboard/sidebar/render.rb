# frozen_string_literal: true

module Switchboard
  class Sidebar
    # Rendering (#57): the model -> frame half of the sidebar — every paint
    # path (render/render_help), the row formatter and its fixed columns, the
    # glyph/dot state resolution, header/footer/console, and the ? overlay
    # lines. A concern module, not an object: a frame reads a dozen-plus ivars
    # of live view state, so the honest seam is one class in several files
    # (state ownership stays in Sidebar; see CLAUDE.md conventions).
    module Render
      # Agent-state icons. Idle (no agent) draws a blank slot, so the column only
      # lights up when something's there. Motion lives in the GLYPH (the spinner
      # cycles, the diamond blinks) — driven by @pulse on the PULSE repaint — so
      # each state needs only a single palette ANSI color that follows the
      # terminal's light/dark theme for free. No 256-color ramp, no bg detection.
      #
      # Two forms per animated state: a bare glyph (`glyph_for`, used on the
      # reverse-video selected row where color is stripped but shape survives) and
      # a pre-built colored string (`dot_for`, normal rows — built once, no
      # per-frame allocation). Thinking cycles a braille spinner; waiting blinks a
      # filled/hollow diamond; done is a steady dot.
      SPIN_FRAMES  = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze              # thinking: bare spinner glyphs
      SPIN_COLORED = SPIN_FRAMES.map { |g| "\e[1;34m#{g}\e[0m" }.freeze # ...pre-built in blue
      WANTS_ON  = "\e[1;35m◆\e[0m"  # input needed: magenta diamond, lit
      WANTS_OFF = "\e[1;35m◇\e[0m"  # ...and hollow, the blink's off-beat
      DONE      = "\e[1;32m●\e[0m"  # green: replied, ready for you (not blocked)
      MONITORING = "\e[1;32m∞\e[0m" # a background monitor/loop runs continuously here. Shares DONE's green ON PURPOSE — the ∞ glyph (not a new color) distinguishes it from ●, so the palette stays tight. Steady, so it stays off the pulse cadence — dormancy preserved.
      BLINK_PERIOD = 4             # @pulse ticks per blink half-cycle (~0.5s at PULSE)

      # Completion twinkle — the visual twin of the sound: a brief ✦/✧ shimmer when a
      # hooked agent's turn lands (:done), settling to the steady DONE dot. Bright
      # green so it reads a touch louder than DONE for the moment it lasts. Two forms,
      # like the spinner: a bare glyph for the reverse-video selected row (shape
      # survives, color is stripped) and a pre-built colored string for normal rows.
      SPARKLE_GLYPHS  = %w[✦ ✧].freeze
      SPARKLE_COLORED = SPARKLE_GLYPHS.map { |g| "\e[1;92m#{g}\e[0m" }.freeze

      # The "you are here" pointer: marks the session's current workspace with SHAPE,
      # not just the cyan name, so it reads without relying on color. One column,
      # dropped into the otherwise-blank ws gutter, so the 4-col prefix — and name
      # alignment, and the badge math off it — is unchanged; blank on every other row.
      CURRENT_MARK = "»"

      BRANCH_FG = "\e[90m"         # branch rows: bright-black, a theme-relative dim (#23)

      MIN_NAME_COLS = 3            # below this many cols left for the name, drop the diff
                                   # badge so a row never overruns the pane (issue #79)

      # Key-hint legend, built by `footer` (below) and kept within the pin width.
      # Reload isn't shown — it's automatic; Ctrl-L triggers it internally (the
      # session-switch hook poke). The first line is the session label: in the home
      # session it's the "you are at the base" title (HOME_TITLE), otherwise the
      # navigation keys, which differ by row kind (a project opens/collapses).
      HOME_TITLE = "switchboard · home"
      # The home sidebar's brand header (crafted, home-only — see `header`). The
      # wordmark gives the name presence beyond the footer; the ◖═◗ motif reads as a
      # patch cable plugged between two jacks — the telephone switchboard the tool is
      # named for. Bold cyan is switchboard's signature accent (the "you are here" hue).
      BRAND    = "\e[1;36m"
      WORDMARK = "◖═◗ Switchboard"

      NAV_PROJ   = "↑↓ move · ↵ open/collapse"
      NAV_WS     = "↑↓ move · ↵ open"
      # No NAV_BR: a branch row's ↵ opens its workspace's session — the SAME session
      # as the ws row (one session per worktree, keyed on path not branch), never a
      # branch checkout (swapping branches under a working agent is a footgun). So it
      # shares NAV_WS's honest "open"; a "switch" label would imply a checkout it
      # never does — and shouldn't.

      # The `?` overlay's key map is built at render time from the resolved bindings
      # (Keymap.help_rows, issue #108) so the shown keys can never drift from what
      # dispatch honors — [key, description] rows, a blank key marking a section
      # heading. Top-loaded with navigation, so a short pane drops the tail, not the
      # top. The tmux-layer keys that operate the sidebar (prefix-toggle/home) are
      # appended from config (tmux_help_rows), resolved, not static.
      HELP_KEY_COLS = 6 # key column width; longer combos (move/prefix rows) overflow it

      private

      def winsize
        $stdout.winsize
      rescue StandardError
        [40, 40]
      end

      # A SINGLE line: the context-sensitive nav verb + the `? help` gateway. The
      # action keys (a/n/o/O/r/d/e/R/H/q) used to be crammed into two more lines ONLY
      # because the footer was the sole place to teach them; the #62 overlay is now the
      # complete reference, so the footer sheds the tail and gives those two rows back
      # to the tree. `? help` is the always-on pointer to everything dropped — a help
      # you must already know `?` to find would be circular. One line for every row
      # kind, so the tree never reflows as the cursor moves (the nav verb swaps:
      # open/collapse/switch; the home session shows its title instead). The empty tree
      # (fresh install) shows the first-project invite in place of nav.
      def footer
        return filter_footer if @filter
        # empty tree: invite the first project (the add key resolved live, #108)
        return ["#{key_hint(:add_project)} add a project · #{help_hint}"] unless current

        # ws AND br both open the worktree session, so they read alike (NAV_WS).
        nav = current.kind == "proj" ? NAV_PROJ : NAV_WS
        ["#{@home ? HOME_TITLE : nav} · #{help_hint}"]
      end

      # The persistent "? help" gateway, the ? resolved from the live bindings so a
      # remapped help key shows correctly (issue #108).
      def help_hint
        "#{key_hint(:help)} help"
      end

      # An action's resolved key for a footer hint, falling back to its default when
      # the binding was collision-dropped (doctor reports the clash) so the hint
      # never shows a blank. This DELIBERATELY diverges from the `?` overlay, which
      # shows a `—` for a dropped binding (Keymap.help_rows): the one-line footer
      # prefers a non-blank best-effort key, while the overlay + doctor are the
      # authoritative surfaces for the rare misconfigured-collision case.
      def key_hint(action)
        @bindings[action] || Keymap::DEFAULTS[action]
      end

      # The filter-mode legend: the live query, then the in-mode keys. j/k are query
      # input here (unlike the tree, where they move), so movement is the arrows
      # / ^N^P. ↵ is context-sensitive — opens a highlighted workspace, or creates a
      # new one on a highlighted project header — so the label tracks the row. The
      # count is workspaces only (headers don't count) — it reassures you the query is
      # biting (and a 0-match query isn't a frozen pane). Three lines: filter mode is
      # live state (query + action + count), not key-teaching, so unlike the slimmed
      # one-line normal footer it keeps the room it needs; entering/leaving the mode is
      # a deliberate switch, so the height change there is fine (the tree changes too).
      def filter_footer
        n = @rows.count { |node| node.kind != "proj" }
        count = n == 1 ? "1 match" : "#{n} matches"
        action = current&.kind == "proj" ? "↵ new workspace" : "↵ open"
        ["/#{@filter}", "#{action} · esc cancel", "↑↓ ^n/^p move · #{count}"]
      end

      # The brand header above the tree. EVERY session leads with the wordmark, so the
      # name has presence beyond the footer in any pane — a minimal one-liner on a
      # focused worktree session. The HOME sidebar (switchboard's anchor, where the
      # tree is short and base-camp framing fits) additionally seats a time-of-day
      # greeting, a one-line console of what the board is handling, and a rule — and
      # the `H` toggle (@full_header, shared on disk) extends that same full header to
      # every other session. Each line carries its own ANSI and is fit to `cols`; only
      # the wordmark wears the accent.
      def header(cols)
        wordmark = "#{BRAND}#{trunc(WORDMARK, cols)}\e[0m"
        return [wordmark] unless @home || @full_header

        [
          wordmark,
          "\e[2m#{trunc(greeting, cols)}\e[0m",
          "\e[2m#{trunc(console, cols)}\e[0m",
          "\e[2m#{'─' * cols}\e[0m"
        ]
      end

      # First name for the home greeting, from git's global identity (falling back to
      # $USER), downcased to match the sidebar's lowercase voice. nil when we can't
      # tell — the greeting then drops the name. Called once, lazily, from greeting
      # (memoized there); degrades to nil on any failure, like every other shell-out here.
      def operator_name
        name = `git config user.name 2>/dev/null`.strip
        name = ENV["USER"].to_s if name.empty?
        first = name.split.first
        first && !first.empty? ? first.downcase : nil
      rescue StandardError
        nil
      end

      # Time-of-day greeting for the home header, by name when we know the operator.
      # The name is resolved once here (lazy + memoized; nil is a valid result, so the
      # uncomputed sentinel is `false`) — only a home pane that renders a greeting ever
      # shells out. The time part is recomputed each paint (cheap), tracking the clock.
      def greeting
        @operator = operator_name if @operator == false
        part = case Time.now.hour
               when 0...12  then "morning"
               when 12...18 then "afternoon"
               else              "evening"
               end
        @operator ? "good #{part}, #{@operator}" : "good #{part}"
      end

      # One-line operator console for the home header: how many workspaces the board
      # is patching, how many agents are working right now, how many PRs are open.
      # Counts the whole tree (@nodes) so a collapsed project still tallies; the
      # active/PR clauses drop when zero to keep the line calm. Terse to fit the pane.
      def console
        trees  = @nodes.count { |n| n.kind == "ws" }
        active = @agents.values.count(:thinking)
        prs    = @nodes.count { |n| n.pr.is_a?(Hash) && View.pr_state(n.pr) == "OPEN" }
        parts  = ["#{trees} #{trees == 1 ? 'worktree' : 'worktrees'}"]
        parts << "#{active} active"                       if active.positive?
        parts << "#{prs} #{prs == 1 ? 'PR' : 'PRs'} open" if prs.positive?
        parts.join(" · ")
      end

      def render
        return render_help if @help # the ? overlay replaces the tree (issue #62)

        rows, cols = winsize
        head = header(cols)
        foot = footer
        head = [] if rows - foot.size - head.size < 1 # too short to seat both — tree first
        top = head.size
        height = rows - foot.size - top
        scroll(height)

        visible = @rows[@offset, height].to_a
        @visible_rows = visible # the on-screen slice — pulsing? animates only for these
        adds_w, dels_w, pr_w = column_widths(@rows) # fixed columns, measured once (#118)
        out = +"\e[H"
        head.each_with_index do |text, i|
          out << "\e[#{i + 1};1H\e[K#{text}" # header lines carry (and reset) their own ANSI
        end
        visible.each_with_index do |node, i|
          active = @offset + i == @cursor
          out << "\e[#{top + i + 1};1H\e[K" << line(node, active, cols, adds_w: adds_w, dels_w: dels_w, pr_w: pr_w)
        end
        # Erase rows left over from a previous, longer state (e.g. after a
        # collapse), then draw the footer hints on the bottom rows.
        out << "\e[#{top + visible.size + 1};1H\e[0J"
        foot.each_with_index do |text, i|
          out << "\e[#{rows - foot.size + 1 + i};1H\e[K\e[2m#{trunc(text, cols)}\e[0m"
        end
        $stdout.write(out)
      end

      # The ? help overlay (issue #62). Paints the full key map with the same
      # cursor-addressed \e[K / \e[0J no-flash technique as render (no full \e[2J, so
      # the per-tick repaint while it's open doesn't flicker), with a dim "any key to
      # close" hint pinned to the bottom row. The body comes from help_body, capped so
      # the hint always seats.
      def render_help
        rows, cols = winsize
        lines = help_body(rows, cols)
        out = +"\e[H"
        lines.each_with_index do |text, i|
          out << "\e[#{i + 1};1H\e[K#{text}" # each line carries (and resets) its own ANSI
        end
        out << "\e[#{lines.size + 1};1H\e[0J" # erase below the last line (incl. any old footer)
        out << "\e[#{rows};1H\e[K\e[2m#{trunc('any key to close', cols)}\e[0m"
        $stdout.write(out)
      end

      # The overlay's lines, capped to leave the bottom row for the "any key to close"
      # hint. A short pane drops the tail (HELP is top-loaded with navigation), never
      # the top. Pure given winsize + @config, so the height-cap is unit-testable
      # without raw I/O — the suite keeps render-to-stdout out of scope.
      def help_body(rows, cols)
        help_lines(cols).first([rows - 1, 0].max)
      end

      # Format the key map (Keymap.help_rows, built from the live @bindings so the
      # shown keys never drift — issue #108) plus the resolved tmux rows into rendered
      # lines: the wordmark, then each section as a blank separator + bold heading, and
      # each key row as `key.ljust(HELP_KEY_COLS)  desc`. trunc runs on the PLAIN string
      # BEFORE the ANSI is wrapped on, so truncation can never cut an escape (line()).
      def help_lines(cols)
        out = ["#{BRAND}#{trunc(WORDMARK, cols)}\e[0m"]
        (Keymap.help_rows(@bindings) + tmux_help_rows).each do |key, desc|
          if key.empty?
            out << "" << "#{BRAND}#{trunc(desc, cols)}\e[0m" # blank separator, then the heading
          else
            out << trunc("#{key.ljust(HELP_KEY_COLS)}  #{desc}", cols)
          end
        end
        out
      end

      # The tmux-layer keys that operate the sidebar itself, resolved at render time
      # (the prefix is needed first, unlike the in-pane keys — the heading says so).
      # `show / hide` answers "how do I hide this whole thing?" (no in-sidebar key does
      # — q quits everything); `move between panes` surfaces the user's OWN select-pane
      # keys (Tmux.pane_switch_keys, memoized), the implicit step switchboard never
      # binds. toggle defaults to "s"; home + pane-switch rows drop when unbound/undetected.
      def tmux_help_rows
        toggle = @config.tmux_key("toggle")
        home   = @config.tmux_key("home")
        switch = (@pane_switch_keys ||= Tmux.pane_switch_keys)
        rows = [["", "tmux (operate the sidebar)"]]
        rows << ["prefix #{toggle}", "show / hide the sidebar"] if toggle
        rows << ["prefix #{switch.join(' ')}", "move between panes"] if switch.any?
        rows << ["prefix #{home}", "jump to the home session"] if home
        rows
      end

      def scroll(height)
        @offset = @cursor if @cursor < @offset
        @offset = @cursor - height + 1 if @cursor >= @offset + height
        @offset = 0 if @offset.negative?
      end

      # The three right-hand columns are a property of the whole visible row set,
      # not a single row (#118), so they're measured once here and threaded into
      # every line — letting the +adds, −dels, and #n numbers each stack into a
      # straight column. Measured over the full @rows (collapse-/filter-aware), NOT
      # the on-screen slice, so the columns stay put while you scroll instead of
      # reflowing each keypress; folding a noisy project naturally tightens them.
      # Projects carry no cells and so don't size the columns. Returns the adds /
      # dels sub-column widths and the PR column width.
      def column_widths(rows)
        adds_w = dels_w = pr_w = 0
        rows.each do |node|
          next if node.kind == "proj"

          pr_w = [pr_w, View.pr_identifier(node.pr).length].max
          adds, dels = View.diff_parts(diff_visible?(node) ? diff_for(node) : nil)
          adds_w = [adds_w, adds.to_s.length].max
          dels_w = [dels_w, dels.to_s.length].max
        end
        [adds_w, dels_w, pr_w]
      end

      # The plain width the right region reserves: the diff column (the two sub-
      # columns plus their separator, when both seat) then the PR column, with a
      # 2-col gap between them only when both are present.
      def region_width(diff_w, pr_w)
        w = diff_w + pr_w
        w += 2 if diff_w.positive? && pr_w.positive?
        w
      end

      def line(node, active, cols, adds_w: nil, dels_w: nil, pr_w: nil)
        # The flush-right region is the diff count then the PR identifier ("+22 −333
        # #12"), each right-justified into a fixed column so they stack down the
        # tree (#118). Reserve its plain width (plus a gap) so the name truncates to
        # fit rather than overrunning.
        id = node.kind == "proj" ? "" : View.pr_identifier(node.pr)
        counts = diff_visible?(node) ? diff_for(node) : nil
        adds, dels = View.diff_parts(counts) # plain "+22" / "−333", nil where zero

        # Column widths are threaded from render; single-row callers (and tests)
        # fall back to this row's own widths — a one-row column equals the row, so
        # the output is unchanged. Projects carry neither, so they get the full width.
        adds_w ||= adds.to_s.length
        dels_w ||= dels.to_s.length
        pr_w   ||= id.length
        adds_w = dels_w = pr_w = 0 if node.kind == "proj"
        diff_w = adds_w + dels_w + (adds_w.positive? && dels_w.positive? ? 1 : 0)

        # Too narrow to seat name + diff + badge? Drop the whole diff column first —
        # uniformly across rows, since cols/widths are shared, so the columns never
        # split (the badge is the more essential signal). Reachable only on a hand-
        # narrowed pane with a huge diff AND a long PR number.
        region_w = region_width(diff_w, pr_w)
        if diff_w.positive? && cols - region_w - 1 < MIN_NAME_COLS
          adds_w = dels_w = diff_w = 0
          region_w = region_width(diff_w, pr_w)
        end
        left_cols = region_w.zero? ? cols : [cols - region_w - 1, 1].max
        text = trunc(plain(node), left_cols)

        # The reverse-video cursor bar only when the sidebar is the focused pane;
        # off-focus the cursor row renders like any other, so the bright bar never
        # tugs at your eye while you're working in the pane beside it. The diff/badge
        # go plain here so they read under the inverted bar.
        if active && @focused
          right = right_region(counts, node.pr, adds_w, dels_w, pr_w, with_color: false)
          bar = region_w.zero? ? text : "#{text.ljust(left_cols)} #{right}"
          return "\e[7m#{bar.ljust(cols)}\e[0m"
        end

        body = colored(node, text, current: node.kind == "ws" && node.path == @current_path)
        return body if region_w.zero?

        # `colored` preserves `text`'s visible width, so pad off the plain region
        # width (right_region pads each cell off its plain length, then wraps ANSI).
        right_colored = right_region(counts, node.pr, adds_w, dels_w, pr_w, with_color: true)
        pad = [cols - text.length - region_w, 1].max
        "#{body}#{' ' * pad}#{right_colored}"
      end

      # The fixed-width right region: [+adds][ ][−dels]  [#pr], each (sub)cell
      # right-justified into its column so the numbers stack vertically (#118). An
      # absent cell renders as aligned blanks, not a gap that shifts its neighbor.
      # The plain cell text is re-derived from counts/pr here (not threaded) so the
      # call sites pass only the source + the cross-row widths. with_color: false
      # gives the plain form (width math / the reverse-video bar); true wraps ANSI —
      # width math stays on the plain strings either way.
      def right_region(counts, pr, adds_w, dels_w, pr_w, with_color:)
        id = View.pr_identifier(pr)
        cells = []
        cells << diff_cell(counts, adds_w, dels_w, with_color: with_color) if adds_w.positive? || dels_w.positive?
        cells << pad_cell(id, with_color ? View.pr_tag(pr) : id, pr_w) if pr_w.positive?
        cells.join("  ")
      end

      # The diff column: the adds sub-cell and dels sub-cell, each right-justified
      # into its sub-column (so +adds stack and −dels stack), joined by one space.
      def diff_cell(counts, adds_w, dels_w, with_color:)
        adds, dels = View.diff_parts(counts)
        styled_adds, styled_dels = with_color ? View.diff_tag_parts(counts) : [adds, dels]
        parts = []
        parts << pad_cell(adds, styled_adds, adds_w) if adds_w.positive?
        parts << pad_cell(dels, styled_dels, dels_w) if dels_w.positive?
        parts.join(" ")
      end

      # Right-justify one cell into its column: pad off the PLAIN string's width,
      # then emit the (possibly ANSI-wrapped) content — so color never throws the
      # width off. An empty cell becomes width spaces (the aligned blank).
      def pad_cell(text, styled, width)
        (" " * [width - text.to_s.length, 0].max) + styled.to_s
      end

      # Plain (no color) — used for the highlighted row and as the base text. The
      # ws prefix is always 4 cols ("  X ") so names line up whether or not a dot is
      # present; idle leaves the dot slot blank. The dot carries the live, uncolored
      # state glyph (`glyph_for`): under the reverse-video cursor bar color is
      # stripped but the spinner/diamond/dot SHAPE survives, so the selected row
      # still shows what its agent is doing.
      def plain(node)
        case node.kind
        when "proj"
          # In filter mode the children show regardless of fold, so the header always
          # reads expanded (▾); the ▸ collapsed glyph only applies to the normal tree.
          folded = @filter.nil? && @collapsed.include?(node.project)
          "#{folded ? '▸' : '▾'} #{node.project}"
        when "ws"   then "#{pointer(node.path)} #{ws_glyph(node.path)} #{node.name}#{fold_cue(node)}"
        else             "     #{node.last ? '└' : '├'}#{node.active ? '●' : ' '}#{node.branch}"
        end
      end

      # The " ▸N" cue trailing a folded multi-branch workspace's name — N branch rows
      # tucked away by the global `z` fold (issue #107). "" for every other row (folded
      # is only set on a fold_ws clone). Plain here for width math; colored() wraps it
      # in the dim SGR, reserving this same width off the name budget so the two paths
      # stay the same visible width (the line()/right-region alignment depends on it).
      def fold_cue(node)
        node.folded ? " ▸#{node.folded}" : ""
      end

      # The bare (uncolored) "you are here" gutter pointer for a workspace path —
      # CURRENT_MARK for the session's current workspace, a blank otherwise. Shared by
      # plain (so the marker survives under the reverse-video cursor bar, where color
      # is stripped but shape isn't); colored builds its own bold-cyan form.
      def pointer(path)
        path == @current_path ? CURRENT_MARK : " "
      end

      def colored(node, text, current: false)
        case node.kind
        when "proj" then "\e[1m#{text}\e[0m"
        when "ws"
          dot = sparkling?(node.path) ? SPARKLE_COLORED[(@pulse / 2) % SPARKLE_COLORED.size] : dot_for(render_state(node.path))
          # The " ▸N" fold cue is appended ONLY when its full width was reserved off the
          # name budget (budget >= 1 ⇒ ≥1 name col left after the cue). At a very narrow
          # pane the budget floors and there's no room: drop the cue so colored's visible
          # width matches plain's `text` (== the pre-#107 no-cue width) instead of
          # overrunning and staircasing the #118 diff/PR columns. The cue returns as the
          # pane widens; the common case is unchanged (budget large, cue always shows).
          cue = fold_cue(node)
          budget = text.length - 4 - cue.length
          cue = "" if budget < 1
          name = trunc(node.name.to_s, [budget, 1].max)
          ptr = " "
          if current
            ptr  = "#{BRAND}#{CURRENT_MARK}\e[0m"  # "you are here" pointer — bold-cyan, switchboard's signature accent
            name = "\e[36m#{name}\e[0m"            # ...and the name cyan, matching the prompt's directory color
          elsif @attention.include?(node.path)
            name = "\e[1;33m#{name}\e[0m"          # unviewed completion — bold yellow until you look (the current row is never marked)
          end
          "#{ptr} #{dot} #{name}#{cue.empty? ? '' : "\e[2m#{cue}\e[0m"}" # dim ▸N cue last, its width already reserved
        else "#{BRANCH_FG}#{text}\e[0m"
        end
      end

      # Bare state glyph for a workspace row, twinkling briefly right after the
      # agent's turn lands before it settles to the steady dot. Bare (uncolored) so
      # the shape survives under the reverse-video selected row, mirroring glyph_for.
      def ws_glyph(path)
        return SPARKLE_GLYPHS[(@pulse / 2) % SPARKLE_GLYPHS.size] if sparkling?(path)

        glyph_for(render_state(path))
      end

      # Bare state glyph (no color), the single source for both render paths. The
      # spinner cycles through SPIN_FRAMES on @pulse; the diamond blinks filled/
      # hollow every BLINK_PERIOD ticks; done is steady; idle is a blank slot.
      def glyph_for(state)
        case state
        when :thinking   then SPIN_FRAMES[@pulse % SPIN_FRAMES.size]
        when :waiting    then (@pulse / BLINK_PERIOD).even? ? "◆" : "◇"
        when :monitoring then "∞"
        when :done       then "●"
        else " "
        end
      end

      # Colored state glyph for a normal (non-selected) row. Mirrors glyph_for in
      # palette ANSI; thinking indexes the pre-built SPIN_COLORED so there's no
      # per-frame string allocation.
      def dot_for(state)
        case state
        when :thinking   then SPIN_COLORED[@pulse % SPIN_COLORED.size]
        when :waiting    then (@pulse / BLINK_PERIOD).even? ? WANTS_ON : WANTS_OFF
        when :monitoring then MONITORING
        when :done       then DONE
        else " "
        end
      end

      # The state to DRAW for a ws row: the live agent state, except a monitored worktree
      # AT REST (done, or idle/nil after its hooks aged out) shows :monitoring instead — so
      # idle-between-ticks reads as "watching", not "finished". Active states win, so you
      # still see live work (thinking) and input requests (waiting). Sparkle is handled by
      # the callers, ahead of this. The single source both paint paths (glyph_for/dot_for)
      # resolve through, so precedence can't drift between plain and colored.
      def render_state(path)
        state = @agents[path]
        return state if %i[thinking waiting].include?(state)

        @monitoring.include?(path) ? :monitoring : state
      end

      def trunc(str, width)
        str = str.to_s
        return "" if width <= 0

        str.length > width ? "#{str[0, width - 1]}…" : str
      end
    end
    include Render
  end
end
