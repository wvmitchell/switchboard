# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "rbconfig"

module Switchboard
  # The real binary under a C/POSIX locale (a tmux pane started without LANG) with non-ASCII
  # paths. Ruby tags every file read and command output with the locale's encoding, so
  # without bin/switchboard pinning UTF-8 the upgrade path compares and parses US-ASCII text:
  # the reporter script always reads stale and a non-ASCII path crashes install/upgrade/doctor.
  # A subprocess because the pin lives in bin/switchboard, before the library loads.
  #
  # Value: protects=upgrade/doctor in a C-locale pane with a non-ASCII home; fails_when=the
  # binary stops pinning UTF-8 (or an ENV-derived path keeps its BINARY tag); why_new=run-2
  # Red Team locale sweep (reproduced); seam=none; no_claim=a real tmux server (none needed)
  class UpgradeLocaleTest < SandboxTest
    def setup
      super
      @home = path("josé")
      ENV["HOME"] = @home
      ENV["XDG_DATA_HOME"] = File.join(@home, ".local", "share")
      @repo = temp_git_repo(File.join("josé", "café"))
      @wt = File.join(@home, "wts", "café", "feat")
      git(@repo, "worktree", "add", "-q", @wt, "-b", "feat")
      File.write(Config.path, YAML.dump("projects" => [{ "name" => "café", "path" => @repo }]))
      # The install itself lives under the non-ASCII path too (a clone in /Users/José), so
      # every path switchboard derives from its own location is non-ASCII as well.
      install = File.join(@home, "src", "switchboard")
      FileUtils.mkdir_p(install)
      FileUtils.cp_r([File.expand_path("../bin", __dir__), File.expand_path("../lib", __dir__),
                      File.expand_path("../switchboard.tmux", __dir__)], install)
      @bindir = File.join(@home, "bin")
      FileUtils.mkdir_p(@bindir)
      File.symlink(File.join(install, "bin", "switchboard"), File.join(@bindir, "switchboard")) # the installed switchboard
      ENV["SWITCHBOARD_BIN"] = "/old/bin/switchboard"
      ClaudeHook.enable(@wt) # hooks from an older install
    end

    def run_bin(*args, dir: @home)
      env = { "LC_ALL" => "C", "LANG" => "C", "PATH" => "#{@bindir}:#{ENV['PATH']}", "SWITCHBOARD_BIN" => nil }
      out = IO.popen(env, [RbConfig.ruby, File.join(@bindir, "switchboard"), *args], chdir: dir, err: %i[child out], &:read)
      [out, $?]
    end

    def test_finish_in_a_c_locale_with_non_ascii_paths_rewires_and_exits_0
      out, status = run_bin("upgrade", "--finish", "0.0.1")
      assert status.success?, out
      refute_match(/Error|\.rb:\d+/, out)
      assert_includes out.b, "updated 1 (1 hooked)".b
      settings = File.read(ClaudeHook.settings_path(@wt), encoding: Encoding::UTF_8)
      refute_includes settings, "/old/bin/switchboard"
    end

    def test_doctor_reads_freshly_refreshed_hooks_as_current_in_a_c_locale
      run_bin("upgrade", "--finish", "0.0.1") # bring everything current
      out, status = run_bin("doctor", dir: @wt)
      assert status.success?, out
      assert_includes out.b, "\e[32m✓\e[0m claude hooks here: ".b, "the current row, not the neutral one"
      refute_includes out.b, "run the installed".b
      refute_includes out.b, "out of date".b
      refute_match(/Error|\.rb:\d+/, out)
    end
  end
end
