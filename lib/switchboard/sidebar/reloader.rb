# frozen_string_literal: true

module Switchboard
  class Sidebar
    # Code reload (#48): exec self in place. Asked by SIGUSR1 (`upgrade` / `reload-sidebars`,
    # which only signal a pane whose tag is our pid) or by the backstop in tick (the Homebrew
    # keg moved). Due at once on screen; off screen after a random spread, so a fleet doesn't
    # boot and rescan at once — but a switch-in makes it due right away. Never under an overlay
    # or while a search is being typed, and never mid-prompt (prompts block the loop, so the request waits).
    # The why behind each step: docs/explanation-sidebar-lifecycle.md.
    #
    # The sidebar owns what the payload carries and whether its overlays allow a swap, and
    # passes those in; this owns the signal, the pane tag, the deadline and the exec.
    class Reloader
      ANNOUNCE_GRACE = 1 # seconds past REFRESH a scan still counts as "just now" for a reload's first ring (#48)
      TAG_TRIES = 5      # attempts at a pane tag that didn't land (#48): a one-off tmux failure, not tmux < 3.0's every-time one

      attr_reader :resume, :wake_r

      def initialize
        @resume = nil        # the payload a reload handed us (CodeReload.take_resume), nil on a cold start
        @reload_requested = false
        @reload_signal = false # set by the SIGUSR1 trap; the loop turns it into a request
        @reexec_at = nil     # monotonic when a requested reload is due (off screen: spread out)
        @reexec_blocked_root = nil # a root whose preflight failed: the backstop won't retry it
        @warm_not_before = nil # a reloaded off-screen pane's first warm waits out the spread
        @last_announce_scan = nil # monotonic of the last announcing on-screen scan: a reload's first scan may ring only after a recent one
        @wake_r = @wake_w = nil # self-pipe the trap writes, so IO.select wakes for it
        @prev_reload_trap = nil
        @tag_pending = nil   # the pid tag owed when one didn't land, retried by tick (retry_tag)
        @tag_tries = 0
        @tag_clears = false  # whether that owed tag may clear a failed-reload flag (a new image's first)
      end

      def take_resume
        @resume = CodeReload.take_resume
      end

      # A self-pipe the trap writes, so IO.select wakes for it. The trap only sets a flag:
      # anything more in a signal handler is asking for trouble.
      def install_reload_trap
        @wake_r, @wake_w = IO.pipe unless @wake_r
        wake = @wake_w
        @prev_reload_trap = trap(CodeReload::SIGNAL) do
          @reload_signal = true
          wake.write_nonblock(".", exception: false)
        rescue IOError
          nil
        end
      rescue ArgumentError, SystemCallError
        nil
      end

      def restore_reload_trap
        trap(CodeReload::SIGNAL, @prev_reload_trap || "DEFAULT") if @wake_r
        [@wake_r, @wake_w].each { |io| io&.close unless io&.closed? }
        @wake_r = @wake_w = nil
      rescue ArgumentError, SystemCallError
        nil
      end

      def drain_wake
        loop { @wake_r.read_nonblock(64) }
      rescue IO::WaitReadable, EOFError, IOError
        nil
      end

      # Our pane's tag: our pid, or "0" while we're between images (R4). A pid tag that didn't
      # land is owed: a "0" left by our own exec would make every later reload skip us.
      def tag_pane(value = Process.pid, clear_failed: true)
        landed = CodeReload.tag_sidebar_pane(ENV["TMUX_PANE"], value, clear_failed: clear_failed)
        return landed if value.to_s == "0" # exec replaces us right after: nothing to retry

        @tag_pending, @tag_tries, @tag_clears = landed ? [nil, 0, false] : [value, 1, clear_failed]
        landed
      end

      def on_tick(visible:)
        request_reload(visible: visible) if code_moved? # a `brew upgrade` nobody signaled us about (#48)
        retry_tag
        reap_strays if @resume
      end

      # Retry an owed tag as it was asked, TAG_TRIES attempts in all, then give up (the pane
      # keeps whatever tag it had). A new image's first tag may clear a failed-reload flag; the
      # old code's re-tag after a failed exec never does, so a retry can't hide that failure.
      def retry_tag
        return unless @tag_pending

        @tag_tries += 1
        landed = CodeReload.tag_sidebar_pane(ENV["TMUX_PANE"], @tag_pending, clear_failed: @tag_clears)
        @tag_pending = nil if landed || @tag_tries >= TAG_TRIES
      end

      # The keg SWITCHBOARD_BIN resolves to isn't the one we loaded, and it isn't one whose
      # preflight already failed (a broken release mustn't cost a boot every tick).
      def code_moved?
        return false if @reload_requested || !CodeReload.stale?

        CodeReload.current_root != @reexec_blocked_root
      end

      def request_reload(visible:)
        @reload_requested = true
        due = visible ? monotonic : monotonic + CodeReload.spread_delay
        @reexec_at = [@reexec_at, due].compact.min
      end

      # Turns a pending signal into a request, then: is a swap due now?
      def reexec_due?(visible:, allowed:)
        if @reload_signal
          @reload_signal = false
          request_reload(visible: visible)
        end
        return false unless @reload_requested && allowed

        visible || monotonic >= @reexec_at
      end

      # Seconds until a requested reload is due (0 once it's overdue), nil with none requested.
      def reexec_wait
        return nil unless @reload_requested && @reexec_at

        [@reexec_at - monotonic, 0].max
      end

      # Preflight, then exec. Every failure keeps this process running its current code.
      def reexec(paint:, payload:)
        @reload_requested = false
        @reexec_at = nil
        bin = ENV["SWITCHBOARD_BIN"] or return
        paint.call # the loop top runs before its paint: show the caught-up tree during the check
        # One resolution for the check and the exec: a `brew upgrade` can repoint opt/ during the
        # check, and exec'ing the link again would run a keg the check never saw. A link that
        # won't resolve fails this reload rather than guess. Flagged (a checkout or keg that's gone
        # for good must show; after a brief relink, the next reload that lands clears it), but no
        # root is blocked: the known-broken one stands; a signal or the backstop retries.
        real = CodeReload.real_bin(bin) or return reload_failed(bin, block: false)
        root = CodeReload.root_of(real)
        handover = payload.call
        case CodeReload.preflight(real, "sidebar", "--check", env: { CodeReload::RESUME_ENV => handover })
        when :ok then exec_in_place(real, root, handover)
        else reload_failed(root) # a timeout too: flagged, and `reload-sidebars` asks again on demand
        end
      end

      def note_announcing_scan
        @last_announce_scan = monotonic
      end

      # No catch-up scan here, so a swap right after must start silent: its baseline
      # predates whatever another pane rang while we were away (#48).
      def silence_pending_reload
        @last_announce_scan = nil if @reload_requested
      end

      # May the new image's first scan ring? Only if we were on screen and announcing just now;
      # otherwise it owes a silent catch-up like any switch-in (R7).
      def announce?(visible:)
        visible && !@last_announce_scan.nil? && monotonic - @last_announce_scan <= REFRESH + ANNOUNCE_GRACE
      end

      def hold_first_warm
        @warm_not_before = monotonic + CodeReload.spread_delay
      end

      def warm_spread_over?
        !(@warm_not_before && monotonic < @warm_not_before)
      end

      private

      # Stay on this code, say so on the pane (doctor, the next reload), and (with `block:`) keep
      # the backstop off this root until a different one appears; an install that won't resolve
      # only flags, leaving the blocked root as it was. A signal still asks again: a test run that
      # only timed out (a cold disk right after `brew upgrade`) gets its retry from the next
      # `reload-sidebars`, not from a clock of its own.
      def reload_failed(root, block: true)
        @reexec_blocked_root = root if block
        @tag_clears = false # a boot tag still owed must not erase the flag written below
        CodeReload.flag_failed_reload(ENV["TMUX_PANE"], root)
      end

      def exec_in_place(real, root, payload)
        reexec_guard = ENV.delete("SB_REEXEC") # bin/switchboard's one-shot guard (Upgrade.handoff clears it too)
        ENV[CodeReload::RESUME_ENV] = payload
        # A second signal before the new image installs its trap would kill it (handlers
        # reset on exec; SIG_IGN survives it), and senders skip a "0" tag (R4).
        trap(CodeReload::SIGNAL, "IGNORE")
        tag_pane(0)
        $stdout.flush
        exec(real, "sidebar")
      rescue SystemCallError
        ENV.delete(CodeReload::RESUME_ENV)
        ENV["SB_REEXEC"] = reexec_guard if reexec_guard
        install_reload_trap
        tag_pane(clear_failed: false) # still old code: the failure flag below must stand
        reload_failed(root)
      end

      # exec kept our pid but not the old image's Process.detach threads, so its children (a PR
      # refresh, a sound) would linger as zombies. The sweep may also reap this image's own
      # detached children before their detach thread does; no caller reads a detach thread's
      # value, and shell-outs wait inline on this same thread, so no status anyone uses is lost.
      def reap_strays
        loop { break unless Process.wait(-1, Process::WNOHANG) }
      rescue Errno::ECHILD
        nil
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
