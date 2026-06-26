# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # The CLI dispatch logic that isn't just a pass-through to Installer: flag
  # parsing and the emdash-free `init`. (install/uninstall themselves are thin
  # delegations covered by InstallerTest; doctor's rows are ANSI formatting.)
  class CLITest < SandboxTest
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

    def test_init_writes_an_empty_config_when_absent
      out = capture { CLI.init }
      assert Config.exist?
      assert_equal Config.default_data, YAML.safe_load_file(Config.path)
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

    def test_doctor_reports_player_and_sound_rows
      out = capture do
        stub_method(Sound, :player_argv, -> { ["afplay"] }) { run_doctor }
      end
      assert_includes out, "audio player: afplay"
      assert_includes out, "sound done: train"
      assert_includes out, "sound waiting: chime"
    end

    # --- doctor: PATH symlink rows (the required command + the optional alias) ---

    def test_doctor_reports_both_symlink_rows
      capture { Installer.install(no_tmux: true) }
      out = capture { run_doctor }
      assert_includes out, "PATH symlink: #{Installer.symlink_path}"
      assert_includes out, "PATH symlink: #{Installer.symlink_path('sb')}"
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
    def test_quit_clears_agent_state
      cleared = false
      stub_method(AgentState, :clear_all, -> { cleared = true }) do
        stub_method(Tmux, :kill_all, -> { [] }) do
          capture { CLI.quit }
        end
      end
      assert cleared, "quit wipes the stale hook states before teardown"
    end

    # --- prune_summary: honest reporting (F5) + dry-run next step (DX-2) ------

    def test_prune_summary_distinguishes_unreachable_from_empty
      assert_equal "no tmux server — nothing to reconcile", CLI.prune_summary(report(reachable: false), false)
      assert_equal "no sb/ sessions found", CLI.prune_summary(report(sb_count: 0), false)
      assert_equal "3 sb/ session(s), none orphaned", CLI.prune_summary(report(sb_count: 3), false)
    end

    def test_prune_summary_kill_lists_orphans_without_next_step
      out = CLI.prune_summary(report(sb_count: 3, orphans: ["sb/app/gone"]), false)
      assert_includes out, "killed 1 orphaned session(s):"
      assert_includes out, "  sb/app/gone"
      refute_includes out, "run `switchboard prune`"
    end

    def test_prune_summary_dry_run_appends_next_step
      out = CLI.prune_summary(report(sb_count: 3, orphans: ["sb/app/gone"]), true)
      assert_includes out, "would kill 1 orphaned session(s):"
      assert_includes out, "run `switchboard prune` to remove these"
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

    def test_doctor_reports_a_config_parse_error
      File.write(Config.path, "}{ not yaml")
      out = with_key_stubs(live: true) { capture { CLI.send(:doctor_binding_live) } }
      assert_includes out, "config failed to parse"
    end

    def test_doctor_warns_about_a_clobbered_binding
      File.write(Config.path, YAML.dump("tmux_keys" => { "toggle" => "b" }))
      out = with_key_stubs(live: true, options: { "@switchboard-toggle-clobbered" => "send-keys hi" }) do
        capture { CLI.send(:doctor_binding_live) }
      end
      assert_includes out, "replaced a prior binding: send-keys hi"
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

    private

    # doctor probes `gh auth status` (a real, networked token check); stub that one
    # seam so the doctor rows can be exercised offline like the rest of the suite.
    def run_doctor(&blk)
      stub_method(Pr, :authenticated?, -> { false }) { blk ? blk.call : CLI.doctor }
    end

    # Stub the two tmux shell-outs doctor_binding_live makes: the live-binding probe
    # and the @option reads (clobber markers). Keeps the doctor rows offline.
    def with_key_stubs(live:, options: {}, &blk)
      stub_method(Installer, :toggle_key_live?, -> { live }) do
        stub_method(Installer, :tmux_option, ->(name) { options[name] }, &blk)
      end
    end

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
  end
end
