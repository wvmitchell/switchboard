# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # The reads behind the sidebar's dots. What a failure does to the sidebar is pinned in
  # sidebar_test ("one presence source failing"); this pins the module's own contract.
  class PresenceTest < SandboxTest
    def agent_state(result = {}, &block)
      Object.new.tap do |as|
        as.define_singleton_method(:scan, &(block || ->(_paths, hooks_only: false) { result }))
        as.define_singleton_method(:last_hook_states) { result }
        as.define_singleton_method(:stale_waiting) { {} }
      end
    end

    # Claude writes `done` 13-29ms before `idle`, so a session read ahead of the hook read
    # would widen that race with its ps/lsof.
    def test_the_hooks_are_read_before_the_sessions
      reads = []
      as = agent_state do |_paths, hooks_only: false|
        reads << :hooks
        {}
      end
      stub_method(ClaudeSessions, :scan, ->(*, **) { reads << :sessions; {} }) do
        Presence.scan(["/wt/a"], agent_state: as)
      end
      assert_equal %i[hooks sessions], reads
    end

    # The on-screen reload after a delete passes hooks_only alone, and a hidden pane's normal
    # scan passes cheap alone, so neither knob may imply the other.
    def test_hooks_only_reaches_the_agents_and_cheap_reaches_the_sessions
      [[true, false], [false, true]].each do |hooks_only, cheap|
        seen = []
        as = agent_state do |_paths, hooks_only: false|
          seen << hooks_only
          {}
        end
        stub_method(ClaudeSessions, :scan, ->(_paths, cheap: false) { seen << cheap; {} }) do
          Presence.scan(["/wt/a"], agent_state: as, hooks_only: hooks_only, cheap: cheap)
        end
        assert_equal [hooks_only, cheap], seen
      end
    end

    # Value: protects=idle and fresh reach the snapshot unswapped; fails_when=scan crosses the two
    # fields; why_new=the sidebar seam test stubs scan, so a swap survived the suite; seam=none;
    # no_claim=real session files (records stubbed)
    def test_a_snapshot_carries_each_source
      a = File.realpath(path)
      Monitoring.mark(a)
      Notify.mark(a)
      now_ms = Time.now.to_f * 1000
      settled = { status: "idle", status_at: now_ms - ((ClaudeSessions::SETTLE + 5) * 1000) }
      recs = { a => [{ status: "busy", pid: 7 }], "/settled" => [settled], "/fresh" => [{ status: "idle", status_at: now_ms }] }
      snap = stub_method(ClaudeSessions, :scan, ->(*, **) { recs }) do
        Presence.scan([a], agent_state: agent_state({ a => :done }))
      end
      assert_equal({ a => :done }, snap.agents)
      assert_equal recs, snap.sessions
      assert_equal({ a => 7 }, snap.offstage)
      assert_equal({ a => 7 }, snap.handoff)
      assert_equal Set["/settled"], snap.idle
      assert_equal Set["/fresh"], snap.fresh
      assert_includes snap.monitoring, a
      assert_includes snap.notify, a
    end

    # Value: protects=handoff names the busy session beside a shell one; fails_when=handoff reuses
    # the first offstage pid; why_new=every other row has one record, so that survived; seam=none;
    # no_claim=real session files (literal records)
    # --- merge_waiting: a Claude session's `waiting` is the ◆'s evidence ------------------
    def waiting_rec = { status: "waiting", pid: 7 }
    def settled_idle = { status: "idle", pid: 7, status_at: (Time.now.to_f - ClaudeSessions::SETTLE - 5) * 1000 }
    def fresh_idle = { status: "idle", pid: 7, status_at: Time.now.to_f * 1000 }

    # Value: protects=a subagent's tool call can't turn an open dialog into a bold ● and a false chime; fails_when=the hook file wins over the session; why_new=Presence had no merge; seam=none; no_claim=real sessions-file semantics (live probe, 2.1.327)
    def test_a_session_at_a_dialog_overrules_a_hook_overwritten_to_done
      agents, hooks, confirmed = Presence.merge_waiting({ "/a" => :done }, { "/a" => :done }, {},
                                                        { "/a" => [waiting_rec] }, Set.new)
      assert_equal({ "/a" => :waiting }, agents)
      assert_equal({ "/a" => :waiting }, hooks, "the edge tracker sees a steady waiting: no edge, baseline stays waiting")
      assert_equal Set["/a"], confirmed
    end

    def test_an_unhooked_claude_at_a_dialog_draws_waiting_but_feeds_no_edge
      agents, hooks, = Presence.merge_waiting({}, {}, {}, { "/a" => [waiting_rec] }, Set.new)
      assert_equal({ "/a" => :waiting }, agents)
      assert_empty hooks
    end

    # Value: protects=a rejected prompt's ◆ goes when its session settles idle, with no chime; fails_when=the confirmed rule is dropped or the path stays in the edge input; why_new=no Esc case existed; seam=none; no_claim=real Esc timing (live probe)
    def test_a_confirmed_dialog_rejected_with_esc_rests_without_an_edge
      agents, hooks, confirmed = Presence.merge_waiting({ "/a" => :waiting }, { "/a" => :waiting }, {},
                                                        { "/a" => [settled_idle] }, Set["/a"])
      assert_equal({ "/a" => :done }, agents)
      assert_empty hooks, "left out of the edge input: a waiting→done here would chime for a reject"
      assert_equal Set["/a"], confirmed, "stays cleared until the hook leaves waiting"
    end

    # Value: protects=the sessions file can't hide a dialog it never reported; fails_when=the clear skips the confirmed check; why_new=pins D9's fail-visible guard; seam=none; no_claim=which dialogs Claude reports as waiting
    def test_an_unconfirmed_waiting_beside_an_idle_session_keeps_its_diamond
      agents, hooks, confirmed = Presence.merge_waiting({ "/a" => :waiting }, { "/a" => :waiting }, {},
                                                        { "/a" => [settled_idle] }, Set.new)
      assert_equal({ "/a" => :waiting }, agents)
      assert_equal({ "/a" => :waiting }, hooks)
      assert_empty confirmed
    end

    def test_a_confirmed_dialog_waits_for_a_settled_idle
      agents, = Presence.merge_waiting({ "/a" => :waiting }, { "/a" => :waiting }, {}, { "/a" => [fresh_idle] }, Set["/a"])
      assert_equal({ "/a" => :waiting }, agents, "an idle inside the 2s race window is no evidence yet")
    end

    def test_confirmed_ends_when_the_hook_moves_on
      _, _, confirmed = Presence.merge_waiting({ "/a" => :thinking }, { "/a" => :thinking }, {},
                                               { "/a" => [{ status: "busy", pid: 7 }] }, Set["/a"])
      assert_empty confirmed, "the next prompt starts fresh"
    end

    # Value: protects=Claude with a readable session gets no TTL extension (D2); fails_when=a stale ◆ ignores the session; why_new=stale_waiting is new; seam=none; no_claim=none beyond protects
    def test_a_readable_session_overrules_the_stale_waiting_extension
      agents, hooks, = Presence.merge_waiting({ "/a" => :waiting, "/b" => :waiting }, { "/a" => :waiting, "/b" => :waiting },
                                              { "/a" => :done, "/b" => nil }, { "/a" => [settled_idle] }, Set.new)
      assert_equal :done, agents["/a"], "a session that says otherwise wins"
      assert_equal :waiting, agents["/b"], "no session (Codex): the extension stands"
      assert_equal({ "/b" => :waiting }, hooks)
    end

    # Value: protects=an undocumented session status can't erase a live ◆ (fail closed); fails_when=any non-empty session overrules the extension; why_new=the test above uses a recognized idle only; seam=none; no_claim=which statuses Claude adds later
    def test_an_unrecognized_session_status_leaves_the_stale_waiting_standing
      [{ status: "compacting", pid: 7 }, { pid: 7 }, fresh_idle].each do |rec|
        agents, hooks, = Presence.merge_waiting({ "/a" => :waiting }, { "/a" => :waiting }, { "/a" => :done },
                                                { "/a" => [rec] }, Set.new)
        assert_equal :waiting, agents["/a"], "#{rec.inspect} is no evidence"
        assert_equal({ "/a" => :waiting }, hooks)
      end
    end

    # Value: protects=the merge never writes into the scan's shared sessions hash; fails_when=it reads sessions[path] through the default proc; why_new=ClaudeSessions.scan's hash keeps that proc; seam=none; no_claim=none beyond protects
    def test_the_merge_leaves_the_sessions_hash_untouched
      sessions = Hash.new { |h, k| h[k] = [] }
      Presence.merge_waiting({ "/a" => :done }, { "/a" => :done }, {}, sessions, Set["/b"])
      assert_empty sessions
    end

    def test_a_failed_session_read_changes_nothing
      args = [{ "/a" => :done }, { "/a" => :done }, { "/a" => :done }, nil, Set["/a"]]
      assert_equal args.values_at(0, 1, 4), Presence.merge_waiting(*args)
    end

    def test_session_evidence_sorts_each_session_state
      now = Time.at(1_000)
      at = ->(secs_ago) { (now.to_f - secs_ago) * 1000 }
      offstage, handoff, idle, fresh = Presence.session_evidence(
        {
          "/agent" => [{ status: "busy", pid: 1 }],
          "/shell" => [{ status: "shell", pid: 2 }],
          "/mixed" => [{ status: "shell", pid: 3 }, { status: "busy", pid: 4 }],
          "/settled" => [{ status: "idle", status_at: at.call(ClaudeSessions::SETTLE) }],
          "/fresh" => [{ status: "idle", status_at: at.call(0) }],
          "/waiting" => [{ status: "waiting" }]
        },
        now: now
      )
      assert_equal({ "/agent" => 1, "/shell" => 2, "/mixed" => 3 }, offstage)
      assert_equal({ "/agent" => 1, "/mixed" => 4 }, handoff, "only a background agent holds the chime")
      assert_equal Set["/settled"], idle
      assert_equal Set["/fresh"], fresh
    end

    def test_a_failed_session_read_is_nil_not_empty
      snap = stub_method(ClaudeSessions, :scan, ->(*, **) { raise "unreadable" }) do
        Presence.scan(["/wt/a"], agent_state: agent_state)
      end
      assert_nil snap.sessions, "{} would read as every session finished"
      assert_empty snap.offstage
    end

    # The read succeeded, so the evidence blanks without the read reporting a failure.
    def test_a_fault_reading_the_evidence_keeps_the_sessions
      recs = { "/wt/a" => [{ status: "busy", pid: 7 }] }
      snap = stub_method(ClaudeSessions, :scan, ->(*, **) { recs }) do
        stub_method(ClaudeSessions, :activity, ->(*, **) { raise "odd record" }) do
          Presence.scan(["/wt/a"], agent_state: agent_state)
        end
      end
      assert_equal recs, snap.sessions
      assert_empty snap.offstage
      assert_empty snap.handoff
    end

    def test_an_agent_state_fault_raises_to_the_caller
      as = agent_state { |*, **| raise "hook dir vanished" }
      assert_raises(RuntimeError) { Presence.scan(["/wt/a"], agent_state: as) }
    end

    def test_a_monitoring_fault_raises_to_the_caller
      stub_method(Monitoring, :monitored, ->(*) { raise "marker dir vanished" }) do
        assert_raises(RuntimeError) { Presence.scan(["/wt/a"], agent_state: agent_state) }
      end
    end

    def test_links_pass_every_argument_through
      seen = nil
      stub_method(RemoteLink, :scan, ->(paths, **kw) { seen = [paths, kw]; { "/wt/a" => [] } }) do
        result = Presence.links(["/wt/a"], cheap: true, sessions: { "/wt/a" => [] }, stale_after: 60)
        assert_equal({ "/wt/a" => [] }, result)
      end
      assert_equal [["/wt/a"], { stale_after: 60, cheap: true, sessions: { "/wt/a" => [] } }], seen
    end

    def test_a_link_fault_is_empty_links
      stub_method(RemoteLink, :scan, ->(*, **) { raise "format changed" }) do
        assert_equal({}, Presence.links(["/wt/a"], cheap: false, sessions: nil, stale_after: nil))
      end
    end
  end
end
