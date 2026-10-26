# frozen_string_literal: true

require_relative "keyed_marker_store"

module Switchboard
  # A held completion chime, one marker per worktree. When an agent's turn ends while a
  # background agent it started is still running (Claude's session `status` reads
  # `busy`, ClaudeSessions::HANDOFF_STATUS), the Stop's `done` is a hand-off, not a
  # finish: the sidebar draws ◷ and holds the chime + bold instead of ringing. The hold
  # rings once, when that work is actually over. A background shell (`shell`) draws ◷
  # but is never held: it may never end.
  #
  # On disk, not in a sidebar ivar, because a sidebar that was off screen at the
  # hand-off never saw the edge (its baseline already read done), yet it may be the
  # one on screen when the work finishes. Any pane that sees the hand-off writes the
  # marker; the first on-screen pane to see it mature CLAIMS it by unlinking the file
  # — only one unlink can succeed — and rings. A KeyedMarkerStore twin of Attention:
  # keyed by realpath, GC'd when the worktree is gone. Content is
  # "<realpath>\t<epoch>\t<pid>"; the pid is the session that was busy, so a hold
  # whose Claude exited (its session file removed) can still mature on kill(0).
  module OffstageHold
    module_function

    def state_dir
      KeyedMarkerStore.dir("SWITCHBOARD_OFFSTAGE_HOLD_DIR", "offstage_hold")
    end

    # Hold `path`'s chime; true once the marker is on disk (the caller rings now when
    # it isn't, rather than lose the chime). Idempotent: a later hand-off of the same
    # worktree just rewrites it.
    def hold(path, pid:, now: Time.now)
      real = realpath(path)
      return false unless real && Dir.exist?(real)

      !KeyedMarkerStore.write(state_dir, key(real), [real, now.to_i, pid.to_i].join("\t")).nil?
    end

    # The held worktrees among `paths`, as { raw_path => { pid: Integer or nil, at: epoch } }. A pid
    # outside 1..PID_MAX reads as nil (no pid evidence): kill(0, 0) "succeeds" and past
    # pid_t kill raises. GCs a marker whose worktree is gone. Fully rescued to {}.
    def held(paths)
      live = {}
      KeyedMarkerStore.scan(state_dir) do |content|
        real, epoch, pid = content.split("\t", 3)
        next false unless real && Dir.exist?(real)

        pid = Integer(pid.to_s, exception: false)
        live[real] = { pid: pid&.between?(1, ClaudeSessions::PID_MAX) ? pid : nil,
                       at: Integer(epoch.to_s, exception: false) || 0 }
        true
      end
      paths.each_with_object({}) do |p, out|
        hold = live[realpath(p)]
        out[p] = hold if hold
      end
    rescue StandardError
      {}
    end

    # Drop a hold without ringing (its follow-up turn started: that turn's own Stop
    # rings normally).
    def release(path)
      real = realpath(path)
      KeyedMarkerStore.delete(state_dir, key(real)) if real
    end

    # Take the hold to ring it: true for exactly one caller across every process. A raw
    # unlink, not KeyedMarkerStore.delete: only its success says who won.
    def claim(path)
      real = realpath(path) or return false
      File.delete(File.join(state_dir, key(real)))
      true
    rescue StandardError
      false
    end

    # Rename: the hold follows its worktree (old realpath captured before the move). Not
    # KeyedMarkerStore.carry, which rewrites the content to the bare path and would drop
    # the pid the kill(0) maturity reads.
    def carry(old_real, new_real)
      file = File.join(state_dir, key(old_real))
      content = File.read(file).chomp
      _real, epoch, pid = content.split("\t", 3)
      KeyedMarkerStore.write(state_dir, key(new_real), [new_real, epoch, pid].join("\t"))
      KeyedMarkerStore.delete(state_dir, key(old_real))
    rescue StandardError
      nil
    end

    # Wipe every hold. Rides `quit` beside AgentState/Monitoring/Notify.clear_all: the
    # agents are gone, so nothing will finish.
    def clear_all
      Dir.glob(File.join(state_dir, "*")).each do |file|
        File.delete(file) if File.file?(file)
      rescue StandardError
        next
      end
    rescue StandardError
      nil
    end

    def key(real)
      KeyedMarkerStore.key(real)
    end

    def realpath(path)
      File.realpath(path)
    rescue StandardError
      nil
    end
  end
end
