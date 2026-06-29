# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "shellwords"

module Switchboard
  # CodexHook merges switchboard's agent-state reporter + the #92 rename nudge into
  # a worktree's .codex/hooks.json. Codex reads the SAME JSON shape as Claude, so
  # the merge/strip/reporter machinery is HookFile's; these tests pin the
  # Codex-specific delivery file and event→state map (PermissionRequest→waiting,
  # no Notification) plus the shared merge-safety guarantees through this adapter.
  class CodexHookTest < SandboxTest
    def worktree
      @worktree ||= begin
        wt = path("wt")
        FileUtils.mkdir_p(wt)
        wt
      end
    end

    def hooks
      JSON.parse(File.read(CodexHook.settings_path(worktree)))["hooks"]
    end

    def commands_for(event)
      Array(hooks[event]).flat_map { |g| Array(g["hooks"]).map { |h| h["command"] } }
    end

    def seed(json)
      sp = CodexHook.settings_path(worktree)
      FileUtils.mkdir_p(File.dirname(sp))
      File.write(sp, json)
    end

    def test_enable_writes_codex_hooks_json_and_enabled_is_true
      CodexHook.enable(worktree)
      assert File.exist?(CodexHook.settings_path(worktree)), "writes .codex/hooks.json"
      assert CodexHook.enabled?(worktree)
    end

    def test_settings_path_is_codex_hooks_json
      assert_equal File.join(worktree, ".codex", "hooks.json"), CodexHook.settings_path(worktree)
    end

    # The event→state contract that makes the dot move for Codex.
    def test_event_state_mapping
      CodexHook.enable(worktree)
      %w[PreToolUse PostToolUse].each do |ev|
        grp = hooks[ev].find { |g| g["hooks"].any? { |h| h["command"].include?(HookFile::MARK) } }
        assert_equal "*", grp["matcher"], "#{ev} matches all tools"
        assert(grp["hooks"].any? { |h| h["command"].end_with?("thinking") }, "#{ev} → thinking")
      end
      pr = hooks["PermissionRequest"].find { |g| g["hooks"].any? { |h| h["command"].include?(HookFile::MARK) } }
      assert_equal "*", pr["matcher"], "PermissionRequest matches all tools"
      assert(pr["hooks"].any? { |h| h["command"].end_with?("waiting") }, "PermissionRequest → waiting")
      assert(commands_for("UserPromptSubmit").any? { |c| c.end_with?("thinking") }, "UserPromptSubmit → thinking")
      assert(commands_for("SessionStart").any? { |c| c.include?(HookFile::MARK) && c.end_with?("done") },
             "SessionStart reporter → done")
    end

    # Codex has no Notification event — PermissionRequest is the waiting signal instead.
    def test_no_notification_event
      CodexHook.enable(worktree)
      assert_nil hooks["Notification"], "Codex mapping omits Notification"
    end

    # SessionStart carries BOTH the reporter and the #92 nudge; the nudge is the plain
    # plant, not the --stop backstop (which still matches NUDGE_MARK — guards a misroute).
    def test_sessionstart_has_reporter_and_plain_nudge
      CodexHook.enable(worktree)
      cmds = commands_for("SessionStart")
      assert(cmds.any? { |c| c.include?(HookFile::NUDGE_MARK) }, "nudge present")
      assert(cmds.any? { |c| c.include?(HookFile::MARK) }, "reporter present")
      assert(cmds.none? { |c| c.include?("--stop") }, "SessionStart nudge is the plain variant")
    end

    # Stop is ONE unified command (rename-nudge --stop + sh fallback). Codex runs Stop
    # hooks concurrently too, so a sibling sh reporter could race the blocking nudge and
    # ring a false completion — there must be exactly one.
    def test_stop_is_one_unified_command
      CodexHook.enable(worktree)
      groups = hooks["Stop"]
      assert_equal 1, groups.size, "exactly one Stop group"
      cmd = groups[0]["hooks"][0]["command"]
      assert_includes cmd, "rename-nudge --stop"
      assert_includes cmd, "else", "carries the stale-binary sh fallback"
    end

    def test_enable_is_idempotent
      CodexHook.enable(worktree)
      CodexHook.enable(worktree)
      assert_equal 1, commands_for("SessionStart").count { |c| c.include?(HookFile::NUDGE_MARK) }, "no duplicate nudge"
      assert_equal 1, commands_for("SessionStart").count { |c| c.include?(HookFile::MARK) }, "no duplicate reporter"
      assert_equal 1, hooks["Stop"].size, "no duplicate Stop"
    end

    def test_enable_preserves_foreign_hooks_and_keys
      seed(JSON.pretty_generate("model" => "gpt-5.5",
                                "hooks" => { "PreToolUse" => [{ "matcher" => "Bash",
                                                                "hooks" => [{ "type" => "command", "command" => "./mine.sh" }] }] }))
      CodexHook.enable(worktree)
      data = JSON.parse(File.read(CodexHook.settings_path(worktree)))
      assert_equal "gpt-5.5", data["model"], "foreign top-level key preserved"
      assert_includes commands_for("PreToolUse"), "./mine.sh", "foreign hook preserved alongside ours"
    end

    # A present-but-unparseable file must be left intact (NOT clobbered) and warned about.
    def test_enable_leaves_corrupt_json_untouched
      seed("}{ not json")
      out, err = capture_io { assert_nil CodexHook.enable(worktree) }
      assert_equal "}{ not json", File.read(CodexHook.settings_path(worktree)), "left untouched"
      assert_match(/isn't valid JSON/, err)
      assert_empty out
    end

    def test_enable_adds_codex_file_to_git_excludes
      repo = temp_git_repo
      CodexHook.enable(repo)
      exclude = File.read(File.join(repo, ".git", "info", "exclude"))
      assert_includes exclude, ".codex/hooks.json"
    end

    def test_disable_strips_only_ours_and_keeps_foreign
      seed(JSON.pretty_generate("hooks" => { "PreToolUse" => [{ "matcher" => "Bash",
                                                                "hooks" => [{ "type" => "command", "command" => "./mine.sh" }] }] }))
      CodexHook.enable(worktree)
      CodexHook.disable(worktree)
      refute CodexHook.enabled?(worktree)
      data = JSON.parse(File.read(CodexHook.settings_path(worktree)))
      assert_equal ["./mine.sh"], data.dig("hooks", "PreToolUse").flat_map { |g| g["hooks"].map { |h| h["command"] } }
    end

    def test_disable_deletes_file_when_only_ours
      CodexHook.enable(worktree)
      assert File.exist?(CodexHook.settings_path(worktree))
      CodexHook.disable(worktree)
      refute File.exist?(CodexHook.settings_path(worktree)), "an emptied hooks file is removed"
    end

    def test_disable_on_absent_file_is_a_noop
      assert_nil CodexHook.disable(worktree)
    end

    def test_enabled_is_false_for_absent_and_foreign_only
      refute CodexHook.enabled?(worktree), "absent file"
      seed(JSON.pretty_generate("hooks" => { "Stop" => [{ "hooks" => [{ "type" => "command", "command" => "./theirs.sh" }] }] }))
      refute CodexHook.enabled?(worktree), "foreign-only file"
    end
  end
end
