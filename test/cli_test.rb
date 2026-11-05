# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "pathname"

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
      stub_method(Model, :workspace_at, ->(*) { wt }) do
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
      stub_method(Model, :workspace_at, ->(*) { wt }) do
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
      stub_method(Model, :workspace_at, ->(*) { wt }) do
        assert_includes capture { CLI.monitoring(nil) }, "monitoring off"
        Monitoring.mark(File.realpath(d))
        assert_includes capture { CLI.monitoring("status") }, "monitoring on"
      end
    end

    def test_monitoring_outside_a_workspace_is_a_noop
      stub_method(Model, :workspace_at, ->(*) { nil }) do
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
      stub_method(Model, :workspace_at, ->(*) { wt }) do
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
      stub_method(Model, :workspace_at, ->(*) { wt }) do
        out = capture { CLI.monitoring("notify") } # never ran `on`
        assert_includes out, "not monitoring"
        assert_empty Notify.pending([real]), "no marker written when not monitoring"
        assert_empty Attention.marked([real]), "and no bold either"
      end
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

    # Value (disable row): protects=disable-hooks' own git-root lookup outside a repo; fails_when=its
    # copy of the lookup diverges from enable-hooks'; why_new=only enable was driven outside a repo;
    # seam=none; no_claim=the exit status
    # enable-hooks and disable-hooks want the git root, registered or not. A relative or
    # quoted-tilde path argument keeps resolving the way the shell user meant it.
    def test_hooks_verbs_take_relative_and_tilde_paths_in_an_unregistered_repo
      repo = temp_git_repo("loose")
      real = File.realpath(repo)
      from_home = "~/#{Pathname(real).relative_path_from(Pathname(File.realpath(Dir.home)))}"
      Dir.chdir(File.dirname(repo)) do
        [File.basename(repo), from_home].each do |arg|
          capture { CLI.enable_hooks(arg) }
          assert ClaudeHook.enabled?(real), "enabled from #{arg}"
          capture { CLI.disable_hooks(arg) }
          refute ClaudeHook.enabled?(real), "disabled from #{arg}"
        end
      end
      FileUtils.mkdir_p(path("plain"))
      assert_output("", /not inside a git worktree/) { Dir.chdir(path("plain")) { CLI.enable_hooks } }
      assert_output("", /not inside a git worktree/) { Dir.chdir(path("plain")) { CLI.disable_hooks } }
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
      assert_includes out, "this worktree only; new worktrees still get them", "the only opt-out says its scope"

      CodexHook.install_global
      out2 = Dir.chdir(repo) { capture { CLI.disable_hooks } }
      assert_match(/codex hooks are global/, out2)
    end

    # Value: protects=disable-hooks never reports success while claude's hooks are still wired, and the command exits 1 then (0 on a real removal); fails_when=the post-disable check, the false return or the dispatcher's exit(1) is dropped; why_new=disable swallows its own failures, nothing checked the result; seam=none; no_claim=a permissions failure on a real filesystem (stubbed disable)
    def test_disable_hooks_fails_when_the_hooks_are_still_there
      repo = temp_git_repo
      AgentHooks.enable(repo)
      got = nil
      stub_method(ClaudeHook, :disable, ->(_wt) {}) do
        out = Dir.chdir(repo) { capture { got = CLI.disable_hooks } }
        assert_equal false, got
        assert_match(/couldn't remove claude hooks/, out)
        refute_match(/disabled switchboard's hooks/, out)

        e = assert_raises(SystemExit) { Dir.chdir(repo) { capture { CLI.run(["disable-hooks"]) } } }
        assert_equal 1, e.status, "scripts see the failure too"
      end
      Dir.chdir(repo) { capture { CLI.run(["disable-hooks"]) } } # a real removal: no exit
      refute ClaudeHook.enabled?(repo)
    end

    # Value: protects=a corrupt settings file still holding switchboard's hooks (left untouched by disable, read as "not enabled") isn't reported as disabled; fails_when=the corrupt? check is dropped; why_new=enabled? alone returns false for a file it can't parse; seam=none; no_claim=unreadable (permissions) variant
    def test_disable_hooks_fails_on_a_corrupt_settings_file_with_our_hooks
      repo = temp_git_repo
      FileUtils.mkdir_p(File.join(repo, ".claude"))
      File.write(ClaudeHook.settings_path(repo), "{ \"hooks\": \"#{HookFile::MARK}\" ")
      got = nil
      out = Dir.chdir(repo) { capture { got = CLI.disable_hooks } }
      assert_equal false, got
      assert_match(/couldn't remove claude hooks/, out)
    end

    # Value: protects=a malformed settings file of your own (no switchboard marks) doesn't fail disable-hooks, so a setup-script opt-out can't sink a workspace on it; fails_when=disable fails on any unparseable file again; why_new=adversarial review: it failed on files that never held our hooks; seam=none; no_claim=none beyond protects
    def test_disable_hooks_passes_over_a_malformed_file_of_your_own
      repo = temp_git_repo
      FileUtils.mkdir_p(File.join(repo, ".claude"))
      File.write(ClaudeHook.settings_path(repo), "{ not json")
      got = nil
      out, = capture_io { got = Dir.chdir(repo) { CLI.disable_hooks } }
      refute_equal false, got
      assert_match(/disabled switchboard's hooks/, out)
      assert_equal "{ not json", File.read(ClaudeHook.settings_path(repo)), "your file is left as it was"
    end

    # Value: protects=an unreadable (chmod 000) settings file isn't reported as disabled; fails_when=the unreadable? check is dropped; why_new=enabled?/unparseable? both read EACCES as "fine"; seam=none; no_claim=root, who reads anything (skipped)
    def test_disable_hooks_fails_on_an_unreadable_settings_file
      skip "root reads anything" if Process.uid.zero?
      repo = temp_git_repo
      AgentHooks.enable(repo)
      settings = ClaudeHook.settings_path(repo)
      File.chmod(0o000, settings)
      got = nil
      out, err = capture_io { got = Dir.chdir(repo) { CLI.disable_hooks } }
      assert_equal false, got
      assert_includes out + err, "couldn't remove claude hooks"
    ensure
      File.chmod(0o600, settings) if settings && File.exist?(settings)
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
      stub_method(Model, :workspace_at, ->(*) { wt }) do
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
      stub_method(Model, :workspace_at, ->(*) { Worktree.new(project: "proj", path: "/x", primary: true) }) do
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
      stub_method(Model, :workspace_at, ->(*) { Worktree.new(project: "proj", path: "/x", primary: false) }) do
        stub_method(Rename, :perform, ->(*) { Rename::Result.new(:partial, "/wts/proj/new") }) do
          err = nil
          capture { err = capture_err { refute CLI.rename("new") } } # :partial also puts the landing to stdout
          assert_match(/session rename failed/, err)
        end
      end
    end

    def test_rename_reports_exists_and_fails
      stub_method(Model, :workspace_at, ->(*) { Worktree.new(project: "proj", path: "/x", primary: false) }) do
        stub_method(Rename, :perform, ->(*) { Rename::Result.new(:exists, "/wts/proj/taken") }) do
          err = capture_err { refute CLI.rename("taken") }
          assert_match(/already exists/, err)
        end
      end
    end

    def test_rename_reports_branch_exists_and_fails
      stub_method(Model, :workspace_at, ->(*) { Worktree.new(project: "proj", path: "/x", primary: false) }) do
        stub_method(Rename, :perform, ->(*) { Rename::Result.new(:branch_exists, "/wts/proj/taken") }) do
          err = capture_err { refute CLI.rename("taken") }
          assert_match(/branch named taken already exists/, err)
        end
      end
    end

    def test_rename_reports_unchanged_and_succeeds
      stub_method(Model, :workspace_at, ->(*) { Worktree.new(project: "proj", path: "/x", primary: false) }) do
        stub_method(Rename, :perform, ->(*) { Rename::Result.new(:unchanged, "/wts/proj/old") }) do
          out = capture { assert CLI.rename("old") }
          assert_match(/already named old/, out)
        end
      end
    end

    def test_workspace_at_is_nil_outside_any_repo
      FileUtils.mkdir_p(path("plain"))
      Dir.chdir(path("plain")) { assert_nil Model.workspace_at(Config.new) }
    end

    def test_workspace_at_finds_the_managed_worktree
      old = rename_fixture
      wt = Dir.chdir(old) { Model.workspace_at(Config.new) }
      refute_nil wt
      assert_equal "proj", wt.project
      refute wt.primary, "a linked worktree isn't primary"
    end

    def test_workspace_at_degrades_when_realpath_raises
      old = rename_fixture
      Dir.chdir(old) do
        stub_method(File, :realpath, ->(*) { raise Errno::ENOENT }) do
          assert_nil Model.workspace_at(Config.new)
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
    def test_workspace_at_flags_the_primary_checkout
      repo = temp_git_repo("proj")
      File.write(Config.path, YAML.dump("worktree_root" => path("wts"),
                                        "projects" => [{ "name" => "proj", "path" => repo }]))
      wt = Dir.chdir(repo) { Model.workspace_at(Config.new) }
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
      stub_method(Model, :workspace_at, ->(*) { Worktree.new(project: "proj", path: "/x", primary: false) }) do
        stub_method(Rename, :perform, ->(*) { Rename::Result.new(:invalid, nil) }) do
          err = capture_err { refute CLI.rename("bad name") }
          assert_match(/invalid name/, err)
          assert_match(/valid git branch name/, err)
        end
      end
    end

    def test_rename_reports_failed_and_fails
      stub_method(Model, :workspace_at, ->(*) { Worktree.new(project: "proj", path: "/x", primary: false) }) do
        stub_method(Rename, :perform, ->(*) { Rename::Result.new(:failed, nil) }) do
          err = capture_err { refute CLI.rename("x") }
          assert_match(/rename failed/, err)
        end
      end
    end

    def test_rename_pokes_the_sidebar_when_inside_tmux
      poked = false
      stub_method(Model, :workspace_at, ->(*) { Worktree.new(project: "proj", path: "/x", primary: false) }) do
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

    # workspace_at(path) resolves from a given path (a subdir), via show-toplevel.
    def test_workspace_at_resolves_from_a_given_subdir
      repo = temp_git_repo("proj", origin: true)
      File.write(Config.path, YAML.dump("worktree_root" => path("wts"),
                                        "projects" => [{ "name" => "proj", "path" => repo }]))
      dest = path("wts", "proj", "alpha")
      git(repo, "worktree", "add", "-q", "-b", "alpha", dest)
      sub = File.join(dest, "deep")
      FileUtils.mkdir_p(sub)
      from_home = "~/#{Pathname(File.realpath(sub)).relative_path_from(Pathname(File.realpath(Dir.home)))}"
      relative = Pathname(File.realpath(sub)).relative_path_from(Pathname(File.realpath(Dir.pwd))).to_s
      [sub, from_home, relative].each do |given|
        wt = Model.workspace_at(Config.new, given)
        refute_nil wt, given
        assert_equal "alpha", File.basename(wt.path)
        refute wt.primary
      end
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

    # --- session-name sync (SessionName): the agent notice, the worker verb, doctor ---

    def test_a_rename_that_spawned_the_sync_tells_the_agent_the_coming_note_is_switchboards
      stub_method(Model, :workspace_at, ->(*) { Worktree.new(project: "proj", path: "/x", primary: false) }) do
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
          stub_method(Model, :workspace_at, ->(*) { wt }) { CLI.run(["sync-session-name", dir, "new"]) }
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
            stub_method(Model, :workspace_at, ->(*) { wt }) { CLI.run(["sync-session-name", dir, "new"]) }
          end
        end
      end
      assert_empty calls
    end

    # Value: protects=the verb judges the path it was handed, wherever it runs: the workspace
    # root passes, its subdir, the primary and a stray dir don't; fails_when=sync_session_name
    # stops passing dest to workspace_at; why_new=the tests above stub workspace_at and ignore
    # its args; seam=none; no_claim=typing into a real pane
    def test_sync_session_name_judges_the_given_path_from_any_cwd
      repo = temp_git_repo("proj", origin: true)
      File.write(Config.path, YAML.dump("worktree_root" => path("wts"), "projects" => [{ "name" => "proj", "path" => repo }]))
      dest = path("wts", "proj", "alpha")
      git(repo, "worktree", "add", "-q", "-b", "alpha", dest)
      FileUtils.mkdir_p([File.join(dest, "deep"), path("plain")])
      sync_from = lambda do |cwd, given|
        calls = []
        stub_method(Process, :daemon, ->(*) {}) do
          stub_method(SessionName, :work, ->(*a) { calls << a }) do
            Dir.chdir(cwd) { CLI.run(["sync-session-name", given, "new"]) }
          end
        end
        calls
      end
      assert_equal [[dest, "new"]], sync_from.call(path("plain"), dest)
      [File.join(dest, "deep"), repo, path("plain")].each do |refused|
        assert_empty sync_from.call(dest, refused), refused
      end
    end

    # --- reload-sidebars (#48, D4) ---------------------------------------------

    def reload_sidebars_with(counts)
      calls = 0
      out, = stub_method(CodeReload, :reload_all, -> { calls += 1; counts }) { capture_io { CLI.run(["reload-sidebars"]) } }
      [out, calls]
    end

    def test_reload_sidebars_reports_what_it_reached
      out, calls = reload_sidebars_with({ signaled: 2, respawned: 1, left: 1, failed: 1 })
      assert_equal 1, calls
      assert_includes out, "sidebars: 2 asked to reload in place, 1 restarted"
      assert_includes out, "1 sidebar left running old code"
      assert_includes out, "1 sidebar failed to reload last time"
    end

    def test_reload_sidebars_with_nothing_to_reach_says_so
      assert_includes reload_sidebars_with({ signaled: 0, respawned: 0, left: 0 }).first, "no sidebars running"
      assert_includes reload_sidebars_with(nil).first, "no tmux server running"
    end

    # Value: protects=the verb never says "no sidebars running" while one runs (found by /ship QA);
    # fails_when=the fallback line keys off the summary alone; seam=none
    def test_reload_sidebars_with_only_skipped_sidebars_names_them
      out, = reload_sidebars_with({ signaled: 0, respawned: 0, left: 1 })
      assert_includes out, "1 sidebar left running old code"
      refute_includes out, "no sidebars running"
    end

    # Value: protects=the dogfood loop in the sandbox (any binary may reload); fails_when=the
    # verb gains the installed-binary gate upgrade has; seam=installed_bin? (PATH)
    def test_reload_sidebars_runs_from_any_binary
      _, calls = stub_method(Installer, :installed_bin?, -> { false }) { reload_sidebars_with({ signaled: 1, respawned: 0, left: 0 }) }
      assert_equal 1, calls
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
  end
end
