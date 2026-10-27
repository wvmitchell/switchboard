# frozen_string_literal: true

require_relative "test_helper"
require "json"

module Switchboard
  # The CLI dispatch logic that isn't just a pass-through to Installer: flag
  # parsing and the emdash-free `init`. (install/uninstall themselves are thin
  # delegations covered by InstallerTest; doctor's rows are ANSI formatting.)
  class CLITest < SandboxTest
    # --- reap-worktree: the background removal core (daemonizing is split off) -----

    # The off-loop removal actually removes the worktree + its (merged) branch, clears
    # the hide marker, and pokes every pane to repaint. Driven against a real repo.
    def test_reap_worktree_removes_the_worktree_branch_and_clears_the_marker
      repo = temp_git_repo("app")
      git(repo, "worktree", "add", "-q", path("wt"), "-b", "feature")
      PendingDelete.mark(path("wt"))
      bcast = 0
      stub_method(Tmux, :broadcast_warm, ->(**) { bcast += 1 }) do
        CLI.send(:reap_worktree!, repo, path("wt"), "feature")
      end
      refute(Git.worktrees(repo).any? { |w| w[:path] == path("wt") }, "the worktree is removed")
      refute File.exist?(path("wt")), "and its dir is gone"
      refute_includes git(repo, "branch", "--format=%(refname:short)").split, "feature", "merged branch dropped"
      assert_empty PendingDelete.pending([path("wt")]), "the hide marker is cleared"
      assert_equal 1, bcast, "every pane is told to repaint from git truth"
    end

    # A canceled dispatch's placeholder branch is never "merged" into your local base, so
    # only an explicit force (the tree was proven untouched first) removes it.
    def test_reap_worktree_force_deletes_an_unmerged_branch_only_when_asked
      repo = temp_git_repo("app")
      %w[kept gone].each do |b|
        git(repo, "worktree", "add", "-q", path(b), "-b", b)
        git(path(b), "commit", "-q", "--allow-empty", "-m", "ahead")
      end
      stub_method(Tmux, :broadcast_warm, ->(**) {}) do
        CLI.send(:reap_worktree!, repo, path("kept"), "kept")
        CLI.send(:reap_worktree!, repo, path("gone"), "gone", force_branch: true)
      end
      branches = git(repo, "branch", "--format=%(refname:short)").split
      assert_includes branches, "kept", "the safe -d keeps an unmerged branch"
      refute_includes branches, "gone"
    end

    # Value: protects=d removes our own un-set-up build's tree even when an interrupted add left it locked (in any locale), but never a workspace the user locked; fails_when=reap drops the second --force (that ✘ can never be deleted), keys on git's localized lock text, or forces past any lock; why_new=no test locked a tree; seam=none; no_claim=how git words the lock (the reason here is deliberately not English)
    def test_reap_worktree_forces_past_a_lock_only_on_an_unfinished_build
      repo = temp_git_repo("app")
      %w[half mine].each do |b|
        git(repo, "worktree", "add", "-q", path(b), "-b", b)
        git(repo, "worktree", "lock", "--reason", "initialisiere", path(b))
      end
      rec = Creation.create(project: "app", name: "half", path: path("half"), task: "t")
      Creation.update(rec["id"], state: "failed", reason: "interrupted", worktree_added: true)
      stub_method(Tmux, :broadcast_warm, ->(**) {}) do
        %w[half mine].each { |b| CLI.send(:reap_worktree!, repo, path(b), b) }
      end
      refute File.exist?(path("half")), "an interrupted add's lock doesn't strand its ✘"
      assert File.exist?(path("mine")), "a lock on a workspace you made stays yours"
    end

    # If the removal fails, the marker is still cleared so the (undeleted) row
    # REAPPEARS rather than staying hidden — a delete that didn't take mustn't be masked.
    def test_reap_worktree_clears_the_marker_even_when_removal_fails
      PendingDelete.mark("/wt/gone")
      stub_method(Git, :remove_worktree, ->(*, **) { false }) do
        stub_method(Git, :delete_branch, ->(*, **) { false }) do
          stub_method(Tmux, :broadcast_warm, ->(**) {}) do
            CLI.send(:reap_worktree!, "/repos/app", "/wt/gone", "feature")
          end
        end
      end
      assert_empty PendingDelete.pending(["/wt/gone"]), "marker cleared so the row reappears"
    end

    # --- create: the CLI twin of the sidebar's add → [n] new ------------------
    # The handler is a thin wrapper over Registrar.create (covered in
    # registrar_test); these pin the CLI surface: the usage guard and that it
    # actually registers.

    def test_create_project_warns_without_a_name
      assert_output("", /usage: switchboard create/) { CLI.send(:create_project, nil) }
    end

    def test_create_project_creates_and_registers
      git(nil, "config", "--global", "user.email", "test@example.com")
      git(nil, "config", "--global", "user.name", "Switchboard Test")
      Config.scaffold
      CLI.instance_variable_set(:@config, nil) # config memoizes; re-read this sandbox's file
      assert_output(/created \+ added shiny/, "") { CLI.send(:create_project, "shiny") }
      assert Config.new.project("shiny"), "the new repo is registered"
    end

    def test_flag_value_returns_the_value_after_the_flag
      assert_equal "/x.conf", CLI.flag_value(["--tmux-conf", "/x.conf"], "--tmux-conf")
    end

    def test_flag_value_is_nil_when_flag_absent
      assert_nil CLI.flag_value(["--no-tmux"], "--tmux-conf")
    end

    def test_flag_value_is_nil_when_flag_is_last_arg
      assert_nil CLI.flag_value(["--tmux-conf"], "--tmux-conf")
    end

    # --- orphan_sidebar_count: doctor's process-vs-pane diff ------------------
    # Surfaces sidebar processes that outlived their pane (procs > panes).

    def test_orphan_sidebar_count_is_the_excess_of_processes_over_panes
      assert_equal 7, CLI.orphan_sidebar_count(18, 11)
    end

    def test_orphan_sidebar_count_is_zero_when_balanced
      assert_equal 0, CLI.orphan_sidebar_count(11, 11)
    end

    def test_orphan_sidebar_count_clamps_when_more_panes_than_processes
      # A pane mid-spawn (or a dead-but-displayed pane) is not an orphan — never negative.
      assert_equal 0, CLI.orphan_sidebar_count(10, 11)
    end

    # doctor's PR-badge freshness line compacts the cache age to its largest unit.
    def test_humanize_age_compacts_to_the_largest_unit
      assert_equal "45s", CLI.humanize_age(45)
      assert_equal "2m",  CLI.humanize_age(150)
      assert_equal "3h",  CLI.humanize_age((3 * 3600) + 5)
      assert_equal "5d",  CLI.humanize_age((5 * 86_400) + 60)
    end

    # Bare `switchboard` is the single launch command: from a plain shell (TMUX
    # unset, the sandbox default) it bootstraps + attaches home; inside tmux it
    # toggles the sidebar in the current window.
    def test_bare_command_outside_tmux_attaches_home
      called = []
      stub_method(Tmux, :go_home, -> { called << :home }) do
        stub_method(Tmux, :toggle_sidebar, -> { called << :toggle }) do
          CLI.run([])
        end
      end
      assert_equal [:home], called
    end

    def test_bare_command_inside_tmux_toggles_sidebar
      ENV["TMUX"] = "/tmp/fake,1,0"
      called = []
      stub_method(Tmux, :go_home, -> { called << :home }) do
        stub_method(Tmux, :toggle_sidebar, -> { called << :toggle }) do
          CLI.run([])
        end
      end
      assert_equal [:toggle], called
    end

    # The keybind dispatches the explicit `toggle-sidebar` subcommand, which must
    # keep toggling (never the new go-home launch) regardless of the bare path.
    def test_toggle_sidebar_subcommand_toggles
      ENV["TMUX"] = "/tmp/fake,1,0"
      called = []
      stub_method(Tmux, :toggle_sidebar, -> { called << :toggle }) do
        CLI.run(["toggle-sidebar"])
      end
      assert_equal [:toggle], called
    end

    # Outside tmux there's no pane to toggle: the subcommand warns and must NOT
    # call into Tmux (which would operate on a nonexistent pane). TMUX is unset
    # by the sandbox default.
    def test_toggle_sidebar_subcommand_outside_tmux_warns_without_calling_tmux
      called = []
      err = capture_err do
        stub_method(Tmux, :toggle_sidebar, -> { called << :toggle }) do
          CLI.run(["toggle-sidebar"])
        end
      end
      assert_empty called
      assert_includes err, "runs inside tmux"
    end

    # The after-new-window hook routes the new window's id through to Tmux.
    def test_sidebar_sync_dispatch_forwards_the_window_id
      got = :unset
      stub_method(Tmux, :sidebar_sync, ->(window) { got = window }) do
        CLI.run(["sidebar-sync", "@7"])
      end
      assert_equal "@7", got
    end

    # The session-window-changed hook routes the now-active window's id through.
    def test_poke_window_dispatch_forwards_the_window_id
      got = :unset
      stub_method(Tmux, :poke_window, ->(window) { got = window }) do
        CLI.run(["poke-window", "@4"])
      end
      assert_equal "@4", got
    end

    # The fragment's `tmux-bind` line routes through to Installer.apply_keybindings.
    def test_tmux_bind_dispatch_applies_keybindings
      called = false
      stub_method(Installer, :apply_keybindings, ->(**_) { called = true }) do
        CLI.run(["tmux-bind"])
      end
      assert called, "tmux-bind dispatches to Installer.apply_keybindings"
    end

    # DX1/DX2: the config-edit reload re-applies the keybindings (so a changed
    # tmux_keys takes effect on save) and announces the result.
    def test_reload_config_poke_reapplies_and_announces_keybindings
      announced = :unset
      orig = ENV["TMUX"]
      ENV["TMUX"] = "/tmp/fake-tmux,1,0"
      stub_method(Tmux, :session_of, -> { "sb/home" }) do
        stub_method(Tmux, :switch, ->(*) {}) do
          stub_method(Tmux, :poke_sidebar_of, ->(*, **) { true }) do
            stub_method(Installer, :apply_keybindings, ->(announce: false, **) { announced = announce }) do
              CLI.send(:reload_config_poke, "")
            end
          end
        end
      end
      assert_equal true, announced, "reload re-applies (DX1) and announces (DX2)"
    ensure
      ENV["TMUX"] = orig
    end

    # `monitoring on|off` marks/clears the current worktree; the worktree resolution is
    # stubbed (it's cwd + Model machinery, covered elsewhere) so the test stays on the
    # subcommand's own behavior.
    def test_monitoring_on_marks_and_off_clears
      d = path("wt")
      FileUtils.mkdir_p(d)
      wt = Worktree.new(project: "p", path: File.realpath(d), primary: false)
      stub_method(CLI, :current_worktree, ->(*) { wt }) do
        out = capture { CLI.monitoring("on") }
        assert_includes out, "monitoring on"
        assert Monitoring.monitored([File.realpath(d)]).any?, "on marks the worktree"

        capture { CLI.monitoring("off") }
        assert_empty Monitoring.monitored([File.realpath(d)]), "off clears it"
      end
    end

    # `monitoring on <secs>` sizes the liveness window for a slow cycle: the marker stays
    # live past the default TTL, and the effective window is echoed back to the agent.
    def test_monitoring_on_with_a_ttl_arg_sizes_the_window
      d = path("wt")
      FileUtils.mkdir_p(d)
      real = File.realpath(d)
      wt = Worktree.new(project: "p", path: real, primary: false)
      stub_method(CLI, :current_worktree, ->(*) { wt }) do
        out = capture { CLI.monitoring("on", (Monitoring::TTL * 4).to_s) }
        assert_includes out, "ttl #{Monitoring::TTL * 4}s"

        aged = Time.now - Monitoring::TTL - 60 # past the default, within the declared window
        File.utime(aged, aged, File.join(Monitoring.state_dir, Monitoring.key(real)))
        assert Monitoring.monitored([real]).any?, "the declared window outlives the default TTL"
      end
    end

    def test_monitoring_status_reports_without_changing_state
      d = path("wt")
      FileUtils.mkdir_p(d)
      wt = Worktree.new(project: "p", path: File.realpath(d), primary: false)
      stub_method(CLI, :current_worktree, ->(*) { wt }) do
        assert_includes capture { CLI.monitoring(nil) }, "monitoring off"
        Monitoring.mark(File.realpath(d))
        assert_includes capture { CLI.monitoring("status") }, "monitoring on"
      end
    end

    def test_monitoring_outside_a_workspace_is_a_noop
      stub_method(CLI, :current_worktree, ->(*) { nil }) do
        out = capture { CLI.monitoring("on") }
        assert_includes out, "not inside a switchboard workspace"
      end
    end

    # `monitoring notify` on a MONITORED workspace writes both markers: Attention (the
    # persistent bold, direct so an away user still gets it) and Notify (the sidebar's
    # announce-gated sound/sparkle signal).
    def test_monitoring_notify_on_a_monitored_workspace_writes_both_markers
      d = path("wt")
      FileUtils.mkdir_p(d)
      real = File.realpath(d)
      wt = Worktree.new(project: "p", path: real, primary: false)
      stub_method(CLI, :current_worktree, ->(*) { wt }) do
        Monitoring.mark(real) # must be monitoring first
        out = capture { CLI.monitoring("notify") }
        assert_includes out, "monitoring notify"
        assert Attention.marked([real]).any?, "notify bolds via a direct Attention mark"
        assert Notify.pending([real]).any?,   "notify writes the sound/sparkle signal"
      end
    end

    # `monitoring notify` is GATED: a non-monitored workspace no-ops with a hint (the verb
    # lives under `monitoring` and is strictly the exception to its suppression).
    def test_monitoring_notify_on_a_non_monitored_workspace_no_ops
      d = path("wt")
      FileUtils.mkdir_p(d)
      real = File.realpath(d)
      wt = Worktree.new(project: "p", path: real, primary: false)
      stub_method(CLI, :current_worktree, ->(*) { wt }) do
        out = capture { CLI.monitoring("notify") } # never ran `on`
        assert_includes out, "not monitoring"
        assert_empty Notify.pending([real]), "no marker written when not monitoring"
        assert_empty Attention.marked([real]), "and no bold either"
      end
    end

    # --- monitoring-nudge (the Layer-2 SessionStart/SessionEnd hook handler) ------

    # A real worktree dir (Monitoring.mark gates on the dir existing) under project "proj".
    def monitoring_wt
      d = path("wt")
      FileUtils.mkdir_p(d)
      Worktree.new(project: "proj", path: File.realpath(d), primary: false)
    end

    def run_monitoring_nudge(worktree:, stdin:, args: [])
      out = nil
      stub_method(CLI, :current_worktree, ->(*) { worktree }) do
        stub_method(CLI, :config, -> { Config.new }) do
          with_stdin(StringIO.new(stdin)) { out = capture { CLI.monitoring_nudge(args) } }
        end
      end
      out
    end

    def test_monitoring_nudge_sessionstart_clears_stale_marker_and_emits_nudge
      nudge_config("background_presence" => true)
      wt = monitoring_wt
      Monitoring.mark(wt.path) # a stale marker left by a prior session
      out = run_monitoring_nudge(worktree: wt, stdin: %({"source":"resume","cwd":"#{wt.path}"}))
      assert_empty Monitoring.monitored([wt.path]), "SessionStart clears the stale marker (per-session declaration)"
      assert_includes JSON.parse(out).dig("hookSpecificOutput", "additionalContext"), "monitoring on"
    end

    def test_monitoring_nudge_end_clears_without_stdout
      nudge_config("background_presence" => true)
      wt = monitoring_wt
      Monitoring.mark(wt.path)
      out = run_monitoring_nudge(worktree: wt, stdin: %({"cwd":"#{wt.path}"}), args: ["--end"])
      assert_empty Monitoring.monitored([wt.path]), "SessionEnd clears the marker"
      assert_equal "", out.strip, "SessionEnd emits nothing on stdout"
    end

    # Value: protects=/clear's real sequence — SessionEnd(reason: clear) drops the ∞, then
    # SessionStart(clear) re-teaches; fails_when=a reason-bearing SessionEnd stops clearing (the
    # premise that keeps `clear` out of CLEARS_ON); why_new=--end was only driven without a
    # reason; seam=current_worktree/config stubs (as above); no_claim=Claude's real event order
    def test_monitoring_nudge_clear_sequence_drops_marker_then_reteaches
      nudge_config("background_presence" => true)
      wt = monitoring_wt
      Monitoring.mark(wt.path)
      run_monitoring_nudge(worktree: wt, stdin: %({"reason":"clear","cwd":"#{wt.path}"}), args: ["--end"])
      assert_empty Monitoring.monitored([wt.path]), "SessionEnd(clear) drops the marker"
      out = run_monitoring_nudge(worktree: wt, stdin: %({"source":"clear","cwd":"#{wt.path}"}))
      assert_includes JSON.parse(out).dig("hookSpecificOutput", "additionalContext"), "monitoring on"
    end

    # The thought experiment: work with an agent -> compaction -> agent sets a monitor.
    # Compaction must (1) NOT clear a live monitor's marker, and (2) STILL re-plant the
    # nudge (compaction can drop the original instruction, so a post-compaction monitor
    # still gets flagged).
    # Value (clear row): protects=/clear keeps a live monitor's ∞ yet re-teaches the
    # convention; fails_when=the CLI wires `clear` into the clear gate or out of the nudge
    # gate; why_new=only the predicates were tested for `clear`; seam=current_worktree/config
    # stubs (as the rows above); no_claim=Claude's actual source strings
    def test_monitoring_nudge_compact_keeps_marker_and_still_reteaches
      nudge_config("background_presence" => true)
      wt = monitoring_wt
      %w[compact clear].each do |source|
        Monitoring.mark(wt.path)
        out = run_monitoring_nudge(worktree: wt, stdin: %({"source":"#{source}","cwd":"#{wt.path}"}))
        assert Monitoring.monitored([wt.path]).any?, "SessionStart(#{source}) itself leaves the marker (for clear, the preceding SessionEnd is what drops it)"
        assert_includes JSON.parse(out).dig("hookSpecificOutput", "additionalContext"), "monitoring on",
                        "#{source} still re-teaches the convention (survives context loss)"
      end
    end

    def test_monitoring_nudge_noop_when_background_presence_off
      nudge_config("background_presence" => false)
      wt = monitoring_wt
      Monitoring.mark(wt.path)
      out = run_monitoring_nudge(worktree: wt, stdin: %({"source":"resume","cwd":"#{wt.path}"}))
      assert Monitoring.monitored([wt.path]).any?, "feature off -> a manual marker is left alone"
      assert_equal "", out.strip
    end

    def test_monitoring_nudge_silent_on_primary_checkout
      nudge_config("background_presence" => true)
      prim = Worktree.new(project: "proj", path: "/p", primary: true)
      assert_equal "", run_monitoring_nudge(worktree: prim, stdin: '{"source":"resume","cwd":"/p"}')
    end

    def test_init_writes_an_empty_config_when_absent
      out = capture { CLI.init }
      assert Config.exist?
      assert_effective_default_config(YAML.safe_load_file(Config.path))
      assert_includes out, "wrote"
    end

    def test_init_is_a_noop_when_config_exists
      File.write(Config.path, "worktree_root: /mine\nprojects: []\n")
      before = File.read(Config.path)
      out = capture { CLI.init }
      assert_equal before, File.read(Config.path)
      assert_includes out, "already exists"
    end

    # `refresh [name] [--poke PANE]` argument parsing.
    def test_refresh_args_parses_name_and_poke
      assert_equal ["proj", "%5"], CLI.refresh_args(["refresh", "proj", "--poke", "%5"])
    end

    def test_refresh_args_name_only
      assert_equal ["proj", nil], CLI.refresh_args(["refresh", "proj"])
    end

    def test_refresh_args_poke_without_name
      assert_equal [nil, "%5"], CLI.refresh_args(["refresh", "--poke", "%5"])
    end

    def test_refresh_args_bare
      assert_equal [nil, nil], CLI.refresh_args(["refresh"])
    end

    # refresh must never raise or touch tmux in the sandbox (TMUX unset), whether
    # the config is empty or the named project is unknown.
    def test_refresh_is_a_noop_on_empty_config
      File.write(Config.path, "worktree_root: /mine\nprojects: []\n")
      assert_nil CLI.refresh
    end

    def test_refresh_unknown_project_is_a_noop
      File.write(Config.path, "worktree_root: /mine\nprojects: []\n")
      assert_nil CLI.refresh("ghost")
    end

    # --- sound: the demo/diagnostic command ----------------------------------

    def test_sound_rejects_an_unknown_state
      err = capture_err { CLI.play_sound("bogus") }
      assert_includes err, "usage"
    end

    def test_sound_warns_when_muted
      File.write(Config.path, YAML.dump("sounds" => { "enabled" => false }))
      err = capture_err { CLI.play_sound("done") }
      assert_includes err, "muted"
    end

    def test_sound_warns_when_no_player_on_path
      err = capture_err do
        stub_method(Sound, :player_argv, -> { nil }) { CLI.play_sound("done") }
      end
      assert_includes err, "no audio player"
    end

    def test_sound_plays_the_resolved_spec_blocking
      captured = nil
      stub_method(Sound, :player_argv, -> { ["afplay"] }) do
        stub_method(Sound, :play, ->(spec, **kw) { captured = [spec, kw] }) do
          CLI.play_sound("done")
        end
      end
      spec, kw = captured
      assert_equal "train", spec      # default :done sound
      assert kw[:wait], "CLI plays blocking so the one-shot finishes"
    end

    # `sound alert` auditions the declared-notify sound — the accept-branch must include it,
    # or `switchboard sound alert` would fall to the usage warning.
    def test_sound_auditions_the_alert_state
      captured = nil
      stub_method(Sound, :player_argv, -> { ["afplay"] }) do
        stub_method(Sound, :play, ->(spec, **kw) { captured = [spec, kw] }) do
          CLI.play_sound("alert")
        end
      end
      spec, kw = captured
      assert_equal "alert", spec, "the alert state resolves to its distinct default sound"
      assert kw[:wait], "CLI plays blocking so the one-shot finishes"
    end

    def test_doctor_reports_player_and_sound_rows
      out = capture do
        stub_method(Sound, :player_argv, -> { ["afplay"] }) { run_doctor }
      end
      assert_includes out, "audio player: afplay"
      assert_includes out, "sound done: train"
      assert_includes out, "sound waiting: chime"
      assert_includes out, "sound alert: alert", "doctor reports the declared-notify sound too"
    end

    # --- doctor: the ⇅ remote-link canary (Claude's undocumented session files) ---

    def write_claude_session(name, data)
      FileUtils.mkdir_p(RemoteLink.sessions_dir)
      File.write(File.join(RemoteLink.sessions_dir, "#{name}.json"), data.is_a?(String) ? data : JSON.generate(data))
    end

    # This test process (plus any `also` pids) stands in for a live Claude; health only
    # counts Claude processes.
    def doctor_as_claude(also: [])
      claude = [Process.pid, *also]
      stub_method(RemoteLink, :claude_pids, ->(pids) { pids.map(&:to_i).select { |p| claude.include?(p) }.to_set }) do
        capture { CLI.send(:doctor_remote_links) }
      end
    end

    def live_session(**over)
      { "pid" => Process.pid, "cwd" => @dir, "sessionId" => "s", "kind" => "interactive",
        "procStart" => ProcessIdentity.start_of(Process.pid), "bridgeSessionId" => "session_x" }.merge(over)
    end

    def test_doctor_remote_links_counts_live_links_and_names_the_dir
      write_claude_session("1", live_session)
      out = doctor_as_claude
      assert_includes out, "remote links (⇅): 1 linked (1 Claude sessions in #{RemoteLink.sessions_dir})"
    end

    def test_doctor_remote_links_flags_a_changed_format
      write_claude_session("1", { "process" => 1, "dir" => "/x" })
      out = capture { CLI.send(:doctor_remote_links) }
      assert_includes out, "none in the shape switchboard reads"
    end

    def test_doctor_remote_links_flags_start_time_drift
      write_claude_session("1", live_session("procStart" => "2026-10-22T19:12:32Z"))
      out = doctor_as_claude
      assert_includes out, "fail the start-time check"
    end

    # Value: protects=doctor's end-to-end row for the QA-probe-002 case (a crash leftover whose
    # pid the OS recycled, beside a healthy session) reads healthy, not as a format change;
    # fails_when=doctor alarms on that mixed dir; why_new=QA probe 002 reproduced the false
    # alarm; seam=claude_pids stubbed (doctor_as_claude); no_claim=the real Claude filter
    # (remote_link_test's test_health_ignores_a_live_pid_that_is_not_claude pins it with real ps)
    def test_doctor_remote_links_ignores_a_recycled_pid_beside_a_healthy_session
      write_claude_session("1", live_session)
      write_claude_session("leftover", live_session("pid" => 1, "procStart" => "Mon Jan  5 09:00:00 2026",
                                                     "bridgeSessionId" => "session_old"))
      out = doctor_as_claude
      refute_includes out, "fail the start-time check"
      assert_includes out, "1 linked"
    end

    # Value: protects=one drifted session among several live CLAUDE sessions is a recycled
    # pid, not a format change — only drift across every live session alarms;
    # fails_when=the guard loosens to any drift (drift.positive?); why_new=ship 2 pass 3
    # testing review (no doctor test had 0 < drift < alive); seam=none (a sleep child stands
    # in for a second Claude); no_claim=a real recycled Claude pid
    def test_doctor_remote_links_ignores_one_drifted_claude_among_healthy_ones
      child = Process.spawn("sleep", "30", out: File::NULL, err: File::NULL)
      write_claude_session("1", live_session)
      write_claude_session("2", live_session("pid" => child, "procStart" => "Mon Jan  5 09:00:00 2026",
                                              "bridgeSessionId" => "session_old"))
      out = doctor_as_claude(also: [child])
      refute_includes out, "fail the start-time check"
      assert_includes out, "1 linked"
    ensure
      Process.kill("TERM", child) if child
      Process.wait(child) if child
    end

    # Value: protects=a dir holding only dead leftovers (no live Claude) reads healthy, not as a
    # procStart format change; fails_when=the alarm's alive.positive? guard goes (0 drift == 0 alive);
    # why_new=every doctor test has a live session or no shape; seam=none; no_claim=a real crash leftover
    def test_doctor_remote_links_does_not_alarm_on_only_dead_leftovers
      write_claude_session("dead", live_session("pid" => 2**22 + 12_345, "procStart" => "Mon Jan  5 09:00:00 2026"))
      out = doctor_as_claude
      refute_includes out, "fail the start-time check"
      assert_includes out, "remote links (⇅): 0 linked (1 Claude sessions in"
    end

    # Value: protects=doctor warns when this shell and tmux (where sidebars run) disagree on
    # CLAUDE_CONFIG_DIR; fails_when=the check reads only this shell's env; why_new=new branch;
    # seam=none (stubs the one tmux read); no_claim=a real tmux server's environment
    def test_doctor_remote_links_flags_a_claude_config_dir_tmux_cannot_see
      write_claude_session("1", live_session)
      ENV["TMUX"] = "/tmp/fake,1,0"
      ENV["CLAUDE_CONFIG_DIR"] = path("claude-elsewhere")
      out = capture { stub_method(CLI, :tmux_global_env, ->(_) { nil }) { CLI.send(:doctor_remote_links) } }
      assert_includes out, "but unset in tmux"
      dir = path("claude-elsewhere") # outside the stub: define_singleton_method rebinds self
      same = capture { stub_method(CLI, :tmux_global_env, ->(_) { dir }) { CLI.send(:doctor_remote_links) } }
      refute_includes same, "in tmux"
    end

    # Value: protects=unset in one place and `~/.claude` (or a trailing-slash spelling) in the
    # other name the SAME dir, so doctor stays quiet; fails_when=the raw strings are compared
    # again (a false "wrong dir" warning); why_new=ship 2 pass 3 red team; seam=none (stubs the
    # one tmux read); no_claim=a real tmux environment
    def test_doctor_claude_config_dir_compares_the_resolved_dirs
      write_claude_session("1", live_session)
      ENV["TMUX"] = "/tmp/fake,1,0"
      ENV.delete("CLAUDE_CONFIG_DIR")
      default = "#{File.join(Dir.home, '.claude')}/"
      out = capture { stub_method(CLI, :tmux_global_env, ->(_) { default }) { CLI.send(:doctor_remote_links) } }
      refute_includes out, "in tmux"
    end

    # Value: protects=tmux's three answers (`NAME=value`, `-NAME` unset, unknown variable)
    # map to value / nil / nil; fails_when=the prefix parse breaks and every set dir reads as
    # unset (a false warning for everyone who sets CLAUDE_CONFIG_DIR); why_new=the doctor test
    # stubs this method; seam=none (stubs IO.popen); no_claim=a real tmux binary's output
    def test_tmux_global_env_reads_set_unset_and_unknown
      { "CLAUDE_CONFIG_DIR=/x/claude\n" => "/x/claude", "-CLAUDE_CONFIG_DIR\n" => nil,
        "unknown variable: CLAUDE_CONFIG_DIR\n" => nil, "" => nil }.each do |out, want|
        got = stub_method(IO, :popen, ->(*, **) { out }) { CLI.send(:tmux_global_env, "CLAUDE_CONFIG_DIR") }
        want ? assert_equal(want, got, "tmux printed #{out.inspect}") : assert_nil(got, "tmux printed #{out.inspect}")
      end
    end

    # Value: protects=the CLAUDE_CONFIG_DIR mismatch hint shows on doctor's FAILURE paths too
    # (it is the likely cause of "no files"); fails_when=the hint only runs on the success
    # row; why_new=QA pass 2 probes 002/003 reproduced it missing; seam=none (stubs the tmux
    # read); no_claim=a real tmux server's environment
    def test_doctor_remote_links_shows_the_config_dir_hint_when_no_files_are_found
      ENV["TMUX"] = "/tmp/fake,1,0"
      ENV["CLAUDE_CONFIG_DIR"] = path("claude-elsewhere")
      out = capture do
        stub_method(CLI, :tmux_global_env, ->(_) { nil }) do
          stub_method(CLI, :`, ->(_) { "/usr/local/bin/claude\n" }) do
            stub_method(RemoteLink, :claude_running?, -> { true }) { CLI.send(:doctor_remote_links) }
          end
        end
      end
      assert_includes out, "no session files"
      assert_includes out, "but unset in tmux"
    end

    def test_doctor_remote_links_notes_a_missing_dir_only_when_claude_is_installed
      without = capture { stub_method(CLI, :`, ->(_) { "" }) { CLI.send(:doctor_remote_links) } }
      assert_empty without, "no Claude Code, no row"
      with = capture do
        stub_method(CLI, :`, ->(_) { "/usr/local/bin/claude\n" }) do
          stub_method(RemoteLink, :claude_running?, -> { true }) { CLI.send(:doctor_remote_links) }
        end
      end
      assert_includes with, "Claude is running but there are no session files"
      idle = capture do
        stub_method(CLI, :`, ->(_) { "/usr/local/bin/claude\n" }) do
          stub_method(RemoteLink, :claude_running?, -> { false }) { CLI.send(:doctor_remote_links) }
        end
      end
      assert_includes idle, "no live Claude sessions", "Claude removes its file on exit: nothing open is not a warning"
      refute_includes idle, "may have moved"
    end

    # --- doctor: PATH symlink rows (the required command + the optional alias) ---

    def test_doctor_reports_both_symlink_rows
      capture { Installer.install(no_tmux: true) }
      out = capture { run_doctor }
      assert_includes out, "PATH symlink: #{Installer.symlink_path}"
      assert_includes out, "PATH symlink: #{Installer.symlink_path('sb')}"
    end

    # --- doctor: which install tmux is wired to (clone → brew moves) ---

    # Value: protects=doctor telling "wired to this install" from "wired to another" or "to one
    # that's gone"; fails_when=the check regresses to marker-presence only (a deleted clone reads
    # ✓ while the toggle/hooks fail silently); why_new=tmux_wired? only checks the marker; seam=none
    def test_doctor_tmux_wired_names_which_install_tmux_runs
      conf = File.expand_path("~/.tmux.conf")
      wire = ->(fragment) { File.write(conf, "#{Installer::BEGIN_MARK}\nrun-shell '#{Shellwords.escape(fragment)}'\n#{Installer::END_MARK}\n") }

      wire.call(Installer.fragment_path)
      assert_match(/✓.*tmux bindings wired/, capture { CLI.send(:doctor_tmux_wired) })

      other = path("old clone", "switchboard.tmux").tap { |f| FileUtils.mkdir_p(File.dirname(f)); File.write(f, "") }
      wire.call(other)
      out = capture { CLI.send(:doctor_tmux_wired) }
      assert_includes out, "wired to another install (#{other})"
      refute_includes out, "✗"

      File.delete(other)
      assert_match(/✗.*tmux is wired to a missing install \(#{Regexp.escape(other)}\)/, capture { CLI.send(:doctor_tmux_wired) })

      File.write(conf, "#{Installer::BEGIN_MARK}\n# edited by hand\n#{Installer::END_MARK}\n")
      assert_match(/✗.*switchboard block but no line it recognizes/, capture { CLI.send(:doctor_tmux_wired) })

      File.delete(conf)
      assert_match(/✗.*tmux bindings wired/, capture { CLI.send(:doctor_tmux_wired) })
    end

    # Under Homebrew there are no symlinks to check; doctor reports the brew PATH
    # entry instead of two ✗ rows for links install deliberately didn't make.
    def test_doctor_reports_homebrew_path_instead_of_symlinks
      out = stub_method(Installer, :homebrew?, -> { true }) { capture { run_doctor } }
      refute_includes out, "PATH symlink:"
      assert_match(/Homebrew/, out)
    end

    # Value: protects=doctor's ✓/✗ verdict on the brew PATH entry; fails_when=the identity check
    # is dropped/inverted or compares strings (brew's bin/ entry is a symlink, not bin_path itself);
    # why_new=the test above only matches /Homebrew/, which both ✓ and ✗ rows contain; seam=none
    def test_doctor_homebrew_path_passes_when_path_resolves_to_this_install
      dir = path("brew-bin").tap { |d| FileUtils.mkdir_p(d) }
      File.symlink(Installer.bin_path, File.join(dir, "switchboard"))
      ENV["PATH"] = dir
      out = stub_method(Installer, :homebrew?, -> { true }) { capture { CLI.send(:doctor_symlinks) } }
      assert_includes out, "✓"
      assert_includes out, "on PATH via Homebrew: #{File.join(dir, 'switchboard')}"
    end

    # Value: protects=doctor's ✗ and its fix advice under brew; fails_when=a missing command
    # and a shadowing clone link get the same (wrong) `brew link` advice, or either reads ✓;
    # why_new=the brew dispatch test only matches /Homebrew/, present in every row; seam=none
    def test_doctor_homebrew_path_fails_when_switchboard_is_missing_or_shadowed
      bin = path("my bin").tap { |d| FileUtils.mkdir_p(d) } # a space, so the rm hint must quote
      ENV["PATH"] = bin
      doctor = -> { stub_method(Installer, :homebrew?, -> { true }) { capture { CLI.send(:doctor_symlinks) } } }
      out = doctor.call
      assert_match(/✗.*isn't on PATH — run `brew link switchboard`/, out)
      assert_equal 1, out.scan("brew link").size, "a missing sb stays a soft note, not a second ✗"
      sb_line = out.lines.find { |l| l.include?("`sb`") }
      assert_includes sb_line, "optional shorthand"
      refute_includes sb_line, "✗"

      # A clone's leftover links ahead of brew's: ✗ with an rm for each, quoted.
      clone = path("old clone").tap { |d| FileUtils.mkdir_p(File.join(d, "bin")); FileUtils.mkdir_p(File.join(d, "lib")) }
      File.write(File.join(clone, "lib", "switchboard.rb"), "")
      File.write(File.join(clone, "bin", "switchboard"), "#!/bin/sh\n").then { File.chmod(0o755, File.join(clone, "bin", "switchboard")) }
      %w[switchboard sb].each { |n| File.symlink(File.join(clone, "bin", "switchboard"), File.join(bin, n)) }
      out = doctor.call
      %w[switchboard sb].each do |n|
        link = File.join(bin, n)
        assert_match(/✗.*`#{n}` on PATH is #{Regexp.escape(link)}, which shadows Homebrew's/, out)
        assert_includes out, "`rm #{Shellwords.escape(link)}`"
      end
      refute_includes out, "switchboard uninstall"

      # Some other program named sb is never flagged or offered for deletion.
      File.delete(File.join(bin, "sb"))
      File.write(File.join(bin, "sb"), "#!/bin/sh\n").then { File.chmod(0o755, File.join(bin, "sb")) }
      sb_line = doctor.call.lines.find { |l| l.include?("`sb`") }
      assert_includes sb_line, "another program; optional shorthand"
      refute_includes sb_line, "✗"
      refute_includes sb_line, "rm "
    end

    # Value: protects=doctor's ✗ + PATH-order advice when `switchboard` on PATH is some other program;
    # fails_when=the required branch is dropped (a foreign switchboard reads as a soft note) or it's
    # offered for `rm` like a clone link (deleting a program that isn't ours); why_new=the shadow test
    # covers only a clone link and a foreign `sb`, never a foreign `switchboard`; seam=none
    def test_doctor_homebrew_path_flags_a_foreign_switchboard_without_offering_rm
      bin = path("foreign-bin").tap { |d| FileUtils.mkdir_p(d) }
      File.write(File.join(bin, "switchboard"), "#!/bin/sh\n").then { File.chmod(0o755, File.join(bin, "switchboard")) }
      ENV["PATH"] = bin
      out = stub_method(Installer, :homebrew?, -> { true }) { capture { CLI.send(:doctor_symlinks) } }
      line = out.lines.find { |l| l.include?("`switchboard` on PATH") }
      assert_match(/✗.*`switchboard` on PATH is #{Regexp.escape(File.join(bin, 'switchboard'))}, another program — put Homebrew's bin earlier on PATH/, line)
      refute_includes line, "rm "
    end

    # Value: protects=a clone's tracked bin/switchboard from doctor's `rm` advice when the clone's
    # bin/ itself is on PATH; fails_when=the symlink check is dropped (doctor tells the user to delete
    # the clone's real launcher); why_new=the shadow test only puts symlinks to a clone on PATH; seam=none
    def test_doctor_homebrew_path_never_offers_rm_for_a_clones_own_launcher
      clone = path("clone").tap { |d| FileUtils.mkdir_p(File.join(d, "bin")); FileUtils.mkdir_p(File.join(d, "lib")) }
      File.write(File.join(clone, "lib", "switchboard.rb"), "")
      launcher = File.join(clone, "bin", "switchboard")
      File.write(launcher, "#!/bin/sh\n").then { File.chmod(0o755, launcher) }
      ENV["PATH"] = File.join(clone, "bin")
      out = stub_method(Installer, :homebrew?, -> { true }) { capture { CLI.send(:doctor_symlinks) } }
      line = out.lines.find { |l| l.include?("`switchboard` on PATH") }
      assert_match(/✗.*shadows Homebrew's — take #{Regexp.escape(File.join(clone, 'bin'))} off your PATH/, line)
      refute_includes out, "rm "
    end

    # A missing `sb` is a soft note, never a hard ✗ — doctor must agree with
    # install that the optional shorthand isn't a failure.
    def test_doctor_marks_missing_sb_as_optional_not_a_failure
      capture { Installer.install(no_tmux: true) }
      File.delete(Installer.symlink_path("sb")) # shorthand absent (collision / old install)
      out = capture { run_doctor }

      sb_line = out.lines.find { |l| l.include?(Installer.symlink_path("sb")) }
      assert sb_line, "expected a doctor row for the sb shorthand"
      assert_includes sb_line, "optional shorthand"
      refute_includes sb_line, "✗"

      sw_line = out.lines.find { |l| l.include?("PATH symlink: #{Installer.symlink_path}") }
      assert_includes sw_line, "✓" # the required command symlink stays a hard check
    end

    # The required command symlink is the opposite case: absent → a hard ✗, not a
    # soft note, so doctor still flags a broken core install.
    def test_doctor_marks_missing_command_symlink_as_failure
      capture { Installer.install(no_tmux: true) }
      File.delete(Installer.symlink_path) # remove the required `switchboard` link
      out = capture { run_doctor }

      sw_line = out.lines.find { |l| l.include?("PATH symlink: #{Installer.symlink_path}") }
      assert sw_line, "expected a doctor row for the switchboard command"
      assert_includes sw_line, "✗"
      refute_includes sw_line, "optional shorthand"
    end

    # --- doctor: per-adapter hook status (#110) ---

    # Value: protects=doctor admitting hooks an older release wrote (missing v0.51.1's
    # SessionEnd timeout) instead of a ✓; fails_when=the row goes back to presence-only;
    # why_new=dec-0dd4f937 shortcut retired; seam=none
    def test_doctor_hooks_flags_hooks_an_older_release_wrote
      repo = temp_git_repo
      File.write(Config.path, YAML.dump("projects" => [{ "name" => "app", "path" => repo }]))
      ENV["SWITCHBOARD_BIN"] = "/old/bin/switchboard"
      AgentHooks.enable(repo)
      ENV["SWITCHBOARD_BIN"] = "/new/bin/switchboard"
      out = stub_method(Installer, :installed_bin?, -> { true }) { Dir.chdir(repo) { capture { CLI.doctor_hooks } } }
      assert_includes out, "claude hooks here are out of date — `switchboard upgrade`"
      refute_includes out, "claude hooks here: "
    end

    # Value: protects=doctor giving a usable fix for a broken settings file instead of the
    # dead-end "enable-hooks" (which refuses it); fails_when=doctor reads it as hooks off;
    # why_new=cycle-2 state-machines; seam=none
    def test_doctor_hooks_reports_a_corrupt_settings_file_of_ours
      repo = temp_git_repo
      FileUtils.mkdir_p(File.join(repo, ".claude"))
      File.write(ClaudeHook.settings_path(repo), "{ #{HookFile::MARK}")
      out = Dir.chdir(repo) { capture { CLI.doctor_hooks } }
      assert_includes out, "isn't valid JSON"
      refute_includes out, "hooks off here"
    end

    def test_doctor_hooks_reports_an_unreadable_settings_path_instead_of_crashing
      repo = temp_git_repo
      FileUtils.mkdir_p(ClaudeHook.settings_path(repo)) # a directory: EISDIR on read
      out = Dir.chdir(repo) { capture { CLI.doctor_hooks } }
      assert_includes out, "can't read"
    end

    # Value: protects=doctor from a dogfood checkout not calling the installed binary's
    # hooks "out of date" (upgrade, judging by the installed one, would say up to date);
    # fails_when=doctor judges staleness by whatever binary runs it; why_new=run-2 Red Team;
    # seam=installed_bin? (PATH lookup)
    def test_doctor_judges_hook_staleness_only_from_the_installed_binary
      repo = temp_git_repo
      ENV["SWITCHBOARD_BIN"] = "/opt/homebrew/opt/switchboard/libexec/bin/switchboard"
      AgentHooks.enable(repo)
      ENV["SWITCHBOARD_BIN"] = "/dogfood/bin/switchboard"
      out = stub_method(Installer, :installed_bin?, -> { false }) { Dir.chdir(repo) { capture { CLI.doctor_hooks } } }
      refute_includes out, "out of date"
      assert_includes out, "claude hooks here"
    end

    def test_doctor_hooks_shows_current_hooks_as_ok_from_the_installed_binary
      repo = temp_git_repo
      ENV["SWITCHBOARD_BIN"] = "/new/bin/switchboard"
      AgentHooks.enable(repo)
      out = stub_method(Installer, :installed_bin?, -> { true }) { Dir.chdir(repo) { capture { CLI.doctor_hooks } } }
      assert_includes out, "\e[32m✓\e[0m claude hooks here: #{ClaudeHook.settings_path(File.realpath(repo))}" # doctor prints git's realpath
      refute_includes out, "out of date"
      refute_includes out, "run the installed"
    end

    def test_doctor_version_reports_latest_available_or_unknown
      { VERSION => "#{VERSION} (latest)", "0.0.1" => "#{VERSION} (latest)", "999.0.0" => "999.0.0 is available (you have #{VERSION}) — `switchboard upgrade`",
        nil => "couldn't check for a newer release" }.each do |latest, line|
        out = stub_method(Upgrade, :install_method, -> { :brew }) do
          stub_method(LatestRelease, :latest, ->(**) { latest }) { capture { CLI.doctor_version } }
        end
        assert_includes out, line
      end
    end

    # Value: protects=doctor not sending a clone or --HEAD user to an upgrade that follows
    # a branch, not tags (it would answer "already newest" forever); fails_when=doctor
    # compares release tags for every install; why_new=Red Team cycle 1; seam=none
    def test_doctor_version_compares_tags_only_for_a_homebrew_install
      { clone: "follows your clone's branch", brew_head: "follows main (--HEAD)" }.each do |method, line|
        looked = false
        out = stub_method(Upgrade, :install_method, -> { method }) do
          stub_method(LatestRelease, :latest, ->(**) { looked = true; "999.0.0" }) { capture { CLI.doctor_version } }
        end
        assert_includes out, line
        refute_includes out, "is available"
        refute looked, "#{method}: no release lookup"
      end
    end

    # Value: protects=`switchboard doctor` showing which version is running and whether a newer
    # release exists; fails_when=doctor stops calling doctor_version (the row vanishes);
    # why_new=only doctor_version itself was tested, never its wiring into doctor; seam=none;
    # no_claim=the other doctor rows
    def test_doctor_reports_the_version_row
      out = stub_method(Upgrade, :install_method, -> { :brew }) do
        stub_method(LatestRelease, :latest, ->(**) { VERSION }) { capture { run_doctor } }
      end
      assert_includes out, "switchboard #{VERSION} (latest)"
    end

    # doctor splits status into claude (per-worktree) and codex (global), and flags the
    # codex trust caveat (a present block isn't proof codex runs it until /hooks-trusted).
    def test_doctor_hooks_reports_claude_per_worktree_and_codex_global
      ENV["CODEX_HOME"] = path("codexhome")
      FileUtils.mkdir_p(ENV["CODEX_HOME"])
      repo = temp_git_repo
      AgentHooks.enable(repo)  # claude, per-worktree
      CodexHook.install_global # codex, global block
      out = Dir.chdir(repo) { capture { CLI.doctor_hooks } }
      assert_match(%r{claude hooks here: .*/\.claude/settings\.local\.json}, out)
      assert_match(%r{codex hooks \(global\): .*/config\.toml}, out)
      assert_includes out, "trusted", "codex trust caveat shown"
      assert_includes out, "/hooks"
    end

    # Value: protects=the global codex rows (trust count, stale/unsafe advice) showing from a
    # home shell; fails_when=doctor_hooks returns before the codex section outside a worktree;
    # why_new=every codex doctor test ran inside a repo; seam=none
    def test_doctor_hooks_reports_codex_outside_a_worktree
      ENV["CODEX_HOME"] = path("codexhome")
      FileUtils.mkdir_p(ENV["CODEX_HOME"])
      CodexHook.install_global
      elsewhere = path("not-a-repo")
      FileUtils.mkdir_p(elsewhere)
      out = Dir.chdir(elsewhere) { capture { CLI.doctor_hooks } }
      assert_match(%r{codex hooks \(global\): .*/config\.toml}, out)
      refute_includes out, "claude hooks", "no per-worktree row without a worktree"
    end

    # Value: protects=doctor from a home shell not nagging users who declined codex hooks;
    # fails_when=the "not installed" hint prints outside a worktree; why_new=ship red team (moving
    # the worktree guard into the Claude loop exposed it); seam=none
    def test_doctor_hooks_skips_the_codex_install_hint_outside_a_worktree
      ENV["CODEX_HOME"] = path("codexhome")
      FileUtils.mkdir_p(ENV["CODEX_HOME"])
      elsewhere = path("not-a-repo")
      FileUtils.mkdir_p(elsewhere)
      refute_includes Dir.chdir(elsewhere) { capture { CLI.doctor_hooks } }, "codex hooks (global) not installed"
      repo = temp_git_repo
      assert_includes Dir.chdir(repo) { capture { CLI.doctor_hooks } }, "codex hooks (global) not installed"
    end

    # Value: protects=doctor telling the user codex hooks are unapproved (dead dots) and
    # going quiet once they're all approved; fails_when=the row ignores trust_status or the
    # warning shows at N == M; why_new=doctor printed the same caveat regardless; seam=stub
    # trust_status (its counting is pinned in codex_hook_test)
    def test_doctor_hooks_reports_the_codex_trust_count
      ENV["CODEX_HOME"] = path("codexhome")
      FileUtils.mkdir_p(ENV["CODEX_HOME"])
      repo = temp_git_repo
      CodexHook.install_global
      { [0, 9] => true, [4, 9] => true, [9, 9] => false }.each do |status, warns|
        out = stub_method(CLI, :codex_bypasses_trust?, -> { false }) do # independent of any memoized config
          stub_method(CodexHook, :trust_status, -> { status }) { Dir.chdir(repo) { capture { CLI.doctor_hooks } } }
        end
        assert_includes out, "#{status[0]}/#{status[1]} trusted"
        assert_equal warns, out.include?("/hooks"), "warning shown only when some hook is untrusted (#{status.inspect})"
      end

      # A session_command that bypasses trust never approves in /hooks: 0/9 is expected there.
      out = stub_method(CLI, :codex_bypasses_trust?, -> { true }) do
        stub_method(CodexHook, :trust_status, -> { [0, 9] }) { Dir.chdir(repo) { capture { CLI.doctor_hooks } } }
      end
      refute_includes out, "/hooks", "no dead-dots warning when codex runs with the bypass"
      assert_includes out, "bypass-hook-trust"
    end

    # Value: protects=doctor naming the real fix when the on-disk block isn't what install
    # writes — re-run install, not "approve in /hooks" (which would bless stale commands);
    # fails_when=a stale/unrewritable block still gets the trust count + /hooks hint as the
    # advice; why_new=red-team inv3 pass 2; seam=stub block_state (pinned in codex_hook_test)
    def test_doctor_hooks_sends_a_stale_or_unrewritable_block_to_install
      ENV["CODEX_HOME"] = path("codexhome")
      FileUtils.mkdir_p(ENV["CODEX_HOME"])
      repo = temp_git_repo
      CodexHook.install_global
      ENV["SWITCHBOARD_BIN"], was = "/elsewhere/bin/switchboard", ENV["SWITCHBOARD_BIN"]
      { stale: "re-run `switchboard install`", unsafe: "can't be rewritten safely",
        collision: "already has its own [hooks] config" }.each do |state, says|
        out = stub_method(CLI, :codex_bypasses_trust?, -> { false }) do
          stub_method(CodexHook, :block_state, -> { state }) { Dir.chdir(repo) { capture { CLI.doctor_hooks } } }
        end
        assert_includes out, says, state.to_s
        refute_includes out, "trusted", "#{state}: no trust count for a block install would change"
        # :stale names the switchboard this block expects, so the user re-runs the right install.
        assert_includes out, "(/elsewhere/bin/switchboard)", "stale names the bin" if state == :stale
      end
    ensure
      ENV["SWITCHBOARD_BIN"] = was if defined?(was)
    end

    # Value: protects=doctor's dead-dots warning stays on unless EVERY codex launch bypasses
    # trust; fails_when=one bypassing project (any?) silences it for the rest; why_new=only
    # all-or-nothing configs were tested; seam=none
    def test_codex_bypasses_trust_reads_global_and_project_session_commands
      cfg = path("config.yml")
      ENV["SWITCHBOARD_CONFIG"] = cfg
      project = ->(cmd) { "projects:\n  - name: p\n    path: /tmp/p\n    session_command: #{cmd}\n" }
      {
        "session_command: claude\n#{project.('codex --dangerously-bypass-hook-trust')}" => true, # the only codex launch bypasses
        "session_command: codex --dangerously-bypass-hook-trust\n" => true,                       # global bypass
        "session_command: codex\n" => false,
        "session_command: codex\n#{project.('codex --dangerously-bypass-hook-trust')}" => false,  # mixed: global still dead
        "session_command: claude\n" => false,                                                        # no codex launch at all
        # Value (rows below): protects=a path- or chain-launched codex counts as a codex launch,
        # and a codex-prefixed word doesn't; fails_when=the launch regex loses its `/`/`;`
        # boundary or its word end; why_new=only bare `codex` was tried; seam=none
        "session_command: /opt/homebrew/bin/codex --dangerously-bypass-hook-trust\n" => true,
        "session_command: codex --dangerously-bypass-hook-trust\n#{project.('cd x;codex')}" => false, # chained launch, no bypass
        "session_command: codex --dangerously-bypass-hook-trust\n#{project.('codex-wrapper')}" => true, # not a codex launch
        # Value: protects=a tool whose name merely ENDS in codex isn't a codex launch;
        # fails_when=the launch regex loses its leading boundary; why_new=only trailing-word
        # and path/chain prefixes were tried; seam=none; no_claim=which tools exist by that name
        "session_command: codex --dangerously-bypass-hook-trust\n#{project.('mycodex run')}" => true
      }.each do |yaml, want|
        File.write(cfg, yaml)
        CLI.instance_variable_set(:@config, nil) # config memoizes; re-read this sandbox's file
        assert_equal want, CLI.codex_bypasses_trust?, yaml
      end
    ensure
      CLI.instance_variable_set(:@config, nil)
    end

    # Nothing wired → claude off here + codex global not installed, no trust note.
    def test_doctor_hooks_reports_off_when_nothing_is_wired
      ENV["CODEX_HOME"] = path("codexhome")
      FileUtils.mkdir_p(ENV["CODEX_HOME"])
      repo = temp_git_repo
      out = Dir.chdir(repo) { capture { CLI.doctor_hooks } }
      assert_includes out, "claude hooks off here"
      assert_includes out, "codex hooks (global) not installed"
      refute_includes out, "trusted"
    end

    # enable-hooks wires claude per-worktree and POINTS AT install for codex when the global
    # block is absent; once the block exists it self-heals (re-ensures) and says "(global)".
    def test_enable_hooks_reports_codex_global_state
      ENV["CODEX_HOME"] = path("codexhome")
      FileUtils.mkdir_p(ENV["CODEX_HOME"])
      repo = temp_git_repo
      out = Dir.chdir(repo) { capture { CLI.enable_hooks } }
      assert_match(%r{claude: .*/\.claude/settings\.local\.json}, out)
      assert_match(/codex:.*not enabled/, out)

      CodexHook.install_global
      out2 = Dir.chdir(repo) { capture { CLI.enable_hooks } }
      assert_match(/codex:.*\(global\)/, out2)

      # Value: protects=a refused re-ensure never prints the "(global) — run /hooks" success
      # line; fails_when=enable_hooks ignores install_global's result again (QA probe 002);
      # why_new=only the success path was covered; seam=stub install_global
      { unsafe: "can't be rewritten safely", conflict: "changed while switchboard was writing it",
        collision: "already has its own [hooks]", nil => "couldn't write" }.each do |result, text|
        out3 = stub_method(CodexHook, :install_global, -> { result }) { Dir.chdir(repo) { capture { CLI.enable_hooks } } }
        refute_match(/run `\/hooks` in codex to approve/, out3, "#{result.inspect} must not read as success")
        assert_includes out3, text, "#{result.inspect} is reported as a failure"
      end

      # Value: protects=a refused codex re-ensure fails the command for scripts too (exit 1) while
      # success exits 0; fails_when=enable_hooks stops returning false on a refusal; why_new=only the
      # printed text was pinned; seam=stub install_global; no_claim=claude's wiring (asserted above)
      stub_method(CodexHook, :install_global, -> { :unsafe }) do
        e = assert_raises(SystemExit) { Dir.chdir(repo) { capture { CLI.run(["enable-hooks"]) } } }
        assert_equal 1, e.status
      end
      Dir.chdir(repo) { capture { CLI.run(["enable-hooks"]) } } # the real block: no exit

      # A stale block (another checkout's bin) is rewritten and reads as success, not a refusal.
      ENV["SWITCHBOARD_BIN"], was = "/elsewhere/bin/switchboard", ENV["SWITCHBOARD_BIN"]
      assert_equal :stale, CodexHook.block_state
      out4 = Dir.chdir(repo) { capture { CLI.run(["enable-hooks"]) } }
      assert_match(/codex:.*\(global\)/, out4)
      assert_equal :current, CodexHook.block_state
    ensure
      ENV["SWITCHBOARD_BIN"] = was if defined?(was)
    end

    # disable-hooks clears claude per-worktree; the "codex is global — uninstall removes it"
    # note appears ONLY when the global block is installed (so it's not misleading otherwise).
    def test_disable_hooks_notes_codex_is_global_only_when_installed
      ENV["CODEX_HOME"] = path("codexhome")
      FileUtils.mkdir_p(ENV["CODEX_HOME"])
      repo = temp_git_repo
      out = Dir.chdir(repo) { capture { CLI.disable_hooks } }
      refute_match(/codex hooks are global/, out)

      CodexHook.install_global
      out2 = Dir.chdir(repo) { capture { CLI.disable_hooks } }
      assert_match(/codex hooks are global/, out2)
    end

    # --- prune / quit (Reconcile + Tmux stubbed so no real tmux is touched) ---

    def report(reachable: true, sb_count: 0, orphans: [])
      Reconcile::Report.new(reachable: reachable, sb_count: sb_count, orphans: orphans)
    end

    def test_prune_passes_dry_run_for_dry_run_and_n_flags
      rep = report # hoist: inside the stub, self is Reconcile, not the test
      [["--dry-run"], ["-n"]].each do |args|
        captured = :unset
        stub_method(Reconcile, :prune, ->(_cfg, dry_run: false, **) { captured = dry_run; rep }) do
          capture { CLI.prune(args) }
        end
        assert_equal true, captured, "#{args.inspect} should request a dry run"
      end
    end

    def test_prune_bare_is_not_a_dry_run
      rep = report
      captured = :unset
      stub_method(Reconcile, :prune, ->(_cfg, dry_run: false, **) { captured = dry_run; rep }) do
        capture { CLI.prune([]) }
      end
      assert_equal false, captured
    end

    def test_quit_reports_closed_count
      stub_method(Tmux, :kill_all, -> { ["sb/a/x", "sb/home"] }) do
        assert_includes capture { CLI.quit }, "closed 2 switchboard session(s)"
      end
    end

    def test_quit_when_nothing_to_close
      stub_method(Tmux, :kill_all, -> { [] }) do
        assert_includes capture { CLI.quit }, "no switchboard sessions to close"
      end
    end

    # `switchboard quit` clears stale agent state too (the CLI twin of the sidebar
    # `q`), so a torn-down agent doesn't relaunch showing as still "working".
    # Value: protects=a held ◷ chime dies with the agents quit kills; fails_when=quit stops
    # calling OffstageHold.clear_all, so a dead pid matures the hold and rings a phantom chime
    # on the next launch; why_new=only OffstageHold.clear_all itself was tested, not quit's
    # wiring; seam=none; no_claim=the real tmux teardown
    def test_quit_clears_agent_state
      cleared = false
      w = path("worktrees", "held")
      FileUtils.mkdir_p(w)
      OffstageHold.hold(w, pid: 1)
      stub_method(AgentState, :clear_all, -> { cleared = true }) do
        stub_method(Tmux, :kill_all, -> { [] }) do
          capture { CLI.quit }
        end
      end
      assert cleared, "quit wipes the stale hook states before teardown"
      assert_empty OffstageHold.held([w]), "...and every held ◷ chime"
    end

    # --- prune_summary: honest reporting (F5) + dry-run next step (DX-2) ------

    def test_prune_summary_distinguishes_unreachable_from_empty
      assert_equal "no tmux server — nothing to reconcile", CLI.prune_summary(report(reachable: false), [], false)
      assert_equal "no sb/ sessions found", CLI.prune_summary(report(sb_count: 0), [], false)
      assert_equal "3 sb/ session(s), none orphaned", CLI.prune_summary(report(sb_count: 3), [], false)
    end

    def test_prune_summary_kill_lists_orphans_without_next_step
      out = CLI.prune_summary(report(sb_count: 3, orphans: ["sb/app/gone"]), [], false)
      assert_includes out, "killed 1 orphaned session(s):"
      assert_includes out, "  sb/app/gone"
      refute_includes out, "run `switchboard prune`"
    end

    def test_prune_summary_dry_run_appends_next_step
      out = CLI.prune_summary(report(sb_count: 3, orphans: ["sb/app/gone"]), [], true)
      assert_includes out, "would kill 1 orphaned session(s):"
      assert_includes out, "run `switchboard prune` to remove these"
    end

    # The orphaned-sidebar-process reap is a SEPARATE axis (process-with-no-pane vs
    # session-with-no-worktree): it appends its own line and never suppresses the
    # session summary, so a clean-sessions-but-stale-sidebars run reports both truths.
    def test_prune_summary_appends_sidebar_reap_line
      out = CLI.prune_summary(report(sb_count: 3), [111, 222], false)
      assert_includes out, "3 sb/ session(s), none orphaned"
      assert_includes out, "reaped 2 orphaned sidebar process(es)"
    end

    def test_prune_summary_sidebar_reap_dry_run_says_would
      out = CLI.prune_summary(report(sb_count: 3), [111], true)
      assert_includes out, "would reap 1 orphaned sidebar process(es)"
    end

    def test_prune_summary_omits_sidebar_line_when_none_reaped
      out = CLI.prune_summary(report(sb_count: 3), [], false)
      refute_includes out, "sidebar process"
    end

    # --- doctor_sessions: actionable orphan line (DX-1), three branches --------

    def test_doctor_sessions_is_silent_when_unreachable
      rep = report(reachable: false)
      stub_method(Reconcile, :prune, ->(_cfg, **) { rep }) do
        assert_equal "", capture { CLI.send(:doctor_sessions) }.strip
      end
    end

    def test_doctor_sessions_reports_clean_when_no_orphans
      rep = report(reachable: true, sb_count: 3, orphans: [])
      stub_method(Reconcile, :prune, ->(_cfg, **) { rep }) do
        assert_includes capture { CLI.send(:doctor_sessions) }, "no orphaned sb/ sessions"
      end
    end

    def test_doctor_sessions_flags_orphans_with_the_fix_command
      rep = report(reachable: true, sb_count: 3, orphans: ["sb/app/gone"])
      stub_method(Reconcile, :prune, ->(_cfg, **) { rep }) do
        out = capture { CLI.send(:doctor_sessions) }
        assert_includes out, "1 orphaned sb/ session(s)"
        assert_includes out, "switchboard prune"
      end
    end

    # --- remove (unregister a project; rm alias) ------------------------------

    def test_remove_unregisters_a_project
      File.write(Config.path, YAML.dump("projects" => [{ "name" => "app", "path" => "/repos/app" }]))
      out = capture { CLI.run(["remove", "app"]) }
      assert_includes out, "removed app"
      refute Config.new.project("app"), "the project is gone from the config"
    end

    def test_remove_warns_on_unknown_project
      Config.scaffold
      err = capture_err { CLI.run(["remove", "ghost"]) }
      assert_match(/no such project/, err)
    end

    def test_remove_requires_a_name
      err = capture_err { CLI.run(["remove"]) }
      assert_match(/usage: switchboard remove/, err)
    end

    def test_rm_is_an_alias_for_remove
      File.write(Config.path, YAML.dump("projects" => [{ "name" => "app", "path" => "/repos/app" }]))
      capture { CLI.run(["rm", "app"]) }
      refute Config.new.project("app")
    end

    # --- doctor: tmux_keys rows (issue #15) -----------------------------------

    def test_doctor_shows_the_configured_toggle_key
      File.write(Config.path, YAML.dump("tmux_keys" => { "toggle" => "b" }))
      out = with_key_stubs(live: true) { capture { CLI.send(:doctor_binding_live) } }
      assert_includes out, "prefix-b bound (toggle-sidebar)"
    end

    def test_doctor_flags_an_invalid_key_value
      File.write(Config.path, YAML.dump("tmux_keys" => { "toggle" => "a b" }))
      out = with_key_stubs(live: true) { capture { CLI.send(:doctor_binding_live) } }
      assert_includes out, "tmux_keys.toggle"
      assert_includes out, "isn't a usable key"
      assert_includes out, "prefix-s bound", "still reports the fallback key as bound"
    end

    def test_doctor_flags_a_home_toggle_collision
      File.write(Config.path, YAML.dump("tmux_keys" => { "toggle" => "b", "home" => "b" }))
      out = with_key_stubs(live: true) { capture { CLI.send(:doctor_binding_live) } }
      assert_includes out, "collides with the toggle key"
    end

    # Value: protects=a config.yml that parses but isn't a map (a dropped colon makes it one
    # string; leading dashes a list) reads as broken, not as an empty healthy config; fails_when=
    # load_data accepts any parsed value; why_new=ship 2 red team; seam=none
    def test_doctor_config_row_fails_on_a_config_that_is_not_a_map
      { "a string" => "worktree_root ~/wt\n", "a list" => "- projects\n- base\n" }.each do |label, body|
        File.write(Config.path, body)
        CLI.instance_variable_set(:@config, nil)
        out = capture { CLI.send(:doctor_config) }
        assert_includes out, "config failed to parse (the top level isn't a map of settings)", label
        assert_empty Config.new.projects, "#{label}: degrades to no projects, never raises"
      end
    end

    # Value: protects=a config.yml that is literally `false` reads as broken, not as an empty
    # healthy config; fails_when=load_data falls back to {} for any falsy value; why_new=ship 2
    # Codex adversarial; seam=none
    # Value: protects=an empty or comment-only config.yml still loads clean (doctor, install and
    # upgrade don't fail on it); fails_when=load_data drops the nil-only {} fallback; why_new=ship
    # 3 testing specialist; seam=none; no_claim=none beyond protects
    def test_an_empty_or_comment_only_config_is_not_broken
      ["", "# only a comment\n"].each do |body|
        File.write(Config.path, body)
        assert_nil Config.new.load_error, body.inspect
      end
    end

    def test_a_config_that_is_just_false_is_broken
      File.write(Config.path, "false\n")
      assert_equal "the top level isn't a map of settings", Config.new.load_error
    end

    # Value: protects=one doctor row per cause: when the toggle key isn't live at all, its
    # NOT-bound row stands alone (no duplicate drift line); fails_when=doctor_key_drift ignores
    # liveness; why_new=ship 2 Claude adversarial; seam=tmux_wired?/tmux_server?
    def test_doctor_shows_no_toggle_drift_row_when_the_key_is_not_live
      File.write(Config.path, YAML.dump("tmux_keys" => { "toggle" => "t" }))
      opts = { "@switchboard-toggle-key" => "s", "@switchboard-config-path" => File.expand_path(Config.path) }
      out = stub_method(Installer, :tmux_wired?, ->(*) { true }) do
        stub_method(Installer, :tmux_server?, -> { true }) do
          with_key_stubs(live: false, options: opts) { capture { CLI.send(:doctor_binding_live) } }
        end
      end
      assert_includes out, "NOT bound"
      refute_includes out, "tmux_keys.toggle is"
    end

    # Value: protects=hiding the toggle drift row (its NOT-bound row covers it) never hides a
    # home key edited by hand; fails_when=skip_toggle returns from the whole check; why_new=ship
    # 3 testing specialist; seam=tmux_wired?/tmux_server?; no_claim=a live tmux server
    def test_doctor_still_shows_home_drift_when_the_toggle_row_is_hidden
      File.write(Config.path, YAML.dump("tmux_keys" => { "toggle" => "t", "home" => "H" }))
      opts = { "@switchboard-toggle-key" => "s", "@switchboard-config-path" => File.expand_path(Config.path) }
      out = stub_method(Installer, :tmux_wired?, ->(*) { true }) do
        stub_method(Installer, :tmux_server?, -> { true }) do
          with_key_stubs(live: false, options: opts) { capture { CLI.send(:doctor_key_drift, skip_toggle: true) } }
        end
      end
      refute_includes out, "tmux_keys.toggle is"
      assert_includes out, "tmux_keys.home is H in config, but tmux has nothing bound"
    end

    # Value: protects=a configured key that isn't bound (tmux refused it, or the toggle fell
    # back onto it) is said in doctor, not silent; fails_when=doctor_key_drift ignores the
    # recorded -rejected key; why_new=ship 3 D3; seam=tmux_wired?/tmux_server?; no_claim=a live
    # tmux server
    def test_doctor_names_a_configured_key_that_isnt_bound
      File.write(Config.path, YAML.dump("tmux_keys" => { "toggle" => "F13", "home" => "s" }))
      opts = { "@switchboard-toggle-key" => "s", "@switchboard-toggle-rejected" => "F13",
               "@switchboard-home-rejected" => "s", "@switchboard-config-path" => File.expand_path(Config.path) }
      out = stub_method(Installer, :tmux_wired?, ->(*) { true }) do
        stub_method(Installer, :tmux_server?, -> { true }) do
          with_key_stubs(live: true, options: opts) { capture { CLI.send(:doctor_key_drift) } }
        end
      end
      assert_includes out, "tmux_keys.toggle is F13 in config, but it isn't bound (tmux refused it)"
      assert_includes out, "tmux_keys.home is s in config, but it isn't bound (tmux refused it, or the toggle fell back onto it)"
      refute_includes out, "but tmux has", "a refused key is never drift"
    end

    def test_doctor_reports_a_config_parse_error
      File.write(Config.path, "}{ not yaml")
      out = with_key_stubs(live: true) { capture { CLI.send(:doctor_binding_live) } }
      assert_includes out, "tmux_keys: using the default keys", "the key section says what the parse error means for it"
      # Extended (ship 7 maintainability): with keys already bound, a broken config keeps
      # them, and doctor says so instead of naming the defaults.
      kept = with_key_stubs(live: true, options: { "@switchboard-home-key" => "H" }) { capture { CLI.send(:doctor_binding_live) } }
      assert_includes kept, "tmux_keys: keeping the keys already bound (config.yml didn't parse"
      refute_includes kept, "using the default keys"
    end

    # Value: protects=#14: doctor never vouches for a config.yml that won't parse; fails_when=the
    # config row checks only existence (green ✓ on a broken file); why_new=QA probe 001 found the
    # green row still printed above the parse error; seam=none
    def test_doctor_config_row_fails_on_a_config_that_will_not_parse
      File.write(Config.path, "--\nprojects:\n  - name: app\n")
      out = capture { CLI.send(:doctor_config) }
      assert_includes out, "✗"
      assert_includes out, "config: #{Config.path} — config failed to parse ("
      refute_includes out, "✓"
      File.write(Config.path, YAML.dump("projects" => []))
      CLI.instance_variable_set(:@config, nil) if CLI.instance_variable_defined?(:@config)
      assert_includes capture { CLI.send(:doctor_config) }, "✓"
      File.delete(Config.path)
      assert_includes capture { CLI.send(:doctor_config) }, "no config — run `switchboard install`"
    end

    # Value: protects=doctor flagging a tmux_keys edit nobody applied, and staying quiet
    # about a key tmux refused; fails_when=doctor_key_drift is dropped or ignores the rejected
    # key; why_new=the bound key still works, so every other row read green; seam=tmux_server?
    # Extended (audit): the home role too — protects=a home key added by hand and never bound
    # reading "nothing bound", not an empty `prefix-`; fails_when=the drift loop skips home or
    # the unbound side's wording breaks; seam=tmux_server?
    def test_doctor_flags_a_tmux_key_edited_by_hand_but_not_a_refused_one
      File.write(Config.path, YAML.dump("tmux_keys" => { "toggle" => "t", "home" => "H" }))
      drift = "tmux_keys.toggle is t in config, but tmux has prefix-s bound"
      unwired = stub_method(Installer, :tmux_wired?, ->(*) { false }) do # --no-tmux: no keys of ours to drift
        stub_method(Installer, :tmux_server?, -> { true }) do
          with_key_stubs(live: true, options: { "@switchboard-toggle-key" => "s", "@switchboard-config-path" => File.expand_path(Config.path) }) { capture { CLI.send(:doctor_binding_live) } }
        end
      end
      refute_includes unwired, "in config, but tmux has", "no drift row when tmux isn't wired to switchboard"
      out = stub_method(Installer, :tmux_wired?, ->(*) { true }) do
        stub_method(Installer, :tmux_server?, -> { true }) do
          with_key_stubs(live: true, options: { "@switchboard-toggle-key" => "s", "@switchboard-config-path" => File.expand_path(Config.path) }) { capture { CLI.send(:doctor_binding_live) } }
        end
      end
      assert_includes out, drift
      assert_includes out, "tmux_keys.home is H in config, but tmux has nothing bound"
      out = stub_method(Installer, :tmux_wired?, ->(*) { true }) do
        stub_method(Installer, :tmux_server?, -> { true }) do
          options = { "@switchboard-config-path" => File.expand_path(Config.path), "@switchboard-toggle-key" => "s", "@switchboard-toggle-rejected" => "t", "@switchboard-home-key" => "H" }
          with_key_stubs(live: true, options: options) { capture { CLI.send(:doctor_binding_live) } }
        end
      end
      refute_includes out, "in config, but tmux has"
      File.write(Config.path, YAML.dump("tmux_keys" => { "toggle" => "s" })) # home removed from config
      CLI.instance_variable_set(:@config, nil) # CLI memoizes config
      out = stub_method(Installer, :tmux_wired?, ->(*) { true }) do
        stub_method(Installer, :tmux_server?, -> { true }) do
          options = { "@switchboard-config-path" => File.expand_path(Config.path), "@switchboard-toggle-key" => "s", "@switchboard-home-key" => "S" }
          with_key_stubs(live: true, options: options) { capture { CLI.send(:doctor_binding_live) } }
        end
      end
      assert_includes out, "tmux_keys.home is unbound in config, but tmux has prefix-S bound"
    end

    def test_doctor_warns_about_a_clobbered_binding
      File.write(Config.path, YAML.dump("tmux_keys" => { "toggle" => "b" }))
      out = with_key_stubs(live: true, options: { "@switchboard-toggle-clobbered" => "send-keys hi" }) do
        capture { CLI.send(:doctor_binding_live) }
      end
      assert_includes out, "replaced a prior binding: send-keys hi"
    end

    # Generated by /ship coverage audit.
    # Value: protects=doctor probing and naming the toggle key switchboard actually bound (its
    # fallback after tmux rejected the configured one); fails_when=doctor reads config's key
    # again; why_new=with_key_stubs ignores the probed key; seam=none; no_claim=tmux's rejection
    def test_doctor_checks_the_toggle_key_switchboard_actually_bound
      File.write(Config.path, YAML.dump("tmux_keys" => { "toggle" => "F13" }))
      asked = []
      out = stub_method(Installer, :toggle_key_live?, ->(key = nil) { asked << key; key == "s" }) do
        stub_method(Installer, :tmux_option, ->(name) { name == "@switchboard-toggle-key" ? "s" : nil }) do
          capture { CLI.send(:doctor_binding_live) }
        end
      end
      assert_equal ["s"], asked
      assert_includes out, "prefix-s bound (toggle-sidebar)"
      refute_includes out, "NOT bound"
    end

    # Value: protects=doctor pointing a stale running tmux at `switchboard upgrade`; fails_when=
    # the NOT-bound row drops the upgrade advice or reads as bound; why_new=coverage gap;
    # seam=none; no_claim=the live probe itself
    def test_doctor_flags_an_unbound_toggle_key_with_upgrade_advice
      out = stub_method(Installer, :bound_toggle_key, -> { "s" }) do
        with_key_stubs(live: false) { capture { CLI.send(:doctor_binding_live) } }
      end
      assert_includes out, "prefix-s NOT bound"
      assert_includes out, "run `switchboard upgrade`"
    end

    # Value: protects=doctor naming a missing live hook slot and the upgrade fix; fails_when=
    # a missing slot reads live or loses the upgrade advice; why_new=coverage gap; seam=none;
    # no_claim=the show-hooks parse (live_hooks_from)
    def test_doctor_flags_a_hook_slot_missing_from_the_server
      live = Installer::HOOK_SLOTS.to_h { |s| [s, true] }.merge(Installer::HOOK_SLOTS.first => false)
      out = stub_method(Installer, :live_hooks, -> { live }) { capture { CLI.send(:doctor_hooks_live) } }
      assert_includes out, "tmux hooks not live: #{Installer::HOOK_SLOTS.first}"
      assert_includes out, "run `switchboard upgrade`"
    end

    # --- doctor: unknown top-level keys (the misindent backstop) --------------

    def test_doctor_is_silent_about_unknown_keys_by_default
      File.write(Config.path, YAML.dump("worktree_root" => "/x", "projects" => []))
      assert_equal "", capture { CLI.send(:doctor_unknown_keys) }, "a clean config reports nothing"
    end

    def test_doctor_flags_a_misindented_sidebar_key_with_the_fix
      File.write(Config.path, YAML.dump("worktree_root" => "/x", "new_workspace" => "w"))
      out = capture { CLI.send(:doctor_unknown_keys) }
      assert_includes out, "\"new_workspace\""
      assert_includes out, "does nothing"
      assert_includes out, "nest it under `sidebar_keys:`", "names the parent so the fix is obvious"
    end

    def test_doctor_flags_a_generic_unknown_key
      File.write(Config.path, YAML.dump("worktree_root" => "/x", "wortree_root" => "/typo"))
      out = capture { CLI.send(:doctor_unknown_keys) }
      assert_includes out, "\"wortree_root\""
      assert_includes out, "unrecognized", "a non-action key gets the generic hint, not a sidebar_keys steer"
    end

    # --- doctor: sidebar_keys rows (issue #108) -------------------------------

    def test_doctor_is_silent_about_sidebar_keys_by_default
      assert_equal "", capture { CLI.send(:doctor_sidebar_keys) }, "no remap -> nothing to report"
    end

    def test_doctor_confirms_a_clean_remap
      File.write(Config.path, YAML.dump("sidebar_keys" => { "new_workspace" => "c", "delete" => "x" }))
      out = capture { CLI.send(:doctor_sidebar_keys) }
      assert_includes out, "sidebar_keys: 2 remapped, no clashes"
    end

    def test_doctor_flags_an_invalid_sidebar_key
      File.write(Config.path, YAML.dump("sidebar_keys" => { "rename" => "foo" }))
      out = capture { CLI.send(:doctor_sidebar_keys) }
      assert_includes out, "sidebar_keys.rename"
      assert_includes out, "isn't a single printable key"
      assert_includes out, "using \"r\"", "names the default it fell back to"
    end

    def test_doctor_flags_a_sidebar_key_collision
      File.write(Config.path, YAML.dump("sidebar_keys" => { "delete" => "j" })) # j == down's default
      out = capture { CLI.send(:doctor_sidebar_keys) }
      assert_includes out, "sidebar_keys.delete"
      assert_includes out, "clashes with down"
      assert_includes out, "left unbound"
    end

    # Value: protects=doctor tells the truth when a NEW action's default lost to an existing
    # remap; fails_when=it says the user's phone_link "clashes" or claims aliases phone_link
    # doesn't have; why_new=red team, ship of v0.54.0; seam=none; no_claim=none beyond protects
    def test_doctor_explains_a_new_default_taken_by_an_existing_remap
      File.write(Config.path, YAML.dump("sidebar_keys" => { "open_pr" => "p" }))
      out = capture { CLI.send(:doctor_sidebar_keys) }
      assert_includes out, "sidebar_keys.phone_link its default \"p\" is taken by open_pr"
      assert_includes out, "set sidebar_keys.phone_link to reach it"
      refute_includes out, "aliases still work", "phone_link has no arrow/ctrl alias"
    end

    # Value: protects=the alias hint still prints for an action that HAS aliases, and an invalid
    # remap reads as "its default lost", not as a clash the user wrote; fails_when=the ACTIONS
    # lookup breaks (hint gone everywhere) or the branch keys on nil only; why_new=testing + red
    # team, ship of v0.54.0; seam=none; no_claim=none beyond protects
    def test_doctor_keeps_the_alias_hint_for_an_action_that_has_aliases
      File.write(Config.path, YAML.dump("sidebar_keys" => { "up" => "j" }))
      out = capture { CLI.send(:doctor_sidebar_keys) }
      assert_includes out, "sidebar_keys.up (\"j\") clashes with down"
      assert_includes out, "its arrow/ctrl aliases still work"
    end

    def test_doctor_reads_an_invalid_remap_as_the_default_losing
      File.write(Config.path, YAML.dump("sidebar_keys" => { "open_pr" => "p", "phone_link" => "pp" }))
      out = capture { CLI.send(:doctor_sidebar_keys) }
      assert_includes out, "sidebar_keys.phone_link its default \"p\" is taken by open_pr"
    end

    # --- switchboard rename (issue #42) -------------------------------------

    # Config registering proj -> repo, plus a linked worktree at wts/proj/<leaf>.
    # Returns the worktree path.
    def rename_fixture(leaf = "old")
      repo = temp_git_repo("proj")
      File.write(Config.path, YAML.dump("worktree_root" => path("wts"),
                                        "projects" => [{ "name" => "proj", "path" => repo }]))
      dest = path("wts", "proj", leaf)
      git(repo, "worktree", "add", "-q", dest, "-b", leaf)
      dest
    end

    # No-arg `switchboard rename`: nothing to rename to, so it warns usage (including
    # the current workspace name) and exits non-zero — switchboard never guesses a name.
    def test_rename_no_arg_warns_usage_with_the_current_name
      wt = Worktree.new(project: "proj", path: "/x/alpha", primary: false)
      stub_method(CLI, :current_worktree, -> { wt }) do
        err = capture_err { refute CLI.rename(nil) }
        assert_match(/usage: switchboard rename/, err)
        assert_includes err, "alpha"
      end
    end

    def test_rename_no_arg_outside_a_worktree_warns
      FileUtils.mkdir_p(path("plain"))
      Dir.chdir(path("plain")) do
        err = capture_err { refute CLI.rename(nil) }
        assert_match(/not inside a switchboard-managed worktree/, err)
      end
    end

    def test_rename_outside_a_worktree_warns_and_fails
      FileUtils.mkdir_p(path("plain"))
      Dir.chdir(path("plain")) do
        err = capture_err { refute CLI.rename("x") }
        assert_match(/not inside a switchboard-managed worktree/, err)
      end
    end

    def test_rename_refuses_the_primary_checkout
      stub_method(CLI, :current_worktree, -> { Worktree.new(project: "proj", path: "/x", primary: true) }) do
        err = capture_err { refute CLI.rename("x") }
        assert_match(/can't rename the primary checkout/, err)
      end
    end

    def test_rename_renames_a_managed_worktree_from_inside_it
      old = rename_fixture
      # git canonicalizes the worktree path (macOS /var -> /private/var), so assert
      # on the leaf shape, not the exact symlinked prefix.
      out = Dir.chdir(old) { capture { assert CLI.rename("fresh") } }
      assert File.directory?(path("wts", "proj", "fresh"))
      assert_includes out, "renamed to "
      assert_includes out, "wts/proj/fresh"
      assert_includes out, "cd into the new path"
    end

    def test_rename_reports_partial_and_fails
      stub_method(CLI, :current_worktree, -> { Worktree.new(project: "proj", path: "/x", primary: false) }) do
        stub_method(Rename, :perform, ->(*) { Rename::Result.new(:partial, "/wts/proj/new") }) do
          err = nil
          capture { err = capture_err { refute CLI.rename("new") } } # :partial also puts the landing to stdout
          assert_match(/session rename failed/, err)
        end
      end
    end

    def test_rename_reports_exists_and_fails
      stub_method(CLI, :current_worktree, -> { Worktree.new(project: "proj", path: "/x", primary: false) }) do
        stub_method(Rename, :perform, ->(*) { Rename::Result.new(:exists, "/wts/proj/taken") }) do
          err = capture_err { refute CLI.rename("taken") }
          assert_match(/already exists/, err)
        end
      end
    end

    def test_rename_reports_branch_exists_and_fails
      stub_method(CLI, :current_worktree, -> { Worktree.new(project: "proj", path: "/x", primary: false) }) do
        stub_method(Rename, :perform, ->(*) { Rename::Result.new(:branch_exists, "/wts/proj/taken") }) do
          err = capture_err { refute CLI.rename("taken") }
          assert_match(/branch named taken already exists/, err)
        end
      end
    end

    def test_rename_reports_unchanged_and_succeeds
      stub_method(CLI, :current_worktree, -> { Worktree.new(project: "proj", path: "/x", primary: false) }) do
        stub_method(Rename, :perform, ->(*) { Rename::Result.new(:unchanged, "/wts/proj/old") }) do
          out = capture { assert CLI.rename("old") }
          assert_match(/already named old/, out)
        end
      end
    end

    def test_current_worktree_is_nil_outside_any_repo
      FileUtils.mkdir_p(path("plain"))
      Dir.chdir(path("plain")) { assert_nil CLI.current_worktree }
    end

    def test_current_worktree_finds_the_managed_worktree
      old = rename_fixture
      wt = Dir.chdir(old) { CLI.current_worktree }
      refute_nil wt
      assert_equal "proj", wt.project
      refute wt.primary, "a linked worktree isn't primary"
    end

    def test_current_worktree_degrades_when_realpath_raises
      old = rename_fixture
      Dir.chdir(old) do
        stub_method(File, :realpath, ->(*) { raise Errno::ENOENT }) do
          assert_nil CLI.current_worktree
        end
      end
    end

    # Value: protects=install/uninstall's result reaching the process exit status (a refused codex
    # write or a stopped uninstall exits 1, success exits 0); fails_when=the dispatch drops or
    # flips the `== false` / `unless` mapping; why_new=the Installer tests pin only the return
    # value; seam=stub Installer.install/uninstall; no_claim=what makes them return false
    def test_run_maps_install_and_uninstall_results_to_the_exit_status
      %w[install uninstall].each do |verb|
        stub_method(Installer, verb.to_sym, ->(**) { false }) do
          e = assert_raises(SystemExit) { capture { CLI.run([verb]) } }
          assert_equal 1, e.status, verb
        end
        stub_method(Installer, verb.to_sym, ->(**) { true }) { capture { CLI.run([verb]) } } # no exit
      end
    end

    # Value: protects=a failed `switchboard upgrade` exiting 1 (scripts and `&&` chains rely
    # on it) with its arguments passed through; fails_when=the dispatch drops the `unless`
    # mapping or argv.drop(1); why_new=upgrade_test pins only Upgrade.run's return value;
    # seam=stub Upgrade.run; no_claim=what makes an upgrade fail
    def test_run_maps_the_upgrade_result_to_the_exit_status
      got = nil
      stub_method(Upgrade, :run, ->(argv) { got = argv; false }) do
        e = assert_raises(SystemExit) { capture { CLI.run(%w[upgrade --finish 0.1.0]) } }
        assert_equal 1, e.status
      end
      assert_equal %w[--finish 0.1.0], got
      stub_method(Upgrade, :run, ->(_argv) { true }) { capture { CLI.run(["upgrade"]) } } # no exit
    end

    def test_run_rename_exits_nonzero_on_failure
      capture_err do
        e = assert_raises(SystemExit) { CLI.run(["rename"]) }
        assert_equal 1, e.status
      end
    end

    # The realpath-derived primary flag is the guard that stops renaming the trunk —
    # exercise its true branch (the linked-worktree test only covers false).
    def test_current_worktree_flags_the_primary_checkout
      repo = temp_git_repo("proj")
      File.write(Config.path, YAML.dump("worktree_root" => path("wts"),
                                        "projects" => [{ "name" => "proj", "path" => repo }]))
      wt = Dir.chdir(repo) { CLI.current_worktree }
      refute_nil wt
      assert wt.primary, "the trunk checkout is flagged primary"
    end

    # The cd hint must return you to the subdir you were standing in, under the new
    # path (subpath_in non-empty branch + report_rename's File.join).
    def test_rename_cd_hint_preserves_the_subdir
      old = rename_fixture
      FileUtils.mkdir_p(File.join(old, "sub", "dir"))
      out = Dir.chdir(File.join(old, "sub", "dir")) { capture { assert CLI.rename("fresh") } }
      assert_includes out, "wts/proj/fresh/sub/dir"
    end

    def test_rename_reports_invalid_and_fails
      stub_method(CLI, :current_worktree, -> { Worktree.new(project: "proj", path: "/x", primary: false) }) do
        stub_method(Rename, :perform, ->(*) { Rename::Result.new(:invalid, nil) }) do
          err = capture_err { refute CLI.rename("bad name") }
          assert_match(/invalid name/, err)
          assert_match(/valid git branch name/, err)
        end
      end
    end

    def test_rename_reports_failed_and_fails
      stub_method(CLI, :current_worktree, -> { Worktree.new(project: "proj", path: "/x", primary: false) }) do
        stub_method(Rename, :perform, ->(*) { Rename::Result.new(:failed, nil) }) do
          err = capture_err { refute CLI.rename("x") }
          assert_match(/rename failed/, err)
        end
      end
    end

    def test_rename_pokes_the_sidebar_when_inside_tmux
      poked = false
      stub_method(CLI, :current_worktree, -> { Worktree.new(project: "proj", path: "/x", primary: false) }) do
        stub_method(Rename, :perform, ->(*) { Rename::Result.new(:ok, "/wts/proj/new") }) do
          stub_method(Tmux, :poke_current_sidebar, -> { poked = true }) do
            ENV["TMUX"] = "/tmp/fake-tmux,1,0"
            capture { assert CLI.rename("new") }
          end
        end
      end
      assert poked, "an :ok rename pokes the sidebar inside tmux"
    end

    # CLI memoizes its Config; clear it so each test reads its own sandbox config.
    def teardown
      CLI.instance_variable_set(:@config, nil)
      super
    end

    # Value: protects=doctor's fix for stale hooks in a repo outside the config (upgrade
    # only refreshes configured projects, so "run upgrade" would never fix it); fails_when=
    # doctor points every out-of-date worktree at upgrade; why_new=state-machines cycle 1;
    # seam=none
    # Value: protects=doctor from a dogfood checkout saying it can't judge hooks it didn't
    # write, instead of a false "out of date" or "current"; fails_when=the not-installed row is
    # dropped or reordered after current?; why_new=run-6 state-machines; seam=installed_bin? stub
    def test_doctor_hooks_from_a_non_installed_binary_says_ask_the_installed_one
      repo = temp_git_repo
      AgentHooks.enable(repo)
      out = stub_method(Installer, :installed_bin?, -> { false }) { Dir.chdir(repo) { capture { CLI.doctor_hooks } } }
      assert_includes out, "run the installed `switchboard doctor` to check they're current"
      refute_includes out, "out of date"
    end

    def test_doctor_points_an_unconfigured_repo_at_enable_hooks
      repo = temp_git_repo
      ENV["SWITCHBOARD_BIN"] = "/old/bin/switchboard"
      AgentHooks.enable(repo)
      ENV["SWITCHBOARD_BIN"] = "/new/bin/switchboard"
      out = stub_method(Installer, :installed_bin?, -> { true }) { Dir.chdir(repo) { capture { CLI.doctor_hooks } } }
      assert_includes out, "out of date — `switchboard enable-hooks` (not a configured project"
    end

    # doctor probes `gh auth status` (a real, networked token check); stub that one
    # seam so the doctor rows can be exercised offline like the rest of the suite.
    def run_doctor(&blk)
      stub_method(Pr, :authenticated?, -> { false }) { blk ? blk.call : CLI.doctor }
    end

    # Stub the two tmux shell-outs doctor_binding_live makes: the live-binding probe
    # and the @option reads (clobber markers). Keeps the doctor rows offline.
    def with_key_stubs(live:, options: {}, &blk)
      stub_method(Installer, :toggle_key_live?, ->(*) { live }) do
        stub_method(Installer, :tmux_option, ->(name) { options[name] }, &blk)
      end
    end

    # --- rename-nudge (#92 SessionStart hook entry) --------------------------

    # Write a sandboxed config and force `config` to re-read it (drop any memoized one).
    def nudge_config(extra)
      base = { "worktree_root" => path("wts"), "projects" => [{ "name" => "proj", "path" => "/p" }] }
      File.write(Config.path, YAML.dump(base.merge(extra)))
    end

    # Run rename_nudge with a stubbed worktree + the given stdin, return captured stdout.
    # `args` selects the event path (e.g. ["--stop"] for the Stop backstop). The Stop
    # path also reports agent state by spawning the sh reporter — stubbed to a no-op so
    # tests stay offline and focused on the stdout (block decision) contract.
    def run_nudge(worktree:, stdin:, args: [])
      out = nil
      stub_method(CLI, :current_worktree, ->(*) { worktree }) do
        stub_method(CLI, :config, -> { Config.new }) do
          stub_method(CLI, :report_stop_state, ->(*) {}) do
            with_stdin(StringIO.new(stdin)) { out = capture { CLI.rename_nudge(args) } }
          end
        end
      end
      out
    end

    # Capture the state the unified --stop path reports (stubbing the sh-reporter spawn).
    def stop_reported_state(worktree:, stdin:)
      reported = :none
      stub_method(CLI, :current_worktree, ->(*) { worktree }) do
        stub_method(CLI, :config, -> { Config.new }) do
          stub_method(CLI, :report_stop_state, ->(s) { reported = s }) do
            with_stdin(StringIO.new(stdin)) { capture { CLI.rename_nudge(["--stop"]) } }
          end
        end
      end
      reported
    end

    def placeholder_wt
      Worktree.new(project: "proj", path: "/wts/proj/wandering-finch", primary: false)
    end

    def test_rename_nudge_emits_json_when_gated_on
      nudge_config("auto_rename" => true)
      out = run_nudge(worktree: placeholder_wt, stdin: '{"source":"resume","cwd":"/x"}')
      ctx = JSON.parse(out)["hookSpecificOutput"]
      assert_equal "SessionStart", ctx["hookEventName"]
      assert_includes ctx["additionalContext"], "wandering-finch"
    end

    def test_rename_nudge_silent_when_auto_rename_off
      nudge_config("auto_rename" => false)
      assert_equal "", run_nudge(worktree: placeholder_wt, stdin: '{"source":"resume","cwd":"/x"}')
    end

    def test_rename_nudge_silent_when_not_a_placeholder
      nudge_config("auto_rename" => true)
      named = Worktree.new(project: "proj", path: "/wts/proj/fix-auth", primary: false)
      assert_equal "", run_nudge(worktree: named, stdin: '{"source":"resume","cwd":"/x"}')
    end

    # /clear wipes the earlier plant out of context, so it re-plants (like compact).
    def test_rename_nudge_replants_on_clear_source
      nudge_config("auto_rename" => true)
      refute_empty run_nudge(worktree: placeholder_wt, stdin: '{"source":"clear","cwd":"/x"}')
    end

    def test_rename_nudge_silent_on_primary_checkout
      nudge_config("auto_rename" => true)
      prim = Worktree.new(project: "proj", path: "/p", primary: true)
      assert_equal "", run_nudge(worktree: prim, stdin: '{"source":"resume","cwd":"/p"}')
    end

    def test_rename_nudge_silent_on_malformed_stdin
      nudge_config("auto_rename" => true)
      assert_equal "", run_nudge(worktree: placeholder_wt, stdin: "{ not json")
      assert_equal "", run_nudge(worktree: placeholder_wt, stdin: "")
    end

    # The Stop backstop (--stop): blocks the turn when the agent ends it still on a
    # placeholder, feeding back an imperative rename reminder.
    def test_rename_nudge_stop_emits_a_block_decision_when_gated_on
      nudge_config("auto_rename" => true)
      out = run_nudge(worktree: placeholder_wt, stdin: '{"stop_hook_active":false,"cwd":"/x"}', args: ["--stop"])
      dec = JSON.parse(out)
      assert_equal "block", dec["decision"]
      assert_includes dec["reason"], "wandering-finch"
    end

    # The loop guard: once Claude has resumed from our block, --stop stays silent so the
    # turn can end (block once, never nag).
    def test_rename_nudge_stop_silent_once_stop_hook_active
      nudge_config("auto_rename" => true)
      assert_equal "", run_nudge(worktree: placeholder_wt,
                                 stdin: '{"stop_hook_active":true,"cwd":"/x"}', args: ["--stop"])
    end

    # Self-clears on rename: a named workspace gets no Stop block.
    def test_rename_nudge_stop_silent_when_not_a_placeholder
      nudge_config("auto_rename" => true)
      named = Worktree.new(project: "proj", path: "/wts/proj/fix-auth", primary: false)
      assert_equal "", run_nudge(worktree: named, stdin: '{"stop_hook_active":false,"cwd":"/x"}', args: ["--stop"])
    end

    def test_rename_nudge_stop_silent_when_auto_rename_off
      nudge_config("auto_rename" => false)
      assert_equal "", run_nudge(worktree: placeholder_wt,
                                 stdin: '{"stop_hook_active":false,"cwd":"/x"}', args: ["--stop"])
    end

    # Fail-closed end-to-end: a Stop payload missing stop_hook_active emits nothing (no
    # block), matching the SessionStart path's silence on malformed/incomplete stdin.
    def test_rename_nudge_stop_silent_when_flag_absent
      nudge_config("auto_rename" => true)
      assert_equal "", run_nudge(worktree: placeholder_wt, stdin: '{"cwd":"/x"}', args: ["--stop"])
    end

    # The unification: --stop is the Stop state reporter too. It reports `thinking` when
    # it blocks (so a forced-to-continue agent never reads as `done`)...
    def test_rename_nudge_stop_reports_thinking_when_blocking
      nudge_config("auto_rename" => true)
      assert_equal "thinking",
                   stop_reported_state(worktree: placeholder_wt, stdin: '{"stop_hook_active":false,"cwd":"/x"}')
    end

    # ...and `done` when it doesn't block (here: a named workspace — a normal completion).
    def test_rename_nudge_stop_reports_done_when_not_blocking
      nudge_config("auto_rename" => true)
      named = Worktree.new(project: "proj", path: "/wts/proj/fix-auth", primary: false)
      assert_equal "done",
                   stop_reported_state(worktree: named, stdin: '{"stop_hook_active":false,"cwd":"/x"}')
    end

    # Even a non-managed (nil) worktree still reports done on Stop — the dot depends on it
    # (the state report is unconditional; only the block is gated).
    def test_rename_nudge_stop_reports_done_for_an_unmanaged_worktree
      nudge_config("auto_rename" => true)
      assert_equal "done", stop_reported_state(worktree: nil, stdin: '{"stop_hook_active":false,"cwd":"/x"}')
    end

    # The correctness crux of the unification (the rest stub report_stop_state): the real
    # write must land where AgentState reads it. report_stop_state spawns the same sh
    # reporter, whose `pwd -P`/cksum key is computed from our inherited cwd — so a state
    # written here must round-trip back through AgentState.scan as that worktree's state.
    def test_report_stop_state_round_trips_through_agentstate
      HookFile.ensure_script
      wt = path("wt")
      FileUtils.mkdir_p(wt)
      Dir.chdir(wt) { CLI.report_stop_state("thinking") }
      assert_equal({ wt => :thinking }, AgentState.new.scan([wt]))
    end

    # The hard contract: a fault must never raise (would error a session start) and
    # must leave stdout empty (a stray byte poisons Claude startup).
    def test_rename_nudge_never_raises_and_stays_silent_on_a_fault
      nudge_config("auto_rename" => true)
      out = nil
      stub_method(CLI, :current_worktree, ->(*) { raise "boom" }) do
        with_stdin(StringIO.new('{"source":"resume","cwd":"/x"}')) { out = capture { CLI.rename_nudge } }
      end
      assert_equal "", out
    end

    # current_worktree(at) resolves from a given path (a subdir), via show-toplevel.
    def test_current_worktree_resolves_from_a_given_subdir
      repo = temp_git_repo("proj", origin: true)
      File.write(Config.path, YAML.dump("worktree_root" => path("wts"),
                                        "projects" => [{ "name" => "proj", "path" => repo }]))
      dest = path("wts", "proj", "alpha")
      git(repo, "worktree", "add", "-q", "-b", "alpha", dest)
      sub = File.join(dest, "deep")
      FileUtils.mkdir_p(sub)
      wt = nil
      stub_method(CLI, :config, -> { Config.new }) { wt = CLI.current_worktree(sub) }
      refute_nil wt
      assert_equal "alpha", File.basename(wt.path)
      refute wt.primary
    end

    # Value: protects=doctor's reporter row agreeing with what upgrade will do: current ✓,
    # another release's –, missing while worktrees are hooked ✗, not yet materialized –;
    # fails_when=the row goes back to File.exist?; why_new=state-machines cycle 2; seam=none
    def test_doctor_reports_the_reporter_the_way_upgrade_reads_it
      row = -> { stub_method(Installer, :installed_bin?, -> { true }) { capture { CLI.doctor_reporter } } }
      assert_includes row.call, "not materialized yet"
      HookFile.ensure_script
      assert_includes row.call, "\e[32m✓\e[0m agent-state reporter"
      File.write(HookFile.script_path, "#!/bin/sh\n# an older release\n")
      assert_includes row.call, "from another release — `switchboard upgrade`"
      neutral = stub_method(Installer, :installed_bin?, -> { false }) { capture { CLI.doctor_reporter } }
      refute_includes neutral, "another release", "another binary can't judge the installed one's reporter"
      repo = temp_git_repo
      File.write(Config.path, YAML.dump("projects" => [{ "name" => "app", "path" => repo }]))
      ClaudeHook.enable(repo)
      File.delete(HookFile.script_path)
      assert_includes row.call, "\e[31m✗\e[0m agent-state reporter missing"
    end

    # Value: protects=doctor naming the real problem with a settings file that IS valid JSON
    # (a malformed hooks section), not sending the user hunting for a syntax error;
    # fails_when=doctor's row goes back to a fixed "isn't valid JSON"; why_new=run-5 review
    # (maintainability + state-machines); seam=none
    def test_doctor_names_a_malformed_hooks_section
      repo = temp_git_repo
      FileUtils.mkdir_p(File.join(repo, ".claude"))
      File.write(ClaudeHook.settings_path(repo), %({"hooks": []}))
      out = Dir.chdir(repo) { capture { CLI.doctor_hooks } }
      assert_includes out, "has a malformed hooks section — fix it, then `switchboard enable-hooks`"
      refute_includes out, "valid JSON"
    end

    # Value: protects=a user's own broken settings file getting a usable fix from doctor and
    # an honest refusal from enable-hooks (it used to say "enabled"); fails_when=doctor reads
    # it as hooks off, or enable-hooks reports success on a file it left alone;
    # why_new=state-machines cycle 2; seam=none
    def test_a_users_broken_settings_file_gets_a_fix_not_a_dead_end
      repo = temp_git_repo
      FileUtils.mkdir_p(File.join(repo, ".claude"))
      File.write(ClaudeHook.settings_path(repo), "{ // mine")
      out = Dir.chdir(repo) { capture { CLI.doctor_hooks } }
      assert_includes out, "isn't valid JSON"
      refute_includes out, "hooks off here"
      got = nil
      out, err = capture_io { got = CLI.enable_hooks(repo) }
      assert_equal false, got
      refute_includes out, "enabled agent-state hooks"
      assert_includes out + err, "claude hooks not enabled"
      assert_equal "{ // mine", File.read(ClaudeHook.settings_path(repo)), "left untouched"
    end

    # Value: protects=enable-hooks bringing an older release's hooks up to date, and never
    # reporting success when that rewrite failed (old hooks still read as "enabled");
    # fails_when=enable_hooks gates on enabled? again; why_new=state-machines cycle 3 (a
    # regression from cycle 2's gate); seam=none; no_claim=permission models beyond chmod
    def test_enable_hooks_reports_success_only_when_this_versions_hooks_landed
      repo = temp_git_repo
      ENV["SWITCHBOARD_BIN"] = "/old/bin/switchboard"
      ClaudeHook.enable(repo)
      ENV["SWITCHBOARD_BIN"] = "/new/bin/switchboard"
      dir = File.join(repo, ".claude")
      File.chmod(0o555, dir) # the rewrite can't land; the old hooks stay
      got = nil
      out, err = capture_io { got = CLI.enable_hooks(repo) }
      assert_equal false, got
      refute_includes out, "enabled agent-state hooks"
      assert_includes out + err, "claude hooks not enabled"

      File.chmod(0o755, dir)
      out, = capture_io { got = CLI.enable_hooks(repo) }
      refute_equal false, got
      assert ClaudeHook.current?(repo), "stale hooks rewritten to this version's"
      assert_includes out, "enabled agent-state hooks"
    ensure
      File.chmod(0o755, dir) if dir && File.exist?(dir)
    end

    # Value: protects=enable-hooks not claiming success while the shared reporter its hooks
    # run couldn't be written (doctor would say the reporter is missing); fails_when=
    # enable_hooks stops checking the reporter; why_new=Red Team cycle 3; seam=none
    def test_enable_hooks_fails_when_the_reporter_couldnt_be_written
      repo = temp_git_repo
      dir = File.dirname(HookFile.script_path)
      FileUtils.mkdir_p(dir)
      File.chmod(0o500, dir)
      got = nil
      out, err = capture_io { got = CLI.enable_hooks(repo) }
      assert_equal false, got
      assert_includes out + err, "agent-state reporter: couldn't write"
    ensure
      File.chmod(0o700, dir) if dir
    end

    # Value: protects=enable-hooks on an unreadable settings path (a directory) failing with its
    # "fix <path>" advice; fails_when=the current? check raises EISDIR (its SystemCallError rescue
    # dropped) and the command dies with a backtrace; why_new=mutation of current?'s rescue
    # survived the suite; seam=none; no_claim=the AgentHooks warn wording
    def test_enable_hooks_refuses_an_unreadable_settings_path_without_crashing
      repo = temp_git_repo
      FileUtils.mkdir_p(ClaudeHook.settings_path(repo)) # EISDIR on read
      got = nil
      out, err = capture_io { got = CLI.enable_hooks(repo) }
      assert_equal false, got
      assert_includes out + err, "claude hooks not enabled"
      refute_includes out, "enabled agent-state hooks"
    end


    # Value: protects=doctor flagging a missing reporter the global codex block still runs;
    # fails_when=doctor's reporter row ignores the codex block; why_new=state-machines run 4
    # (D2); seam=none
    def test_doctor_flags_a_missing_reporter_the_codex_block_runs
      ENV["SWITCHBOARD_BIN"] = "/bin/switchboard"
      CodexHook.install_global
      File.delete(HookFile.script_path) if File.exist?(HookFile.script_path)
      out = stub_method(Installer, :installed_bin?, -> { true }) { capture { CLI.doctor_reporter } }
      assert_includes out, "agent-state reporter missing"
    end


    # Value: protects=doctor's claude row reading "can't read" (promptly) for a FIFO or a
    # mode-000 settings file, ahead of the parse/enabled rows; fails_when=the unreadable? row
    # moves after a check that blocks or misreads the file; why_new=run-5 cycle-2
    # state-machines (only a directory was tried); seam=none
    def test_doctor_hooks_reads_a_fifo_or_unpermitted_settings_file_as_unreadable
      require "timeout"
      repo = temp_git_repo
      path = ClaudeHook.settings_path(repo)
      FileUtils.mkdir_p(File.dirname(path))
      File.mkfifo(path)
      out = Timeout.timeout(5) { Dir.chdir(repo) { capture { CLI.doctor_hooks } } }
      assert_match(%r{can't read \S*/\.claude/settings\.local\.json}, out)
      next_case = !Process.uid.zero? # root reads a mode-000 file
      if next_case
        File.delete(path)
        File.write(path, "{}")
        File.chmod(0o000, path)
        out = Dir.chdir(repo) { capture { CLI.doctor_hooks } }
        assert_match(%r{can't read \S*/\.claude/settings\.local\.json}, out)
      end
    ensure
      File.chmod(0o600, path) if path && File.file?(path)
    end

    # --- session-name sync (SessionName): the agent notice, the worker verb, doctor ---

    def test_a_rename_that_spawned_the_sync_tells_the_agent_the_coming_note_is_switchboards
      stub_method(CLI, :current_worktree, -> { Worktree.new(project: "proj", path: "/x", primary: false) }) do
        stub_method(Rename, :perform, ->(*) { Rename::Result.new(:ok, "/wts/proj/new", true) }) do
          out = capture { assert CLI.rename("new") }
          assert_match(/Claude session here will be renamed to new too/, out)
          assert_match(/switchboard syncing it, not a new request/, out)
        end
        stub_method(Rename, :perform, ->(*) { Rename::Result.new(:unchanged, "/wts/proj/new", true) }) do
          assert_match(/renamed to new too/, capture { assert CLI.rename("new") })
        end
        stub_method(Rename, :perform, ->(*) { Rename::Result.new(:ok, "/wts/proj/new") }) do
          refute_match(/Claude session/, capture { assert CLI.rename("new") })
        end
      end
    end

    def test_run_sync_session_name_daemonizes_then_runs_the_worker
      calls = []
      dir = path("wts", "proj", "new")
      FileUtils.mkdir_p(dir)
      wt = Worktree.new(project: "proj", path: dir, primary: false)
      stub_method(Process, :daemon, ->(*a) { calls << [:daemon, *a] }) do
        stub_method(SessionName, :work, ->(*a) { calls << [:work, *a] }) do
          stub_method(CLI, :current_worktree, ->(*) { wt }) { CLI.run(["sync-session-name", dir, "new"]) }
          CLI.run(%w[sync-session-name])
        end
      end
      assert_equal [[:daemon, true, true], [:work, dir, "new"]], calls
    end

    # Value: protects=the public verb types only into a switchboard workspace; fails_when=a
    # parent dir reaches every Claude under it; why_new=pass-3 security; seam=none
    def test_sync_session_name_refuses_anything_but_a_non_primary_worktree
      calls = []
      dir = path("wts", "proj", "new")
      FileUtils.mkdir_p(dir)
      [nil, Worktree.new(project: "proj", path: dir, primary: true),
       Worktree.new(project: "proj", path: path("wts", "proj"), primary: false)].each do |wt|
        stub_method(Process, :daemon, ->(*a) { calls << a }) do
          stub_method(SessionName, :work, ->(*a) { calls << a }) do
            stub_method(CLI, :current_worktree, ->(*) { wt }) { CLI.run(["sync-session-name", dir, "new"]) }
          end
        end
      end
      assert_empty calls
    end

    def test_doctor_lists_session_name_failures_with_the_retry
      ws = path("wts", "proj", "named")
      FileUtils.mkdir_p(ws)
      SessionName::Outcome.record(ws, :failed_send, "named")
      out = capture { CLI.send(:doctor_session_names) }
      assert_includes out, "session name: #{File.realpath(ws)}"
      assert_includes out, "text may be left in the prompt"
      assert_includes out, "clear that prompt, then retry with `switchboard rename named`"
    end

    def test_doctor_session_names_flags_status_values_it_doesnt_know_and_is_silent_otherwise
      write_claude_session("1", live_session("status" => "pondering", "name" => "a"))
      out = stub_method(RemoteLink, :claude_pids, ->(pids) { pids.map(&:to_i).to_set }) { capture { CLI.send(:doctor_session_names) } }
      assert_match(/Claude changed the format; renames won't reach the session/, out)
      write_claude_session("1", live_session("status" => "idle", "name" => "a"))
      out = stub_method(RemoteLink, :claude_pids, ->(pids) { pids.map(&:to_i).to_set }) { capture { CLI.send(:doctor_session_names) } }
      assert_empty out
    end

    # Value: protects=the format canary fires only when EVERY live session's status is
    # unknown; fails_when=one odd session (a new transient status) trips it; why_new=the
    # test above has one session at a time; seam=none; no_claim=real Claude status values
    def test_doctor_session_names_stays_silent_when_only_some_statuses_are_unknown
      # Value: protects=doctor raises no format alarm when no Claude session is open (0 of 0 isn't
      # "every"); fails_when=the verified.positive? gate is dropped; why_new=every canary test seeds
      # a live session; seam=none; no_claim=none beyond protects
      assert_empty capture { CLI.send(:doctor_session_names) }, "no sessions, nothing to say"
      write_claude_session("1", live_session("status" => "pondering", "name" => "a"))
      write_claude_session("2", live_session("status" => "idle", "name" => "b"))
      out = stub_method(RemoteLink, :claude_pids, ->(pids) { pids.map(&:to_i).to_set }) { capture { CLI.send(:doctor_session_names) } }
      assert_empty out
    end

    # Value: protects=doctor notices Claude dropping/renaming the `name` field the worker confirms
    # by; fails_when=the name canary is removed; why_new=red-team (unconfirmed loop); seam=none
    def test_doctor_session_names_flags_sessions_of_an_unknown_kind
      write_claude_session("1", live_session("kind" => "repl", "status" => "idle", "name" => "a"))
      out = stub_method(RemoteLink, :claude_pids, ->(pids) { pids.map(&:to_i).to_set }) { capture { CLI.send(:doctor_session_names) } }
      assert_match(/no live Claude session reports a kind switchboard knows/, out)
    end

    def test_doctor_session_names_flags_sessions_without_a_name_and_explains_unconfirmed
      write_claude_session("1", live_session("status" => "idle"))
      out = stub_method(RemoteLink, :claude_pids, ->(pids) { pids.map(&:to_i).to_set }) { capture { CLI.send(:doctor_session_names) } }
      assert_match(/no live Claude session records a name/, out)
      ws = path("wts", "proj", "named")
      FileUtils.mkdir_p(ws)
      SessionName::Outcome.record(ws, :unconfirmed, "named")
      assert_match(/Claude never showed the new name/, capture { CLI.send(:doctor_session_names) })
    end

    private

    def capture
      out = StringIO.new
      orig = $stdout
      $stdout = out
      yield
      out.string
    ensure
      $stdout = orig
    end

    def capture_err
      err = StringIO.new
      orig = $stderr
      $stderr = err
      yield
      err.string
    ensure
      $stderr = orig
    end

    # --- reload-sidebars (#48, D4) ---------------------------------------------

    def reload_sidebars_with(counts)
      calls = 0
      out, = stub_method(CodeReload, :reload_all, -> { calls += 1; counts }) { capture_io { CLI.run(["reload-sidebars"]) } }
      [out, calls]
    end

    def test_reload_sidebars_reports_what_it_reached
      out, calls = reload_sidebars_with({ signaled: 2, respawned: 1, left: 1 })
      assert_equal 1, calls
      assert_includes out, "sidebars: 2 reloading in place, 1 restarted"
      assert_includes out, "1 sidebar left running old code"
    end

    def test_reload_sidebars_with_nothing_to_reach_says_so
      assert_includes reload_sidebars_with({ signaled: 0, respawned: 0, left: 0 }).first, "no sidebars running"
      assert_includes reload_sidebars_with(nil).first, "no tmux server running"
    end

    # Value: protects=the dogfood loop in the sandbox (any binary may reload); fails_when=the
    # verb gains the installed-binary gate upgrade has; seam=installed_bin? (PATH)
    def test_reload_sidebars_runs_from_any_binary
      _, calls = stub_method(Installer, :installed_bin?, -> { false }) { reload_sidebars_with({ signaled: 1, respawned: 0, left: 0 }) }
      assert_equal 1, calls
    end
  end
end
