# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/sidebar_case"
require "json"

module Switchboard
  # The ◷ "waiting on background work" dot and its held chime: a turn that ends while
  # work it started still runs (Claude's session reads busy/shell) shows ◷; a background
  # agent (`busy`) also holds the done chime + bold until that work is over.
  class SidebarOffstageTest < SidebarCase
    def edges(prev: nil)
      e = Sidebar::Edges.new
      e.instance_variable_set(:@prev_hook_states, prev) if prev
      e
    end

    def scan(e, now, path, offstage: {}, idle: Set.new, announce_sounds: true, monitoring: Set.new, current_path: nil)
      e.on_scan(now, monitoring: monitoring, nodes: [ws("a", path: path)], config: Config.new,
                current_path: current_path, offstage: offstage, idle: idle,
                announce_sounds: announce_sounds, refresh_prs: false)
    end

    def sounds_during
      played = []
      stub_method(Sound, :play, ->(spec, **) { played << spec }) { yield }
      played
    end

    def dead_pid = 2**22 + 12_345

    # --- Edges: the hold --------------------------------------------------------

    def test_a_hand_off_holds_the_chime_and_the_bold
      w = real_dir("a")
      e = edges(prev: { w => :thinking })
      played = sounds_during { scan(e, { w => :done }, w, offstage: { w => Process.pid }) }
      assert_empty played
      refute Attention.marked([w]).include?(w)
      assert_equal({ w => Process.pid }, OffstageHold.held([w]).transform_values { _1[:pid] })
    end

    # Regression (D5-2): a normal turn end — the session already reads idle — rings and
    # bolds on the same scan, exactly as before the ◷.
    def test_a_normal_completion_still_rings_and_bolds_on_the_same_scan
      w = real_dir("a")
      e = edges(prev: { w => :thinking })
      played = sounds_during { scan(e, { w => :done }, w, idle: Set[w]) }
      assert_equal ["train"], played
      assert_includes Attention.marked([w]), w
      assert_empty OffstageHold.held([w])
    end

    def test_a_held_chime_rings_once_when_the_session_settles_idle
      w = real_dir("a")
      OffstageHold.hold(w, pid: Process.pid)
      e = edges(prev: { w => :done })
      played = sounds_during do
        scan(e, { w => :done }, w, idle: Set[w])
        scan(e, { w => :done }, w, idle: Set[w])
      end
      assert_equal ["train"], played, "one ring, then the hold is gone"
      assert_includes Attention.marked([w]), w
    end

    # Codex O2 / D8: missing evidence (a failed scan, a garbled file, an unknown status)
    # is not "finished".
    def test_no_evidence_keeps_holding_silently
      w = real_dir("a")
      OffstageHold.hold(w, pid: Process.pid)
      played = sounds_during { scan(edges(prev: { w => :done }), { w => :done }, w) }
      assert_empty played
      assert_equal [w], OffstageHold.held([w]).keys
    end

    def test_a_gone_session_process_matures_the_hold
      w = real_dir("a")
      OffstageHold.hold(w, pid: dead_pid)
      played = sounds_during { scan(edges(prev: { w => :done }), { w => :done }, w) }
      assert_equal ["train"], played
    end

    def test_still_offstage_keeps_holding
      w = real_dir("a")
      OffstageHold.hold(w, pid: dead_pid)
      played = sounds_during { scan(edges(prev: { w => :done }), { w => :done }, w, offstage: { w => Process.pid }) }
      assert_empty played
      assert_equal [w], OffstageHold.held([w]).keys
    end

    # Only an on-screen announcing scan claims; a warm or catch-up scan leaves it.
    def test_a_silent_scan_leaves_a_mature_hold_for_the_on_screen_pane
      w = real_dir("a")
      OffstageHold.hold(w, pid: Process.pid)
      e = edges(prev: { w => :done })
      played = sounds_during { scan(e, { w => :done }, w, idle: Set[w], announce_sounds: false) }
      assert_empty played
      refute Attention.marked([w]).include?(w), "no bold without the claim"
      played = sounds_during { scan(e, { w => :done }, w, idle: Set[w]) }
      assert_equal ["train"], played
    end

    def test_the_follow_up_turn_releases_the_hold_and_its_own_stop_rings
      w = real_dir("a")
      e = edges(prev: { w => :done })
      OffstageHold.hold(w, pid: Process.pid)
      played = sounds_during do
        scan(e, { w => :thinking }, w, offstage: { w => Process.pid })
        assert_empty OffstageHold.held([w]), "released by the follow-up turn"
        scan(e, { w => :done }, w, idle: Set[w])
      end
      assert_equal ["train"], played, "the follow-up turn's own Stop rings, once"
    end

    # Codex O1 / D7: a pane that was off screen at the hand-off (its baseline already read
    # done, so it never saw the edge) still rings when it's the one on screen at the finish.
    def test_a_pane_that_missed_the_hand_off_still_rings_it
      w = real_dir("a")
      edges(prev: { w => :thinking }).tap { |other| scan(other, { w => :done }, w, offstage: { w => 1 }) }
      fresh = edges(prev: { w => :done })
      played = sounds_during { scan(fresh, { w => :done }, w, idle: Set[w]) }
      assert_equal ["train"], played
    end

    def test_a_warm_scan_writes_the_hold_too
      w = real_dir("a")
      sounds_during { scan(edges(prev: { w => :thinking }), { w => :done }, w, offstage: { w => 1 }, announce_sounds: false) }
      assert_equal [w], OffstageHold.held([w]).keys
    end

    def test_a_monitored_worktree_never_holds
      w = real_dir("a")
      played = sounds_during do
        scan(edges(prev: { w => :thinking }), { w => :done }, w, offstage: { w => 1 }, monitoring: Set[w])
      end
      assert_empty played
      assert_empty OffstageHold.held([w])
    end

    def test_a_waiting_edge_is_never_held
      w = real_dir("a")
      played = sounds_during { scan(edges(prev: { w => :thinking }), { w => :waiting }, w, offstage: { w => 1 }) }
      assert_equal ["chime"], played
      assert_empty OffstageHold.held([w])
    end

    # Value: protects=a hand-off whose hold can't be written still chimes (now, not never);
    # fails_when=the hand-off leaves completions before its hold lands; why_new=review found
    # the lost chime; seam=none; no_claim=a real disk error (stubbed to fail)
    def test_a_hold_that_fails_to_land_rings_now
      w = real_dir("a")
      played = stub_method(OffstageHold, :hold, ->(*, **) { false }) do
        sounds_during { scan(edges(prev: { w => :thinking }), { w => :done }, w, offstage: { w => 1 }) }
      end
      assert_equal ["train"], played
      assert_includes Attention.marked([w]), w
    end

    # Value: protects=one chime per turn end across panes; fails_when=an announcing normal
    # ring leaves the hold a peer pane wrote inside the done-before-idle race, which then
    # matures and rings the same end again; why_new=review (cross-pane race); seam=none;
    # no_claim=two real sidebar processes (two Edges stand in)
    def test_an_on_screen_normal_ring_consumes_a_peer_s_race_hold
      w = real_dir("a")
      scan(edges(prev: { w => :thinking }), { w => :done }, w, offstage: { w => 1 }, announce_sounds: false)
      assert_equal [w], OffstageHold.held([w]).keys, "the silent pane scanned inside the race"
      e = edges(prev: { w => :thinking })
      played = sounds_during do
        scan(e, { w => :done }, w)
        scan(e, { w => :done }, w, idle: Set[w])
      end
      assert_equal ["train"], played
      assert_empty OffstageHold.held([w])
    end

    # Value: protects=a short follow-up turn only an off-screen pane saw still rings once on
    # screen; fails_when=a silent scan releases the hold on the follow-up's :thinking;
    # why_new=review (red team); seam=none; no_claim=real scan cadences
    def test_a_follow_up_turn_only_a_silent_pane_saw_still_rings_on_screen
      w = real_dir("a")
      OffstageHold.hold(w, pid: Process.pid)
      scan(edges(prev: { w => :done }), { w => :thinking }, w, offstage: { w => 1 }, announce_sounds: false)
      assert_equal [w], OffstageHold.held([w]).keys, "a silent pane leaves it held"
      played = sounds_during { scan(edges(prev: { w => :done }), { w => :done }, w, idle: Set[w]) }
      assert_equal ["train"], played, "the on-screen pane, which saw no edge, rings it on maturity"
    end

    # Value: protects=a silent pane that sees the hand-off edge LATE (after the work ended)
    # never takes the only ring; fails_when=a silent normal :done releases holds (Codex
    # adversarial review: zero chimes); why_new=review; seam=none; no_claim=real cadences
    def test_a_silent_pane_seeing_the_hand_off_late_leaves_the_ring_on_screen
      w = real_dir("a")
      OffstageHold.hold(w, pid: Process.pid, now: Time.now - 60)
      scan(edges(prev: { w => :thinking }), { w => :done }, w, idle: Set[w], announce_sounds: false)
      assert_equal [w], OffstageHold.held([w]).keys
      played = sounds_during { scan(edges(prev: { w => :done }), { w => :done }, w, idle: Set[w]) }
      assert_equal ["train"], played
    end

    def test_a_failed_session_read_releases_nothing
      w = real_dir("a")
      OffstageHold.hold(w, pid: Process.pid)
      e = edges(prev: { w => :thinking })
      sounds_during do
        e.on_scan({ w => :done }, monitoring: Set.new, nodes: [ws("a", path: w)], config: Config.new,
                  current_path: nil, refresh_prs: false, sessions_ok: false)
      end
      assert_equal [w], OffstageHold.held([w]).keys, "no evidence: the hold stays for the real finish"
    end

    def test_a_garbled_hold_pid_is_no_evidence_and_never_stalls_the_others
      w = real_dir("a")
      x = real_dir("b")
      OffstageHold.hold(x, pid: dead_pid)
      File.write(File.join(OffstageHold.state_dir, OffstageHold.key(w)), "#{w}\t0\t99999999999999")
      assert_nil OffstageHold.held([w])[w][:pid]
      e = edges(prev: { w => :done, x => :done })
      played = sounds_during do
        e.on_scan({ w => :done, x => :done }, monitoring: Set.new, nodes: [ws("a", path: w), ws("b", path: x)],
                  config: Config.new, current_path: nil, refresh_prs: false)
      end
      assert_equal ["train"], played, "b's dead pid matures; a's garbled pid neither raises nor matures"
      assert_equal [w], OffstageHold.held([w, x]).keys
    end

    # The silent-scan cells of the hold state matrix (state-machines review): a warm or
    # catch-up scan never rings, never claims, never releases.
    def test_a_silent_scan_never_resolves_a_hold
      w = real_dir("a")
      { "still offstage" => { offstage: { w => 1 } }, "pid gone" => {}, "no evidence" => {},
        "follow-up turn" => { now: :thinking }, "a prompt" => { now: :waiting } }.each do |cell, opt|
        OffstageHold.hold(w, pid: cell == "pid gone" ? dead_pid : Process.pid)
        played = sounds_during do
          scan(edges(prev: { w => :done }), { w => opt.fetch(:now, :done) }, w,
               offstage: opt.fetch(:offstage, {}), announce_sounds: false)
        end
        assert_empty played, cell
        assert_equal [w], OffstageHold.held([w]).keys, cell
        OffstageHold.clear_all
      end
    end

    def test_a_subagent_prompt_releases_the_hold_and_rings_its_own_chime
      w = real_dir("a")
      OffstageHold.hold(w, pid: Process.pid)
      played = sounds_during { scan(edges(prev: { w => :done }), { w => :waiting }, w, offstage: { w => 1 }) }
      assert_equal ["chime"], played
      assert_empty OffstageHold.held([w])
    end

    # Learning: a raise in a new on_scan consumer must not lose the edges or the baseline.
    def test_a_hold_store_fault_leaves_the_scan_intact
      w = real_dir("a")
      e = edges(prev: { w => :thinking })
      got = nil
      stub_method(OffstageHold, :held, ->(*) { raise "boom" }) { sounds_during { got = scan(e, { w => :done }, w) } }
      assert_equal [w], got
      assert_equal :done, e.instance_variable_get(:@prev_hook_states)[w]
    end

    # --- render ---------------------------------------------------------------

    def state_of(agents: {}, monitoring: [], offstage: [], creation: nil)
      w = "/wt/a"
      sb = sidebar(nodes: [ws("a", path: w)], agents: { w => agents }.compact, monitoring: monitoring.map { w })
      sb.instance_variable_set(:@offstage, offstage.empty? ? Set.new : Set[w])
      sb.instance_variable_set(:@creation_for, creation ? { w => creation } : {})
      sb.send(:render_state, w)
    end

    # Regression (D5-3) + the new row: the full precedence table in one place.
    def test_render_state_precedence
      assert_equal :thinking, state_of(agents: :thinking)
      assert_equal :waiting, state_of(agents: :waiting)
      assert_equal :done, state_of(agents: :done)
      assert_nil state_of(agents: nil)
      assert_equal :monitoring, state_of(agents: :done, monitoring: [1])
      assert_equal :failed, state_of(agents: :done, creation: { "state" => "failed" })
      assert_equal :building, state_of(agents: nil, creation: { "state" => "building" })
      assert_equal :offstage, state_of(agents: :done, offstage: [1])
      assert_equal :offstage, state_of(agents: nil, offstage: [1]), "render_state draws it over a blank row; settled_offstage decides who gets there"
      assert_equal :thinking, state_of(agents: :thinking, offstage: [1]), "live work wins"
      assert_equal :waiting, state_of(agents: :waiting, offstage: [1]), "an input request wins"
      assert_equal :monitoring, state_of(agents: :done, monitoring: [1], offstage: [1]), "∞ outranks ◷"
    end

    def test_the_glyph_and_the_legend
      sb = sidebar
      assert_equal "◷", sb.send(:glyph_for, :offstage)
      assert_equal "\e[1;34m◷\e[0m", sb.send(:dot_for, :offstage)
      assert_equal "\e[1;34m", Sidebar::SPIN_COLORED.first[0, 7], "the spinner's exact blue"
      assert(Sidebar::LEGEND.any? { |_c, glyph, label| glyph == "◷" && label == "background" })
    end

    # --- refresh_agents: the evidence -------------------------------------------

    def write_session(cwd, status:, at: Time.now)
      FileUtils.mkdir_p(ClaudeSessions.sessions_dir)
      File.write(File.join(ClaudeSessions.sessions_dir, "#{Process.pid}.json"),
                 JSON.generate("pid" => Process.pid, "cwd" => cwd, "sessionId" => "s", "kind" => "interactive",
                               "procStart" => ProcessIdentity.start_of(Process.pid), "status" => status,
                               "statusUpdatedAt" => (at.to_f * 1000).to_i))
    end

    def write_hook(cwd, state, epoch)
      FileUtils.mkdir_p(AgentState.state_dir)
      File.write(File.join(AgentState.state_dir, "1"), "#{state}\t#{cwd}\t#{epoch}\n")
    end

    def refreshed(w)
      sb = sidebar(nodes: [ws("a", path: w)])
      stub_method(Agents, :cwds_of, ->(*) { {} }) { sb.send(:refresh_agents, refresh_prs: false, hooks_only: true) }
      sb
    end

    def test_a_settled_hand_off_draws_the_clock
      w = real_dir("a")
      write_session(w, status: "busy")
      write_hook(w, "done", Time.now.to_i - 5)
      sb = refreshed(w)
      assert_equal :offstage, sb.send(:render_state, w)
      assert_equal({ w => Process.pid }, sb.instance_variable_get(:@offstage_raw))
    end

    # Claude writes `done` 13-29ms before `idle` on a normal turn end (probed live): a
    # fresh `done` beside `busy` must not flash ◷.
    # Value: protects=a background shell (maybe a dev server that never ends) shows ◷ but never
    # holds the chime, which would mute the turn you're waiting on; fails_when=`shell` joins the
    # hand-off evidence; why_new=review (D6: hold only on busy); seam=none; no_claim=a real shell
    def test_a_background_shell_draws_the_clock_but_holds_nothing
      w = real_dir("a")
      write_session(w, status: "shell")
      write_hook(w, "done", Time.now.to_i - 5)
      sb = refreshed(w)
      assert_equal :offstage, sb.send(:render_state, w)
      assert_empty sb.instance_variable_get(:@offstage_raw)
    end

    def test_a_fresh_done_beside_busy_does_not_draw_the_clock
      w = real_dir("a")
      write_session(w, status: "busy")
      write_hook(w, "done", Time.now.to_i)
      sb = refreshed(w)
      assert_equal :done, sb.send(:render_state, w)
      assert_equal [w], sb.instance_variable_get(:@offstage_raw).keys, "the hold still sees it"
    end

    # Value: protects=◷ stays up through a background job longer than PRESENCE_TTL; fails_when=
    # settled_offstage needs a fresh hook age (v6 writes none during subagent work); why_new=
    # review (adversarial F2 + Codex); seam=none; no_claim=a real 15-minute job
    def test_the_clock_outlives_the_hook_report_s_presence_ttl
      w = real_dir("a")
      write_session(w, status: "busy")
      write_hook(w, "done", Time.now.to_i - AgentState::PRESENCE_TTL - 60)
      sb = sidebar(nodes: [ws("a", path: w)])
      sb.instance_variable_get(:@edges).instance_variable_set(:@prev_hook_states, { w => :done })
      stub_method(Agents, :cwds_of, ->(*) { {} }) { sb.send(:refresh_agents, refresh_prs: false, hooks_only: true) }
      assert_equal :offstage, sb.send(:render_state, w)
    end

    def test_an_idle_session_draws_the_plain_dot
      w = real_dir("a")
      write_session(w, status: "idle", at: Time.now - 10)
      write_hook(w, "done", Time.now.to_i - 10)
      assert_equal :done, refreshed(w).send(:render_state, w)
    end

    # Value: protects=a hook-less Claude never reads as a hand-off (D2: its session is
    # `busy` through every foreground turn, so ◷ there would claim background work that
    # isn't there); fails_when=settled_offstage accepts a missing hook age again;
    # why_new=the hook-less ◷ was dropped in review; seam=none; no_claim=a real hook-less Claude
    def test_a_hook_less_busy_session_never_draws_the_clock
      w = real_dir("a")
      write_session(w, status: "busy")
      sb = refreshed(w)
      refute_equal :offstage, sb.send(:render_state, w)
      assert_equal [w], sb.instance_variable_get(:@offstage_raw).keys, "still offstage evidence for holds"
    end

    # Value: protects=a hidden pane repaints ● → ◷ once the hand-off's done settles, though
    # nothing on disk changes then; fails_when=the warm fingerprint drops hook_fingerprint's
    # settled bit (back to a plain dir_fingerprint), leaving off-screen panes on a stale ●
    # until switch-in; why_new=no test covered the settle bit; seam=none (Time.now stubbed
    # only to age a fixed mtime); no_claim=the real IDLE/WARM_TTL cadence
    def test_a_hook_report_crossing_the_settle_line_moves_the_warm_fingerprint
      w = real_dir("a")
      write_hook(w, "done", Time.now.to_i)
      file = File.join(AgentState.state_dir, "1")
      t = Time.now
      File.utime(t, t, file)
      sb = sidebar(nodes: [ws("a", path: w)])
      fresh = stub_method(Time, :now, -> { t + 0.5 }) { sb.send(:warm_fingerprint) }
      again = stub_method(Time, :now, -> { t + 1 }) { sb.send(:warm_fingerprint) }
      settled = stub_method(Time, :now, -> { t + ClaudeSessions::SETTLE + 1 }) { sb.send(:warm_fingerprint) }
      assert_equal fresh, again, "still unsettled: no wake"
      refute_equal fresh, settled, "the done settling wakes the hidden pane"
    end

    # --- the dispatch ping (D9) -------------------------------------------------

    def test_a_dispatch_handed_off_on_turn_one_waits_to_ping
      w = "/wt/a"
      sb = sidebar(nodes: [ws("a", path: w)])
      sb.instance_variable_set(:@visible, true)
      sb.instance_variable_set(:@creation_for, { w => { "id" => "c1", "state" => "turn_done" } })
      rung = []
      sb.instance_variable_get(:@edges).define_singleton_method(:announce) { |path, *| rung << path }
      stub_method(Creation, :ring_due?, ->(*) { true }) do
        stub_method(Creation, :claim_ring, ->(*) { { "project" => "app", "state" => "turn_done" } }) do
          sb.instance_variable_set(:@offstage_raw, { w => 1 })
          sb.send(:ring_creations)
          assert_empty rung, "still offstage: the durable ping waits"
          sb.instance_variable_set(:@offstage_raw, {})
          sb.send(:ring_creations)
        end
      end
      assert_equal [w], rung
    end

    # Value: protects=a first-turn ping waits only on POSITIVE evidence the work goes on;
    # fails_when=it waits on missing evidence (a drifted status or failed read would silence
    # every dispatch ping) or rings on the ~15ms fresh idle; why_new=review (adversarial F1);
    # seam=none; no_claim=real session files
    def test_the_dispatch_ping_waits_only_on_busy_or_a_fresh_idle
      w = "/wt/a"
      sb = sidebar(nodes: [ws("a", path: w)])
      sb.instance_variable_set(:@offstage_raw, { w => 1 })
      assert sb.send(:dispatch_waiting?, w), "busy (a background agent)"
      sb.instance_variable_set(:@offstage_raw, {})
      sb.instance_variable_set(:@session_fresh, Set[w])
      assert sb.send(:dispatch_waiting?, w), "an idle too fresh to trust"
      sb.instance_variable_set(:@session_fresh, Set.new)
      refute sb.send(:dispatch_waiting?, "/wt/b"), "no evidence (no session, failed read) rings"
    end

    # Value: protects=a dispatch whose first turn left a dev server running still pings at
    # its end; fails_when=the ping waits on `shell` (it may never end); why_new=review (D6);
    # seam=none; no_claim=a real dev server
    def test_a_background_shell_never_holds_the_dispatch_ping
      w = real_dir("a")
      write_session(w, status: "shell")
      write_hook(w, "done", Time.now.to_i - 5)
      refute refreshed(w).send(:dispatch_waiting?, w)
    end

    # Value: protects=a bare/hook-less create's READY ping (it launched) isn't held for its
    # work; fails_when=the gate applies to every record; why_new=review (Codex structured);
    # seam=none; no_claim=a real dispatch
    def test_a_ready_ping_isn_t_gated_on_background_work
      w = "/wt/a"
      sb = sidebar(nodes: [ws("a", path: w)])
      sb.instance_variable_set(:@visible, true)
      sb.instance_variable_set(:@creation_for, { w => { "id" => "c1", "state" => "ready" } })
      sb.instance_variable_set(:@offstage_raw, { w => 1 })
      rung = []
      sb.instance_variable_get(:@edges).define_singleton_method(:announce) { |p, *| rung << p }
      stub_method(Creation, :ring_due?, ->(*) { true }) do
        stub_method(Creation, :claim_ring, ->(*) { { "project" => "app", "state" => "ready" } }) { sb.send(:ring_creations) }
      end
      assert_equal [w], rung
    end

    def test_a_failed_dispatch_rings_even_while_its_session_is_busy
      w = "/wt/a"
      sb = sidebar(nodes: [ws("a", path: w)])
      sb.instance_variable_set(:@visible, true)
      sb.instance_variable_set(:@creation_for, { w => { "id" => "c1", "state" => "failed" } })
      sb.instance_variable_set(:@offstage_raw, { w => 1 })
      rung = []
      sb.instance_variable_get(:@edges).define_singleton_method(:announce) { |_p, _proj, st, *| rung << st }
      stub_method(Creation, :ring_due?, ->(*) { true }) do
        stub_method(Creation, :claim_ring, ->(*) { { "project" => "app", "state" => "failed" } }) do
          sb.send(:ring_creations)
        end
      end
      assert_equal [:failed], rung
    end
  end
end
