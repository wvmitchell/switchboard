# frozen_string_literal: true

module Switchboard
  class Sidebar
    # The update line (#47): whether this pane shows one, what it says, and the background check that
    # feeds it. The config arrives on each call, because the sidebar reassigns it on a config reload.
    class UpdateCue
      SPAWN_TTL = 60 # min seconds between this pane's own update due? checks

      attr_reader :cue, :seen

      def initialize
        @cue = nil              # the newer release to announce under the wordmark, or nil
        @seen = nil             # [cache, version.rb] mtimes the last refresh read: reload's warm baseline
        @applies = nil          # Homebrew + installed binary? (UpdateCheck.applies?, memoized)
        @installed_version = nil # the installed version.rb's VERSION, re-read when its mtime moves
        @installed_version_mtime = nil
        @spawned = nil          # monotonic of this pane's last update due? check
      end

      # [cache mtime, version.rb mtime] as they are now, nil when the line is off — the
      # warm gate's change signal. Stats only.
      def fingerprint(config)
        return nil unless show?(config)

        [mtime(UpdateCheck.cache_path), mtime(UpdateCheck.version_file)]
      rescue StandardError
        nil
      end

      # Called by rebuild. Stats BEFORE reading, so `seen` can only lag what was
      # drawn (one spare warm), never lead it (a missed one). version.rb is re-read only
      # when its mtime moves.
      def refresh(config)
        @cue = nil
        @seen = fingerprint(config)
        return unless @seen

        version_mtime = @seen[1]
        if version_mtime != @installed_version_mtime
          @installed_version_mtime = version_mtime
          @installed_version = UpdateCheck.installed_version || VERSION
        end
        @cue = UpdateCheck.cue(UpdateCheck.read, @installed_version)
      end

      # Detaches `switchboard check-update` when the cache is stale. The attempt file is
      # touched first (UpdateCheck.claim), so the next pane to ask reads "not due" at once.
      def maybe_check(config)
        bin = ENV["SWITCHBOARD_BIN"]
        return unless bin && !UpdateCheck.sandbox? && !UpdateCheck.disabled_by_env? && show?(config)

        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return unless @spawned.nil? || now - @spawned >= SPAWN_TTL

        @spawned = now
        return unless UpdateCheck.due? && UpdateCheck.claim

        Process.detach(Process.spawn(bin, "check-update", in: File::NULL, out: File::NULL, err: File::NULL))
      rescue SystemCallError
        nil
      end

      private

      # Shown on a Homebrew install's own sidebars, or in the sandbox (seeded, #126) so a
      # checkout can show it; `update_check: false` hides it everywhere.
      def show?(config)
        return false unless config.update_check?
        return true if UpdateCheck.sandbox?

        @applies = UpdateCheck.applies? if @applies.nil? # one `command -v`, memoized
        @applies
      end

      def mtime(path)
        File.mtime(path).to_f
      rescue SystemCallError
        nil
      end
    end
  end
end
