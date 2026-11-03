# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "shellwords"

module Switchboard
  # ClaudeHook merges switchboard's agent-state reporter into a worktree's
  # .claude/settings.local.json. The load-bearing guarantees, all here: it never
  # clobbers settings it doesn't own, it refuses to touch an unparseable file
  # (Corrupt, not silent-empty), and it round-trips cleanly. XDG_DATA_HOME and the
  # worktree dir are both sandboxed (SandboxTest), so the reporter materializes
  # into the tmpdir, not real ~/.local/share.
  class ClaudeHookTest < SandboxTest
    def worktree
      @worktree ||= begin
        wt = path("wt")
        FileUtils.mkdir_p(wt)
        wt
      end
    end

    def settings
      JSON.parse(File.read(ClaudeHook.settings_path(worktree)))
    end

    def commands_for(data, event)
      Array(data.dig("hooks", event)).flat_map { |g| Array(g["hooks"]).map { |h| h["command"] } }
    end

    def seed(json)
      sp = ClaudeHook.settings_path(worktree)
      FileUtils.mkdir_p(File.dirname(sp))
      File.write(sp, json)
    end

    def test_enable_then_enabled_is_true
      ClaudeHook.enable(worktree)
      assert ClaudeHook.enabled?(worktree)
    end

    # #92: SessionStart carries BOTH the agent-state reporter and the rename nudge.
    def test_enable_adds_the_rename_nudge_alongside_the_reporter
      ClaudeHook.enable(worktree)
      cmds = commands_for(settings, "SessionStart")
      assert(cmds.any? { |c| c.include?(HookFile::NUDGE_MARK) }, "nudge command present")
      assert(cmds.any? { |c| c.include?(HookFile::MARK) }, "reporter command still present")
      # SessionStart gets the soft plant, NOT the Stop backstop — guards against a
      # regression that wires --stop onto SessionStart (which still matches NUDGE_MARK).
      assert(cmds.none? { |c| c.include?("--stop") }, "SessionStart nudge is the plain variant")
    end

    # Re-enable must not pile up duplicate SessionStart commands (ours? dedups both).
    def test_enable_is_idempotent_for_both_sessionstart_commands
      ClaudeHook.enable(worktree)
      ClaudeHook.enable(worktree)
      cmds = commands_for(settings, "SessionStart")
      assert_equal 1, cmds.count { |c| c.include?(HookFile::NUDGE_MARK) }, "no duplicate nudge"
      assert_equal 1, cmds.count { |c| c.include?(HookFile::MARK) }, "no duplicate reporter"
    end

    # Background-presence (Layer 2): SessionStart also carries the monitoring nudge/clear,
    # and SessionEnd carries the clear-on-exit — both MONITOR_MARK-tagged so ours? dedups.
    def test_enable_wires_the_monitoring_nudge_on_sessionstart_and_sessionend
      ClaudeHook.enable(worktree)
      start = commands_for(settings, "SessionStart")
      assert(start.any? { |c| c.include?(HookFile::MONITOR_MARK) && !c.include?("--end") },
             "SessionStart carries the monitoring nudge/clear")
      ends = commands_for(settings, "SessionEnd")
      assert_equal 1, ends.length, "SessionEnd has exactly one command"
      assert_includes ends.first, "monitoring-nudge --end", "SessionEnd clears the marker on exit"
    end

    # Re-enable must not pile up duplicate monitoring commands (ours? recognizes MONITOR_MARK).
    def test_enable_is_idempotent_for_the_monitoring_commands
      ClaudeHook.enable(worktree)
      ClaudeHook.enable(worktree)
      assert_equal 1, commands_for(settings, "SessionStart").count { |c| c.include?(HookFile::MONITOR_MARK) },
                   "no duplicate SessionStart monitoring command"
      assert_equal 1, commands_for(settings, "SessionEnd").length, "no duplicate SessionEnd command"
    end

    # SessionEnd is entirely switchboard's, so disable strips it (and the whole file, when
    # only ours remained) — proves ours? recognizes the SessionEnd clear for removal.
    def test_disable_strips_the_sessionend_clear
      ClaudeHook.enable(worktree)
      ClaudeHook.disable(worktree)
      refute File.exist?(ClaudeHook.settings_path(worktree)),
             "SessionEnd was only ours -> file gone after disable"
    end

    # #92 + unification: Stop hooks run in parallel with no ordering, so a separate sh
    # reporter racing the blocking nudge could record a blocked (still-working) agent as
    # `done`. So Stop carries ONE command — `rename-nudge --stop` reports the state itself
    # (done, or thinking when it blocks), with a stale-binary fallback to the sh reporter.
    def test_enable_gives_stop_one_unified_reporter_backstop_command
      ClaudeHook.enable(worktree)
      cmds = commands_for(settings, "Stop")
      assert_equal 1, cmds.length, "Stop has exactly one command — no separate sh reporter to race"
      assert_includes cmds.first, "rename-nudge --stop", "the unified reporter+backstop"
      assert_includes cmds.first, "done", "...with a fallback that still records done if the binary is stale"
    end

    # Re-enable must not pile up duplicate Stop commands.
    def test_enable_is_idempotent_for_the_stop_command
      ClaudeHook.enable(worktree)
      ClaudeHook.enable(worktree)
      assert_equal 1, commands_for(settings, "Stop").length, "no duplicate Stop command on re-enable"
    end

    # Migration: a pre-unification settings file with a separate sh `done` reporter on
    # Stop gets stripped on re-enable (the EVENTS loop no longer touches Stop), leaving
    # only the unified command — so the false-completion race can't survive an upgrade.
    def test_enable_strips_a_legacy_separate_stop_reporter
      seed(JSON.generate("hooks" => { "Stop" => [
                           { "hooks" => [{ "type" => "command", "command" => "#{HookFile.script_path} done" }] }
                         ] }))
      ClaudeHook.enable(worktree)
      cmds = commands_for(settings, "Stop")
      assert_equal 1, cmds.length, "the legacy standalone sh Stop reporter is gone"
      assert_includes cmds.first, "rename-nudge --stop"
    end

    # disable strips the nudge too (ours? recognizes it), not just the reporter.
    def test_disable_strips_the_nudge
      ClaudeHook.enable(worktree)
      ClaudeHook.disable(worktree)
      refute ClaudeHook.enabled?(worktree)
    end

    # The baked binary path is Shellwords-escaped (it can contain spaces).
    def test_nudge_command_escapes_the_binary_path
      orig = ENV["SWITCHBOARD_BIN"]
      ENV["SWITCHBOARD_BIN"] = "/has space/switchboard"
      ClaudeHook.enable(worktree)
      cmd = commands_for(settings, "SessionStart").find { |c| c.include?(HookFile::NUDGE_MARK) }
      assert_includes cmd, '/has\ space/switchboard rename-nudge'
    ensure
      orig ? ENV["SWITCHBOARD_BIN"] = orig : ENV.delete("SWITCHBOARD_BIN")
    end

    # The nudge invocation is guarded so a stale/missing baked bin path (a repo move)
    # is a clean no-op at SessionStart, not a "command not found" on every session.
    def test_nudge_command_is_guarded_against_a_missing_binary
      ClaudeHook.enable(worktree)
      cmd = commands_for(settings, "SessionStart").find { |c| c.include?(HookFile::NUDGE_MARK) }
      assert_includes cmd, "command -v", "presence-checks the binary before running it"
      assert cmd.strip.end_with?("|| true"), "falls back to a 0 exit when absent"
    end

    # The regression this guards: PreToolUse fires before the permission prompt,
    # so the dot can't clear once you answer. PostToolUse AND PostToolUseFailure
    # both fire after the granted tool runs — dropping either re-introduces a
    # stuck-magenta dot. (Prior learning, 2026-06-20.)
    def test_enable_wires_both_posttooluse_and_failure_to_thinking
      ClaudeHook.enable(worktree)
      %w[PostToolUse PostToolUseFailure].each do |event|
        cmds = commands_for(settings, event)
        assert(cmds.any? { |c| c.include?(HookFile::MARK) && c.end_with?("thinking") },
               "#{event} should map to a thinking reporter")
      end
    end

    # PermissionRequest fires the instant Claude asks, ahead of Notification's delayed
    # permission_prompt. The command must be a plain reporter: printing anything could
    # answer the prompt for the user.
    def test_enable_wires_permission_request_to_a_silent_waiting_reporter
      ClaudeHook.enable(worktree)
      group = settings.dig("hooks", "PermissionRequest").first
      assert_equal "*", group["matcher"]
      assert_equal ["#{Shellwords.escape(HookFile.script_path)} waiting"], group["hooks"].map { |h| h["command"] }
    end

    # Output from a PermissionRequest hook can answer the prompt, so the reporter it runs must
    # print nothing — only record the state.
    def test_the_waiting_reporter_prints_nothing
      out = IO.popen([HookFile.ensure_script, "waiting"], "r+", chdir: worktree) { |io| io.close_write; io.read }
      assert_equal "", out
      assert_equal 0, $?.exitstatus, "a non-zero exit (2 above all) would answer the permission prompt"
      assert_equal ["waiting"], Dir.glob(File.join(AgentState.state_dir, "*")).map { |f| File.read(f).split("\t").first }

      # A state dir it can't create still leaves the prompt to the user: silent, exit 0.
      File.write(path("blocker"), "")
      ENV["SWITCHBOARD_STATE_DIR"] = File.join(path("blocker"), "agents")
      out = IO.popen([HookFile.ensure_script, "waiting"], "r+", chdir: worktree, err: File::NULL) { |io| io.close_write; io.read }
      assert_equal "", out
      assert_equal 0, $?.exitstatus
    end

    # Every enable / worktree create calls ensure_script; an up-to-date reporter must not be
    # rewritten (each rewrite is a window a running hook could straddle).
    def test_ensure_script_leaves_a_current_reporter_alone
      script = HookFile.ensure_script
      ino = File.stat(script).ino
      HookFile.ensure_script
      assert_equal ino, File.stat(script).ino
    end

    # Claude's SessionEnd default budget is 1.5s, tight for a cold Ruby start, so the clear
    # carries its own timeout. Only SessionEnd: every other event keeps Claude's default.
    def test_only_sessionend_carries_an_explicit_timeout
      ClaudeHook.enable(worktree)
      timeouts = settings["hooks"].transform_values { |gs| gs.flat_map { |g| g["hooks"].filter_map { |h| h["timeout"] } } }
      assert_equal({ "SessionEnd" => [HookFile::SESSION_END_TIMEOUT] }, timeouts.reject { |_e, t| t.empty? })
    end

    # Value: protects=the magenta dot means "blocked on you" for every such type and only
    # those; fails_when=a type is dropped, or matching drifts back to the whole payload;
    # why_new=no test ran the notify mode at all; seam=none
    def test_notify_mode_classifies_by_the_notification_type_value
      script = HookFile.ensure_script
      cases = {
        %({"notification_type":"permission_prompt"}) => "waiting",
        %({"notification_type": "elicitation_dialog"}) => "waiting",
        %({"notification_type":"elicitation_url_dialog"}) => "waiting",
        %({"notification_type":"agent_needs_input"}) => "waiting",
        %({"notification_type":"idle_prompt"}) => "done",
        %({"notification_type":"agent_completed"}) => "done",
        %({"notification_type":"auth_success"}) => "done",
        %({"notification_type":"something_new"}) => "done",
        %({"message":"no type field"}) => "done",
        # Decoys: a type name elsewhere in the payload must not trip waiting.
        %({"cwd":"/w/permission_prompt","message":"agent_needs_input \\"notification_type\\":\\"permission_prompt\\"","notification_type":"idle_prompt"}) => "done"
      }
      cases.each do |payload, want|
        FileUtils.rm_rf(Dir.glob(File.join(AgentState.state_dir, "*")))
        IO.popen([script, "notify"], "w", chdir: worktree) { |io| io.write(payload) }
        got = Dir.glob(File.join(AgentState.state_dir, "*")).map { |f| File.read(f).split("\t").first }
        assert_equal [want], got, payload
      end
    end

    # Value: protects=a subagent's tool calls never claim the MAIN agent is working, and a
    # subagent's approved permission prompt doesn't leave the dot magenta; fails_when=the
    # agent_id filter is dropped, widened to PermissionRequest/Notification, or matches a
    # substring; why_new=the filter is new (D11, probed live on 2.1.310); seam=none
    def test_thinking_mode_ignores_a_subagent_s_tool_calls
      script = HookFile.ensure_script
      report = lambda do |mode, payload, before: nil|
        FileUtils.rm_rf(Dir.glob(File.join(AgentState.state_dir, "*")))
        IO.popen([script, before], "r+", chdir: worktree) { |io| io.close_write } if before
        IO.popen([script, mode], "w", chdir: worktree) { |io| io.write(payload) }
        Dir.glob(File.join(AgentState.state_dir, "*")).map { |f| File.read(f).split("\t").first }
      end
      sub = %("agent_id":"ab93e608633c21d3f","agent_type":"general-purpose")
      assert_equal ["thinking"], report.call("thinking", %({"hook_event_name":"PreToolUse","tool_name":"Bash"}))
      assert_empty report.call("thinking", %({"hook_event_name":"PreToolUse",#{sub}}))
      assert_empty report.call("thinking", %({"hook_event_name":"PostToolUse",#{sub}}))
      assert_empty report.call("thinking", %({"hook_event_name":"PreToolUse","agent_id":"a4aa777ec6d1df69d"})), "Claude's internal agents too"
      assert_equal ["done"], report.call("thinking", %({"hook_event_name":"PostToolUse",#{sub}}), before: "waiting"),
                   "the subagent's approved prompt: magenta must not stick"
      assert_equal ["done"], report.call("thinking", %({"hook_event_name":"PostToolUseFailure",#{sub}}), before: "waiting")
      assert_equal ["waiting"], report.call("waiting", %({"hook_event_name":"PermissionRequest",#{sub}})), "a subagent's prompt still wants you"
      decoy = %({"hook_event_name":"PreToolUse","tool_input":{"command":"echo \\"agent_id\\":\\"x\\""}})
      assert_equal ["thinking"], report.call("thinking", decoy), "an agent_id inside a string value isn't the key"
    end

    # Value: protects=the state each Claude event records (the dot); fails_when=an EVENTS row
    # is edited or dropped and its reporter records the wrong state; why_new=only single
    # events were spot-checked; seam=none
    def test_every_event_records_its_mapped_state
      ClaudeHook.enable(worktree)
      ClaudeHook::EVENTS.each do |event, state, matcher|
        group = settings.dig("hooks", event).find { |g| g["hooks"].any? { |h| h["command"].include?(HookFile::MARK) && !h["command"].include?("nudge") } }
        assert group, "#{event} has a reporter"
        assert group["hooks"].first["command"].end_with?(" #{state}"), "#{event} -> #{state}"
        if matcher
          assert_equal matcher, group["matcher"], "#{event} matcher"
        else
          refute group.key?("matcher"), "#{event} is matcher-less"
        end
      end
    end

    def test_enable_preserves_foreign_settings
      seed(JSON.pretty_generate(
        "permissions" => { "allow" => ["Bash"] },
        "hooks" => { "PreToolUse" => [{ "hooks" => [{ "type" => "command", "command" => "my-own-hook" }] }] }
      ))
      ClaudeHook.enable(worktree)
      data = settings
      assert_equal ["Bash"], data.dig("permissions", "allow"), "foreign key untouched"
      cmds = commands_for(data, "PreToolUse")
      assert_includes cmds, "my-own-hook", "foreign hook kept"
      assert(cmds.any? { |c| c.include?(HookFile::MARK) }, "ours added alongside")
    end

    def test_disable_removes_ours_and_restores_foreign
      seed(JSON.pretty_generate(
        "permissions" => { "allow" => ["Bash"] },
        "hooks" => { "PreToolUse" => [{ "hooks" => [{ "type" => "command", "command" => "mine" }] }] }
      ))
      ClaudeHook.enable(worktree)
      ClaudeHook.disable(worktree)
      data = settings
      refute ClaudeHook.enabled?(worktree)
      assert_equal ["Bash"], data.dig("permissions", "allow")
      assert_equal ["mine"], commands_for(data, "PreToolUse")
    end

    def test_disable_deletes_the_file_when_only_ours_remain
      ClaudeHook.enable(worktree)
      assert File.exist?(ClaudeHook.settings_path(worktree))
      ClaudeHook.disable(worktree)
      refute File.exist?(ClaudeHook.settings_path(worktree)), "an emptied settings file is removed"
    end

    def test_enable_refuses_to_clobber_corrupt_json
      seed("}{ not json")
      out, err = capture_io { assert_nil ClaudeHook.enable(worktree) }
      assert_equal "}{ not json", File.read(ClaudeHook.settings_path(worktree)), "left untouched"
      assert_match(/isn't valid JSON/, err)
      assert_empty out
    end

    def test_enable_treats_an_empty_file_as_fresh
      seed("")
      ClaudeHook.enable(worktree)
      assert ClaudeHook.enabled?(worktree)
    end

    # #110 review: re-enable must not duplicate the SessionStart nudge / Stop even for
    # an adapter whose EVENTS omit those events — the reset clears all ours up front,
    # so the unconditional nudge/Stop appends can't pile up. Exercises HookFile directly
    # with a minimal adapter shape (no SessionStart in EVENTS).
    def test_enable_does_not_duplicate_nudge_for_an_adapter_without_sessionstart
      rel = ".agent/hooks.json"
      events = [["UserPromptSubmit", "thinking", nil]] # deliberately no SessionStart
      2.times { HookFile.enable(worktree, rel, events) }
      hooks = JSON.parse(File.read(File.join(worktree, rel)))["hooks"]
      nudges = Array(hooks["SessionStart"]).flat_map { |g| g["hooks"] }
                                           .count { |h| h["command"].include?(HookFile::NUDGE_MARK) }
      stops = Array(hooks["Stop"]).size
      assert_equal 1, nudges, "nudge not duplicated when SessionStart is off EVENTS"
      assert_equal 1, stops, "Stop not duplicated"
    end

    # strip_ours now lives on the shared HookFile engine (both adapters delegate to it).
    def test_strip_ours_is_idempotent_and_keeps_foreign
      groups = [{ "hooks" => [{ "type" => "command", "command" => "x" },
                              { "type" => "command", "command" => "#{HookFile.ensure_script} thinking" }] }]
      once = HookFile.strip_ours(groups)
      assert_equal once, HookFile.strip_ours(once)
      assert_equal ["x"], once.flat_map { |g| g["hooks"].map { |h| h["command"] } }
    end

    def test_ensure_script_materializes_executable_reporter_under_xdg_data
      script = HookFile.ensure_script
      assert File.exist?(script)
      assert script.start_with?(ENV["XDG_DATA_HOME"]), "reporter lives under sandboxed XDG_DATA_HOME"
      assert File.executable?(script)
      assert_equal HookFile::SCRIPT, File.read(script)
    end

    # Value: protects=a hook already running the old reporter (sh reads it as it goes) when an
    # upgrade rewrites it; fails_when=ensure_script writes the same inode in place again, so a
    # running sh resumes mid-way into the new text (syntax error, exit 2); why_new=only a fresh
    # write was pinned; seam=none; no_claim=sh's read buffering (the inode is the contract)
    def test_ensure_script_replaces_a_stale_reporter_without_touching_the_old_inode
      script = HookFile.ensure_script
      File.write(script, "#!/bin/sh\n# old reporter\n")
      running = File.open(script) # what a hook mid-run holds
      HookFile.ensure_script
      assert_equal "#!/bin/sh\n# old reporter\n", running.read, "the running copy is untouched"
      assert_equal HookFile::SCRIPT, File.read(script)
      assert File.executable?(script)
    ensure
      running&.close
    end

    def test_enable_adds_settings_to_git_local_excludes
      repo = temp_git_repo
      ClaudeHook.enable(repo)
      exclude = File.read(File.join(repo, ".git", "info", "exclude"))
      assert_includes exclude, ".claude/settings.local.json"
    end

    # #110 review: the reporter path lives under XDG data home, which can contain a
    # space — the command must shell-escape it (HookFile.enable), or it splits and
    # the dot silently never updates. Shellwords.escape is a no-op on a clean path,
    # so the common case is unchanged; this guards the spaced-home case for both
    # adapters (the logic is shared in HookFile).
    def test_reporter_command_escapes_a_spaced_script_path
      ENV["XDG_DATA_HOME"] = path("x y/data")
      ClaudeHook.enable(worktree)
      cmd = commands_for(settings, "UserPromptSubmit").first
      assert_includes cmd, Shellwords.escape(HookFile.script_path), "script path is shell-escaped"
      assert_equal HookFile.script_path, Shellwords.split(cmd).first, "command parses to the script as one token"
    end

    # `switchboard new` is separate from subagents (R6): switchboard never hooks a
    # subagent launch, for Claude or Codex.
    def test_no_subagent_events_are_ever_wired
      events = ClaudeHook::EVENTS.map(&:first) + CodexHook::EVENTS.map(&:first) +
               HookFile.command_entries(ClaudeHook::EVENTS, "/s", "switchboard").map { |e| e[:event] } +
               HookFile.command_entries(CodexHook::EVENTS, "/s", "switchboard").map { |e| e[:event] }
      assert_empty events.grep(/subagent/i)
    end

    # --- a symlink the repo committed (Codex review, Step 11) -------------------------

    # A repo with `.claude/settings.local.json` (or `.claude`) committed as a symlink to
    # `outside`: a hostile repo aims it at your global Claude settings.
    def committed_link_repo(link_dir: false)
      repo = temp_git_repo("linked")
      outside = path("outside", "settings.json")
      FileUtils.mkdir_p(File.dirname(outside))
      File.write(outside, "{}\n")
      if link_dir
        File.symlink(File.dirname(outside), File.join(repo, ".claude"))
      else
        FileUtils.mkdir_p(File.join(repo, ".claude"))
        File.symlink(outside, ClaudeHook.settings_path(repo))
      end
      git(repo, "add", "-A")
      git(repo, "commit", "-q", "-m", "link")
      [repo, outside]
    end

    # Value: protects=creating a workspace never writes switchboard's hooks through a symlink the repo committed (out of the worktree); fails_when=load_settings stops refusing a committed link; why_new=Codex Step 11 finding, nothing covered it; seam=none; no_claim=a link you made yourself (hook_refresh_test keeps writing through it)
    def test_enable_refuses_a_committed_settings_symlink
      repo, outside = committed_link_repo
      _out, err = capture_io { ClaudeHook.enable(repo) }
      assert_equal "{}\n", File.read(outside), "the link's target is untouched"
      assert_match(/symlink the repo committed/, err)
      refute ClaudeHook.current?(repo)
    end

    # Value: protects=a committed `.claude` dir symlink is refused the same way; fails_when=only the file is checked, not its directory; why_new=the dir is the other way out; seam=none; no_claim=deeper ancestors (the worktree root itself)
    def test_enable_refuses_a_committed_claude_dir_symlink
      repo, outside = committed_link_repo(link_dir: true)
      capture_io { ClaudeHook.enable(repo) }
      assert_equal ["settings.json"], Dir.children(File.dirname(outside)), "nothing written beside the target"
      assert_equal "{}\n", File.read(outside)
    end

    # Value: protects=a committed DANGLING link isn't followed to create its target; fails_when=the check moves after exist? (false for a dangling link); why_new=the case a naive guard misses; seam=none; no_claim=none beyond protects
    def test_enable_refuses_a_committed_dangling_symlink
      repo, outside = committed_link_repo
      File.delete(outside)
      capture_io { ClaudeHook.enable(repo) }
      refute File.exist?(outside), "the link's target was not created"
    end

    # A committed link under another letter case: macOS opens `.Claude` for `.claude`, so it
    # must count as committed too. On a case-sensitive filesystem the link isn't at our path
    # at all, so there's nothing to escape through.
    def test_enable_refuses_a_committed_link_in_another_letter_case
      repo = temp_git_repo("cased")
      outside = path("outside2", "settings.json")
      FileUtils.mkdir_p(File.dirname(outside))
      File.write(outside, "{}\n")
      File.symlink(File.dirname(outside), File.join(repo, ".Claude"))
      git(repo, "add", "-A")
      git(repo, "commit", "-q", "-m", "cased link")
      skip "case-sensitive filesystem: .claude isn't the committed .Claude" unless File.symlink?(File.join(repo, ".claude"))

      capture_io { ClaudeHook.enable(repo) }
      assert_equal ["settings.json"], Dir.children(File.dirname(outside)), "nothing written through the renamed link"
    end

    # Value: protects=a committed link to a file without switchboard's hooks doesn't fail disable-hooks (nothing of ours to remove), so a setup-script opt-out still works there; fails_when=committed links always fail disable; why_new=fix-check: such repos failed setup on every workspace; seam=none; no_claim=none beyond protects
    def test_disable_hooks_passes_a_committed_link_with_nothing_of_ours
      repo, outside = committed_link_repo
      got = nil
      out, = capture_io { got = Dir.chdir(repo) { CLI.disable_hooks } }
      refute_equal false, got
      assert_match(/disabled switchboard's hooks/, out)
      assert_equal "{}\n", File.read(outside)
      File.delete(outside) # dangling: still nothing of ours
      refute_equal false, Dir.chdir(repo) { capture_io { got = CLI.disable_hooks }; got }
    end

    # Value: protects=the refusal names where the committed link leads, so someone already hooked through one can clean that file; fails_when=the target drops out of the message; why_new=fix-check: no path out for already-affected users; seam=none; no_claim=none beyond protects
    def test_a_committed_link_refusal_names_its_target_once
      repo, outside = committed_link_repo
      _out, err = capture_io { ClaudeHook.enable(repo) }
      assert_includes err, File.realpath(outside)
      assert_equal 1, err.scan("leaving it untouched").size, "said once"
    end

    # Value: protects=disable-hooks on a committed link fails (exit 1) instead of deleting the link and reporting success; fails_when=committed links stop reading as unparseable; why_new=Codex: disable deleted the local link while hooks stayed in the target; seam=none; no_claim=an outside target that already held hooks from before this guard (refused alike, left as is)
    def test_disable_hooks_fails_on_a_committed_symlink
      repo, outside = committed_link_repo
      File.write(outside, JSON.generate("hooks" => { "Stop" => [{ "hooks" => [{ "type" => "command", "command" => "x #{HookFile::MARK}" }] }] }))
      got = nil
      out, = capture_io { got = Dir.chdir(repo) { CLI.disable_hooks } }
      assert_equal false, got
      assert_match(/couldn't remove claude hooks/, out)
      assert File.symlink?(ClaudeHook.settings_path(repo)), "the committed link is left in place"
    end
  end
end
