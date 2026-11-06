# frozen_string_literal: true

require_relative "test_helper"
require "json"

module Switchboard
  # `switchboard doctor`: the rows it prints for each check, and the pure decisions behind them.
  class DoctorTest < SandboxTest
    # doctor probes `gh auth status` (a real, networked token check); stub that one
    # seam so the doctor rows can be exercised offline like the rest of the suite.
    def run_doctor(&blk)
      stub_method(Pr, :authenticated?, -> { false }) { blk ? blk.call : Doctor.run(Config.new) }
    end

    # Value: protects=the `doctor` verb reaching Doctor.run with the CLI's loaded config;
    # fails_when=the dispatch line drops the verb or stops passing config; why_new=every other
    # test calls Doctor directly; seam=none; no_claim=the rows themselves (tested below)
    def test_the_doctor_verb_runs_doctor_with_the_loaded_config
      File.write(Config.path, YAML.dump("worktree_root" => path("wts"), "projects" => []))
      CLI.instance_variable_set(:@config, nil)
      given = :unset
      stub_method(Doctor, :run, ->(config) { given = config }) { CLI.run(%w[doctor]) }
      assert_same CLI.config, given
    ensure
      CLI.instance_variable_set(:@config, nil)
    end

    # --- orphan_sidebar_count: doctor's process-vs-pane diff ------------------
    # Surfaces sidebar processes that outlived their pane (procs > panes).

    def test_orphan_sidebar_count_is_the_excess_of_processes_over_panes
      assert_equal 7, Doctor.orphan_sidebar_count(18, 11)
    end

    def test_orphan_sidebar_count_is_zero_when_balanced
      assert_equal 0, Doctor.orphan_sidebar_count(11, 11)
    end

    def test_orphan_sidebar_count_clamps_when_more_panes_than_processes
      # A pane mid-spawn (or a dead-but-displayed pane) is not an orphan — never negative.
      assert_equal 0, Doctor.orphan_sidebar_count(10, 11)
    end

    # doctor's PR-badge freshness line compacts the cache age to its largest unit.
    def test_humanize_age_compacts_to_the_largest_unit
      assert_equal "45s", Doctor.humanize_age(45)
      assert_equal "2m",  Doctor.humanize_age(150)
      assert_equal "3h",  Doctor.humanize_age((3 * 3600) + 5)
      assert_equal "5d",  Doctor.humanize_age((5 * 86_400) + 60)
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

    # This test process (plus any `also` pids) stands in for a live Claude; health only
    # counts Claude processes.
    def doctor_as_claude(also: [])
      claude = [Process.pid, *also]
      stub_method(RemoteLink, :claude_pids, ->(pids) { pids.map(&:to_i).select { |p| claude.include?(p) }.to_set }) do
        capture { Doctor.doctor_remote_links }
      end
    end

    def test_doctor_remote_links_flags_a_changed_format
      write_claude_session("1", { "process" => 1, "dir" => "/x" })
      out = capture { Doctor.doctor_remote_links }
      assert_includes out, "none in the shape switchboard reads"
    end

    # Value: protects=doctor warns when this shell and tmux (where sidebars run) disagree on
    # CLAUDE_CONFIG_DIR; fails_when=the check reads only this shell's env; why_new=new branch;
    # seam=none (stubs the one tmux read); no_claim=a real tmux server's environment
    def test_doctor_remote_links_flags_a_claude_config_dir_tmux_cannot_see
      write_claude_session("1", live_session)
      ENV["TMUX"] = "/tmp/fake,1,0"
      ENV["CLAUDE_CONFIG_DIR"] = path("claude-elsewhere")
      out = capture { stub_method(Doctor, :tmux_global_env, ->(_) { nil }) { Doctor.doctor_remote_links } }
      assert_includes out, "but unset in tmux"
      dir = path("claude-elsewhere") # outside the stub: define_singleton_method rebinds self
      same = capture { stub_method(Doctor, :tmux_global_env, ->(_) { dir }) { Doctor.doctor_remote_links } }
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
      out = capture { stub_method(Doctor, :tmux_global_env, ->(_) { default }) { Doctor.doctor_remote_links } }
      refute_includes out, "in tmux"
    end

    # Value: protects=tmux's three answers (`NAME=value`, `-NAME` unset, unknown variable)
    # map to value / nil / nil; fails_when=the prefix parse breaks and every set dir reads as
    # unset (a false warning for everyone who sets CLAUDE_CONFIG_DIR); why_new=the doctor test
    # stubs this method; seam=none (stubs IO.popen); no_claim=a real tmux binary's output
    def test_tmux_global_env_reads_set_unset_and_unknown
      { "CLAUDE_CONFIG_DIR=/x/claude\n" => "/x/claude", "-CLAUDE_CONFIG_DIR\n" => nil,
        "unknown variable: CLAUDE_CONFIG_DIR\n" => nil, "" => nil }.each do |out, want|
        got = stub_method(IO, :popen, ->(*, **) { out }) { Doctor.tmux_global_env("CLAUDE_CONFIG_DIR") }
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
        stub_method(Doctor, :tmux_global_env, ->(_) { nil }) do
          stub_method(Doctor, :`, ->(_) { "/usr/local/bin/claude\n" }) do
            stub_method(RemoteLink, :claude_running?, -> { true }) { Doctor.doctor_remote_links }
          end
        end
      end
      assert_includes out, "no session files"
      assert_includes out, "but unset in tmux"
    end

    def test_doctor_remote_links_notes_a_missing_dir_only_when_claude_is_installed
      without = capture { stub_method(Doctor, :`, ->(_) { "" }) { Doctor.doctor_remote_links } }
      assert_empty without, "no Claude Code, no row"
      with = capture do
        stub_method(Doctor, :`, ->(_) { "/usr/local/bin/claude\n" }) do
          stub_method(RemoteLink, :claude_running?, -> { true }) { Doctor.doctor_remote_links }
        end
      end
      assert_includes with, "Claude is running but there are no session files"
      idle = capture do
        stub_method(Doctor, :`, ->(_) { "/usr/local/bin/claude\n" }) do
          stub_method(RemoteLink, :claude_running?, -> { false }) { Doctor.doctor_remote_links }
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
      assert_match(/✓.*tmux bindings wired/, capture { Doctor.doctor_tmux_wired })

      other = path("old clone", "switchboard.tmux").tap { |f| FileUtils.mkdir_p(File.dirname(f)); File.write(f, "") }
      wire.call(other)
      out = capture { Doctor.doctor_tmux_wired }
      assert_includes out, "wired to another install (#{other})"
      refute_includes out, "✗"

      File.delete(other)
      assert_match(/✗.*tmux is wired to a missing install \(#{Regexp.escape(other)}\)/, capture { Doctor.doctor_tmux_wired })

      File.write(conf, "#{Installer::BEGIN_MARK}\n# edited by hand\n#{Installer::END_MARK}\n")
      assert_match(/✗.*switchboard block but no line it recognizes/, capture { Doctor.doctor_tmux_wired })

      File.delete(conf)
      assert_match(/✗.*tmux bindings wired/, capture { Doctor.doctor_tmux_wired })
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
      out = stub_method(Installer, :homebrew?, -> { true }) { capture { Doctor.doctor_symlinks } }
      assert_includes out, "✓"
      assert_includes out, "on PATH via Homebrew: #{File.join(dir, 'switchboard')}"
    end

    # Value: protects=doctor's ✗ and its fix advice under brew; fails_when=a missing command
    # and a shadowing clone link get the same (wrong) `brew link` advice, or either reads ✓;
    # why_new=the brew dispatch test only matches /Homebrew/, present in every row; seam=none
    def test_doctor_homebrew_path_fails_when_switchboard_is_missing_or_shadowed
      bin = path("my bin").tap { |d| FileUtils.mkdir_p(d) } # a space, so the rm hint must quote
      ENV["PATH"] = bin
      doctor = -> { stub_method(Installer, :homebrew?, -> { true }) { capture { Doctor.doctor_symlinks } } }
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
      out = stub_method(Installer, :homebrew?, -> { true }) { capture { Doctor.doctor_symlinks } }
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
      out = stub_method(Installer, :homebrew?, -> { true }) { capture { Doctor.doctor_symlinks } }
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
      out = stub_method(Installer, :installed_bin?, -> { true }) { Dir.chdir(repo) { capture { Doctor.doctor_hooks(Config.new) } } }
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
      out = Dir.chdir(repo) { capture { Doctor.doctor_hooks(Config.new) } }
      assert_includes out, "isn't valid JSON"
      refute_includes out, "hooks off here"
    end

    def test_doctor_hooks_reports_an_unreadable_settings_path_instead_of_crashing
      repo = temp_git_repo
      FileUtils.mkdir_p(ClaudeHook.settings_path(repo)) # a directory: EISDIR on read
      out = Dir.chdir(repo) { capture { Doctor.doctor_hooks(Config.new) } }
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
      out = stub_method(Installer, :installed_bin?, -> { false }) { Dir.chdir(repo) { capture { Doctor.doctor_hooks(Config.new) } } }
      refute_includes out, "out of date"
      assert_includes out, "claude hooks here"
    end

    def test_doctor_hooks_shows_current_hooks_as_ok_from_the_installed_binary
      repo = temp_git_repo
      ENV["SWITCHBOARD_BIN"] = "/new/bin/switchboard"
      AgentHooks.enable(repo)
      out = stub_method(Installer, :installed_bin?, -> { true }) { Dir.chdir(repo) { capture { Doctor.doctor_hooks(Config.new) } } }
      assert_includes out, "\e[32m✓\e[0m claude hooks here: #{ClaudeHook.settings_path(File.realpath(repo))}" # doctor prints git's realpath
      refute_includes out, "out of date"
      refute_includes out, "run the installed"
    end

    def test_doctor_version_reports_latest_available_or_unknown
      { VERSION => "#{VERSION} (latest)", "0.0.1" => "#{VERSION} (latest)", "999.0.0" => "999.0.0 is available (you have #{VERSION}) — `switchboard upgrade`",
        nil => "couldn't check for a newer release" }.each do |latest, line|
        out = stub_method(Upgrade, :install_method, -> { :brew }) do
          stub_method(LatestRelease, :latest, ->(**) { latest }) { capture { Doctor.doctor_version } }
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
          stub_method(LatestRelease, :latest, ->(**) { looked = true; "999.0.0" }) { capture { Doctor.doctor_version } }
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
      out = Dir.chdir(repo) { capture { Doctor.doctor_hooks(Config.new) } }
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
      out = Dir.chdir(elsewhere) { capture { Doctor.doctor_hooks(Config.new) } }
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
      refute_includes Dir.chdir(elsewhere) { capture { Doctor.doctor_hooks(Config.new) } }, "codex hooks (global) not installed"
      repo = temp_git_repo
      assert_includes Dir.chdir(repo) { capture { Doctor.doctor_hooks(Config.new) } }, "codex hooks (global) not installed"
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
        out = stub_method(Doctor, :codex_bypasses_trust?, ->(*) { false }) do # independent of any memoized config
          stub_method(CodexHook, :trust_status, -> { status }) { Dir.chdir(repo) { capture { Doctor.doctor_hooks(Config.new) } } }
        end
        assert_includes out, "#{status[0]}/#{status[1]} trusted"
        assert_equal warns, out.include?("/hooks"), "warning shown only when some hook is untrusted (#{status.inspect})"
      end

      # A session_command that bypasses trust never approves in /hooks: 0/9 is expected there.
      out = stub_method(Doctor, :codex_bypasses_trust?, ->(*) { true }) do
        stub_method(CodexHook, :trust_status, -> { [0, 9] }) { Dir.chdir(repo) { capture { Doctor.doctor_hooks(Config.new) } } }
      end
      refute_includes out, "/hooks", "no dead-dots warning when codex runs with the bypass"
      assert_includes out, "bypass-hook-trust"

      # The same row from the config doctor was handed, with nothing stubbed but the trust count.
      File.write(path("bypass.yml"), YAML.dump("session_command" => "codex --dangerously-bypass-hook-trust"))
      out = stub_method(CodexHook, :trust_status, -> { [0, 9] }) do
        Dir.chdir(repo) { capture { Doctor.doctor_hooks(Config.new(path("bypass.yml"))) } }
      end
      assert_includes out, "bypass-hook-trust", "doctor_hooks reads the config it was given"
      refute_includes out, "/hooks"
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
        out = stub_method(Doctor, :codex_bypasses_trust?, ->(*) { false }) do
          stub_method(CodexHook, :block_state, -> { state }) { Dir.chdir(repo) { capture { Doctor.doctor_hooks(Config.new) } } }
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
        assert_equal want, Doctor.codex_bypasses_trust?(Config.new), yaml
      end
    ensure
      CLI.instance_variable_set(:@config, nil)
    end

    # Nothing wired → claude off here + codex global not installed, no trust note.
    def test_doctor_hooks_reports_off_when_nothing_is_wired
      ENV["CODEX_HOME"] = path("codexhome")
      FileUtils.mkdir_p(ENV["CODEX_HOME"])
      repo = temp_git_repo
      out = Dir.chdir(repo) { capture { Doctor.doctor_hooks(Config.new) } }
      assert_includes out, "claude hooks off here"
      assert_includes out, "codex hooks (global) not installed"
      refute_includes out, "trusted"
    end

    # --- doctor_sessions: actionable orphan line (DX-1), three branches --------

    def report(reachable: true, sb_count: 0, orphans: [])
      Reconcile::Report.new(reachable: reachable, sb_count: sb_count, orphans: orphans)
    end

    def test_doctor_sessions_is_silent_when_unreachable
      rep = report(reachable: false)
      stub_method(Reconcile, :prune, ->(_cfg, **) { rep }) do
        assert_equal "", capture { Doctor.doctor_sessions(Config.new) }.strip
      end
    end

    def test_doctor_sessions_reports_clean_when_no_orphans
      rep = report(reachable: true, sb_count: 3, orphans: [])
      stub_method(Reconcile, :prune, ->(_cfg, **) { rep }) do
        assert_includes capture { Doctor.doctor_sessions(Config.new) }, "no orphaned sb/ sessions"
      end
    end

    def test_doctor_sessions_flags_orphans_with_the_fix_command
      rep = report(reachable: true, sb_count: 3, orphans: ["sb/app/gone"])
      stub_method(Reconcile, :prune, ->(_cfg, **) { rep }) do
        out = capture { Doctor.doctor_sessions(Config.new) }
        assert_includes out, "1 orphaned sb/ session(s)"
        assert_includes out, "switchboard prune"
      end
    end

    # --- doctor: tmux_keys rows (issue #15) -----------------------------------

    def test_doctor_shows_the_configured_toggle_key
      File.write(Config.path, YAML.dump("tmux_keys" => { "toggle" => "b" }))
      out = with_key_stubs(live: true) { capture { Doctor.doctor_binding_live(Config.new) } }
      assert_includes out, "prefix-b bound (toggle-sidebar)"
    end

    def test_doctor_flags_an_invalid_key_value
      File.write(Config.path, YAML.dump("tmux_keys" => { "toggle" => "a b" }))
      out = with_key_stubs(live: true) { capture { Doctor.doctor_binding_live(Config.new) } }
      assert_includes out, "tmux_keys.toggle"
      assert_includes out, "isn't a usable key"
      assert_includes out, "prefix-s bound", "still reports the fallback key as bound"
    end

    def test_doctor_flags_a_home_toggle_collision
      File.write(Config.path, YAML.dump("tmux_keys" => { "toggle" => "b", "home" => "b" }))
      out = with_key_stubs(live: true) { capture { Doctor.doctor_binding_live(Config.new) } }
      assert_includes out, "collides with the toggle key"
    end

    # Value: protects=a config.yml that parses but isn't a map (a dropped colon makes it one
    # string; leading dashes a list) reads as broken, not as an empty healthy config; fails_when=
    # load_data accepts any parsed value; why_new=ship 2 red team; seam=none
    def test_doctor_config_row_fails_on_a_config_that_is_not_a_map
      { "a string" => "worktree_root ~/wt\n", "a list" => "- projects\n- base\n" }.each do |label, body|
        File.write(Config.path, body)
        CLI.instance_variable_set(:@config, nil)
        out = capture { Doctor.doctor_config(Config.new) }
        assert_includes out, "config failed to parse (the top level isn't a map of settings)", label
        assert_empty Config.new.projects, "#{label}: degrades to no projects, never raises"
      end
    end

    # Value: protects=one doctor row per cause: when the toggle key isn't live at all, its
    # NOT-bound row stands alone (no duplicate drift line); fails_when=doctor_key_drift ignores
    # liveness; why_new=ship 2 Claude adversarial; seam=tmux_wired?/tmux_server?
    def test_doctor_shows_no_toggle_drift_row_when_the_key_is_not_live
      File.write(Config.path, YAML.dump("tmux_keys" => { "toggle" => "t" }))
      opts = { "@switchboard-toggle-key" => "s", "@switchboard-config-path" => File.expand_path(Config.path) }
      out = stub_method(Installer, :tmux_wired?, ->(*) { true }) do
        stub_method(Installer, :tmux_server?, -> { true }) do
          with_key_stubs(live: false, options: opts) { capture { Doctor.doctor_binding_live(Config.new) } }
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
          with_key_stubs(live: false, options: opts) { capture { Doctor.doctor_key_drift(Config.new, skip_toggle: true) } }
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
          with_key_stubs(live: true, options: opts) { capture { Doctor.doctor_key_drift(Config.new) } }
        end
      end
      assert_includes out, "tmux_keys.toggle is F13 in config, but it isn't bound (tmux refused it)"
      assert_includes out, "tmux_keys.home is s in config, but it isn't bound (tmux refused it, or the toggle fell back onto it)"
      refute_includes out, "but tmux has", "a refused key is never drift"
    end

    def test_doctor_reports_a_config_parse_error
      File.write(Config.path, "}{ not yaml")
      out = with_key_stubs(live: true) { capture { Doctor.doctor_binding_live(Config.new) } }
      assert_includes out, "tmux_keys: using the default keys", "the key section says what the parse error means for it"
      # Extended (ship 7 maintainability): with keys already bound, a broken config keeps
      # them, and doctor says so instead of naming the defaults.
      kept = with_key_stubs(live: true, options: { "@switchboard-home-key" => "H" }) { capture { Doctor.doctor_binding_live(Config.new) } }
      assert_includes kept, "tmux_keys: keeping the keys already bound (config.yml didn't parse"
      refute_includes kept, "using the default keys"
    end

    # Value: protects=#14: doctor never vouches for a config.yml that won't parse; fails_when=the
    # config row checks only existence (green ✓ on a broken file); why_new=QA probe 001 found the
    # green row still printed above the parse error; seam=none
    def test_doctor_config_row_fails_on_a_config_that_will_not_parse
      File.write(Config.path, "--\nprojects:\n  - name: app\n")
      out = capture { Doctor.doctor_config(Config.new) }
      assert_includes out, "✗"
      assert_includes out, "config: #{Config.path} — config failed to parse ("
      refute_includes out, "✓"
      File.write(Config.path, YAML.dump("projects" => []))
      CLI.instance_variable_set(:@config, nil) if CLI.instance_variable_defined?(:@config)
      assert_includes capture { Doctor.doctor_config(Config.new) }, "✓"
      File.delete(Config.path)
      assert_includes capture { Doctor.doctor_config(Config.new) }, "no config — run `switchboard install`"
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
          with_key_stubs(live: true, options: { "@switchboard-toggle-key" => "s", "@switchboard-config-path" => File.expand_path(Config.path) }) { capture { Doctor.doctor_binding_live(Config.new) } }
        end
      end
      refute_includes unwired, "in config, but tmux has", "no drift row when tmux isn't wired to switchboard"
      out = stub_method(Installer, :tmux_wired?, ->(*) { true }) do
        stub_method(Installer, :tmux_server?, -> { true }) do
          with_key_stubs(live: true, options: { "@switchboard-toggle-key" => "s", "@switchboard-config-path" => File.expand_path(Config.path) }) { capture { Doctor.doctor_binding_live(Config.new) } }
        end
      end
      assert_includes out, drift
      assert_includes out, "tmux_keys.home is H in config, but tmux has nothing bound"
      out = stub_method(Installer, :tmux_wired?, ->(*) { true }) do
        stub_method(Installer, :tmux_server?, -> { true }) do
          options = { "@switchboard-config-path" => File.expand_path(Config.path), "@switchboard-toggle-key" => "s", "@switchboard-toggle-rejected" => "t", "@switchboard-home-key" => "H" }
          with_key_stubs(live: true, options: options) { capture { Doctor.doctor_binding_live(Config.new) } }
        end
      end
      refute_includes out, "in config, but tmux has"
      File.write(Config.path, YAML.dump("tmux_keys" => { "toggle" => "s" })) # home removed from config
      CLI.instance_variable_set(:@config, nil) # CLI memoizes config
      out = stub_method(Installer, :tmux_wired?, ->(*) { true }) do
        stub_method(Installer, :tmux_server?, -> { true }) do
          options = { "@switchboard-config-path" => File.expand_path(Config.path), "@switchboard-toggle-key" => "s", "@switchboard-home-key" => "S" }
          with_key_stubs(live: true, options: options) { capture { Doctor.doctor_binding_live(Config.new) } }
        end
      end
      assert_includes out, "tmux_keys.home is unbound in config, but tmux has prefix-S bound"
    end

    def test_doctor_warns_about_a_clobbered_binding
      File.write(Config.path, YAML.dump("tmux_keys" => { "toggle" => "b" }))
      out = with_key_stubs(live: true, options: { "@switchboard-toggle-clobbered" => "send-keys hi" }) do
        capture { Doctor.doctor_binding_live(Config.new) }
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
          capture { Doctor.doctor_binding_live(Config.new) }
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
      out = stub_method(Installer, :bound_toggle_key, ->(**) { "s" }) do
        with_key_stubs(live: false) { capture { Doctor.doctor_binding_live(Config.new) } }
      end
      assert_includes out, "prefix-s NOT bound"
      assert_includes out, "run `switchboard upgrade`"
    end

    # Value: protects=doctor naming a missing live hook slot and the upgrade fix; fails_when=
    # a missing slot reads live or loses the upgrade advice; why_new=coverage gap; seam=none;
    # no_claim=the show-hooks parse (live_hooks_from)
    def test_doctor_flags_a_hook_slot_missing_from_the_server
      live = Installer::HOOK_SLOTS.to_h { |s| [s, true] }.merge(Installer::HOOK_SLOTS.first => false)
      out = stub_method(Installer, :live_hooks, -> { live }) { capture { Doctor.doctor_hooks_live } }
      assert_includes out, "tmux hooks not live: #{Installer::HOOK_SLOTS.first}"
      assert_includes out, "run `switchboard upgrade`"
    end

    # --- doctor: unknown top-level keys (the misindent backstop) --------------

    def test_doctor_is_silent_about_unknown_keys_by_default
      File.write(Config.path, YAML.dump("worktree_root" => "/x", "projects" => []))
      assert_equal "", capture { Doctor.doctor_unknown_keys(Config.new) }, "a clean config reports nothing"
    end

    def test_doctor_flags_a_misindented_sidebar_key_with_the_fix
      File.write(Config.path, YAML.dump("worktree_root" => "/x", "new_workspace" => "w"))
      out = capture { Doctor.doctor_unknown_keys(Config.new) }
      assert_includes out, "\"new_workspace\""
      assert_includes out, "does nothing"
      assert_includes out, "nest it under `sidebar_keys:`", "names the parent so the fix is obvious"
    end

    def test_doctor_flags_a_generic_unknown_key
      File.write(Config.path, YAML.dump("worktree_root" => "/x", "wortree_root" => "/typo"))
      out = capture { Doctor.doctor_unknown_keys(Config.new) }
      assert_includes out, "\"wortree_root\""
      assert_includes out, "unrecognized", "a non-action key gets the generic hint, not a sidebar_keys steer"
    end

    # Value: protects=a config still carrying agent_state_hooks gets a doctor line naming it retired and pointing at disable-hooks; fails_when=RETIRED_KEYS is dropped or the generic typo hint wins; why_new=no test covered a retired key; seam=none; no_claim=none beyond protects
    def test_doctor_names_a_retired_key_and_what_replaced_it
      File.write(Config.path, YAML.dump("worktree_root" => "/x", "agent_state_hooks" => false))
      out = capture { Doctor.doctor_unknown_keys(Config.new) }
      assert_includes out, "\"agent_state_hooks\""
      assert_includes out, "retired"
      assert_includes out, "switchboard disable-hooks"
      refute_includes out, "unrecognized", "a retired key isn't a typo"
    end

    # --- doctor: sidebar_keys rows (issue #108) -------------------------------

    def test_doctor_is_silent_about_sidebar_keys_by_default
      assert_equal "", capture { Doctor.doctor_sidebar_keys(Config.new) }, "no remap -> nothing to report"
    end

    def test_doctor_confirms_a_clean_remap
      File.write(Config.path, YAML.dump("sidebar_keys" => { "new_workspace" => "c", "delete" => "x" }))
      out = capture { Doctor.doctor_sidebar_keys(Config.new) }
      assert_includes out, "sidebar_keys: 2 remapped, no clashes"
    end

    def test_doctor_flags_an_invalid_sidebar_key
      File.write(Config.path, YAML.dump("sidebar_keys" => { "rename" => "foo" }))
      out = capture { Doctor.doctor_sidebar_keys(Config.new) }
      assert_includes out, "sidebar_keys.rename"
      assert_includes out, "isn't a single printable key"
      assert_includes out, "using \"r\"", "names the default it fell back to"
    end

    def test_doctor_flags_a_sidebar_key_collision
      File.write(Config.path, YAML.dump("sidebar_keys" => { "delete" => "j" })) # j == down's default
      out = capture { Doctor.doctor_sidebar_keys(Config.new) }
      assert_includes out, "sidebar_keys.delete"
      assert_includes out, "clashes with down"
      assert_includes out, "left unbound"
    end

    # Value: protects=doctor tells the truth when a NEW action's default lost to an existing
    # remap; fails_when=it says the user's phone_link "clashes" or claims aliases phone_link
    # doesn't have; why_new=red team, ship of v0.54.0; seam=none; no_claim=none beyond protects
    def test_doctor_explains_a_new_default_taken_by_an_existing_remap
      File.write(Config.path, YAML.dump("sidebar_keys" => { "open_pr" => "p" }))
      out = capture { Doctor.doctor_sidebar_keys(Config.new) }
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
      out = capture { Doctor.doctor_sidebar_keys(Config.new) }
      assert_includes out, "sidebar_keys.up (\"j\") clashes with down"
      assert_includes out, "its arrow/ctrl aliases still work"
    end

    def test_doctor_reads_an_invalid_remap_as_the_default_losing
      File.write(Config.path, YAML.dump("sidebar_keys" => { "open_pr" => "p", "phone_link" => "pp" }))
      out = capture { Doctor.doctor_sidebar_keys(Config.new) }
      assert_includes out, "sidebar_keys.phone_link its default \"p\" is taken by open_pr"
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
      out = stub_method(Installer, :installed_bin?, -> { false }) { Dir.chdir(repo) { capture { Doctor.doctor_hooks(Config.new) } } }
      assert_includes out, "run the installed `switchboard doctor` to check they're current"
      refute_includes out, "out of date"
    end

    def test_doctor_points_an_unconfigured_repo_at_enable_hooks
      repo = temp_git_repo
      ENV["SWITCHBOARD_BIN"] = "/old/bin/switchboard"
      AgentHooks.enable(repo)
      ENV["SWITCHBOARD_BIN"] = "/new/bin/switchboard"
      out = stub_method(Installer, :installed_bin?, -> { true }) { Dir.chdir(repo) { capture { Doctor.doctor_hooks(Config.new) } } }
      assert_includes out, "out of date — `switchboard enable-hooks` (not a configured project"
    end

    # Value: protects=doctor's reporter row agreeing with what upgrade will do: current ✓,
    # another release's –, missing while worktrees are hooked ✗, not yet materialized –;
    # fails_when=the row goes back to File.exist?; why_new=state-machines cycle 2; seam=none
    def test_doctor_reports_the_reporter_the_way_upgrade_reads_it
      row = -> { stub_method(Installer, :installed_bin?, -> { true }) { capture { Doctor.doctor_reporter } } }
      assert_includes row.call, "not materialized yet"
      HookFile.ensure_script
      assert_includes row.call, "\e[32m✓\e[0m agent-state reporter"
      File.write(HookFile.script_path, "#!/bin/sh\n# an older release\n")
      assert_includes row.call, "from another release — `switchboard upgrade`"
      neutral = stub_method(Installer, :installed_bin?, -> { false }) { capture { Doctor.doctor_reporter } }
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
      out = Dir.chdir(repo) { capture { Doctor.doctor_hooks(Config.new) } }
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
      out = Dir.chdir(repo) { capture { Doctor.doctor_hooks(Config.new) } }
      assert_includes out, "isn't valid JSON"
      refute_includes out, "hooks off here"
      got = nil
      out, err = capture_io { got = CLI.enable_hooks(repo) }
      assert_equal false, got
      refute_includes out, "enabled agent-state hooks"
      assert_includes out + err, "claude hooks not enabled"
      assert_equal "{ // mine", File.read(ClaudeHook.settings_path(repo)), "left untouched"
    end


    # Value: protects=doctor flagging a missing reporter the global codex block still runs;
    # fails_when=doctor's reporter row ignores the codex block; why_new=state-machines run 4
    # (D2); seam=none
    def test_doctor_flags_a_missing_reporter_the_codex_block_runs
      ENV["SWITCHBOARD_BIN"] = "/bin/switchboard"
      CodexHook.install_global
      File.delete(HookFile.script_path) if File.exist?(HookFile.script_path)
      out = stub_method(Installer, :installed_bin?, -> { true }) { capture { Doctor.doctor_reporter } }
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
      out = Timeout.timeout(5) { Dir.chdir(repo) { capture { Doctor.doctor_hooks(Config.new) } } }
      assert_match(%r{can't read \S*/\.claude/settings\.local\.json}, out)
      next_case = !Process.uid.zero? # root reads a mode-000 file
      if next_case
        File.delete(path)
        File.write(path, "{}")
        File.chmod(0o000, path)
        out = Dir.chdir(repo) { capture { Doctor.doctor_hooks(Config.new) } }
        assert_match(%r{can't read \S*/\.claude/settings\.local\.json}, out)
      end
    ensure
      File.chmod(0o600, path) if path && File.file?(path)
    end

    def test_doctor_lists_session_name_failures_with_the_retry
      ws = path("wts", "proj", "named")
      FileUtils.mkdir_p(ws)
      SessionName::Outcome.record(ws, :failed_send, "named")
      out = capture { Doctor.doctor_session_names }
      assert_includes out, "session name: #{File.realpath(ws)}"
      assert_includes out, "text may be left in the prompt"
      assert_includes out, "clear that prompt, then retry with `switchboard rename named`"
    end

    def test_doctor_session_names_flags_status_values_it_doesnt_know_and_is_silent_otherwise
      write_claude_session("1", live_session("status" => "pondering", "name" => "a"))
      out = stub_method(RemoteLink, :claude_pids, ->(pids) { pids.map(&:to_i).to_set }) { capture { Doctor.doctor_session_names } }
      assert_match(/Claude changed the format; renames won't reach the session/, out)
      write_claude_session("1", live_session("status" => "idle", "name" => "a"))
      out = stub_method(RemoteLink, :claude_pids, ->(pids) { pids.map(&:to_i).to_set }) { capture { Doctor.doctor_session_names } }
      assert_empty out
    end

    # Value: protects=the format canary fires only when EVERY live session's status is
    # unknown; fails_when=one odd session (a new transient status) trips it; why_new=the
    # test above has one session at a time; seam=none; no_claim=real Claude status values
    def test_doctor_session_names_stays_silent_when_only_some_statuses_are_unknown
      # Value: protects=doctor raises no format alarm when no Claude session is open (0 of 0 isn't
      # "every"); fails_when=the verified.positive? gate is dropped; why_new=every canary test seeds
      # a live session; seam=none; no_claim=none beyond protects
      assert_empty capture { Doctor.doctor_session_names }, "no sessions, nothing to say"
      write_claude_session("1", live_session("status" => "pondering", "name" => "a"))
      write_claude_session("2", live_session("status" => "idle", "name" => "b"))
      out = stub_method(RemoteLink, :claude_pids, ->(pids) { pids.map(&:to_i).to_set }) { capture { Doctor.doctor_session_names } }
      assert_empty out
    end

    # Value: protects=doctor notices Claude dropping/renaming the `name` field the worker confirms
    # by; fails_when=the name canary is removed; why_new=red-team (unconfirmed loop); seam=none
    def test_doctor_session_names_flags_sessions_of_an_unknown_kind
      write_claude_session("1", live_session("kind" => "repl", "status" => "idle", "name" => "a"))
      out = stub_method(RemoteLink, :claude_pids, ->(pids) { pids.map(&:to_i).to_set }) { capture { Doctor.doctor_session_names } }
      assert_match(/no live Claude session reports a kind switchboard knows/, out)
    end

    def test_doctor_session_names_flags_sessions_without_a_name_and_explains_unconfirmed
      write_claude_session("1", live_session("status" => "idle"))
      out = stub_method(RemoteLink, :claude_pids, ->(pids) { pids.map(&:to_i).to_set }) { capture { Doctor.doctor_session_names } }
      assert_match(/no live Claude session records a name/, out)
      ws = path("wts", "proj", "named")
      FileUtils.mkdir_p(ws)
      SessionName::Outcome.record(ws, :unconfirmed, "named")
      assert_match(/Claude never showed the new name/, capture { Doctor.doctor_session_names })
    end

    def live_session(**over)
      { "pid" => Process.pid, "cwd" => @dir, "sessionId" => "s", "kind" => "interactive",
        "procStart" => ProcessIdentity.start_of(Process.pid), "bridgeSessionId" => "session_x" }.merge(over)
    end

    # --- doctor: the ⇅ remote-link canary (Claude's undocumented session files) ---

    def write_claude_session(name, data)
      FileUtils.mkdir_p(RemoteLink.sessions_dir)
      File.write(File.join(RemoteLink.sessions_dir, "#{name}.json"), data.is_a?(String) ? data : JSON.generate(data))
    end

    def test_doctor_remote_links_counts_live_links_and_names_the_dir
      write_claude_session("1", live_session)
      out = doctor_as_claude
      assert_includes out, "remote links (⇅): 1 linked (1 Claude sessions in #{RemoteLink.sessions_dir})"
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

    # Doctor.run with a config that is NOT the one at Config.path, so a row from the wrong one shows.
    # Only the probes are stubbed: gh's presence and auth, the tmux options, the prune report.
    def doctor_run_given(given, options: {}, &on_prune)
      stub_method(Doctor, :`, ->(cmd) { cmd.include?("command -v gh") ? "/usr/bin/gh\n" : "" }) do
        stub_method(Pr, :authenticated?, -> { false }) do
          stub_method(Installer, :tmux_wired?, ->(*) { true }) do
            stub_method(Installer, :tmux_server?, -> { true }) do
              stub_method(Reconcile, :prune, on_prune || ->(_cfg, **) { Reconcile::Report.new(reachable: false, sb_count: 0, orphans: []) }) do
                with_key_stubs(live: true, options: options) { capture { Doctor.run(given) } }
              end
            end
          end
        end
      end
    end

    # Value: protects=every config-reading row of `doctor` answering from the config it was
    # handed; fails_when=a helper or a call down from run reads Config.new or drops config: (the
    # stray read goes unseen when both name one file); why_new=all but doctor_hooks' tests pass
    # Config.new of the same file; seam=none; no_claim=that a real tmux server reports these options
    def test_doctor_run_reads_every_row_from_the_config_it_was_given
      File.write(Config.path, YAML.dump(
        "projects" => [{ "name" => "ignored-project", "path" => path("ignored") }],
        "ignored_stray" => 1, "sounds" => { "done" => "/ignored/done.aiff" }, "tmux_keys" => { "toggle" => "x", "home" => "z" },
        "sidebar_keys" => { "new_workspace" => "Q", "delete" => "Q" }
      ))
      File.write(path("given.yml"), YAML.dump(
        "projects" => [{ "name" => "given-project", "path" => path("given") }],
        "given_stray" => 1, "sounds" => { "done" => "/given/done.aiff" }, "tmux_keys" => { "toggle" => "T", "home" => "g" },
        "sidebar_keys" => { "new_workspace" => "W" }
      ))
      given = Config.new(path("given.yml"))
      pruned = nil
      out = doctor_run_given(given, options: { "@switchboard-config-path" => File.expand_path(path("given.yml")),
                                               "@switchboard-toggle-rejected" => "T", "@switchboard-home-key" => "H",
                                               "@switchboard-home-clobbered" => "was-bound" }) do |cfg, **|
        pruned = cfg
        Reconcile::Report.new(reachable: false, sb_count: 0, orphans: [])
      end

      ["PR badges given-project", 'config key "given_stray"', "sound done: /given/done.aiff",
       "sidebar_keys: 1 remapped, no clashes", "tmux_keys.toggle is T in config, but it isn't bound",
       "tmux_keys.home is g in config, but tmux has prefix-H", "prefix-g (home) replaced a prior binding: was-bound"].each do |row|
        assert_includes out, row
      end
      ["ignored-project", "ignored_stray", "/ignored/", "clashes with"].each { |stray| refute_includes out, stray }
      assert_same given, pruned
    end

    # Value: protects=the parse failure doctor reports being the given config's, in the config row
    # and the tmux_keys note; fails_when=either re-reads Config.new (a healthy file reads ✓ beside a
    # broken one); why_new=the parse tests write the broken file at Config.path; seam=none;
    # no_claim=which config the CLI hands in (the verb test above)
    def test_doctor_run_reports_the_parse_error_of_the_config_it_was_given
      File.write(Config.path, YAML.dump("worktree_root" => path("wts")))
      File.write(path("broken.yml"), "sidebar_keys: [unclosed\n")
      out = doctor_run_given(Config.new(path("broken.yml")))
      assert_includes out, "config failed to parse"
      assert_includes out, "config.yml didn't parse"
    end

    # Value: protects=the config row and the bound-key row naming the config doctor was handed;
    # fails_when=doctor_config goes back to Config.path or the toggle lookup to Config.new;
    # why_new=the row-text test above leaves those two on the default path; seam=none;
    # no_claim=a toggle key tmux recorded, which wins over any config (tested elsewhere)
    def test_doctor_run_config_and_toggle_rows_follow_the_given_config
      File.write(Config.path, YAML.dump("tmux_keys" => { "toggle" => "x" }))
      File.write(path("given.yml"), YAML.dump("tmux_keys" => { "toggle" => "T" }))
      given = Config.new(path("given.yml"))
      out = doctor_run_given(given)
      assert_includes out, "config: #{path('given.yml')}"
      assert_includes out, "prefix-T bound"
      refute_includes out, "prefix-x"

      File.delete(Config.path)
      refute_includes doctor_run_given(given), "no config", "the given file exists, whatever sits at the default path"

      File.delete(path("given.yml"))
      assert_includes doctor_run_given(given), "no config"
    end

    # Stub the two tmux shell-outs doctor_binding_live makes: the live-binding probe
    # and the @option reads (clobber markers). Keeps the doctor rows offline.
    def with_key_stubs(live:, options: {}, &blk)
      stub_method(Installer, :toggle_key_live?, ->(*) { live }) do
        stub_method(Installer, :tmux_option, ->(name) { options[name] }, &blk)
      end
    end

    # Value: protects=doctor stays quiet about a usable cap, however large; fails_when=the check
    # flags a valid or unset value; why_new=the check is new; seam=none; no_claim=none beyond protects
    def test_doctor_is_silent_about_a_usable_max_branch_history
      [{}, { "max_branch_history" => nil }, { "max_branch_history" => 16 }, { "max_branch_history" => 5000 }].each do |data|
        File.write(Config.path, YAML.dump(data))
        assert_equal "", capture { Doctor.doctor_max_branch_history(Config.new) }, "#{data} is fine"
      end
    end

    # Value: protects=a bad value the sidebar quietly replaces is still reported, through the
    # real doctor run; fails_when=Doctor.run stops calling the check, or it names the wrong
    # value; why_new=doctor tests mostly call each check directly, which stays green if run never
    # does; seam=gh auth stub in run_doctor; no_claim=none beyond protects
    def test_doctor_names_a_bad_max_branch_history_and_the_value_it_uses
      [-3, 0, 10.5, "10", true, false, 2**63].each do |bad|
        File.write(Config.path, YAML.dump("max_branch_history" => bad))
        assert_includes capture { Doctor.doctor_max_branch_history(Config.new) },
                        "max_branch_history #{bad.inspect} isn't a whole number above 0 — using 10"
      end
      File.write(Config.path, YAML.dump("max_branch_history" => -3))
      assert_includes capture { run_doctor }, "max_branch_history -3"
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
  end
end
