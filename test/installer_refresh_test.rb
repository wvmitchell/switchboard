# frozen_string_literal: true

require_relative "test_helper"
require "json"

module Switchboard
  # Installer.refresh_wiring (run by install and by upgrade's finish step) and the
  # plain-shell fragment reload. Real git repos/worktrees; tmux via the run_tmux seam.
  class InstallerRefreshTest < SandboxTest
    def setup
      super
      @repo = temp_git_repo("app")
      @linked = path("wts", "app", "feature")
      git(@repo, "worktree", "add", "-q", @linked, "-b", "feature")
      @plain = path("wts", "app", "plain")
      git(@repo, "worktree", "add", "-q", @plain, "-b", "plain")
      File.write(Config.path, YAML.dump("projects" => [{ "name" => "app", "path" => @repo }]))
    end

    def hook_with(bin, *worktrees)
      ENV["SWITCHBOARD_BIN"] = bin
      worktrees.each { |wt| ClaudeHook.enable(wt) }
    end

    def as_installed(installed = true, &blk)
      stub_method(Installer, :installed_bin?, -> { installed }, &blk)
    end

    def quietly
      orig = $stdout
      $stdout = StringIO.new
      result = yield
      [result, $stdout.string]
    ensure
      $stdout = orig
    end

    # Value: protects=old worktrees getting this version's hooks (v0.51.1's SessionEnd
    # timeout, a moved binary); fails_when=the walk skips primaries or linked worktrees, or
    # wires one that never had hooks; why_new=nothing refreshed existing worktrees; seam=none
    def test_refresh_updates_every_hooked_worktree_and_leaves_unhooked_ones_alone
      hook_with("/old/bin/switchboard", @repo, @linked)
      ENV["SWITCHBOARD_BIN"] = "/new/bin/switchboard"

      ok, out = as_installed { quietly { Installer.refresh_wiring } }
      assert ok
      assert ClaudeHook.current?(@repo), "primary checkout refreshed"
      assert ClaudeHook.current?(@linked), "linked worktree refreshed"
      refute ClaudeHook.enabled?(@plain), "a worktree without hooks stays without"
      assert_includes out, "updated 2 (2 hooked)"
    end

    # Value: protects=a broken config.yml failing install/upgrade loudly; fails_when=the
    # config_readable? guard is dropped (an unparseable registry lists no worktrees, so the
    # refresh "succeeds" having touched nothing); why_new=only doctor read load_error; seam=none
    def test_refresh_fails_with_the_parse_error_when_the_config_is_malformed
      hook_with("/old/bin/switchboard", @linked)
      ENV["SWITCHBOARD_BIN"] = "/new/bin/switchboard"
      File.write(Config.path, "--\nprojects:\n  - name: app\n    path: #{@repo}\n") # the #14 repro: one dash short

      ok, out = as_installed { quietly { Installer.refresh_wiring } }
      refute ok
      assert_includes out, "config failed to parse (", out
      assert_includes out, "fix #{Config.path}"
      refute ClaudeHook.current?(@linked), "nothing was refreshed against an empty registry"
    end

    # Value: protects=install/upgrade failing loudly on a config.yml that parses but isn't a map;
    # fails_when=config_readable? sees no load_error for it; why_new=ship 2 red team; seam=none
    def test_refresh_fails_on_a_config_that_is_not_a_map
      File.write(Config.path, "worktree_root ~/wt\n") # one dropped colon: a plain string
      ok, out = as_installed { quietly { Installer.refresh_wiring } }
      refute ok
      assert_includes out, "the top level isn't a map of settings"
    end

    def test_refresh_reports_all_current_without_rewriting
      hook_with("/bin/switchboard", @linked)
      ino = File.stat(ClaudeHook.settings_path(@linked)).ino
      _, out = as_installed { quietly { Installer.refresh_wiring } }
      assert_includes out, "all current (1 hooked)"
      assert_equal ino, File.stat(ClaudeHook.settings_path(@linked)).ino
    end

    # Value: protects=a dogfood checkout never repointing real hooks at itself;
    # fails_when=the installed-binary guard is dropped; why_new=new; seam=installed_bin?
    # (PATH lookup); no_claim=command -v resolution itself
    def test_a_binary_that_isnt_the_installed_one_leaves_hooks_alone
      hook_with("/opt/homebrew/opt/switchboard/libexec/bin/switchboard", @linked)
      ENV["SWITCHBOARD_BIN"] = path("dogfood", "bin", "switchboard")

      ok, out = as_installed(false) { quietly { Installer.refresh_wiring } }
      assert ok, "a skip is not a failure"
      assert_includes out, "not refreshed"
      refute ClaudeHook.current?(@linked), "still on the installed binary's path"
    end

    # Value: protects=one bad worktree not stranding the rest; fails_when=the per-worktree
    # rescue is removed; why_new=new (O3); seam=none
    def test_one_failing_worktree_doesnt_stop_the_others_and_fails_the_step
      hook_with("/old/bin/switchboard", @repo, @linked)
      ENV["SWITCHBOARD_BIN"] = "/new/bin/switchboard"
      original = ClaudeHook.method(:refresh)
      bad = File.realpath(@repo) # git lists worktrees by realpath
      flaky = ->(wt) { wt == bad ? raise(Errno::EACCES, wt) : original.call(wt) }

      ok, out = as_installed { stub_method(ClaudeHook, :refresh, flaky) { quietly { Installer.refresh_wiring } } }
      refute ok
      assert ClaudeHook.current?(@linked), "the other worktree was still updated"
      assert_includes out, "couldn't update #{bad}"
    end

    # Generated by /ship coverage audit.
    # Value: protects=install exiting 1 with an honest closing line when a worktree's hooks
    # couldn't be refreshed; fails_when=install's result or "Done" ignores refresh_wiring;
    # why_new=refresh tests call refresh_wiring directly, not install; seam=none;
    # no_claim=CLI exit mapping (cli_test pins false → exit 1)
    def test_install_fails_and_says_so_when_worktree_hooks_couldnt_be_refreshed
      { false => "Done, except the agent-state hooks", true => "\nDone — " }.each do |hooks_ok, line|
        ok, out = stub_method(Installer, :refresh_wiring, -> { hooks_ok }) do
          quietly { Installer.install(no_tmux: true, codex_hooks: false) }
        end
        assert_equal hooks_ok, ok
        assert_includes out, line
      end
    end

    def test_installed_bin_compares_the_running_binary_with_the_one_on_path
      bin = path("bin", "switchboard")
      FileUtils.mkdir_p(File.dirname(bin))
      File.write(bin, "#!/bin/sh\n")
      File.chmod(0o755, bin)
      ENV["PATH"] = "#{File.dirname(bin)}#{File::PATH_SEPARATOR}#{ENV['PATH']}"
      ENV["SWITCHBOARD_BIN"] = bin
      assert Installer.installed_bin?
      ENV["SWITCHBOARD_BIN"] = path("elsewhere", "switchboard")
      refute Installer.installed_bin?
    end

    # Value: protects=upgrade from a plain shell making new bindings/hooks live;
    # fails_when=the reload is gated on $TMUX again, or the path isn't escaped; why_new=new
    # (D5); seam=run_tmux; no_claim=the live server (smoke test covers it)
    def test_reload_fragment_runs_switchboards_file_in_a_live_server
      calls = []
      frag = "/my code/switchboard/switchboard.tmux"
      stub_method(Installer, :fragment_path, -> { frag }) do
        stub_method(Installer, :wired_fragment, ->(*) { frag }) do
          stub_method(Installer, :run_tmux, ->(*argv) { calls << argv; true }) do
            ENV.delete("TMUX")
            assert Installer.reload_fragment
          end
        end
      end
      assert_equal ["run-shell", "/my\\ code/switchboard/switchboard.tmux"], calls.last
    end

    def test_reload_fragment_is_a_no_op_without_a_server
      calls = []
      result = stub_method(Installer, :wired_fragment, ->(*) { Installer.fragment_path }) do
        stub_method(Installer, :run_tmux, ->(*argv) { calls << argv; false }) { Installer.reload_fragment }
      end
      assert_equal :no_server, result
      assert_equal [["list-sessions"]], calls
    end

    # Value: protects=--no-tmux installs and the real bindings when upgrade runs from a
    # dogfood checkout; fails_when=the wired-here gate is dropped; why_new=new; seam=run_tmux
    def test_reload_fragment_leaves_tmux_alone_unless_tmux_conf_sources_this_install
      calls = []
      stub_method(Installer, :run_tmux, ->(*argv) { calls << argv; true }) do
        stub_method(Installer, :wired_fragment, ->(*) { nil }) { assert_equal :unwired, Installer.reload_fragment }
        stub_method(Installer, :wired_fragment, ->(*) { "/other/clone/switchboard.tmux" }) do
          assert_equal :unwired, Installer.reload_fragment
        end
      end
      assert_empty calls
    end

    # --- review fixes (D1) and untested cells (D2) ---------------------------

    def test_a_conflicted_worktree_fails_the_step_and_says_rerun
      hook_with("/old/bin/switchboard", @linked)
      ok, out = as_installed { stub_method(ClaudeHook, :refresh, ->(_) { :conflict }) { quietly { Installer.refresh_wiring } } }
      refute ok
      assert_includes out, "re-run to retry"
      refute_includes out, "all current", "no green summary over a failure"
    end

    # Value: protects=a corrupt settings file in a worktree being reported, not silently
    # passed as "all current"; fails_when=the listing drops unparseable files again;
    # why_new=D1 item 6; seam=none
    def test_a_corrupt_settings_file_is_reported_and_left_alone
      hook_with("/old/bin/switchboard", @linked)
      broken = File.read(ClaudeHook.settings_path(@linked))[0..-10] # ours, cut off mid-write
      File.write(ClaudeHook.settings_path(@linked), broken)
      ok, out = as_installed { quietly { Installer.refresh_wiring } }
      refute ok
      assert_includes out, "isn't valid JSON"
      assert_equal broken, File.read(ClaudeHook.settings_path(@linked))
    end

    # Value: protects=install/upgrade still refreshing hooks when the registry lists a repo
    # that was deleted or isn't git; fails_when=hooked_worktrees raises or fails on a stale
    # project; why_new=every test here has one valid project; seam=none; no_claim=none beyond protects
    def test_a_stale_project_path_doesnt_stop_the_others_refreshing
      not_git = path("not-git")
      FileUtils.mkdir_p(not_git)
      File.write(Config.path, YAML.dump("projects" => [{ "name" => "gone", "path" => path("deleted") },
                                                       { "name" => "plain", "path" => not_git },
                                                       { "name" => "app", "path" => @repo }]))
      hook_with("/old/bin/switchboard", @linked)
      ENV["SWITCHBOARD_BIN"] = "/new/bin/switchboard"

      ok, out = as_installed { quietly { Installer.refresh_wiring } }
      assert ok
      assert ClaudeHook.current?(@linked)
      assert_includes out, "updated 1 (1 hooked)"
    end

    # Value: protects=refresh never treating a bare repo (a project registered by its .git dir)
    # as a worktree to rewire; fails_when=configured_worktrees stops dropping bare entries;
    # why_new=configured_worktrees' bare reject was untested; seam=none; no_claim=refresh output
    def test_a_bare_project_path_is_not_a_worktree
      bare = path("bare.git")
      git(nil, "clone", "-q", "--bare", @repo, bare)
      linked = path("wts", "bare", "work")
      git(bare, "worktree", "add", "-q", linked, "main")
      File.write(Config.path, YAML.dump("projects" => [{ "name" => "bare", "path" => bare }]))

      got = Installer.configured_worktrees.map { |w| File.realpath(w) }
      assert_includes got, File.realpath(linked)
      refute_includes got, File.realpath(bare)
    end

    def test_no_hooked_worktrees_is_a_quiet_success
      ok, out = as_installed { quietly { Installer.refresh_wiring } }
      assert ok
      refute_includes out, "worktree hooks"
    end

    # Value: protects=the shared reporter script every hooked worktree runs never being
    # replaced by a dogfood checkout's copy; fails_when=refresh_wiring refreshes it from any
    # binary; why_new=D1 item 4; seam=installed_bin? (PATH lookup)
    def test_only_the_installed_binary_refreshes_the_reporter_script
      script = HookFile.ensure_script
      File.write(script, "#!/bin/sh\n# someone else's reporter\n")
      as_installed(false) { quietly { Installer.refresh_wiring } }
      assert_equal "#!/bin/sh\n# someone else's reporter\n", File.read(script)
      as_installed(true) { quietly { Installer.refresh_wiring } }
      assert_equal HookFile::SCRIPT, File.read(script)
    end

    def test_install_names_both_failures_when_codex_and_hooks_fail
      ENV["CODEX_HOME"] = path("codexhome")
      FileUtils.mkdir_p(ENV["CODEX_HOME"])
      out = stub_method(CodexHook, :install_global, -> { :unsafe }) do
        stub_method(Installer, :refresh_wiring, -> { false }) do
          quietly { Installer.install(no_tmux: true, codex_hooks: true) }.last
        end
      end
      assert_includes out, "Done, except the codex hooks and the agent-state hooks"
    end

    # --- cycle-2 findings (D5) ------------------------------------------------

    # Value: protects=install never failing on a settings file switchboard didn't write;
    # fails_when=any unparseable file is listed as hooked; why_new=cycle-2 Red Team; seam=none
    def test_a_broken_settings_file_that_isnt_ours_doesnt_fail_install
      FileUtils.mkdir_p(File.dirname(ClaudeHook.settings_path(@plain)))
      File.write(ClaudeHook.settings_path(@plain), "{ // mine")
      ok, out = as_installed { quietly { Installer.refresh_wiring } }
      assert ok
      refute_includes out, "valid JSON"
      assert_equal "{ // mine", File.read(ClaudeHook.settings_path(@plain))
    end

    def test_a_corrupt_hooked_file_is_reported_but_not_counted_as_stale
      hook_with("/old/bin/switchboard", @linked)
      File.write(ClaudeHook.settings_path(@linked), File.read(ClaudeHook.settings_path(@linked))[0..-10])
      assert ClaudeHook.corrupt?(@linked)
      assert_empty Installer.stale_worktrees, "a broken file is reported, never an upgrade loop"
    end

    def test_another_binary_leaves_current_unhooked_and_corrupt_files_alone
      hook_with("/bin/switchboard", @linked)
      ino = File.stat(ClaudeHook.settings_path(@linked)).ino
      FileUtils.mkdir_p(File.dirname(ClaudeHook.settings_path(@repo)))
      File.write(ClaudeHook.settings_path(@repo), "{ #{HookFile::MARK}")
      ok, = as_installed(false) { quietly { Installer.refresh_wiring } }
      assert ok
      assert_equal ino, File.stat(ClaudeHook.settings_path(@linked)).ino
      refute ClaudeHook.enabled?(@plain)
      assert_equal "{ #{HookFile::MARK}", File.read(ClaudeHook.settings_path(@repo))
    end

    # --- /ship run 2 (D1) -----------------------------------------------------

    # Value: protects=install/upgrade surviving a settings path it can't read (a directory,
    # no permission) in any worktree, hooked or not; fails_when=the listing lets
    # EISDIR/EACCES escape; why_new=run-2 testing + state-machines (reproduced); seam=none
    def test_an_unreadable_settings_file_doesnt_crash_the_refresh
      hook_with("/old/bin/switchboard", @linked)
      ENV["SWITCHBOARD_BIN"] = "/new/bin/switchboard"
      FileUtils.mkdir_p(ClaudeHook.settings_path(@plain)) # a directory where the file goes
      ok, = as_installed { quietly { Installer.refresh_wiring } }
      assert ok
      assert ClaudeHook.current?(@linked), "the readable worktree was still refreshed"
      assert_empty Installer.stale_worktrees
    end

    # Value: protects=install/upgrade under a C/POSIX locale (some tmux panes) surviving
    # a non-ASCII settings file, and still seeing a hooked one; fails_when=settings are
    # read in the locale's encoding; why_new=run-2 Red Team (reproduced); seam=none
    def test_non_ascii_settings_under_a_c_locale_neither_crash_nor_hide_hooks
      hook_with("/old/bin/switchboard", @linked)
      data = JSON.parse(File.read(ClaudeHook.settings_path(@linked), encoding: Encoding::UTF_8))
      data["permissions"] = { "allow" => ["Bash(echo café)"] }
      File.write(ClaudeHook.settings_path(@linked), JSON.pretty_generate(data), encoding: Encoding::UTF_8)
      FileUtils.mkdir_p(File.dirname(ClaudeHook.settings_path(@plain)))
      File.write(ClaudeHook.settings_path(@plain), %({"permissions":{"allow":["Bash(echo naïve)"]}}), encoding: Encoding::UTF_8)
      ENV["SWITCHBOARD_BIN"] = "/new/bin/switchboard"
      prev = Encoding.default_external
      silence_warnings { Encoding.default_external = Encoding::US_ASCII }
      ok, = as_installed { quietly { Installer.refresh_wiring } }
      assert ok
      assert ClaudeHook.current?(@linked), "the hooked file with non-ASCII was found and refreshed"
    ensure
      silence_warnings { Encoding.default_external = prev } if prev
    end

    # Generated by /ship coverage audit.
    # Value: protects=install/upgrade surviving a settings file with invalid UTF-8 bytes;
    # fails_when=load_settings stops mapping EncodingError to Corrupt (strip raises on it);
    # why_new=non-ASCII tests use valid UTF-8; seam=none; no_claim=how the bytes got there
    def test_a_settings_file_with_invalid_utf8_doesnt_crash_the_refresh
      hook_with("/old/bin/switchboard", @linked)
      ENV["SWITCHBOARD_BIN"] = "/new/bin/switchboard"
      FileUtils.mkdir_p(File.dirname(ClaudeHook.settings_path(@plain)))
      File.binwrite(ClaudeHook.settings_path(@plain), "{\"x\":\"caf\xC3\"}\n".b)
      ok, = as_installed { quietly { Installer.refresh_wiring } }
      assert ok
      assert ClaudeHook.current?(@linked), "the other worktree was still refreshed"
      assert_equal "{\"x\":\"caf\xC3\"}\n".b, File.binread(ClaudeHook.settings_path(@plain))
      # Extended by /ship coverage audit: bytes where String#strip raises ArgumentError (not an
      # EncodingError) — a UTF-16 file from a Windows editor; pins load_settings' valid_encoding? guard.
      utf16 = "\xFF\xFE".b + "{}\n".encode(Encoding::UTF_16LE).b
      File.binwrite(ClaudeHook.settings_path(@plain), utf16)
      ok, = as_installed { quietly { Installer.refresh_wiring } }
      assert ok
      assert_equal utf16, File.binread(ClaudeHook.settings_path(@plain))
    end

    def silence_warnings
      old = $VERBOSE
      $VERBOSE = nil
      yield
    ensure
      $VERBOSE = old
    end

    # Value: protects=the "re-run to retry" promise after a conflict: the skipped worktree is
    # still stale, so the next up-to-date upgrade finishes it; fails_when=stale_worktrees
    # drops a worktree whose refresh conflicted (like it drops corrupt ones); why_new=only
    # the conflict report was tested; seam=none; no_claim=a real concurrent Claude write
    def test_a_conflicted_worktree_is_still_a_leftover
      hook_with("/old/bin/switchboard", @linked)
      ENV["SWITCHBOARD_BIN"] = "/new/bin/switchboard"
      as_installed { stub_method(ClaudeHook, :refresh, ->(_) { :conflict }) { quietly { Installer.refresh_wiring } } }
      assert_includes Installer.stale_worktrees.map { |wt| File.realpath(wt) }, File.realpath(@linked)
    end

    # Value: protects=a reporter switchboard couldn't write failing the refresh loudly,
    # instead of finish saying ok while every later upgrade re-finishes; fails_when=
    # refresh_wiring ignores whether ensure_script took; why_new=state-machines cycle 1;
    # seam=none; no_claim=other write failures (disk full) beyond permissions
    def test_an_unwritable_reporter_fails_the_refresh_and_says_so
      File.write(HookFile.ensure_script, "#!/bin/sh\n# an older release\n")
      dir = File.dirname(HookFile.script_path)
      File.chmod(0o500, dir)
      ok, out = as_installed { quietly { Installer.refresh_wiring } }
      assert ok, "nothing hooked runs it yet: a warning, not a failure"
      assert_includes out, "couldn't write"
      assert_includes out, "nothing is hooked yet"

      File.chmod(0o700, dir)
      hook_with("/bin/switchboard", @linked)
      File.write(HookFile.script_path, "#!/bin/sh\n# an older release\n")
      File.chmod(0o500, dir)
      ok, out = as_installed { quietly { Installer.refresh_wiring } }
      refute ok
      assert_includes out, "agent-state reporter: couldn't write"
    ensure
      File.chmod(0o700, dir) if dir
    end

    # Value: protects=a user's own half-edited settings file never counting as setup an
    # upgrade must finish (refresh can't fix it, and it isn't ours); fails_when=
    # hooked_worktrees takes any unparseable file, not only ones with our marks;
    # why_new=state-machines cycle 2; seam=none
    def test_a_users_broken_settings_file_is_not_a_leftover
      FileUtils.mkdir_p(File.dirname(ClaudeHook.settings_path(@plain)))
      File.write(ClaudeHook.settings_path(@plain), "{ // mine")
      assert_empty Installer.stale_worktrees
    end

    # Value: protects=install/upgrade naming WHY a hooked settings file was left untouched — a
    # malformed hooks section or a FIFO is not "invalid JSON", and a FIFO isn't silently skipped;
    # fails_when=report_rewire goes back to one fixed message, or corrupt? drops unreadable
    # files from the scan; why_new=run-5 review (maintainability + state-machines + red-team,
    # D1); seam=none
    def test_an_unparseable_hooked_file_is_reported_with_its_reason
      require "timeout"
      hook_with("/old/bin/switchboard", @linked)
      path = ClaudeHook.settings_path(@linked)
      data = JSON.parse(File.read(path))
      data["hooks"]["Stop"][0]["hooks"] << nil
      File.write(path, JSON.generate(data))
      ok, out = as_installed { quietly { Installer.refresh_wiring } }
      refute ok
      assert_includes out, "has a malformed hooks section — left untouched"
      refute_includes out, "valid JSON"
      FileUtils.rm_f(path)
      File.mkfifo(path)
      ok, out = Timeout.timeout(5) { as_installed { quietly { Installer.refresh_wiring } } }
      refute ok
      assert_includes out, "isn't a regular file under 4 MiB — left untouched"
    end

    # Generated by /ship coverage audit.
    # Value: protects=upgrade/doctor not crashing when SWITCHBOARD_BIN isn't exported (lib run
    # outside bin/switchboard) while a switchboard is on PATH; fails_when=the empty-env guard is
    # dropped (File.identical?(path, nil) raises TypeError); why_new=only set values were tested;
    # seam=none; no_claim=how the env came to be unset
    def test_installed_bin_is_false_without_raising_when_the_running_binary_is_unknown
      shim = path("shim", "switchboard")
      FileUtils.mkdir_p(File.dirname(shim))
      File.write(shim, "#!/bin/sh\n")
      File.chmod(0o755, shim)
      ENV["PATH"] = "#{File.dirname(shim)}#{File::PATH_SEPARATOR}#{ENV['PATH']}"
      ENV.delete("SWITCHBOARD_BIN")
      refute Installer.installed_bin?
      ENV["SWITCHBOARD_BIN"] = ""
      refute Installer.installed_bin?
    end

    # Generated by /ship coverage audit.
    # Value: protects=a never-hooked worktree whose settings path is a FIFO or mode-000 file
    # being reported (not hung on/crashed), the hooked sibling still refreshed, and no endless
    # "finish setup" loop; fails_when=corrupt? stops counting unreadable non-ours files, or
    # stale_worktrees keeps them; why_new=prior tests only turned a HOOKED file into a FIFO;
    # seam=none; no_claim=what Claude does with such a file
    def test_an_unreadable_never_hooked_settings_path_is_reported_but_not_a_leftover
      skip "root reads mode-000 files" if Process.uid.zero?
      require "timeout"
      HookFile.ensure_script
      hook_with("/old/bin/switchboard", @linked)
      ENV["SWITCHBOARD_BIN"] = "/new/bin/switchboard"
      path = ClaudeHook.settings_path(@plain)
      FileUtils.mkdir_p(File.dirname(path))
      File.mkfifo(path)
      ok, out = Timeout.timeout(5) { as_installed { quietly { Installer.refresh_wiring } } }
      refute ok
      assert_includes out, "#{path} isn't a regular file under 4 MiB — left untouched"
      assert ClaudeHook.current?(@linked), "the hooked sibling was still refreshed"
      assert_empty Installer.stale_worktrees
      stub_method(Installer, :wired_fragment, ->(*) { nil }) { as_installed { refute Upgrade.leftovers? } }

      FileUtils.rm_f(path)
      File.write(path, "{}")
      File.chmod(0o000, path)
      ok, out = as_installed { quietly { Installer.refresh_wiring } }
      refute ok
      assert_includes out, "#{path} can't be read — left untouched"
      assert_empty Installer.stale_worktrees
      stub_method(Installer, :wired_fragment, ->(*) { nil }) { as_installed { refute Upgrade.leftovers? } }
    ensure
      File.chmod(0o644, path) if path && File.file?(path)
    end
  end
end
