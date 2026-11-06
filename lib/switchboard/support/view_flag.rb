# frozen_string_literal: true

require "fileutils"
require_relative "paths"

module Switchboard
  # A shared on/off view preference: one marker file whose mere existence is the flag.
  # Every window's sidebar is its own process, so only a flag on disk reads the same in all
  # of them and survives a respawn. Toggling is one atomic create or delete, with no
  # read-modify-write race between sidebars. Only existence is read, never the contents, so
  # a torn write can't misread and no temp+rename is needed. A store is the [env override,
  # leaf] pair Paths.state takes; it's resolved inside each rescue so a bad override
  # degrades instead of crashing the paint.
  module ViewFlag
    module_function

    def on?(store)
      File.exist?(Paths.state(*store))
    rescue StandardError
      false
    end

    # Idempotent: turning on a flag that's already on is a no-op.
    def on(store)
      marker = Paths.state(*store)
      FileUtils.mkdir_p(File.dirname(marker))
      File.write(marker, "on")
    rescue StandardError
      nil
    end

    # Idempotent: a missing marker is a quiet no-op, so a toggle can call it unconditionally.
    def off(store)
      File.delete(Paths.state(*store))
    rescue StandardError
      nil
    end
  end
end
