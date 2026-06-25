# frozen_string_literal: true

require "fileutils"

module Switchboard
  # The shared sidebar pane WIDTH, stepped by the tree's ←/→ keys (issue #78). The
  # pane was a hardcoded 40 cols that pin_if_resized re-asserted every paint; this
  # makes the chosen width state the pin respects instead.
  #
  # State lives on disk, NOT in a sidebar ivar, for the same reason Collapse,
  # Attention, and FullHeader do: every window's sidebar is its own process, so only
  # a shared on-disk value sizes them all alike (and survives a respawn). Like those,
  # it is a durable VIEW PREFERENCE — deliberately NOT cleared on quit.
  #
  # A single global file (like FullHeader), but holding an integer rather than a bare
  # existence flag — so unlike FullHeader the value is *read*, which means a torn
  # write could misread; hence the atomic temp+rename of Collapse. A garbage/torn/
  # absent file resolves to DEFAULT, so a bad read just sizes the pane normally.
  # Concurrent resizes are last-writer-wins (one global file) — fine for a view
  # preference; FullHeader avoids this only because existence is idempotent.
  module Width
    module_function

    DEFAULT = 40 # mirrors Tmux::SIDEBAR_WIDTH, the historical fixed width
    MIN = 20
    MAX = 80

    # The current width, clamped to [MIN, MAX]. The single source of truth, read on
    # hydrate by every sidebar and as Tmux.pin's default. Degrades to DEFAULT on a
    # missing/garbage/torn file, so a bad read never crashes the paint.
    def resolved
      # Base 10 explicitly: a stray leading zero (a hand-edit) is decimal, not octal
      # — and a `0x..`/garbage value then raises into the DEFAULT fallback as intended.
      Integer(File.read(state_file).strip, 10).clamp(MIN, MAX)
    rescue StandardError
      DEFAULT
    end

    # Persist a chosen width. Clamped (defense in depth), then atomic temp+rename so a
    # peer's concurrent read never sees a half-written value — the multi-process
    # pattern (Collapse, Attention, the synthesized WAVs).
    def set(width)
      n = Integer(width).clamp(MIN, MAX)
      FileUtils.mkdir_p(File.dirname(state_file))
      tmp = "#{state_file}.#{Process.pid}.tmp"
      File.write(tmp, n.to_s)
      File.rename(tmp, state_file) # atomic on the same fs
    rescue StandardError
      nil
    end

    # The single state file, XDG-state-rooted beside the collapse folds and the
    # full-header marker. Resolved from ENV per call (not frozen at load) so the test
    # sandbox can redirect it.
    def state_file
      File.expand_path(
        ENV["SWITCHBOARD_WIDTH_FILE"] ||
          File.join(ENV["XDG_STATE_HOME"] || "~/.local/state", "switchboard", "width")
      )
    end
  end
end
