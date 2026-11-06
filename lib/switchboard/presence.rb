# frozen_string_literal: true

require_relative "claude_sessions"
require_relative "monitoring"
require_relative "notify"
require_relative "remote_link"

module Switchboard
  # What's running where, read from every source at once: raw evidence only. Policy that
  # needs a front end's state stays with that front end (the sidebar settles ◷ against its
  # edge tracker and rings its own edges).
  module Presence
    # agents, monitoring, notify: per the source. sessions: nil when that read failed (no
    # evidence, which must not read as "finished"). offstage, handoff, idle, fresh: see
    # session_evidence.
    Snapshot = Struct.new(:agents, :sessions, :offstage, :handoff, :idle, :fresh, :monitoring, :notify,
                          keyword_init: true)

    module_function

    # An agent_state or monitoring failure raises, which the caller treats as a failed scan.
    # The other sources degrade alone. hooks_only (the dots) and cheap (sessions, off screen)
    # are independent: an on-screen reload after a delete passes only hooks_only.
    def scan(paths, agent_state:, hooks_only: false, cheap: false)
      agents = agent_state.scan(paths, hooks_only: hooks_only)
      # AFTER the hooks: Claude writes `done` 13-29ms before `idle`, so a session read
      # that precedes the hook read (its ps/lsof take ~30-125ms) would widen that race.
      sessions = claude_sessions(paths, cheap: cheap)
      offstage, handoff, idle, fresh = session_evidence(sessions)
      Snapshot.new(agents: agents, sessions: sessions, offstage: offstage, handoff: handoff, idle: idle, fresh: fresh,
                   monitoring: Monitoring.monitored(paths), notify: Notify.pending(paths))
    end

    # Live /remote-control links per worktree. Its own rescue (RemoteLink.scan is total
    # already) because a raise reaching a scan's failure handling would blank every dot.
    # `cheap` while off screen, so a hidden pane spawns no ps/lsof for links. `sessions` is
    # the scan's read; nil (it failed, or the scan raised before it) makes RemoteLink read
    # for itself. A separate call so a caller can run it after a failed scan.
    def links(paths, cheap:, sessions:, stale_after:)
      RemoteLink.scan(paths, stale_after: stale_after, cheap: cheap, sessions: sessions)
    rescue StandardError
      {}
    end

    def claude_sessions(paths, cheap:)
      ClaudeSessions.scan(paths, cheap: cheap)
    rescue StandardError
      nil
    end

    # The ◷ evidence: [{ path => pid } of sessions still running work after their turn
    # (busy/shell: draws ◷), the same for `busy` alone (a background agent: holds the
    # chime), Set of paths whose sessions read a settled idle, Set of paths with an idle
    # too fresh to trust]. Empty on no evidence.
    def session_evidence(sessions, now: Time.now)
      offstage = {}
      handoff = {}
      idle = Set.new
      fresh = Set.new
      (sessions || {}).each do |path, recs|
        case ClaudeSessions.activity(recs, now: now)
        when :offstage
          offstage[path] = recs.find { |r| ClaudeSessions::OFFSTAGE_STATUSES.include?(r[:status]) }[:pid]
          agent = recs.find { |r| r[:status] == ClaudeSessions::HANDOFF_STATUS }
          handoff[path] = agent[:pid] if agent
        when :idle then idle << path
        else fresh << path if recs.any? { |r| r[:status] == "idle" && !ClaudeSessions.settled_idle?(r, now) }
        end
      end
      [offstage, handoff, idle, fresh]
    rescue StandardError
      [{}, {}, Set.new, Set.new]
    end
  end
end
