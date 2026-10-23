# frozen_string_literal: true

require_relative "test_helper"
require "json"

module Switchboard
  # HookFile.refresh / current?: what `switchboard upgrade` uses to bring already-hooked
  # worktrees up to date, plus the atomic settings write both it and `enable` ride. The
  # enable/disable semantics themselves are pinned (unedited) by claude_hook_test.rb.
  class HookRefreshTest < SandboxTest
    def worktree
      @worktree ||= path("wt").tap { |wt| FileUtils.mkdir_p(wt) }
    end

    def settings_path = ClaudeHook.settings_path(worktree)
    def settings = JSON.parse(File.read(settings_path))

    def rewrite(data)
      File.write(settings_path, "#{JSON.pretty_generate(data)}\n")
    end

    def test_a_fresh_enable_is_current
      ClaudeHook.enable(worktree)
      assert ClaudeHook.current?(worktree)
    end

    # Value: protects=v0.51.1's SessionEnd timeout reaching worktrees hooked before it;
    # fails_when=staleness compares command strings only; why_new=no staleness check
    # existed; seam=none
    def test_a_sessionend_without_its_timeout_is_stale
      ClaudeHook.enable(worktree)
      data = settings
      data["hooks"]["SessionEnd"].each { |g| g["hooks"].each { |h| h.delete("timeout") } }
      rewrite(data)
      refute ClaudeHook.current?(worktree)
    end

    def test_hooks_pointing_at_another_binary_are_stale
      ENV["SWITCHBOARD_BIN"] = "/old/clone/bin/switchboard"
      ClaudeHook.enable(worktree)
      ENV["SWITCHBOARD_BIN"] = "/opt/homebrew/opt/switchboard/libexec/bin/switchboard"
      refute ClaudeHook.current?(worktree)
    end

    def test_a_missing_or_corrupt_file_is_not_current
      refute ClaudeHook.current?(worktree)
      FileUtils.mkdir_p(File.dirname(settings_path))
      File.write(settings_path, "{nope")
      refute ClaudeHook.current?(worktree)
    end

    # Value: protects=upgrade leaving up-to-date settings files alone (no needless write,
    # no live-reload churn in a running agent); fails_when=refresh rewrites unconditionally;
    # why_new=new; seam=none
    def test_refreshing_a_current_file_leaves_it_untouched
      ClaudeHook.enable(worktree)
      ino = File.stat(settings_path).ino
      assert_equal :current, ClaudeHook.refresh(worktree)
      assert_equal ino, File.stat(settings_path).ino
    end

    def test_refreshing_a_stale_file_rewrites_ours_and_keeps_the_users
      ENV["SWITCHBOARD_BIN"] = "/old/bin/switchboard"
      ClaudeHook.enable(worktree)
      data = settings
      data["permissions"] = { "allow" => ["Bash(ls)"] }
      data["hooks"]["Stop"] << { "hooks" => [{ "type" => "command", "command" => "my-own-hook" }] }
      rewrite(data)
      ENV["SWITCHBOARD_BIN"] = "/new/bin/switchboard"

      assert_equal :rewired, ClaudeHook.refresh(worktree)
      assert ClaudeHook.current?(worktree)
      assert_equal({ "allow" => ["Bash(ls)"] }, settings["permissions"])
      stop = settings["hooks"]["Stop"].flat_map { |g| g["hooks"].map { |h| h["command"] } }
      assert_includes stop, "my-own-hook"
      refute(stop.any? { |c| c.include?("/old/bin") }, "no command left on the old binary")
    end

    # Value: protects=a permission Claude grants mid-upgrade; fails_when=refresh writes its
    # merge of the earlier read over Claude's newer file; why_new=new; seam=none (the
    # concurrent write rides the merge step itself); no_claim=a write in the last instant
    # before the rename (not a lock)
    def test_a_file_changed_while_merging_is_skipped_not_overwritten
      ENV["SWITCHBOARD_BIN"] = "/old/bin/switchboard"
      ClaudeHook.enable(worktree)
      ENV["SWITCHBOARD_BIN"] = "/new/bin/switchboard"
      grant = settings.merge("permissions" => { "allow" => ["Bash(git status)"] })
      original = HookFile.method(:merged)
      file = settings_path
      claude_writes = lambda do |*args| # runs as HookFile, so no test helpers in here
        File.write(file, JSON.pretty_generate(grant))
        original.call(*args)
      end

      result = stub_method(HookFile, :merged, claude_writes) { ClaudeHook.refresh(worktree) }
      assert_equal :conflict, result
      assert_equal grant, settings, "Claude's write survives"
    end

    def test_a_corrupt_file_is_reported_and_left_alone
      FileUtils.mkdir_p(File.dirname(settings_path))
      File.write(settings_path, "{nope")
      assert_equal :corrupt, ClaudeHook.refresh(worktree)
      assert_equal "{nope", File.read(settings_path)
    end

    # Value: protects=a running Claude never reading a torn settings file; fails_when=
    # write_json goes back to an in-place File.write; why_new=write_json had no test;
    # seam=none; no_claim=Claude's file watcher (the inode swap is the contract)
    def test_writes_replace_the_file_instead_of_rewriting_it_in_place
      ClaudeHook.enable(worktree)
      reader = File.open(settings_path)
      before = File.read(settings_path)
      ENV["SWITCHBOARD_BIN"] = "/new/bin/switchboard"
      ClaudeHook.enable(worktree)
      assert_equal before, reader.read, "an open reader still sees the whole old file"
    ensure
      reader&.close
    end

    def test_a_symlinked_settings_file_stays_a_symlink
      real = path("dotfiles", "settings.local.json")
      FileUtils.mkdir_p(File.dirname(real))
      File.write(real, "{}")
      FileUtils.mkdir_p(File.dirname(settings_path))
      File.symlink(real, settings_path)

      ClaudeHook.enable(worktree)
      assert File.symlink?(settings_path)
      assert JSON.parse(File.read(real))["hooks"], "hooks landed in the link's target"
    end

    # Value: protects=a hook the user (or Claude's /hooks UI) adds after switchboard's not
    # reading as stale forever; fails_when=staleness compares group order; why_new=D1 item 2;
    # seam=none
    def test_a_users_hook_after_switchboards_is_still_current
      ClaudeHook.enable(worktree)
      data = settings
      data["hooks"]["SessionStart"] << { "hooks" => [{ "type" => "command", "command" => "my-own-hook" }] }
      rewrite(data)
      assert ClaudeHook.current?(worktree)
      assert_equal :current, ClaudeHook.refresh(worktree)
    end

    # Value: protects=a Claude write landing while refresh refreshes the reporter script;
    # fails_when=the changed-file check runs before ensure_script; why_new=D1 item 3;
    # seam=none (the concurrent write rides ensure_script itself)
    def test_a_file_changed_while_the_reporter_is_refreshed_is_merged_not_lost
      ENV["SWITCHBOARD_BIN"] = "/old/bin/switchboard"
      ClaudeHook.enable(worktree)
      ENV["SWITCHBOARD_BIN"] = "/new/bin/switchboard"
      grant = settings.merge("permissions" => { "allow" => ["Bash(ls)"] })
      original = HookFile.method(:ensure_script)
      file = settings_path
      claude_writes = lambda do # runs as HookFile, so no test helpers in here
        File.write(file, JSON.pretty_generate(grant))
        original.call
      end
      result = stub_method(HookFile, :ensure_script, claude_writes) { ClaudeHook.refresh(worktree) }
      assert_equal :rewired, result
      assert_equal({ "allow" => ["Bash(ls)"] }, settings["permissions"], "Claude's grant survives the rewrite")
      assert ClaudeHook.current?(worktree)
    end

    # Value: protects=a disable-hooks (or deleted file) between listing and refresh staying
    # disabled; fails_when=refresh writes the full set into a file without our hooks;
    # why_new=D1 item 5; seam=none
    def test_refresh_never_adds_hooks_to_a_file_without_them
      FileUtils.mkdir_p(File.dirname(settings_path))
      File.write(settings_path, %({"permissions":{"allow":["Bash(ls)"]}}\n))
      before = File.read(settings_path)
      assert_equal :current, ClaudeHook.refresh(worktree)
      assert_equal before, File.read(settings_path)

      FileUtils.rm_f(settings_path)
      assert_equal :current, ClaudeHook.refresh(worktree)
      refute File.exist?(settings_path), "no settings file conjured up"
    end

    # Value: protects=Claude (or /hooks) rewriting the file with the same hooks in another
    # key order not reading as stale; fails_when=the order-free compare sorts by a
    # key-order-dependent string; why_new=cycle-2 Red Team; seam=none
    def test_reordered_keys_inside_a_group_are_still_current
      ClaudeHook.enable(worktree)
      data = settings
      data["hooks"]["SessionStart"] << { "hooks" => [{ "type" => "command", "command" => "my-own-hook" }] }
      data["hooks"].each_value do |groups|
        groups.map! { |g| g.to_a.reverse.to_h.tap { |r| r["hooks"] = r["hooks"].map { |h| h.to_a.reverse.to_h } } }
      end
      rewrite(data)
      assert ClaudeHook.current?(worktree)
      ino = File.stat(settings_path).ino
      assert_equal :current, ClaudeHook.refresh(worktree), "reordered keys aren't a reason to rewrite"
      assert_equal ino, File.stat(settings_path).ino, "no rewrite (a running Claude would reload it)"
    end

    # Value: protects=a broken settings file the user wrote never being claimed as ours
    # (install would fail on it, upgrade would loop); fails_when=corrupt? counts any
    # unparseable file; why_new=cycle-2 Red Team regression of D1 item 6; seam=none
    def test_only_a_broken_file_holding_our_hooks_counts_as_corrupt
      FileUtils.mkdir_p(File.dirname(settings_path))
      File.write(settings_path, "{ // my half-edited settings")
      refute ClaudeHook.corrupt?(worktree)
      File.write(settings_path, "{ \"hooks\": { \"Stop\": [ #{HookFile::MARK} ")
      assert ClaudeHook.corrupt?(worktree)
    end

    # Value: protects=an up-to-date upgrade not re-finishing forever when the reporter is
    # read under a C locale; fails_when=script_state/ensure_script compare locale-tagged text
    # (SCRIPT isn't ASCII) instead of bytes; why_new=only the binary's UTF-8 pin covered it;
    # seam=none; no_claim=the pin itself (upgrade_locale_test)
    def test_a_current_reporter_isnt_stale_under_a_c_locale
      HookFile.ensure_script
      before = Encoding.default_external
      verbose, $VERBOSE = $VERBOSE, nil
      Encoding.default_external = Encoding::US_ASCII
      assert_equal :current, HookFile.script_state
      ino = File.stat(HookFile.script_path).ino
      HookFile.ensure_script
      assert_equal ino, File.stat(HookFile.script_path).ino, "a current reporter isn't rewritten"
    ensure
      Encoding.default_external = before
      $VERBOSE = verbose
    end

    # Value: protects=a fresh install (no reporter yet) not reading as stale setup that upgrade
    # must finish; fails_when=script_state reads a missing file as stale (script_current? is
    # false on a missing file); why_new=coverage gap; seam=none; no_claim=ensure_script writing it
    def test_a_missing_reporter_is_not_stale
      refute File.exist?(HookFile.script_path)
      assert_equal :missing, HookFile.script_state
    end

    # Value: protects=a settings file that is valid JSON but not an object (`[]`) reading as
    # broken everywhere, not "hooks off" in doctor and a crash in enable; fails_when=
    # load_settings accepts any parsed value again; why_new=Red Team cycle 3; seam=none
    def test_a_non_object_settings_file_is_unparseable_not_off
      FileUtils.mkdir_p(File.dirname(settings_path))
      File.write(settings_path, "[]")
      assert ClaudeHook.unparseable?(worktree)
      refute ClaudeHook.enabled?(worktree), "the enabled? probe reads it as empty, no crash"
      assert_equal :corrupt, ClaudeHook.refresh(worktree)
      assert_equal "[]", File.read(settings_path), "left untouched"
    end

    # Value: protects=a reporter that lost its exec bit (hooks exec it directly) reading as
    # stale, so upgrade/doctor/enable-hooks repair it, and a fresh one never appearing without
    # it; fails_when=script_current? compares bytes only, or the bit is set after the rename;
    # why_new=state-machines run 4 (D6); seam=none
    def test_a_reporter_without_its_exec_bit_is_not_current
      HookFile.ensure_script
      assert File.executable?(HookFile.script_path)
      File.chmod(0o644, HookFile.script_path)
      assert_equal :stale, HookFile.script_state, "right bytes, not runnable"
      HookFile.ensure_script
      assert_equal :current, HookFile.script_state
    end

    # Value: protects=install/upgrade/doctor never blocking or exhausting memory on a settings
    # path that is a FIFO or a symlink to /dev/zero (every configured worktree is read);
    # fails_when=a reader goes back to File.read without the regular-file check; why_new=Codex
    # adversarial run 4 (High); seam=none; no_claim=other device files
    def test_a_settings_path_that_isnt_a_regular_file_is_never_read
      require "timeout"
      FileUtils.mkdir_p(File.dirname(settings_path))
      [-> { File.mkfifo(settings_path) }, -> { File.symlink("/dev/zero", settings_path) },
       -> { File.write(settings_path, ""); File.truncate(settings_path, HookFile::MAX_SETTINGS + 1) }].each do |make|
        FileUtils.rm_f(settings_path)
        make.call
        Timeout.timeout(5) do
          refute ClaudeHook.enabled?(worktree)
          assert ClaudeHook.corrupt?(worktree), "reported (install/upgrade name it), never silently dropped"
          assert ClaudeHook.unreadable?(worktree), "reported as unreadable"
          refute ClaudeHook.current?(worktree)
          assert_equal :corrupt, ClaudeHook.refresh(worktree)
          assert_nil ClaudeHook.enable(worktree), "enable refuses it"
        end
      end
    end

    # Value: protects=install/upgrade/doctor surviving a settings file that starts with an
    # invalid UTF-8 byte (String#strip raised ArgumentError, unrescued, aborting the whole
    # scan); fails_when=load_settings stops checking the encoding before strip;
    # why_new=run-5 Codex adversarial (reproduced); seam=none
    def test_a_settings_file_with_invalid_utf8_reads_as_corrupt
      FileUtils.mkdir_p(File.dirname(settings_path))
      File.binwrite(settings_path, "\xFF{}".b)
      refute ClaudeHook.corrupt?(worktree), "not ours: no marks"
      assert ClaudeHook.unparseable?(worktree)
      assert_includes ClaudeHook.corrupt_reason(worktree), "isn't valid JSON"
      refute ClaudeHook.current?(worktree)
      File.binwrite(settings_path, "\xFF#{HookFile::MARK}".b)
      assert ClaudeHook.corrupt?(worktree), "ours: reported"
      assert_equal :corrupt, ClaudeHook.refresh(worktree)
    end

    # Value: protects=a settings file whose hooks section has the wrong shape (an array, a null
    # entry) reading as corrupt everywhere instead of crashing enable-hooks or an upgrade;
    # fails_when=load_settings stops checking the shape merged walks; why_new=Codex structured
    # P2 + adversarial run 4; seam=none
    def test_a_malformed_hooks_section_is_corrupt_not_a_crash
      FileUtils.mkdir_p(File.dirname(settings_path))
      ['{"hooks": []}', '{"hooks": "x"}',
       %({"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "#{HookFile::MARK}"}, null]}]}})].each do |body|
        File.write(settings_path, body)
        refute ClaudeHook.current?(worktree), body
        assert_equal :corrupt, ClaudeHook.refresh(worktree), body
        assert_nil ClaudeHook.enable(worktree), body
        assert_equal body, File.read(settings_path), "left untouched"
      end
      assert ClaudeHook.corrupt?(worktree), "ours (it carries our mark), so it's reported"
    end

    # Value: protects=a rewritten reporter being executable the moment it appears, not only
    # after the trailing chmod; fails_when=ensure_script drops mode: from its atomic write;
    # why_new=coverage audit (proposed test 4); seam=none; no_claim=a chmod that raises
    def test_a_rewritten_reporter_is_executable_without_the_trailing_chmod
      script = HookFile.script_path
      FileUtils.mkdir_p(File.dirname(script))
      File.write(script, "#!/bin/sh\n# an older release\n")
      File.chmod(0o644, script)
      real = File.method(:chmod)
      skip_final = ->(mode, f) { f == script ? 1 : real.call(mode, f) }
      stub_method(File, :chmod, skip_final) { HookFile.ensure_script }
      assert_equal HookFile::SCRIPT.b, File.binread(script)
      assert_equal 0o755, File.stat(script).mode & 0o777
    end

    # Value: protects=a hooked settings file switchboard has no permission to read being
    # reported by install/upgrade (D3, like a FIFO) with a reason, and refresh not raising;
    # fails_when=corrupt?'s permission rescue reads false again, or refresh lets EACCES out;
    # why_new=run-5 cycle-2 state-machines (reproduced); seam=none; no_claim=root, who reads anything
    def test_a_hooked_file_without_read_permission_is_reported_not_skipped
      skip "root can read a mode-000 file" if Process.uid.zero?
      ClaudeHook.enable(worktree)
      File.chmod(0o000, settings_path)
      assert ClaudeHook.corrupt?(worktree), "reported, never silently dropped"
      assert ClaudeHook.unreadable?(worktree)
      assert_equal :corrupt, ClaudeHook.refresh(worktree)
      assert_equal "#{settings_path} can't be read", ClaudeHook.corrupt_reason(worktree)
    ensure
      File.chmod(0o600, settings_path) if File.exist?(settings_path)
    end
  end
end
