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
    def run_sidebar(visible:, resume: nil, prewarm: true, session: "sb/app/x")
      File.write(ENV["SWITCHBOARD_CONFIG"], "projects: []\n")
      ENV[CodeReload::RESUME_ENV] = resume if resume
      sb = Sidebar.new
      sb.instance_variable_get(:@config).define_singleton_method(:prewarm?) { prewarm }
      log = []
      %i[pin_if_resized cursor_to_current render reconcile_on_launch].each { |m| sb.define_singleton_method(m) { |*| log << m } }
      sb.define_singleton_method(:reload) { |**kw| log << [:reload, kw] }
      sb.define_singleton_method(:warm_reload) { |*| log << :warm_reload }
      stdin, w = IO.pipe
      w.close
      stdin.define_singleton_method(:raw!) { nil }
      stdin.define_singleton_method(:cooked!) { nil }
      tag = ->(_pane, value) { log << [:tag, value, sb.instance_variable_get(:@wake_r) ? :trap_first : :tag_first] }
      out = with_stdin(stdin) do
        stub_method(Tmux, :enable_focus_events, -> {}) do
          stub_method(Tmux, :session_of, ->(*) { session }) do
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

    # Value: protects=a reload of the home sidebar never re-runs launch-time pruning (a fleet
    # reload would prune N times); fails_when=the @resume guard is dropped; seam=none
    def test_only_a_launch_of_home_prunes_not_a_reload
      _, log, = run_sidebar(visible: false, session: Tmux::HOME)
      assert_includes log, :reconcile_on_launch, "a fresh home sidebar prunes, as before"
      _, log, = run_sidebar(visible: false, session: Tmux::HOME, resume: CodeReload.encode)
      refute_includes log, :reconcile_on_launch
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
      assert_equal [:pin_if_resized, [:reload, { announce_sounds: true }], :cursor_to_current, :render], untagged(log),
                   "no carried cursor (a respawned old sidebar): start on the current workspace, like a fresh one"
      assert_equal 2, offset_of(sb)
      refute ENV.key?(CodeReload::RESUME_ENV), "taken, so no child inherits it"
    end

    # Value: protects=a reloaded sidebar keeps its own cursor row instead of jumping "here";
    # fails_when=the fallback runs even with a carried cursor; seam=none
    def test_a_resume_with_a_cursor_leaves_it_to_the_carried_row
      cursor = { "kind" => "ws", "project" => "app", "path" => "/wt/b", "branch" => nil }
      _, log, = run_sidebar(visible: true, resume: CodeReload.encode(cursor: cursor))
      refute_includes log, :cursor_to_current, "restore_resumed_cursor owns it (with its own fallback)"
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

    def test_the_switch_poke_still_reloads_while_an_overlay_holds_the_exec
      sb, = reloading(visible: false)
      sb.send(:request_reload)
      sb.instance_variable_set(:@filter, "")
      reloads = 0
      sb.define_singleton_method(:reload) { |**| reloads += 1 }
      sb.define_singleton_method(:reload_due?) { true }
      stub_method(Tmux, :visible?, ->(*) { true }) { sb.send(:reload_and_refresh) }
      assert_equal 1, reloads, "a held reload must not starve the switch-in refresh"
    end

    # Value: protects=a split escape never reaches the new image as a bare key (`O` opens the
    # repo); fails_when=exec runs with a partial sequence pending; seam=none
    def test_a_half_read_escape_sequence_holds_the_exec
      sb, execs = reloading(visible: true)
      sb.instance_variable_set(:@pending, +"\e[")
      sb.send(:request_reload)
      sb.send(:maybe_reexec)
      assert_empty execs
      sb.instance_variable_set(:@pending, +"")
      sb.send(:maybe_reexec)
      assert_equal [:exec], execs
    end

    # Value: protects=a held escape never spins the CPU on an overdue reload (Red Team pass 2);
    # fails_when=the pending gate lives outside reexec_allowed?; seam=none
    def test_a_pending_escape_keeps_the_normal_timeout_past_the_deadline
      sb, = reloading(visible: false)
      sb.instance_variable_set(:@reload_requested, true)
      sb.instance_variable_set(:@reexec_at, sb.send(:monotonic) - 5)
      sb.instance_variable_set(:@pending, +"\e[")
      assert_equal Sidebar::IDLE, sb.send(:frame_timeout)
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

    # Value: protects=a resumed fleet's hidden panes don't all warm (git rescan) at once (P1);
    # fails_when=tick's warm branch stops consulting warm_spread_over?; why_new=the existing test
    # pins only the predicate, never that tick obeys it; seam=none
    def test_tick_holds_a_resumed_hidden_panes_warm_until_its_spread_ends
      sb, = reloading(visible: false)
      warms = 0
      sb.define_singleton_method(:warm_fingerprint) { "moved" }
      sb.define_singleton_method(:warm_reload) { |*| warms += 1; false }
      ENV["SWITCHBOARD_BIN"] = File.join(CodeReload::LOADED_ROOT, "bin", "switchboard")
      tick = lambda do
        stub_method(Tmux, :visible?, ->(*) { false }) do
          stub_method(Tmux, :window_panes, ->(*) { 2 }) { sb.send(:tick) }
        end
      end
      sb.instance_variable_set(:@warm_not_before, sb.send(:monotonic) + 30)
      tick.call
      assert_equal 0, warms, "inside its spread: no warm"
      sb.instance_variable_set(:@warm_not_before, sb.send(:monotonic) - 1)
      tick.call
      assert_equal 1, warms, "spread over: the normal warm gate applies"
    end

    # Value: protects=repeated signals can't postpone a hidden pane's reload forever;
    # fails_when=request_reload overwrites @reexec_at instead of keeping the earliest;
    # why_new=only single requests were tested; seam=none
    def test_a_second_request_never_pushes_the_deadline_back
      ENV[CodeReload::SPREAD_ENV] = "30"
      sb, = reloading(visible: false)
      first = sb.send(:monotonic) + 1
      sb.instance_variable_set(:@reexec_at, first)
      sb.instance_variable_set(:@reload_requested, true)
      stub_method(CodeReload, :spread_delay, ->(*) { 25.0 }) { sb.send(:request_reload) }
      assert_equal first, sb.instance_variable_get(:@reexec_at)
    end

    # Value: protects=a reload of an on-screen sidebar keeps ringing (its first scan announces);
    # fails_when=refresh_agents stops stamping @last_announce_scan, or stamps it on silent/hidden
    # scans; why_new=the payload test sets the stamp by hand; seam=none
    def test_an_announcing_on_screen_scan_is_what_lets_the_payload_announce
      a = real_dir("a")
      sb = sidebar(nodes: [ws("a", path: a)])
      states = { a => :done }
      as = Struct.new(:last_hook_states).new(states)
      as.define_singleton_method(:scan) { |_paths, hooks_only: false| states }
      sb.instance_variable_set(:@agent_state, as)
      sb.instance_variable_set(:@visible, true)
      stub_method(Sound, :play, ->(*) {}) do
        sb.send(:refresh_agents, announce_sounds: false, refresh_prs: false)
        refute CodeReload.decode(sb.send(:resume_payload))[:announce], "a silent catch-up scan doesn't count"
        sb.send(:refresh_agents, refresh_prs: false)
      end
      assert CodeReload.decode(sb.send(:resume_payload))[:announce]
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

    def exec_sidebar(preflight: :ok, root: "/Cellar/new", sb: nil, &on_exec)
      ENV["SWITCHBOARD_BIN"] = "/opt/sb/bin/switchboard"
      sb ||= sidebar(nodes: [proj("app"), ws("a"), ws("b")], cursor: 2)
      sb.instance_variable_set(:@visible, true)
      sb.instance_variable_set(:@reload_requested, true)
      tags = []
      sb.define_singleton_method(:exec) { |*argv| on_exec.call(argv) }
      flags = []
      calls = []
      order = []
      stub_method(CodeReload, :preflight, ->(*args, **kw) { calls << [args, kw]; preflight }) do
        stub_method(CodeReload, :current_root, ->(*) { root }) do
          stub_method(Tmux, :flag_failed_reload, ->(_p, r) { flags << r; order << [:flag, r] }) do
            stub_method(Tmux, :tag_sidebar_pane, ->(_p, v) { tags << v; order << [:tag, v] }) { capture_stdout { sb.send(:reexec) } }
          end
        end
      end
      @failure_flags = flags
      @preflight_calls = calls
      @tmux_order = order
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
      assert_equal [[:tag, 0], [:tag, Process.pid], [:flag, "/Cellar/new"]], @tmux_order,
                   "flagged AFTER the re-tag, which would otherwise clear it"
    end

    # Value: protects=the likeliest real failure (the bin no longer resolves) still flags the pane;
    # fails_when=an unresolvable root writes an empty flag that reads as not failed; seam=none
    def test_an_unresolvable_install_is_still_flagged
      exec_sidebar(preflight: :failed, root: nil) { flunk "no exec" }
      assert_equal ["/opt/sb/bin/switchboard"], @failure_flags
    end

    def test_a_failed_preflight_never_execs_and_blocks_that_root
      sb, = exec_sidebar(preflight: :failed) { flunk "a binary that won't load is never exec'd" }
      assert_equal "/Cellar/new", sb.instance_variable_get(:@reexec_blocked_root)
      assert_equal ["/Cellar/new"], @failure_flags, "the pane says so, for doctor and the next reload"
    end

    # Value: protects=a slow disk right after brew upgrade doesn't strand a sidebar on old code;
    # fails_when=a timeout blocks the root for good; seam=none
    # Value: protects=a timed-out check is handled like a failure: no exec, flagged, the
    # backstop stays off that root, and an explicit reload still asks again; fails_when=a
    # timeout is exec'd, silently dropped, or blocks signals too; seam=none
    def test_a_preflight_timeout_is_handled_like_a_failure
      sb, = exec_sidebar(preflight: :timeout) { flunk "never exec on a timeout" }
      assert_equal "/Cellar/new", sb.instance_variable_get(:@reexec_blocked_root)
      refute sb.instance_variable_get(:@reload_requested), "no clock of its own: nothing is left pending"
      assert_equal ["/Cellar/new"], @failure_flags
      assert_equal 1, @preflight_calls.size
      exec_sidebar(preflight: :ok, sb: sb) { |_argv| raise Errno::ENOENT, "stop" }
      assert_equal 1, @preflight_calls.size, "a signal (reload-sidebars) tries again despite the blocked root"
    end

    # Value: protects=the preflight proves the new code can build a sidebar and take its payload, not just load
    # (Red Team); fails_when=the exec preflight goes back to `version`; seam=none
    def test_the_exec_preflight_checks_the_sidebar_with_its_payload
      payload = nil
      exec_sidebar { |_argv| payload = ENV[CodeReload::RESUME_ENV]; raise Errno::ENOENT, "stop" }
      args, kw = @preflight_calls.first
      assert_equal ["/opt/sb/bin/switchboard", "sidebar", "--check"], args
      assert_equal payload, kw[:env][CodeReload::RESUME_ENV], "the same payload the exec hands over"
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

    # Value: protects=building the payload never raises out of reexec (that would close the
    # pane), and only on-screen worktrees' baseline travels; fails_when=the rescue or the filter
    # is dropped; seam=none
    def test_the_payload_carries_only_tracked_worktrees_and_never_raises
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a")])
      sb.instance_variable_get(:@edges).restore_baseline(hook_states: { "/wt/a" => :done, "/wt/gone" => :done }, notify: {})
      assert_equal({ "/wt/a" => :done }, CodeReload.decode(sb.send(:resume_payload))[:hook_states])
      sb.instance_variable_get(:@edges).define_singleton_method(:baseline) { raise "boom" }
      refute_nil CodeReload.decode(sb.send(:resume_payload)), "a minimal payload, not an exception"
    end

    def test_a_clean_exit_untags_the_pane
      ENV["TMUX_PANE"] = "%9"
      untagged = []
      sb = sidebar(nodes: [proj("app")])
      stub_method(Tmux, :untag_sidebar_pane, ->(pane) { untagged << pane }) { capture_stdout { sb.send(:teardown) } }
      assert_equal ["%9"], untagged, "a dead pane (remain-on-exit) keeps no pid a sender could signal"
    end

    def test_an_unreadable_payload_still_starts_as_a_reload
      out, = run_sidebar(visible: false, resume: "{garbage")
      refute_includes out, "\e[2J", "handed a payload, so no clear even if it won't decode"
    end

    # --- the trap -----------------------------------------------------------------

    # Value: protects=a reload asked mid-prompt waits for the prompt (a half-typed task survives);
    # fails_when=the handler does more than flag + wake; seam=none; no_claim=real pty timing
    def test_the_signal_only_flags_and_wakes
      sb = sidebar(nodes: [proj("app"), ws("a")])
      sb.define_singleton_method(:reexec) { flunk "nothing runs inside the handler" }
      sb.send(:install_reload_trap)
      Process.kill(CodeReload::SIGNAL, Process.pid)
      installed = trap(CodeReload::SIGNAL, "DEFAULT")
      trap(CodeReload::SIGNAL, installed)
      assert_kind_of Proc, installed, "a handler is installed (else USR1's default would kill the test run)"
      deadline = Time.now + 2
      sleep 0.05 until sb.instance_variable_get(:@reload_signal) || Time.now > deadline
      assert sb.instance_variable_get(:@reload_signal), "the handler set the flag"
      assert IO.select([sb.instance_variable_get(:@wake_r)], nil, nil, 1), "the loop's select wakes"
      refute sb.instance_variable_get(:@reload_requested), "turned into a request only at the loop top"
    ensure
      sb&.send(:restore_reload_trap)
    end

    # --- sidebar --check (the exec preflight) and the zombie sweep -----------------

    # Value: protects=the deep preflight passes for a sidebar that builds and takes its payload, and fails
    # for one that can't (Red Team); fails_when=check swallows nothing or everything; seam=none
    def test_sidebar_check_builds_and_resumes_a_sidebar
      File.write(ENV["SWITCHBOARD_CONFIG"], "projects: []\n")
      ENV[CodeReload::RESUME_ENV] = CodeReload.encode(hook_states: { "/wt/a" => :done })
      assert Sidebar.check
      refute ENV.key?(CodeReload::RESUME_ENV)
      ENV[CodeReload::RESUME_ENV] = "{garbage"
      assert Sidebar.check, "an unreadable payload is a blank resume, not a failure"
      stub_new(->(*) { raise NameError, "boom" }) { refute Sidebar.check }
      broken = Sidebar.new
      broken.define_singleton_method(:apply_resume) { |_p| raise ArgumentError, "resume broke" }
      ENV[CodeReload::RESUME_ENV] = CodeReload.encode
      stub_new(->(*) { broken }) { refute Sidebar.check, "a release that can't take its payload fails" }
    end

    # Value: protects=a reload never swaps a working sidebar for one with no config (the pane
    # closes) or a malformed one (the tree blanks); fails_when=check ignores the config; seam=none
    def test_sidebar_check_refuses_a_missing_or_malformed_config
      File.delete(ENV["SWITCHBOARD_CONFIG"]) if File.exist?(ENV["SWITCHBOARD_CONFIG"])
      refute Sidebar.check, "no config: the new image would exit and close the pane"
      File.write(ENV["SWITCHBOARD_CONFIG"], "projects: [\n  - name: : :\n")
      refute Sidebar.check, "malformed: this image keeps its last-good config, the new one wouldn't"
      File.write(ENV["SWITCHBOARD_CONFIG"], "projects: []\n")
      assert Sidebar.check
    end

    # Sidebar.new stubbed, then REMOVED (stub_method would leave a singleton `new` behind,
    # which the class-surface pin in sidebar_test then sees).
    def stub_new(impl)
      Sidebar.define_singleton_method(:new, impl)
      yield
    ensure
      Sidebar.singleton_class.send(:remove_method, :new)
    end

    def test_the_cli_exits_with_the_check_result
      stub_method(Sidebar, :check, -> { true }) do
        assert_equal 0, assert_raises(SystemExit) { CLI.run(%w[sidebar --check]) }.status
      end
      stub_method(Sidebar, :check, -> { false }) do
        assert_equal 1, assert_raises(SystemExit) { CLI.run(%w[sidebar --check]) }.status
      end
    end

    # Value: protects=children the old image left behind are reaped, not left as zombies
    # (Red Team); fails_when=the resumed tick never sweeps; seam=none
    def zombie
      pid = Process.spawn("true")
      deadline = Time.now + 2
      sleep 0.05 until `ps -o stat= -p #{pid}`.include?("Z") || Time.now > deadline
      assert_includes `ps -o stat= -p #{pid}`, "Z", "the child exited unreaped"
      pid
    end

    def idle_tick(sb)
      sb.instance_variable_get(:@config).define_singleton_method(:prewarm?) { false }
      stub_method(Tmux, :visible?, ->(*) { false }) do
        stub_method(Tmux, :window_panes, ->(*) { 2 }) { sb.send(:tick) }
      end
    end

    # Value: protects=children the old image left behind are reaped, not left as zombies, and a
    # cold start never sweeps (Red Team); fails_when=the tick's `if @resume` gate changes; seam=none
    def test_only_a_resumed_tick_reaps_inherited_children
      pid = zombie
      cold = sidebar(nodes: [proj("app"), ws("a")])
      idle_tick(cold)
      assert_equal pid, Process.wait(pid), "a cold start leaves its children to their waiters"
      pid = zombie
      resumed = sidebar(nodes: [proj("app"), ws("a")])
      resumed.instance_variable_set(:@resume, { cursor: nil })
      idle_tick(resumed)
      assert_raises(Errno::ECHILD) { Process.wait(pid) }
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

    # Value: protects=an on-screen reload never replays a "come look" alert already heard (D1);
    # fails_when=the notify cursor is lost or rounded in the payload (Notify.pending yields File.mtime
    # Times, with nanoseconds); why_new=red at HEAD in the ship coverage audit; seam=none
    def test_a_carried_notify_cursor_survives_the_payload
      t = Time.at(1_000, 123_456_789, :nsec)
      old = Sidebar::Edges.new
      old.instance_variable_set(:@prev_hook_states, { "/wt/a" => :thinking }) # a scanned pane, not a first scan
      old.instance_variable_get(:@prev_notify)["/wt/a"] = t
      got = CodeReload.decode(CodeReload.encode(**old.baseline))
      edges = Sidebar::Edges.new
      edges.restore_baseline(hook_states: got[:hook_states], notify: got[:notify])
      sounds = []
      edges.define_singleton_method(:maybe_refresh_prs) { |_p| }
      stub_method(Sound, :play, ->(spec, **) { sounds << spec }) do
        edges.on_scan({ "/wt/a" => :thinking }, monitoring: Set.new(["/wt/a"]), nodes: [ws("a", path: "/wt/a")],
                                                config: Config.new, current_path: nil, notify_pending: { "/wt/a" => t },
                                                announce_sounds: true, refresh_prs: false)
      end
      assert_empty sounds, "the alert was heard before the reload"
    end

    def test_an_empty_baseline_is_a_first_scan
      edges = Sidebar::Edges.new
      edges.restore_baseline(hook_states: {}, notify: {})
      assert_empty edges_scan(edges, { "/wt/a" => :done }), "no baseline, no edge — as for a fresh process"
      assert_equal({ hook_states: { "/wt/a" => :done }, notify: {} }, edges.baseline)
    end
  end
end
