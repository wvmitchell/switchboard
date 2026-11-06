# frozen_string_literal: true

module Switchboard
  # Typing into panes, and the keys you navigate with.
  module Tmux
    module_function

    # Type `text` into a pane as ONE literal send-keys — tmux runs it atomically, so a
    # key the user presses lands before or after it, never inside.
    def send_literal(pane, text)
      system("tmux", "-u", "send-keys", "-t", pane, "-l", text, out: File::NULL, err: File::NULL)
    end

    # Named keys (Enter, BSpace, …) in one send-keys.
    def send_keys(pane, *keys)
      system("tmux", "-u", "send-keys", "-t", pane, *keys, out: File::NULL, err: File::NULL)
    end

    ARROW_GLYPHS = { "Up" => "↑", "Down" => "↓", "Left" => "←", "Right" => "→" }.freeze

    # The user's OWN pane-navigation keys, parsed from `tmux list-keys -T prefix` —
    # the prefix bindings whose command is select-pane. switchboard splits the sidebar
    # beside the work pane but deliberately never binds pane movement (it rides your
    # existing tmux muscle memory), so the help overlay surfaces YOUR keys for the one
    # implicit step: getting focus into the sidebar and back. Arrow names render as
    # glyphs and the four directions collapse to one token; single-letter keys (o,
    # hjkl) are kept; exotic tokens (modifier combos, special chars) are skipped.
    # Deduped, capped to fit the pane, [] when none/unparseable. Pure given `raw`
    # (which defaults to the shell-out), so the parse is unit-testable offline.
    # Best-effort by design: it reads the PREFIX table and a literal `select-pane`
    # movement command. It does NOT chase if-shell-wrapped / sequenced / aliased binds
    # or the root table (no-prefix nav like vim-tmux-navigator) — those just omit their
    # row rather than guess. The row is correct-or-absent, never a fabricated key.
    def pane_switch_keys(raw = `tmux -u list-keys -T prefix 2>/dev/null`)
      # scrub first: a key bound to a non-ASCII char in a non-UTF-8 locale can put
      # invalid bytes in list-keys output, and a regex match on those raises
      # ArgumentError — crashing the overlay render. Degrade, never crash (the
      # [scrub-raw-tmux-git-bytes] convention).
      keys = raw.to_s.scrub.lines.filter_map do |line|
        # Only MOVEMENT select-pane: directional (-L/-R/-U/-D) or target (-t, the
        # next/prev-pane binds). Excludes mark/unmark (-m/-M) and the like, which are
        # select-pane commands but not "move between panes".
        m = line.match(/-T\s+prefix\s+(\S+)\s+select-pane\s+-[LRUDt]\b/) or next
        k = m[1].delete('"\\')
        ARROW_GLYPHS[k] || (k.match?(/\A[A-Za-z]\z/) ? k : nil)
      end.uniq
      # Collapse the full arrow / vim clusters into one token each — a vim user wants
      # to see "hjkl", not three of four after the cap clips one — and it keeps the row short.
      keys = ["↑↓←→", *(keys - ARROW_GLYPHS.values)] if (ARROW_GLYPHS.values - keys).empty?
      keys = [*(keys - %w[h j k l]), "hjkl"] if (%w[h j k l] - keys).empty?
      keys.first(5)
    end
  end
end
