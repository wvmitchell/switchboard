# frozen_string_literal: true

require_relative "test_helper"
require "json"

module Switchboard
  # Hook merges switchboard's agent-state reporter into a worktree's
  # .claude/settings.local.json. The load-bearing guarantees, all here: it never
  # clobbers settings it doesn't own, it refuses to touch an unparseable file
  # (Corrupt, not silent-empty), and it round-trips cleanly. XDG_DATA_HOME and the
  # worktree dir are both sandboxed (SandboxTest), so the reporter materializes
  # into the tmpdir, not real ~/.local/share.
  class HookTest < SandboxTest
    def worktree
      @worktree ||= begin
        wt = path("wt")
        FileUtils.mkdir_p(wt)
        wt
      end
    end

    def settings
      JSON.parse(File.read(Hook.settings_path(worktree)))
    end

    def commands_for(data, event)
      Array(data.dig("hooks", event)).flat_map { |g| Array(g["hooks"]).map { |h| h["command"] } }
    end

    def seed(json)
      sp = Hook.settings_path(worktree)
      FileUtils.mkdir_p(File.dirname(sp))
      File.write(sp, json)
    end

    def test_enable_then_enabled_is_true
      Hook.enable(worktree)
      assert Hook.enabled?(worktree)
    end

    # #92: SessionStart carries BOTH the agent-state reporter and the rename nudge.
    def test_enable_adds_the_rename_nudge_alongside_the_reporter
      Hook.enable(worktree)
      cmds = commands_for(settings, "SessionStart")
      assert(cmds.any? { |c| c.include?(Hook::NUDGE_MARK) }, "nudge command present")
      assert(cmds.any? { |c| c.include?(Hook::MARK) }, "reporter command still present")
      # SessionStart gets the soft plant, NOT the Stop backstop — guards against a
      # regression that wires --stop onto SessionStart (which still matches NUDGE_MARK).
      assert(cmds.none? { |c| c.include?("--stop") }, "SessionStart nudge is the plain variant")
    end

    # Re-enable must not pile up duplicate SessionStart commands (ours? dedups both).
    def test_enable_is_idempotent_for_both_sessionstart_commands
      Hook.enable(worktree)
      Hook.enable(worktree)
      cmds = commands_for(settings, "SessionStart")
      assert_equal 1, cmds.count { |c| c.include?(Hook::NUDGE_MARK) }, "no duplicate nudge"
      assert_equal 1, cmds.count { |c| c.include?(Hook::MARK) }, "no duplicate reporter"
    end

    # #92 + unification: Stop hooks run in parallel with no ordering, so a separate sh
    # reporter racing the blocking nudge could record a blocked (still-working) agent as
    # `done`. So Stop carries ONE command — `rename-nudge --stop` reports the state itself
    # (done, or thinking when it blocks), with a stale-binary fallback to the sh reporter.
    def test_enable_gives_stop_one_unified_reporter_backstop_command
      Hook.enable(worktree)
      cmds = commands_for(settings, "Stop")
      assert_equal 1, cmds.length, "Stop has exactly one command — no separate sh reporter to race"
      assert_includes cmds.first, "rename-nudge --stop", "the unified reporter+backstop"
      assert_includes cmds.first, "done", "...with a fallback that still records done if the binary is stale"
    end

    # Re-enable must not pile up duplicate Stop commands.
    def test_enable_is_idempotent_for_the_stop_command
      Hook.enable(worktree)
      Hook.enable(worktree)
      assert_equal 1, commands_for(settings, "Stop").length, "no duplicate Stop command on re-enable"
    end

    # Migration: a pre-unification settings file with a separate sh `done` reporter on
    # Stop gets stripped on re-enable (the EVENTS loop no longer touches Stop), leaving
    # only the unified command — so the false-completion race can't survive an upgrade.
    def test_enable_strips_a_legacy_separate_stop_reporter
      seed(JSON.generate("hooks" => { "Stop" => [
                           { "hooks" => [{ "type" => "command", "command" => "#{Hook.script_path} done" }] }
                         ] }))
      Hook.enable(worktree)
      cmds = commands_for(settings, "Stop")
      assert_equal 1, cmds.length, "the legacy standalone sh Stop reporter is gone"
      assert_includes cmds.first, "rename-nudge --stop"
    end

    # disable strips the nudge too (ours? recognizes it), not just the reporter.
    def test_disable_strips_the_nudge
      Hook.enable(worktree)
      Hook.disable(worktree)
      refute Hook.enabled?(worktree)
    end

    # The baked binary path is Shellwords-escaped (it can contain spaces).
    def test_nudge_command_escapes_the_binary_path
      orig = ENV["SWITCHBOARD_BIN"]
      ENV["SWITCHBOARD_BIN"] = "/has space/switchboard"
      Hook.enable(worktree)
      cmd = commands_for(settings, "SessionStart").find { |c| c.include?(Hook::NUDGE_MARK) }
      assert_includes cmd, '/has\ space/switchboard rename-nudge'
    ensure
      orig ? ENV["SWITCHBOARD_BIN"] = orig : ENV.delete("SWITCHBOARD_BIN")
    end

    # The nudge invocation is guarded so a stale/missing baked bin path (a repo move)
    # is a clean no-op at SessionStart, not a "command not found" on every session.
    def test_nudge_command_is_guarded_against_a_missing_binary
      Hook.enable(worktree)
      cmd = commands_for(settings, "SessionStart").find { |c| c.include?(Hook::NUDGE_MARK) }
      assert_includes cmd, "command -v", "presence-checks the binary before running it"
      assert cmd.strip.end_with?("|| true"), "falls back to a 0 exit when absent"
    end

    # The regression this guards: PreToolUse fires before the permission prompt,
    # so the dot can't clear once you answer. PostToolUse AND PostToolUseFailure
    # both fire after the granted tool runs — dropping either re-introduces a
    # stuck-magenta dot. (Prior learning, 2026-06-20.)
    def test_enable_wires_both_posttooluse_and_failure_to_thinking
      Hook.enable(worktree)
      %w[PostToolUse PostToolUseFailure].each do |event|
        cmds = commands_for(settings, event)
        assert(cmds.any? { |c| c.include?(Hook::MARK) && c.end_with?("thinking") },
               "#{event} should map to a thinking reporter")
      end
    end

    def test_enable_preserves_foreign_settings
      seed(JSON.pretty_generate(
        "permissions" => { "allow" => ["Bash"] },
        "hooks" => { "PreToolUse" => [{ "hooks" => [{ "type" => "command", "command" => "my-own-hook" }] }] }
      ))
      Hook.enable(worktree)
      data = settings
      assert_equal ["Bash"], data.dig("permissions", "allow"), "foreign key untouched"
      cmds = commands_for(data, "PreToolUse")
      assert_includes cmds, "my-own-hook", "foreign hook kept"
      assert(cmds.any? { |c| c.include?(Hook::MARK) }, "ours added alongside")
    end

    def test_disable_removes_ours_and_restores_foreign
      seed(JSON.pretty_generate(
        "permissions" => { "allow" => ["Bash"] },
        "hooks" => { "PreToolUse" => [{ "hooks" => [{ "type" => "command", "command" => "mine" }] }] }
      ))
      Hook.enable(worktree)
      Hook.disable(worktree)
      data = settings
      refute Hook.enabled?(worktree)
      assert_equal ["Bash"], data.dig("permissions", "allow")
      assert_equal ["mine"], commands_for(data, "PreToolUse")
    end

    def test_disable_deletes_the_file_when_only_ours_remain
      Hook.enable(worktree)
      assert File.exist?(Hook.settings_path(worktree))
      Hook.disable(worktree)
      refute File.exist?(Hook.settings_path(worktree)), "an emptied settings file is removed"
    end

    def test_enable_refuses_to_clobber_corrupt_json
      seed("}{ not json")
      out, err = capture_io { assert_nil Hook.enable(worktree) }
      assert_equal "}{ not json", File.read(Hook.settings_path(worktree)), "left untouched"
      assert_match(/isn't valid JSON/, err)
      assert_empty out
    end

    def test_enable_treats_an_empty_file_as_fresh
      seed("")
      Hook.enable(worktree)
      assert Hook.enabled?(worktree)
    end

    def test_strip_ours_is_idempotent_and_keeps_foreign
      groups = [{ "hooks" => [{ "type" => "command", "command" => "x" },
                              { "type" => "command", "command" => "#{Hook.ensure_script} thinking" }] }]
      once = Hook.strip_ours(groups)
      assert_equal once, Hook.strip_ours(once)
      assert_equal ["x"], once.flat_map { |g| g["hooks"].map { |h| h["command"] } }
    end

    def test_ensure_script_materializes_executable_reporter_under_xdg_data
      script = Hook.ensure_script
      assert File.exist?(script)
      assert script.start_with?(ENV["XDG_DATA_HOME"]), "reporter lives under sandboxed XDG_DATA_HOME"
      assert File.executable?(script)
      assert_equal Hook::SCRIPT, File.read(script)
    end

    def test_enable_adds_settings_to_git_local_excludes
      repo = temp_git_repo
      Hook.enable(repo)
      exclude = File.read(File.join(repo, ".git", "info", "exclude"))
      assert_includes exclude, ".claude/settings.local.json"
    end
  end
end
