# frozen_string_literal: true

module Switchboard
  class Sidebar
    # Input (#57): everything between raw stdin bytes and an action — the
    # nonblocking read, the terminal-grammar tokenizer, dispatch (structural
    # sequences first, then the #108 keymap), the / filter and ? help key
    # modes, focus handling, and keymap resolution. A concern module on
    # Sidebar (see CLAUDE.md conventions); the input-grammar constants live
    # here WITH their consumers — HELP_IGNORED_BYTES references the poke
    # bytes at require time, so splitting them across files would be a
    # load-order crash (the #57 same-file rule for constant initializers).
    module Input
      RELOAD_CONFIG_BYTE = "\x12"  # C-r: the dedicated post-edit "re-read config" poke (Tmux.poke_sidebar_of)
      WARM_POKE_BYTE = "\x17"      # C-w: "shared view-state changed elsewhere — repaint NOW" broadcast
                                   # (Tmux.broadcast_warm). Lets a collapse/fold/header toggle in one
                                   # sidebar reach every other (off-screen) sidebar's buffer instantly,
                                   # instead of waiting for its lazy warm tick — so a switch right after
                                   # a toggle shows the new view-state with no flash.
      WIDTH_STEP = 2               # cols per ←/→ press; bounds live in Width (issue #78)
      READ_BYTES = 1024            # per read: large enough that a normal input burst (a held
                                   # key-repeat, a switch's focus-event flurry) is never capped
                                   # mid-sequence — so the tokenizer only ever carries a genuine
                                   # producer-fragmented tail, not one we sliced ourselves
      CSI_MAX = 32                 # longest partial CSI tokenize will carry across reads; real
                                   # CSIs are short, so a longer param run is garbage — drop it
                                   # rather than let @pending grow unbounded on a junk byte stream

      # Synthetic byte sequences that arrive on stdin without a keypress — the C-l
      # switch/background-refresh poke, the C-r config poke, and tmux focus in/out.
      # While the ? overlay is open these are IGNORED (a background poke must not dismiss
      # it); every other byte is a real keystroke that closes it. Dropping their side
      # effects is safe here: C-l's reload/visibility self-heals via the tick backstop
      # within REFRESH (tick runs while help is open); C-r can't coincide with help (you
      # can't open the editor while help is up — `e` dismisses it first — and C-r isn't
      # broadcast, it targets the just-focused pane); focus is cosmetic under the overlay.
      # If C-r ever becomes broadcast, revisit this (it'd then need honoring). (issue #62)
      HELP_IGNORED_BYTES = ["\f", RELOAD_CONFIG_BYTE, WARM_POKE_BYTE, "\e[I", "\e[O"].freeze

      # Pure terminal-input tokenizer: returns [complete tokens, trailing incomplete
      # sequence]. The grammar it recognizes (the only escapes a tmux pane delivers):
      #
      #   \e [ <param/intermediate 0x20-0x3F>* <final 0x40-0x7E>   CSI: arrows, focus (\e[I/\e[O)
      #   \e <any other byte>                                      Alt / SS3 lead (2-byte token)
      #   \e        (alone at the end of the buffer)               the Esc key
      #   <byte>                                                   a plain key
      #
      # An incomplete CSI (`\e[…` with no final byte yet) is returned as the remainder
      # rather than emitted, so its final byte can never be read alone as a key. `\e`
      # plus any non-`[` byte is consumed TOGETHER (a 2-byte token), so the `O` in an
      # SS3 `\eO…` can't escape alone either. A lone trailing `\e` is emitted as the
      # Esc key, not carried: terminals write a sequence's bytes as one unit, so a `\e`
      # with nothing after it is the key — and carrying it would stall Esc (filter /
      # prompt cancel) waiting for bytes that never come. The one case this leaves open
      # is a CSI split BEFORE its `[` (a read ending on a lone `\e`, the next starting
      # `[O`): the `\e` flushes as Esc and the `O` could re-orphan. That needs tmux to
      # fragment a 3-byte focus event across reads — it doesn't (it writes the sequence
      # in one go, and READ_BYTES reads it whole) — so it's unreachable here; closing
      # it for good would mean an Esc-timeout in the run loop, not worth the timing.
      def self.tokenize(buf)
        tokens = []
        i = 0
        n = buf.bytesize
        while i < n
          if buf.getbyte(i) != 0x1b            # plain key byte
            tokens << buf.byteslice(i, 1)
            i += 1
          elsif i + 1 >= n                      # lone trailing \e -> the Esc key
            tokens << buf.byteslice(i, 1)
            i += 1
          elsif buf.getbyte(i + 1) != 0x5b      # \e + non-'[' -> Alt / SS3 lead, kept whole
            tokens << buf.byteslice(i, 2)
            i += 2
          else                                  # CSI: \e[ params/intermediates, then a final byte
            j = i + 2
            j += 1 while j < n && (0x20..0x3f).cover?(buf.getbyte(j))
            if j >= n # final byte not here yet -> carry the partial, but cap it: no real
              partial = buf.byteslice(i, n - i) # CSI runs long, so an unterminated param run
              return [tokens, partial.bytesize <= CSI_MAX ? partial : +""] # is garbage, drop+resync
            elsif (0x40..0x7e).cover?(buf.getbyte(j)) # a valid final byte: emit the whole CSI
              tokens << buf.byteslice(i, j - i + 1)
              i = j + 1
            else # byte j is neither param nor final -> malformed: emit \e[… WITHOUT it and
              tokens << buf.byteslice(i, j - i) # resume on byte j, so a real key (a control
              i = j                             # byte like \r/\f after a split \e[) still fires
            end
          end
        end
        [tokens, +""]
      end


      private

      # --- input ---------------------------------------------------------------

      # :eof when our pane closed (read past end-of-stream) so the loop can exit
      # cleanly instead of busy-spinning forever on a dead pty; nil when select woke
      # us spuriously with nothing to read (treated as no key).
      def read_key
        $stdin.read_nonblock(READ_BYTES)
      rescue EOFError
        :eof
      rescue IO::WaitReadable
        nil
      end

      # Split a read into whole key tokens and dispatch each. A read can deliver many
      # keys at once (a held key-repeat, or the flurry of focus events tmux sends the
      # sidebar pane as it loses focus during a session switch). The original bug was
      # read_key's fixed 8-byte read (not a multiple of 3) slicing a multi-event
      # buffer: three focus events = 9 bytes, capped at 8, left a bare `O` (the tail
      # of focus-out `\e[O`) that dispatched as the open-repo key — you'd land on
      # GitHub right after creating a workspace. READ_BYTES (1024) removes that cap
      # for any realistic burst; tokenize is the structural backstop, parsing by the
      # real terminal grammar and carrying any sequence that still straddles a read
      # boundary in @pending so a final byte is never read alone as a key.
      #
      # A stop-token (quit ⇒ dispatch returns false) ends the loop NOW: never dispatch
      # the rest of the buffer past it, so a key buffered after a confirmed `q` can't
      # fall through into another action.
      def handle(buf)
        tokens, @pending = Input.tokenize(@pending + buf.to_s)
        tokens.each { |t| return false unless dispatch(t) }
        true
      end

      def dispatch(key)
        return help_key(key) if @help     # ? overlay is open: a real key closes it, pokes pass through
        return filter_key(key) if @filter # / filter mode swallows the normal bindings

        # Structural sequences first: reserved keys with their own control flow that
        # are NOT user-remappable (issue #108) — the resize arrows, the ↵ context-
        # action, the C-l/C-r pokes, focus in/out. They're non-printable, so a
        # printable sidebar_keys override (Config#valid_sidebar_key?) can never
        # shadow them; checking them up front keeps that explicit.
        case key
        when "\e[C"             then resize(WIDTH_STEP)  # → widen the pane (issue #78)
        when "\e[D"             then resize(-WIDTH_STEP) # ← narrow the pane
        when "\r", "\n"         then enter
        when "\f"               then reload_and_refresh # Ctrl-L (hook poke on switch)
        when WARM_POKE_BYTE     then warm_poke # Ctrl-W (peer broadcast: shared view-state changed)
        when RELOAD_CONFIG_BYTE then reload_config_and_rebuild # Ctrl-R (post-edit reload)
        when "\e[I"             then return false if focus_in # focus-in: light cursor; #64 fast reap may exit the loop
        when "\e[O"             then @focused = false # tmux focus-out: drop it
        else                         return dispatch_action(key)
        end
        true
      end

      # The configurable arm of dispatch (issue #108): resolve the key to an action
      # via @keymap (its default, a sidebar_keys override, or a fixed alias like
      # ↓/^N/^O), then fire it. An unbound key is a no-op. Returns false only when
      # quit tears everything down (so the run loop exits); true otherwise.
      def dispatch_action(key)
        case @keymap[key]
        when :down               then move(1)
        when :up                 then move(-1)
        when :top                then @cursor = 0
        when :bottom             then @cursor = [@rows.size - 1, 0].max # clamp: empty tree → 0, not -1
        when :filter             then start_filter # type-to-filter the tree (issue #60)
        when :add_project        then add
        when :new_workspace      then create
        when :open_pr            then open_pr # open the PR in the browser
        when :open_repo          then open_repo # open the row's repo (branch if it has an open PR, else default)
        when :rename             then rename
        when :delete             then remove
        when :edit_config        then edit_config
        when :refresh_prs        then refresh_prs_now # force a PR-badge refresh (external merge/close)
        when :toggle_branch_fold then toggle_branch_fold # fold/unfold every workspace's branches (#107)
        when :toggle_full_header then toggle_full_header # seat the full header on every session
        when :help               then show_help # the full key map overlay (issue #62)
        when :quit               then return quit # q: tear down ALL switchboard sessions
        end
        true
      end

      # tmux focus-in: this pane is now the active one, so it's on screen. Light the
      # cursor bar and mark visible. If we were HIDDEN, do the same silent catch-up
      # reload tick would on an off->on edge — because marking @visible here consumes
      # the edge tick detects (`visible && !@visible`), so without this an un-poked
      # reappearance (bare attach, a stale window-switch hook) that lands focus on the
      # sidebar would render a stale tree until the next TREE_TICKS reload. A real
      # poked switch-in already set @visible=true, so reappeared is false — no double.
      def focus_in
        @focused = true
        reappeared = !@visible
        set_visible(true)
        reload(announce_sounds: false) if reappeared
        cursor_to_current # going back to the sidebar selects the workspace you're in
        # #64 fast reap: we may have just gained focus BECAUSE our work sibling closed and
        # we became the lone (active) pane. Check now so the wedge is caught within a frame
        # instead of up to one REFRESH tick. Returns true (=> dispatch exits the loop) only
        # in the workspace fall-home case; a normal focus-in (work pane still there) is false.
        lone_pane_handled
      end

      def move(delta)
        return if @rows.empty?

        @cursor = (@cursor + delta).clamp(0, @rows.size - 1)
      end

      # ↵: collapse/expand a project header, or switch to a workspace/branch.
      def enter
        node = current
        return unless node

        node.kind == "proj" ? toggle_collapse(node.project) : switch(node)
      end

      # Resolve the configurable in-sidebar keys (issue #108) from @config into the
      # two views the rest of the sidebar reads: @keymap (key -> action, what
      # dispatch keys off) and @bindings (action -> key, what the ? overlay and
      # footer show). Re-run on every rebuild so an `e` config edit re-binds live.
      def resolve_keymap
        @keymap, @bindings = Keymap.resolve(@config) # single pass: key->action + action->key
      end

      # --- ? help overlay (issue #62) ------------------------------------------
      #
      # `?` opens the full key map over the tree (render_help). While it's open,
      # dispatch routes every key here: a real keystroke closes it, but a synthetic
      # tmux byte (HELP_IGNORED_BYTES — the C-l/C-r pokes, focus in/out) is ignored so a
      # background PR-refresh poke or a focus change can't dismiss it out from under
      # the reader — the same robustness filter_key has. `?` can't open while filtering
      # (there it's a query char), so @help and @filter are never both set.

      # `?`: open the overlay. No recompute — the overlay doesn't read @rows.
      def show_help
        @help = true
      end

      # Any real key dismisses; a poke/focus byte passes through untouched. Always
      # returns true (the loop lives on, and the dismissing key only closes the
      # overlay — no passthrough into an action, even a typed q).
      def help_key(key)
        dismiss_help unless HELP_IGNORED_BYTES.include?(key)
        true
      end

      def dismiss_help
        @help = false
      end

      # --- / filter mode (issue #60) -------------------------------------------
      #
      # An in-sidebar, fzf-style incremental filter — NOT the removed external fzf
      # popup. `/` enters; printable keys extend a query that narrows the rows to
      # matching switch targets; ↵ jumps to the highlighted match; Esc restores the
      # full tree. Like fzf, j/k are query input here (not motion — unlike the tree,
      # where they move) — movement is the arrows / ^N / ^P — so any name is reachable
      # by typing, and no destructive key (d, q) can fire mid-search.

      # Key handling while filtering. Always returns true: filter mode never quits
      # the loop — a typed 'q' is just a query character, not a teardown.
      def filter_key(key)
        case key
        when "\e"           then end_filter            # Esc: cancel, restore the full tree
        when "\r", "\n"     then switch_to_filtered    # ↵: open the highlighted match
        when "\e[B", "\x0E" then move(1)               # ↓ / ^N within the matches
        when "\e[A", "\x10" then move(-1)              # ↑ / ^P
        when "\x7F", "\b"   then backspace_filter       # Backspace (DEL / ^H): trim the query
        else append_filter(key) if printable?(key) # any printable ASCII char -> query
        end
        true
      end

      # A single printable ASCII byte (the only thing that extends the query). Tested
      # at the BYTE level — read_nonblock hands us ASCII-8BIT, so a stray high byte
      # from a non-ASCII keypress is one out-of-range byte we ignore, never a decode
      # that raises. UTF-8 in workspace names isn't typeable into the query (yet).
      def printable?(key)
        key.bytesize == 1 && key.getbyte(0).between?(0x20, 0x7E)
      end

      # /: enter filter mode with an empty query (matches everything, so the full
      # tree shows) and the cursor on the first row. The leap-to-first-match only
      # happens once you type (append_filter) — entry leaves you at the top.
      def start_filter
        @filter = +""
        recompute_rows
        @cursor = 0
      end

      # Esc: leave filter mode, restore the full collapse-aware tree, and land back
      # on the workspace this session is in (cursor_to_current) rather than wherever
      # the filtered cursor sat.
      def end_filter
        @filter = nil
        @cursor = 0
        recompute_rows
        cursor_to_current
      end

      # A printable char extends the query; re-select the top workspace match
      # (fzf-style), so the best result is always one ↵ away as you type.
      def append_filter(ch)
        @filter += ch
        recompute_rows
        @cursor = first_selectable
      end

      # Backspace trims the query; backspacing past the start exits filter mode —
      # erasing your way back through the `/` is the same gesture as Esc.
      def backspace_filter
        return end_filter if @filter.empty?

        @filter = @filter[0..-2]
        recompute_rows
        @cursor = first_selectable
      end

      # ↵ in filter mode is context-sensitive, like the normal tree's ↵ but repurposed
      # for search: on a workspace it switches (open the existing one); on a project
      # header it CREATES a new workspace there (collapse is meaningless while
      # filtering, so ↵-on-project becomes the project-level action). Grab the row
      # before end_filter rebuilds @rows; both paths then act on the normal tree.
      def switch_to_filtered
        node = current
        return unless node

        end_filter
        node.kind == "proj" ? create(node) : switch(node)
      end
    end
    include Input
  end
end
