# frozen_string_literal: true

require_relative "support/sidebar_case"

module Switchboard
  # The sidebar's code reload (#48): asked by SIGUSR1 or the moved-keg backstop, it
  # execs itself in place at a safe point and the new image resumes from the payload.
  # exec, the preflight and tmux are stubbed; the decisions are what's pinned here
  # (the real exec is in test/smoke/sidebar_reload_smoke_test.rb).
  class SidebarReloadTest < SidebarCase
    def teardown
      trap(CodeReload::SIGNAL, "DEFAULT") # a test that installed the real trap never leaks it
      super
    end

    # --- start-up: the cold start is unchanged (R3), a resume shows no blank frame ----

    # Drives the real `run` against an EOF stdin (the loop exits on its first read).
    # Returns [stdout, call log, sidebar].
    def run_sidebar(visible:, resume: nil, prewarm: true)
      File.write(ENV["SWITCHBOARD_CONFIG"], "projects: []\n")
      ENV[CodeReload::RESUME_ENV] = resume if resume
      sb = Sidebar.new
      sb.instance_variable_get(:@config).define_singleton_method(:prewarm?) { prewarm }
      log = []
      %i[pin_if_resized cursor_to_current render].each { |m| sb.define_singleton_method(m) { |*| log << m } }
      sb.define_singleton_method(:reload) { |**kw| log << [:reload, kw] }
      sb.define_singleton_method(:warm_reload) { |*| log << :warm_reload }
      stdin, w = IO.pipe
      w.close
      stdin.define_singleton_method(:raw!) { nil }
      stdin.define_singleton_method(:cooked!) { nil }
      tag = ->(_pane, value) { log << [:tag, value, sb.instance_variable_get(:@wake_r) ? :trap_first : :tag_first] }
      out = with_stdin(stdin) do
        stub_method(Tmux, :enable_focus_events, -> {}) do
          stub_method(Tmux, :session_of, ->(*) { "sb/app/x" }) do
            stub_method(Tmux, :pane_tty, ->(*) { nil }) do
              stub_method(Tmux, :tag_sidebar_pane, tag) do
                stub_method(Tmux, :visible?, ->(*) { visible }) do
                  stub_method(Tmux, :focused?, ->(*) { false }) { capture_stdout { sb.run } }
                end
              end
            end
          end
        end
      end
      [out, log, sb]
    end

    def untagged(log) = log.reject { |e| e.is_a?(Array) && e.first == :tag }

    # Value: protects=today's first paint for every normal spawn (R3); fails_when=the resume
    # branch leaks into a cold start; why_new=run's startup had no unit test; seam=none;
    # no_claim=real terminal rendering (stubbed tmux, captured stdout)
    def test_a_cold_start_on_screen_is_unchanged
      out, log, = run_sidebar(visible: true)
      assert_includes out, "\e[2J", "a fresh sidebar clears its pane"
      assert_equal [:pin_if_resized, :render, [:reload, {}], :cursor_to_current, :render], untagged(log)
    end

    def test_a_cold_start_off_screen_paints_nothing
      out, log, = run_sidebar(visible: false)
      assert_includes out, "\e[2J"
      assert_empty untagged(log), "no paint, no reload: a hidden pane waits for its switch-in"
    end

    def test_the_tag_goes_on_after_the_trap
      _, log, = run_sidebar(visible: false)
      assert_equal [[:tag, Process.pid, :trap_first]], log.select { |e| e.is_a?(Array) && e.first == :tag },
                   "a sender may signal the moment it sees the tag (R4)"
    end

    def test_run_restores_the_signal_handler_on_exit
      before = trap(CodeReload::SIGNAL, "DEFAULT")
      trap(CodeReload::SIGNAL, before)
      run_sidebar(visible: false)
      assert_equal before, trap(CodeReload::SIGNAL, "DEFAULT"), "teardown puts back what was there"
    end

    def test_a_resume_on_screen_skips_the_clear_and_the_empty_paint
      out, log, sb = run_sidebar(visible: true, resume: CodeReload.encode(offset: 2, announce: true))
      refute_includes out, "\e[2J", "the old image's frame stays up until ours overwrites it"
      assert_equal [:pin_if_resized, [:reload, { announce_sounds: true }], :render], untagged(log)
      assert_equal 2, offset_of(sb)
      refute ENV.key?(CodeReload::RESUME_ENV), "taken, so no child inherits it"
    end

    def test_a_resume_announces_only_when_the_payload_says_so
      _, log, = run_sidebar(visible: true, resume: CodeReload.encode)
      assert_includes log, [:reload, { announce_sounds: false }], "a switch-in reload owes a silent catch-up (R7)"
    end

    # Value: protects=a fleet restarted at once doesn't rescan git at once (P1); fails_when=a
    # resumed hidden pane warms immediately; seam=none
    def test_a_resume_off_screen_waits_out_the_spread_before_its_first_warm
      ENV[CodeReload::SPREAD_ENV] = "30"
      _, log, sb = run_sidebar(visible: false, resume: CodeReload.encode)
      assert_empty untagged(log)
      assert_operator sb.instance_variable_get(:@warm_not_before), :>, sb.send(:monotonic)
      refute sb.send(:warm_spread_over?)
    end

    def test_a_resume_restores_the_carried_baseline
      _, _, sb = run_sidebar(visible: false, resume: CodeReload.encode(hook_states: { "/wt/a" => :thinking }))
      assert_equal :thinking, sb.instance_variable_get(:@edges).last_state("/wt/a")
    end

    # --- the carried cursor -------------------------------------------------------

    def test_the_cursor_returns_to_its_row_by_identity
      sb = sidebar(nodes: [proj("app"), ws("a"), ws("b")])
      sb.instance_variable_set(:@resume_cursor, { "kind" => "ws", "project" => "app", "path" => "/wt/b", "branch" => nil })
      sb.send(:restore_resumed_cursor)
      assert_equal "b", current_node(sb).name
      assert_nil sb.instance_variable_get(:@resume_cursor), "once only"
    end

    def test_a_vanished_cursor_row_falls_back_to_the_current_workspace
      sb = sidebar(nodes: [proj("app"), ws("a"), ws("b")], current_path: "/wt/a")
      sb.instance_variable_set(:@resume_cursor, { "kind" => "ws", "project" => "app", "path" => "/wt/gone", "branch" => nil })
      sb.send(:restore_resumed_cursor)
      assert_equal "a", current_node(sb).name
    end

    # --- when it execs ------------------------------------------------------------

    def reloading(visible:)
      sb = sidebar(nodes: [proj("app"), ws("a")])
      sb.instance_variable_set(:@visible, visible)
      execs = []
      sb.define_singleton_method(:reexec) { execs << :exec }
      [sb, execs]
    end

    def test_a_signal_on_screen_execs_at_the_next_loop_top
      sb, execs = reloading(visible: true)
      sb.instance_variable_set(:@reload_signal, true)
      sb.send(:maybe_reexec)
      assert_equal [:exec], execs
    end

    def test_off_screen_it_waits_for_its_spread_then_execs
      ENV[CodeReload::SPREAD_ENV] = "30"
      sb, execs = reloading(visible: false)
      sb.instance_variable_set(:@reload_signal, true)
      sb.send(:maybe_reexec)
      assert_empty execs, "a hidden pane spreads out"
      sb.instance_variable_set(:@reexec_at, sb.send(:monotonic) - 1)
      sb.send(:maybe_reexec)
      assert_equal [:exec], execs
    end

    def test_a_switch_in_makes_a_waiting_reload_due_at_once
      ENV[CodeReload::SPREAD_ENV] = "30"
      sb, execs = reloading(visible: false)
      sb.send(:request_reload)
      sb.instance_variable_set(:@visible, true) # what the C-l switch poke does
      sb.send(:maybe_reexec)
      assert_equal [:exec], execs, "D2: switch in before it reloaded, see it within a second"
    end

    def test_the_switch_poke_skips_its_reload_when_one_is_due
      sb, = reloading(visible: false)
      sb.send(:request_reload)
      reloads = 0
      sb.define_singleton_method(:reload) { |**| reloads += 1 }
      stub_method(Tmux, :visible?, ->(*) { true }) { sb.send(:reload_and_refresh) }
      assert_equal 0, reloads, "the new image's first reload replaces this one"
    end

    def test_an_overlay_or_the_filter_holds_the_reload
      [[:@help, true], [:@link_view, { path: "/wt/a" }], [:@filter, ""]].each do |ivar, value|
        sb, execs = reloading(visible: true)
        sb.instance_variable_set(ivar, value)
        sb.send(:request_reload)
        sb.send(:maybe_reexec)
        assert_empty execs, "#{ivar} open: wait"
        sb.instance_variable_set(ivar, ivar == :@help ? false : nil)
        sb.send(:maybe_reexec)
        assert_equal [:exec], execs, "#{ivar} closed: go"
      end
    end

    # Value: protects=a held reload never spins the CPU (R8); fails_when=frame_timeout honors a
    # passed deadline while blocked; seam=none
    def test_a_blocked_overdue_reload_keeps_the_normal_timeout
      sb, = reloading(visible: false)
      sb.instance_variable_set(:@reload_requested, true)
      sb.instance_variable_set(:@reexec_at, sb.send(:monotonic) - 5)
      sb.instance_variable_set(:@help, true)
      assert_equal Sidebar::IDLE, sb.send(:frame_timeout)
      sb.instance_variable_set(:@help, false)
      assert_equal 0, sb.send(:frame_timeout), "unblocked: wake now"
    end

    def test_a_spread_reload_shortens_the_off_screen_wait
      sb, = reloading(visible: false)
      sb.instance_variable_set(:@reload_requested, true)
      sb.instance_variable_set(:@reexec_at, sb.send(:monotonic) + 2)
      assert_operator sb.send(:frame_timeout), :<=, 2
    end

    # --- the backstop -------------------------------------------------------------

    def test_a_moved_keg_requests_a_reload_from_tick
      sb, = reloading(visible: false)
      sb.instance_variable_get(:@config).define_singleton_method(:prewarm?) { false }
      stub_method(CodeReload, :stale?, ->(*) { true }) do
        stub_method(CodeReload, :current_root, ->(*) { "/Cellar/new" }) do
          stub_method(Tmux, :visible?, ->(*) { false }) do
            stub_method(Tmux, :window_panes, ->(*) { 2 }) { sb.send(:tick) }
          end
        end
      end
      assert sb.instance_variable_get(:@reload_requested)
    end

    def test_a_root_whose_preflight_failed_is_not_retried
      sb, = reloading(visible: false)
      sb.instance_variable_set(:@reexec_blocked_root, "/Cellar/broken")
      stub_method(CodeReload, :stale?, ->(*) { true }) do
        stub_method(CodeReload, :current_root, ->(*) { "/Cellar/broken" }) { refute sb.send(:code_moved?) }
        stub_method(CodeReload, :current_root, ->(*) { "/Cellar/fixed" }) { assert sb.send(:code_moved?), "a newer keg gets its own try" }
      end
    end

    # Value: protects=an idle hidden pane still costs ~one tmux call per IDLE (R3);
    # fails_when=the backstop or the tag adds tmux work to every tick; seam=none
    def test_a_tick_with_an_unmoved_install_adds_no_tmux_calls
      sb, = reloading(visible: false)
      sb.instance_variable_get(:@config).define_singleton_method(:prewarm?) { false }
      ENV["SWITCHBOARD_BIN"] = File.join(CodeReload::LOADED_ROOT, "bin", "switchboard")
      calls = Hash.new(0)
      stub_method(Tmux, :visible?, ->(*) { calls[:visible?] += 1; false }) do
        stub_method(Tmux, :window_panes, ->(*) { calls[:window_panes] += 1; 2 }) do
          stub_method(Tmux, :tag_sidebar_pane, ->(*) { flunk "no tag per tick" }) { sb.send(:tick) }
        end
      end
      assert_equal({ visible?: 1, window_panes: 1 }, calls)
      refute sb.instance_variable_get(:@reload_requested)
    end

    # --- the exec itself ----------------------------------------------------------

    def exec_sidebar(preflight: true, &on_exec)
      ENV["SWITCHBOARD_BIN"] = "/opt/sb/bin/switchboard"
      sb = sidebar(nodes: [proj("app"), ws("a"), ws("b")], cursor: 2)
      sb.instance_variable_set(:@visible, true)
      sb.instance_variable_set(:@reload_requested, true)
      tags = []
      sb.define_singleton_method(:exec) { |*argv| on_exec.call(argv) }
      stub_method(CodeReload, :preflight, ->(*) { preflight }) do
        stub_method(CodeReload, :current_root, ->(*) { "/Cellar/new" }) do
          stub_method(Tmux, :tag_sidebar_pane, ->(_p, v) { tags << v }) { capture_stdout { sb.send(:reexec) } }
        end
      end
      [sb, tags]
    end

    # Value: protects=the new image starts clean and can't be killed by a second signal (R4);
    # fails_when=SB_REEXEC leaks into the exec, the payload is missing, or USR1 isn't ignored; seam=none
    def test_exec_hands_over_the_payload_ignores_the_signal_and_clears_the_tag
      ENV["SB_REEXEC"] = "1"
      seen = nil
      _, tags = exec_sidebar do |argv|
        seen = { argv: argv, payload: CodeReload.decode(ENV[CodeReload::RESUME_ENV]),
                 reexec: ENV.key?("SB_REEXEC"), usr1: trap(CodeReload::SIGNAL, "IGNORE") }
        raise Errno::ENOENT, "stop here"
      end
      assert_equal ["/opt/sb/bin/switchboard", "sidebar"], seen[:argv]
      assert_equal "/wt/b", seen[:payload][:cursor]["path"]
      refute seen[:reexec], "a system-Ruby re-exec must still happen in the new image"
      assert_equal "IGNORE", seen[:usr1], "ignored across exec (R4)"
      assert_equal [0, Process.pid], tags, "0 while between images, then restored after the failed exec"
    end

    def test_a_failed_exec_keeps_running_with_its_state_put_back
      ENV["SB_REEXEC"] = "1"
      sb, = exec_sidebar { raise Errno::ENOENT, "gone" }
      refute ENV.key?(CodeReload::RESUME_ENV)
      assert_equal "1", ENV["SB_REEXEC"]
      refute_equal "IGNORE", trap(CodeReload::SIGNAL, "DEFAULT"), "the handler is back"
      assert_equal "/Cellar/new", sb.instance_variable_get(:@reexec_blocked_root)
      refute sb.instance_variable_get(:@reload_requested)
    end

    def test_a_failed_preflight_never_execs_and_blocks_that_root
      sb, = exec_sidebar(preflight: false) { flunk "a binary that won't load is never exec'd" }
      assert_equal "/Cellar/new", sb.instance_variable_get(:@reexec_blocked_root)
    end

    def test_the_payload_announces_only_after_a_recent_on_screen_scan
      sb = sidebar(nodes: [proj("app"), ws("a")])
      now = sb.send(:monotonic)
      sb.instance_variable_set(:@visible, true)
      sb.instance_variable_set(:@last_announce_scan, now)
      assert CodeReload.decode(sb.send(:resume_payload))[:announce]
      sb.instance_variable_set(:@last_announce_scan, now - 60)
      refute CodeReload.decode(sb.send(:resume_payload))[:announce], "a stale baseline owes a catch-up"
      sb.instance_variable_set(:@last_announce_scan, now)
      sb.instance_variable_set(:@visible, false)
      refute CodeReload.decode(sb.send(:resume_payload))[:announce], "off screen: silent"
    end

    # --- the trap -----------------------------------------------------------------

    # Value: protects=a reload asked mid-prompt waits for the prompt (a half-typed task survives);
    # fails_when=the handler does more than flag + wake; seam=none; no_claim=real pty timing
    def test_the_signal_only_flags_and_wakes
      sb = sidebar(nodes: [proj("app"), ws("a")])
      sb.define_singleton_method(:reexec) { flunk "nothing runs inside the handler" }
      sb.send(:install_reload_trap)
      Process.kill(CodeReload::SIGNAL, Process.pid)
      sleep 0.05 until sb.instance_variable_get(:@reload_signal)
      assert IO.select([sb.instance_variable_get(:@wake_r)], nil, nil, 1), "the loop's select wakes"
      refute sb.instance_variable_get(:@reload_requested), "turned into a request only at the loop top"
    ensure
      sb&.send(:restore_reload_trap)
    end

    # --- the carried baseline (D1) ------------------------------------------------

    def edges_scan(edges, now)
      edges.on_scan(now, monitoring: Set.new, nodes: [], config: Config.new, current_path: nil,
                         announce_sounds: false, refresh_prs: false)
    end

    # Value: protects=a long-quiet agent's completion still rings after a reload (D1);
    # fails_when=the baseline isn't seeded before the first scan; seam=none
    def test_a_carried_thinking_still_gets_its_done_edge
      edges = Sidebar::Edges.new
      edges.restore_baseline(hook_states: { "/wt/a" => :thinking }, notify: {})
      assert_equal ["/wt/a"], edges_scan(edges, { "/wt/a" => :done })
    end

    def test_an_empty_baseline_is_a_first_scan
      edges = Sidebar::Edges.new
      edges.restore_baseline(hook_states: {}, notify: {})
      assert_empty edges_scan(edges, { "/wt/a" => :done }), "no baseline, no edge — as for a fresh process"
      assert_equal({ hook_states: { "/wt/a" => :done }, notify: {} }, edges.baseline)
    end
  end
end
