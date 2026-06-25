# frozen_string_literal: true

require "fileutils"

module Switchboard
  # The shared "show the full header on every session" toggle (the `H` key). The
  # home sidebar always seats the full brand header — wordmark + greeting +
  # console + rule (see Sidebar#header); every other session shows just the
  # wordmark. When this flag is set, that full header extends to ALL sessions.
  #
  # State lives on disk, NOT in a sidebar ivar, for the same reason Collapse and
  # Attention do: every window's sidebar is its own process, so only a shared
  # on-disk flag renders the same header in all of them (and survives a respawn).
  # Like Collapse, it is a durable VIEW PREFERENCE — deliberately NOT cleared on
  # quit. A single marker file whose mere existence is the flag, so toggling is one
  # atomic create/delete with no read-modify-write race between sidebar processes;
  # and because only existence is read (never the contents), a torn write can't
  # misread, so no temp+rename dance is needed (unlike Collapse, which reads names).
  module FullHeader
    module_function

    # On when the marker exists. Degrades to off on any error — a sidebar that
    # can't read the flag just shows the minimal wordmark, never crashes the paint.
    def enabled?
      File.exist?(marker)
    rescue StandardError
      false
    end

    # Turn it on. Idempotent create — re-enabling an already-on flag is a no-op.
    def enable
      FileUtils.mkdir_p(File.dirname(marker))
      File.write(marker, "on")
    rescue StandardError
      nil
    end

    # Turn it off. Idempotent — a missing marker is a quiet no-op, so a toggle can
    # call it unconditionally on the off edge.
    def disable
      File.delete(marker)
    rescue StandardError
      nil
    end

    # The single marker file, XDG-state-rooted beside the collapse folds. Resolved
    # from ENV per call (not frozen at load) so the test sandbox can redirect it.
    def marker
      File.expand_path(
        ENV["SWITCHBOARD_FULL_HEADER_FILE"] ||
          File.join(ENV["XDG_STATE_HOME"] || "~/.local/state", "switchboard", "full_header")
      )
    end
  end
end
