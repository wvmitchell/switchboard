# frozen_string_literal: true

require_relative "../adapters/claude_sessions"
require_relative "monitoring"
require_relative "notify"
require_relative "remote_link"

module Switchboard
  # What's running where, read from every source at once: raw evidence only. Policy that
  # needs a front end's state stays with that front end (the sidebar settles ◷ against its
  # edge tracker and rings its own edges).
  module Presence
    # agents: the dots, after merge_waiting. hook_states: the hook states the edge tracker
    # diffs, after the same merge. confirmed: carry into the next scan (merge_waiting).
    # monitoring, notify: per the source. sessions: nil when that read failed (no evidence,
    # which must not read as "finished"). offstage, handoff, idle, fresh: see
    # session_evidence.
    Snapshot = Struct.new(:agents, :hook_states, :confirmed, :sessions, :offstage, :handoff, :idle, :fresh,
                          :monitoring, :notify, keyword_init: true)

    module_function

    # An agent_state or monitoring failure raises, which the caller treats as a failed scan.
    # The other sources degrade alone. hooks_only (the dots) and cheap (sessions, off screen)
    # are independent: an on-screen reload after a delete passes only hooks_only.
    # `confirmed` is the previous snapshot's.
    def scan(paths, agent_state:, hooks_only: false, cheap: false, confirmed: Set.new)
      agents = agent_state.scan(paths, hooks_only: hooks_only)
      # AFTER the hooks: Claude writes `done` 13-29ms before `idle`, so a session read
      # that precedes the hook read (its ps/lsof take ~30-125ms) would widen that race.
      sessions = claude_sessions(paths, cheap: cheap)
      agents, hook_states, confirmed = merge_waiting(agents, agent_state.last_hook_states, agent_state.stale_waiting,
                                                     sessions, confirmed)
      offstage, handoff, idle, fresh = session_evidence(sessions)
      Snapshot.new(agents: agents, hook_states: hook_states, confirmed: confirmed, sessions: sessions,
                   offstage: offstage, handoff: handoff, idle: idle, fresh: fresh,
                   monitoring: Monitoring.monitored(paths), notify: Notify.pending(paths))
    end

    # A Claude session's own `waiting` is the ◆'s evidence: the hook file can be
    # overwritten while the dialog is open (a background subagent's tool call writes
    # `done`), the session status can't. Per path, with sessions read:
    #   - a session reads `waiting`: draw ◆, and hand the edge tracker :waiting too, so the
    #     overwrite rings nothing and the real finish after you answer still rings. The
    #     path is `confirmed`.
    #   - a confirmed ◆ whose hook still says `waiting` while every session reads a settled
    #     `idle`: the dialog was rejected (Esc fires no hook). Draw it resting and leave it
    #     out of the edge input, so it rings nothing. Only a dialog the session confirmed
    #     clears this way, so the session file can't hide one it never reported.
    #   - a ◆ kept only by AgentState's stale-waiting extension, beside a session that
    #     reads a recognized idle/busy/shell: the session wins. An unknown or missing
    #     status is no evidence, so the ◆ stands.
    # A failed session read (nil) is no evidence: everything passes through unchanged.
    # Returns [agents, hook_states, confirmed], new objects.
    def merge_waiting(agents, hook_states, stale, sessions, confirmed)
      return [agents, hook_states, confirmed] if sessions.nil?

      merged = agents.dup
      effective = hook_states.dup
      kept = Set.new
      (agents.keys | sessions.keys | confirmed.to_a).each do |path|
        recs = sessions.fetch(path, nil) # never sessions[path]: its default proc would add the key
        hook = hook_states[path]
        if ClaudeSessions.waiting?(recs)
          merged[path] = :waiting
          effective[path] = :waiting if effective.key?(path)
          kept << path
        elsif hook == :waiting && confirmed.include?(path)
          kept << path
          next unless ClaudeSessions.activity(recs) == :idle

          merged[path] = :done
          effective.delete(path)
        elsif stale.key?(path) && ClaudeSessions.activity(recs)
          merged[path] = stale[path] || :done
          effective.delete(path)
        end
      end
      [merged, effective, kept]
    rescue StandardError
      [agents, hook_states, confirmed]
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
