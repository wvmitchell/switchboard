# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "rbconfig"

module Switchboard
  # The agent hook entries: what they print, what they record, and that a fault leaves
  # stdout empty and exit 0.
  class HookCommandsTest < SandboxTest
    # --- rename-nudge (#92 SessionStart hook entry) --------------------------

    # Pins agent_dispatch OFF so the rename tests keep asserting exact silence (D7); the
    # dispatch tests below turn it on explicitly.
    def nudge_config(extra)
      base = { "worktree_root" => path("wts"), "agent_dispatch" => false,
               "projects" => [{ "name" => "proj", "path" => "/p" }] }
      File.write(Config.path, YAML.dump(base.merge(extra)))
    end

    # Run rename_nudge with a stubbed worktree + the given stdin, return captured stdout.
    # `args` selects the event path (e.g. ["--stop"] for the Stop backstop). The Stop
    # path also reports agent state by spawning the sh reporter — stubbed to a no-op so
    # tests stay offline and focused on the stdout (block decision) contract.
    def run_nudge(worktree:, stdin:, args: [])
      out = nil
      stub_method(Model, :workspace_at, ->(*) { worktree }) do
        stub_method(HookCommands, :report_stop_state, ->(*) {}) do
          with_stdin(StringIO.new(stdin)) { out = capture { HookCommands.rename_nudge(args) } }
        end
      end
      out
    end

    # Capture the state the unified --stop path reports (stubbing the sh-reporter spawn).
    def stop_reported_state(worktree:, stdin:)
      reported = :none
      stub_method(Model, :workspace_at, ->(*) { worktree }) do
        stub_method(HookCommands, :report_stop_state, ->(s) { reported = s }) do
          with_stdin(StringIO.new(stdin)) { capture { HookCommands.rename_nudge(["--stop"]) } }
        end
      end
      reported
    end

    def placeholder_wt
      Worktree.new(project: "proj", path: "/wts/proj/wandering-finch", primary: false)
    end

    def test_rename_nudge_emits_json_when_gated_on
      nudge_config("auto_rename" => true)
      out = run_nudge(worktree: placeholder_wt, stdin: '{"source":"resume","cwd":"/x"}')
      ctx = JSON.parse(out)["hookSpecificOutput"]
      assert_equal "SessionStart", ctx["hookEventName"]
      assert_includes ctx["additionalContext"], "wandering-finch"
    end

    def test_rename_nudge_silent_when_auto_rename_off
      nudge_config("auto_rename" => false)
      assert_equal "", run_nudge(worktree: placeholder_wt, stdin: '{"source":"resume","cwd":"/x"}')
    end

    def test_rename_nudge_silent_when_not_a_placeholder
      nudge_config("auto_rename" => true)
      named = Worktree.new(project: "proj", path: "/wts/proj/fix-auth", primary: false)
      assert_equal "", run_nudge(worktree: named, stdin: '{"source":"resume","cwd":"/x"}')
    end

    # /clear wipes the earlier plant out of context, so it re-plants (like compact).
    def test_rename_nudge_replants_on_clear_source
      nudge_config("auto_rename" => true)
      refute_empty run_nudge(worktree: placeholder_wt, stdin: '{"source":"clear","cwd":"/x"}')
    end

    def test_rename_nudge_silent_on_primary_checkout
      nudge_config("auto_rename" => true)
      prim = Worktree.new(project: "proj", path: "/p", primary: true)
      assert_equal "", run_nudge(worktree: prim, stdin: '{"source":"resume","cwd":"/p"}')
    end

    # --- the agent-dispatch instruction riding the same SessionStart payload (D7) ---

    def session_context(out)
      JSON.parse(out)["hookSpecificOutput"]["additionalContext"]
    end

    def named_wt
      Worktree.new(project: "proj", path: "/wts/proj/fix-auth", primary: false)
    end

    def test_dispatch_instruction_alone_in_a_named_workspace
      nudge_config("auto_rename" => true, "agent_dispatch" => true)
      assert_equal DispatchNudge.message, session_context(run_nudge(worktree: named_wt, stdin: '{"source":"startup","cwd":"/x"}'))
    end

    def test_dispatch_and_rename_join_into_one_payload_rename_first
      nudge_config("auto_rename" => true, "agent_dispatch" => true)
      out = run_nudge(worktree: placeholder_wt, stdin: '{"source":"startup","cwd":"/x"}')
      assert_equal 1, out.lines.size, "one JSON object"
      assert_equal "#{RenameNudge.message('wandering-finch')}\n\n#{DispatchNudge.message}", session_context(out)
    end

    def test_dispatch_instruction_alone_when_auto_rename_off
      nudge_config("auto_rename" => false, "agent_dispatch" => true)
      assert_equal DispatchNudge.message, session_context(run_nudge(worktree: placeholder_wt, stdin: '{"source":"resume","cwd":"/x"}'))
    end

    # A session `switchboard new` started is told its first message came from another agent,
    # so that brief can't chain another dispatch; one you typed after `n` is not.
    def test_dispatch_instruction_names_an_agent_written_brief
      nudge_config("agent_dispatch" => true)
      ENV["SWITCHBOARD_BRIEF_FROM"] = "cli"
      assert_equal DispatchNudge.message(brief_from_agent: true),
                   session_context(run_nudge(worktree: named_wt, stdin: '{"source":"startup","cwd":"/x"}'))
      %w[resume compact fork].each do |src|
        assert_equal DispatchNudge.message(brief_from_agent: true),
                     session_context(run_nudge(worktree: named_wt, stdin: %({"source":"#{src}","cwd":"/x"}))),
                     "#{src} keeps the conversation that opened on the other agent's brief"
      end
      assert_equal DispatchNudge.message, session_context(run_nudge(worktree: named_wt, stdin: '{"source":"clear","cwd":"/x"}')),
                   "after /clear the next first message is the user's own"
      ENV.delete("SWITCHBOARD_BRIEF_FROM")
      assert_equal DispatchNudge.message, session_context(run_nudge(worktree: named_wt, stdin: '{"source":"startup","cwd":"/x"}'))
    end

    def test_dispatch_instruction_silent_on_primary_checkout
      nudge_config("agent_dispatch" => true)
      prim = Worktree.new(project: "proj", path: "/p", primary: true)
      assert_equal "", run_nudge(worktree: prim, stdin: '{"source":"resume","cwd":"/p"}')
    end

    def test_dispatch_instruction_is_on_by_default
      File.write(Config.path, YAML.dump("worktree_root" => path("wts"), "projects" => [{ "name" => "proj", "path" => "/p" }]))
      assert_equal DispatchNudge.message, session_context(run_nudge(worktree: named_wt, stdin: '{"source":"startup","cwd":"/x"}'))
    end

    # Each piece is rescued alone: a fault building the dispatch text drops only it.
    def test_a_failing_dispatch_piece_still_prints_the_rename_text
      nudge_config("auto_rename" => true, "agent_dispatch" => true)
      out = nil
      stub_method(DispatchNudge, :message, -> { raise "boom" }) do
        out = run_nudge(worktree: placeholder_wt, stdin: '{"source":"startup","cwd":"/x"}')
      end
      assert_equal RenameNudge.message("wandering-finch"), session_context(out)
    end

    def test_rename_nudge_silent_on_malformed_stdin
      nudge_config("auto_rename" => true)
      assert_equal "", run_nudge(worktree: placeholder_wt, stdin: "{ not json")
      assert_equal "", run_nudge(worktree: placeholder_wt, stdin: "")
    end

    # The Stop backstop (--stop): blocks the turn when the agent ends it still on a
    # placeholder, feeding back an imperative rename reminder.
    def test_rename_nudge_stop_emits_a_block_decision_when_gated_on
      nudge_config("auto_rename" => true)
      out = run_nudge(worktree: placeholder_wt, stdin: '{"stop_hook_active":false,"cwd":"/x"}', args: ["--stop"])
      dec = JSON.parse(out)
      assert_equal "block", dec["decision"]
      assert_includes dec["reason"], "wandering-finch"
    end

    # The loop guard: once Claude has resumed from our block, --stop stays silent so the
    # turn can end (block once, never nag).
    def test_rename_nudge_stop_silent_once_stop_hook_active
      nudge_config("auto_rename" => true)
      assert_equal "", run_nudge(worktree: placeholder_wt,
                                 stdin: '{"stop_hook_active":true,"cwd":"/x"}', args: ["--stop"])
    end

    # Self-clears on rename: a named workspace gets no Stop block.
    def test_rename_nudge_stop_silent_when_not_a_placeholder
      nudge_config("auto_rename" => true)
      named = Worktree.new(project: "proj", path: "/wts/proj/fix-auth", primary: false)
      assert_equal "", run_nudge(worktree: named, stdin: '{"stop_hook_active":false,"cwd":"/x"}', args: ["--stop"])
    end

    def test_rename_nudge_stop_silent_when_auto_rename_off
      nudge_config("auto_rename" => false)
      assert_equal "", run_nudge(worktree: placeholder_wt,
                                 stdin: '{"stop_hook_active":false,"cwd":"/x"}', args: ["--stop"])
    end

    # Fail-closed end-to-end: a Stop payload missing stop_hook_active emits nothing (no
    # block), matching the SessionStart path's silence on malformed/incomplete stdin.
    def test_rename_nudge_stop_silent_when_flag_absent
      nudge_config("auto_rename" => true)
      assert_equal "", run_nudge(worktree: placeholder_wt, stdin: '{"cwd":"/x"}', args: ["--stop"])
    end

    # The unification: --stop is the Stop state reporter too. It reports `thinking` when
    # it blocks (so a forced-to-continue agent never reads as `done`)...
    def test_rename_nudge_stop_reports_thinking_when_blocking
      nudge_config("auto_rename" => true)
      assert_equal "thinking",
                   stop_reported_state(worktree: placeholder_wt, stdin: '{"stop_hook_active":false,"cwd":"/x"}')
    end

    # ...and `done` when it doesn't block (here: a named workspace — a normal completion).
    def test_rename_nudge_stop_reports_done_when_not_blocking
      nudge_config("auto_rename" => true)
      named = Worktree.new(project: "proj", path: "/wts/proj/fix-auth", primary: false)
      assert_equal "done",
                   stop_reported_state(worktree: named, stdin: '{"stop_hook_active":false,"cwd":"/x"}')
    end

    # Even a non-managed (nil) worktree still reports done on Stop — the dot depends on it
    # (the state report is unconditional; only the block is gated).
    def test_rename_nudge_stop_reports_done_for_an_unmanaged_worktree
      nudge_config("auto_rename" => true)
      assert_equal "done", stop_reported_state(worktree: nil, stdin: '{"stop_hook_active":false,"cwd":"/x"}')
    end

    # The correctness crux of the unification (the rest stub report_stop_state): the real
    # write must land where AgentState reads it. report_stop_state spawns the same sh
    # reporter, whose `pwd -P`/cksum key is computed from our inherited cwd — so a state
    # written here must round-trip back through AgentState.scan as that worktree's state.
    def test_report_stop_state_round_trips_through_agentstate
      HookFile.ensure_script
      wt = path("wt")
      FileUtils.mkdir_p(wt)
      Dir.chdir(wt) { HookCommands.report_stop_state("thinking") }
      assert_equal({ wt => :thinking }, AgentState.new.scan([wt]))
    end

    # The hard contract: a fault must never raise (would error a session start) and
    # must leave stdout empty (a stray byte poisons Claude startup).
    def test_rename_nudge_never_raises_and_stays_silent_on_a_fault
      nudge_config("auto_rename" => true)
      out = nil
      stub_method(Model, :workspace_at, ->(*) { raise "boom" }) do
        with_stdin(StringIO.new('{"source":"resume","cwd":"/x"}')) { out = capture { HookCommands.rename_nudge } }
      end
      assert_equal "", out
    end

    # --- monitoring-nudge (the Layer-2 SessionStart/SessionEnd hook handler) ------

    # A real worktree dir (Monitoring.mark gates on the dir existing) under project "proj".
    def monitoring_wt
      d = path("wt")
      FileUtils.mkdir_p(d)
      Worktree.new(project: "proj", path: File.realpath(d), primary: false)
    end

    def run_monitoring_nudge(worktree:, stdin:, args: [])
      out = nil
      stub_method(Model, :workspace_at, ->(*) { worktree }) do
        with_stdin(StringIO.new(stdin)) { out = capture { HookCommands.monitoring_nudge(args) } }
      end
      out
    end

    def test_monitoring_nudge_sessionstart_clears_stale_marker_and_emits_nudge
      nudge_config("background_presence" => true)
      wt = monitoring_wt
      Monitoring.mark(wt.path) # a stale marker left by a prior session
      out = run_monitoring_nudge(worktree: wt, stdin: %({"source":"resume","cwd":"#{wt.path}"}))
      assert_empty Monitoring.monitored([wt.path]), "SessionStart clears the stale marker (per-session declaration)"
      assert_includes JSON.parse(out).dig("hookSpecificOutput", "additionalContext"), "monitoring on"
    end

    def test_monitoring_nudge_end_clears_without_stdout
      nudge_config("background_presence" => true)
      wt = monitoring_wt
      Monitoring.mark(wt.path)
      out = run_monitoring_nudge(worktree: wt, stdin: %({"cwd":"#{wt.path}"}), args: ["--end"])
      assert_empty Monitoring.monitored([wt.path]), "SessionEnd clears the marker"
      assert_equal "", out.strip, "SessionEnd emits nothing on stdout"
    end

    # Value: protects=/clear's real sequence — SessionEnd(reason: clear) drops the ∞, then
    # SessionStart(clear) re-teaches; fails_when=a reason-bearing SessionEnd stops clearing (the
    # premise that keeps `clear` out of CLEARS_ON); why_new=--end was only driven without a
    # reason; seam=workspace_at stub (as above); no_claim=Claude's real event order
    def test_monitoring_nudge_clear_sequence_drops_marker_then_reteaches
      nudge_config("background_presence" => true)
      wt = monitoring_wt
      Monitoring.mark(wt.path)
      run_monitoring_nudge(worktree: wt, stdin: %({"reason":"clear","cwd":"#{wt.path}"}), args: ["--end"])
      assert_empty Monitoring.monitored([wt.path]), "SessionEnd(clear) drops the marker"
      out = run_monitoring_nudge(worktree: wt, stdin: %({"source":"clear","cwd":"#{wt.path}"}))
      assert_includes JSON.parse(out).dig("hookSpecificOutput", "additionalContext"), "monitoring on"
    end

    # The thought experiment: work with an agent -> compaction -> agent sets a monitor.
    # Compaction must (1) NOT clear a live monitor's marker, and (2) STILL re-plant the
    # nudge (compaction can drop the original instruction, so a post-compaction monitor
    # still gets flagged).
    # Value (clear row): protects=/clear keeps a live monitor's ∞ yet re-teaches the
    # convention; fails_when=the CLI wires `clear` into the clear gate or out of the nudge
    # gate; why_new=only the predicates were tested for `clear`; seam=workspace_at
    # stubs (as the rows above); no_claim=Claude's actual source strings
    def test_monitoring_nudge_compact_keeps_marker_and_still_reteaches
      nudge_config("background_presence" => true)
      wt = monitoring_wt
      %w[compact clear].each do |source|
        Monitoring.mark(wt.path)
        out = run_monitoring_nudge(worktree: wt, stdin: %({"source":"#{source}","cwd":"#{wt.path}"}))
        assert Monitoring.monitored([wt.path]).any?, "SessionStart(#{source}) itself leaves the marker (for clear, the preceding SessionEnd is what drops it)"
        assert_includes JSON.parse(out).dig("hookSpecificOutput", "additionalContext"), "monitoring on",
                        "#{source} still re-teaches the convention (survives context loss)"
      end
    end

    def test_monitoring_nudge_noop_when_background_presence_off
      nudge_config("background_presence" => false)
      wt = monitoring_wt
      Monitoring.mark(wt.path)
      out = run_monitoring_nudge(worktree: wt, stdin: %({"source":"resume","cwd":"#{wt.path}"}))
      assert Monitoring.monitored([wt.path]).any?, "feature off -> a manual marker is left alone"
      assert_equal "", out.strip
    end

    def test_monitoring_nudge_silent_on_primary_checkout
      nudge_config("background_presence" => true)
      prim = Worktree.new(project: "proj", path: "/p", primary: true)
      assert_equal "", run_monitoring_nudge(worktree: prim, stdin: '{"source":"resume","cwd":"/p"}')
    end

    # --- the contract every entry keeps -------------------------------------------

    LIB = File.expand_path("../lib", __dir__)
    BIN = File.expand_path("../bin/switchboard", __dir__)
    ENTRIES = [%w[rename-nudge], %w[rename-nudge --stop], %w[monitoring-nudge], %w[monitoring-nudge --end]].freeze
    C_LOCALE = { "LC_ALL" => "C", "LANG" => "C" }.freeze

    def test_every_entry_stays_silent_when_a_step_faults
      nudge_config("auto_rename" => true, "background_presence" => true)
      boom = ->(*) { raise "boom" }
      [[Model, :workspace_at], [Config, :new], [Git, :toplevel]].product(ENTRIES).each do |(receiver, step), entry|
        out = :unset
        stub_method(receiver, step, boom) do
          stub_method(HookCommands, :report_stop_state, ->(*) {}) do
            with_stdin(StringIO.new('{"source":"resume","stop_hook_active":false,"cwd":"/x"}')) do
              out = capture { CLI.run(entry) }
            end
          end
        end
        assert_equal "", out, "#{entry.join(' ')} with #{receiver}.#{step} raising"
      end
    end

    # The dot depends on the Stop report, so no fault after the payload parses may skip it.
    def test_a_stop_still_reports_done_when_a_step_faults
      nudge_config("auto_rename" => true)
      [[Model, :workspace_at], [Config, :new], [Git, :toplevel]].each do |receiver, step|
        reported = :none
        stub_method(receiver, step, ->(*) { raise "boom" }) do
          stub_method(HookCommands, :report_stop_state, ->(s) { reported = s }) do
            with_stdin(StringIO.new('{"stop_hook_active":false,"cwd":"/x"}')) { capture { CLI.run(%w[rename-nudge --stop]) } }
          end
        end
        assert_equal "done", reported, "#{receiver}.#{step} raising"
      end
    end

    # The real binary, as an installed hook calls it: stdout carries nothing and it exits 0,
    # whatever the payload and however broken the config.
    def test_the_real_binary_prints_nothing_and_exits_0_on_a_bad_payload_or_config
      FileUtils.mkdir_p(path("plain"))
      File.write(Config.path, "{ not: [yaml")
      ['{ not json', "", "[1]", '{"cwd":"/no/such/dir"}', %({"source":"resume","cwd":"#{path('plain')}"})].each do |stdin|
        ENTRIES.each do |entry|
          out = IO.popen(C_LOCALE, [RbConfig.ruby, BIN, *entry], "r+", chdir: path("plain"), err: File::NULL) do |io|
            io.write(stdin)
            io.close_write
            io.read
          end
          assert $?.success?, "#{entry.join(' ')} exited #{$?.exitstatus} on #{stdin.inspect}"
          assert_equal "", out, "#{entry.join(' ')} printed on #{stdin.inspect}"
        end
      end
    end

    def test_the_installed_verbs_reach_their_entries
      nudge_config("auto_rename" => true, "background_presence" => true)
      wt = placeholder_wt
      stub_method(Model, :workspace_at, ->(*) { wt }) do
        { %w[rename-nudge] => "wandering-finch", %w[monitoring-nudge] => "monitoring on" }.each do |verb, text|
          out = nil
          with_stdin(StringIO.new('{"source":"resume","cwd":"/x"}')) { out = capture { CLI.run(verb) } }
          assert_includes out, text, verb.first
        end
      end
    end

    # --- resolving a workspace under a C locale, where tmux panes often run (review D11) ---

    # A linked worktree under a non-ASCII folder, registered, with a placeholder name.
    def non_ascii_workspace
      repo = temp_git_repo("proj", origin: true)
      root = path("wts-é")
      File.write(Config.path, YAML.dump("worktree_root" => root, "auto_rename" => true, "agent_dispatch" => false,
                                        "projects" => [{ "name" => "proj", "path" => repo }]))
      dest = File.join(root, "proj", "wandering-finch")
      FileUtils.mkdir_p(File.dirname(dest))
      git(repo, "worktree", "add", "-q", "-b", "alpha", dest)
      FileUtils.mkdir_p(File.join(dest, "deep"))
      dest
    end

    # Ruby's own default, US-ASCII: the binary sets UTF-8 at startup, a bare library load doesn't.
    def test_workspace_at_finds_a_non_ascii_worktree_in_a_c_locale_library_load
      dest = non_ascii_workspace
      probe = <<~RUBY
        require "switchboard"
        wt = Switchboard::Model.workspace_at(Switchboard::Config.new, ARGV[0])
        print wt ? wt.project : "nil"
      RUBY
      out = IO.popen(C_LOCALE, [RbConfig.ruby, "-I#{LIB}", "-e", probe, File.join(dest, "deep")], err: %i[child out], &:read)
      assert_equal "proj", out
    end

    def test_the_session_start_hook_finds_a_non_ascii_worktree_through_the_binary
      dest = non_ascii_workspace
      out = IO.popen(C_LOCALE, [RbConfig.ruby, BIN, "rename-nudge"], "r+", chdir: dest, err: File::NULL) do |io|
        io.write(JSON.generate("source" => "resume", "cwd" => File.join(dest, "deep")))
        io.close_write
        io.read
      end
      assert_includes out, "wandering-finch"
    end

    def test_rename_finds_a_non_ascii_worktree_through_the_binary
      dest = non_ascii_workspace
      out = IO.popen(C_LOCALE, [RbConfig.ruby, BIN, "rename"], chdir: File.join(dest, "deep"), err: %i[child out], in: File::NULL, &:read)
      refute_includes out, "not inside a switchboard-managed worktree"
      assert_includes out, "wandering-finch"
    end

    # Value: protects=hooks resolve the workspace from the payload's cwd, falling back to the
    # process cwd only for a missing, blank or non-string one, with each flag reaching its entry;
    # fails_when=an entry drops hook_cwd or the verb stops forwarding its args; why_new=the other
    # tests stub workspace_at or run with both cwds in one workspace; seam=none;
    # no_claim=the cwd Claude or Codex really sends
    def test_every_entry_finds_its_workspace_from_the_payload_cwd_then_the_process_cwd
      dest = non_ascii_workspace
      File.write(Config.path, YAML.dump(YAML.safe_load_file(Config.path).merge("background_presence" => true)))
      FileUtils.mkdir_p(path("plain"))
      run = lambda do |entry, payload, from|
        IO.popen(C_LOCALE, [RbConfig.ruby, BIN, *entry], "r+", chdir: from, err: File::NULL) do |io|
          io.write(JSON.generate(payload))
          io.close_write
          io.read
        end
      end
      expected = { %w[rename-nudge] => "wandering-finch", %w[rename-nudge --stop] => "wandering-finch",
                   %w[monitoring-nudge] => "monitoring on" }
      event = { "source" => "resume", "stop_hook_active" => false }

      expected.each do |entry, text|
        assert_includes run.call(entry, event.merge("cwd" => dest), path("plain")), text, "#{entry} from another cwd"
        assert_equal "", run.call(entry, event.merge("cwd" => path("plain")), dest), "#{entry} ignores a process cwd in a workspace"
        [{}, { "cwd" => "  " }, { "cwd" => 7 }].each do |cwd|
          assert_includes run.call(entry, event.merge(cwd), dest), text, "#{entry} falls back on #{cwd}"
        end
      end

      real = File.realpath(dest)
      Monitoring.mark(real)
      assert_equal "", run.call(%w[monitoring-nudge --end], { "cwd" => dest }, path("plain"))
      assert_empty Monitoring.monitored([real]), "--end reaches the entry and clears the payload cwd's marker"
    end

    # stamp_first_turn wants the git root, not a registered workspace: the record is matched
    # by path, from wherever under the worktree the hook's cwd sits, even once the project
    # has left the config.
    def test_a_stop_from_a_subdir_stamps_through_the_real_git_root
      dest = non_ascii_workspace
      File.write(Config.path, YAML.dump("worktree_root" => path("wts"), "projects" => []))
      rec = Creation.create(project: "proj", name: "fix-auth", path: dest, task: "do it")
      Creation.transition(rec["id"], from: :queued, to: :launching, hooked: true, agent_started: true)
      Creation.transition(rec["id"], from: :launching, to: :ready)
      HookCommands.stamp_first_turn(File.join(dest, "deep"))
      assert_equal "turn_done", Creation.find(rec["id"])["state"]
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
