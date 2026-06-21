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
