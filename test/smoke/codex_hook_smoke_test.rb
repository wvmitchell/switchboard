# frozen_string_literal: true

require_relative "../test_helper"
require "json"
require "timeout"
require "etc"
require "shellwords"

module Switchboard
  # Real-Codex smoke (#110 + the linked-worktree fix): the delivery path NO unit test
  # can reach — does the GLOBAL `[hooks]` block in `~/.codex/config.toml` actually FIRE
  # and write switchboard's agent-state files when a real `codex` runs in a LINKED git
  # worktree? That last word is the whole point: codex (verified 0.142 through 0.164)
  # deliberately does NOT load a linked worktree's own `<worktree>/.codex/hooks.json` — it
  # redirects a linked worktree's project hooks to the main checkout's `.codex/` — and
  # switchboard is nothing but linked worktrees, so the v0.39.0 per-worktree delivery was
  # dead on arrival.
  # The fix moves codex hooks to a CONFIG-level block, which is not project-discovered and
  # so fires everywhere. This smoke is the standing regression guard for that: it builds a
  # primary repo, adds a LINKED worktree, installs the global block into a SANDBOX
  # CODEX_HOME (a copy of the real one, so the run is authed but the user's real config is
  # never touched), drives `codex exec` headlessly in the linked worktree, and asserts the
  # resting state lands where AgentState reads it.
  #
  # The #130 nesting guard (suppress under a Claude-Code parent) is covered offline by
  # codex_hook_test's runtime guard test, not here. The one second (token-spending) run is
  # the untrusted case: an unapproved block must write nothing (the premise of doctor's
  # `N/M trusted` warning, which the bypassing run above can't see).
  #
  # OPT-IN: it needs `codex` on PATH, auth, and network — and it spends tokens — so it runs
  # ONLY when SWITCHBOARD_CODEX_SMOKE=1 (mirrors bin/test-smoke's tmux gate). It's already
  # out of the offline bin/test entirely (test/smoke/ glob). A SandboxTest (not SmokeCase)
  # subclass: it needs a git repo + codex, not tmux, and SandboxTest already walls off
  # XDG_STATE_HOME/SWITCHBOARD_STATE_DIR so the reporter and AgentState share one state dir.
  class CodexHookSmokeTest < SandboxTest
    def setup
      super
      skip "set SWITCHBOARD_CODEX_SMOKE=1 to run the real-codex smoke" unless ENV["SWITCHBOARD_CODEX_SMOKE"] == "1"
      skip "codex not on PATH" unless system("command -v codex >/dev/null 2>&1")
    end

    def test_global_hooks_fire_in_a_linked_worktree
      linked = linked_worktree_with_block
      log = path("events.log")
      log_events(log, %w[PreToolUse PostToolUse Stop]) # sandbox-only witnesses, appended to OUR block in the sandbox copy

      marker = "codex-smoke-#{rand(100_000)}"
      out, ran = run_codex(linked, "Run the shell command: echo #{marker}. Then stop.")
      unless ran
        # A config codex rejects is exactly the regression this smoke exists to catch: red,
        # never a skip. Only auth/network/timeout trouble skips.
        flunk "codex rejected the config: #{out[0, 400]}" if out.match?(CONFIG_ERROR)
        skip "codex run failed (auth/network/sandbox?) — #{out[0, 200]}"
      end

      assert_includes out, marker, "the tool actually ran in the linked worktree (PreToolUse/PostToolUse fired)"

      # The crux: the GLOBAL hook fired inside a LINKED worktree (the v0.39.0 per-worktree
      # path could not) and wrote a resting state where AgentState reads it.
      state = AgentState.new.scan([linked])[linked]
      assert_equal :done, state,
                   "global Stop reporter wrote 'done' for the LINKED worktree into the sandboxed state dir. " \
                   "state dir: #{Dir.glob(File.join(AgentState.state_dir, '*')).map { |f| File.read(f).chomp }.inspect}"

      # Direct evidence, not inference from the final dot: Stop ran, and after the tool.
      fired = File.exist?(log) ? File.readlines(log, chomp: true) : []
      assert_includes fired, "PostToolUse", "PostToolUse hook fired"
      assert_includes fired, "Stop", "Stop hook fired (the unified reporter/backstop)"
      assert_operator fired.index("PostToolUse"), :<, fired.rindex("Stop"), "Stop came after the tool"
      assert_includes fired, "PreToolUse", "PreToolUse hook fired"
      assert_operator fired.index("PreToolUse"), :<, fired.index("PostToolUse"), "thinking holds across the tool"
    end

    # Value: protects=the premise behind doctor's trust warning — codex runs NO untrusted
    # hook, so an unapproved block means dead dots; fails_when=codex starts running untrusted
    # hooks (doctor's warning would then mislead) or this case quietly bypasses trust;
    # why_new=the run above always bypasses trust; seam=none (live, opt-in); no_claim=that an
    # APPROVED block survives a reinstall without bypass (headless codex can't approve hooks;
    # pinned offline by the byte-identical and trust-carry tests in codex_hook_test)
    def test_untrusted_block_writes_no_state
      linked = linked_worktree_with_block
      log = path("events.log")
      log_events(log, %w[SessionStart PostToolUse Stop])

      # A token only the file holds (never the prompt), copied by the tool: the copy proves a tool
      # really ran — the model can't produce it by answering in text.
      token = format("%016x", rand(2**64))
      File.write(File.join(linked, "sb-token.txt"), token)
      out, ran = run_codex(linked, "Run the shell command: cp sb-token.txt sb-seen.txt. Then stop.", bypass_trust: false)
      unless ran
        flunk "codex rejected the config: #{out[0, 400]}" if out.match?(CONFIG_ERROR)
        skip "codex run failed (auth/network/sandbox?) — #{out[0, 200]}"
      end

      seen = File.join(linked, "sb-seen.txt")
      assert_equal token, File.exist?(seen) && File.read(seen), "the tool ran, so an untrusted hook had every chance to fire"
      assert_nil AgentState.new.scan([linked])[linked], "no reporter ran for an untrusted block"
      refute File.exist?(log), "no hook ran at all: #{File.exist?(log) && File.read(log)}"
    end

    private

    CONFIG_ERROR = /failed to load (bootstrap )?configuration|TOML parse error|invalid hook/i # codex 0.163's config-reject text; not a bare "config.toml" (paths show up in auth/trust errors too)

    # Sandbox CODEX_HOME = ONLY the real auth.json (so the run is authed against borrowed
    # credentials), then OUR block written fresh into it. Deliberately not the whole real
    # ~/.codex: copying the user's config.toml would carry their own [hooks] (the install
    # collision-guards on it), and we want to exercise our block in isolation. The real
    # ~/.codex is never touched. Returns a LINKED worktree of a fresh primary repo — the
    # exact case project-local hooks can't reach.
    def linked_worktree_with_block
      real_auth = File.join(Etc.getpwuid(Process.uid).dir, ".codex", "auth.json")
      skip "no real ~/.codex/auth.json to borrow for the run" unless File.exist?(real_auth)
      sandbox_home = path("codexhome")
      FileUtils.mkdir_p(sandbox_home)
      FileUtils.cp(real_auth, File.join(sandbox_home, "auth.json"))
      ENV["CODEX_HOME"] = sandbox_home

      assert_equal CodexHook.config_path, CodexHook.install_global, "global block written into the sandbox config"

      primary = temp_git_repo
      system("git", "-C", primary, "commit", "-q", "--allow-empty", "-m", "init")
      linked = path("linked")
      ok = system("git", "-C", primary, "worktree", "add", "-q", "-b", "smoke-linked", linked,
                  out: File::NULL, err: File::NULL)
      assert ok, "git worktree add created the linked worktree"
      linked
    end

    # Append a witness group (`echo <Event> >> log`) to each named event line of our block
    # in the SANDBOX config, so the run proves which hooks fired and in what order.
    def log_events(log, events)
      body = File.read(CodexHook.config_path)
      events.each do |event|
        witness = %({ hooks = [{ type = "command", command = #{CodexHook.toml_str("echo #{event} >> #{Shellwords.escape(log)}")} }] })
        body.sub!(/^(#{event} = \[.*)\]$/) { "#{Regexp.last_match(1)}, #{witness}]" } or flunk("no #{event} line in the block")
      end
      File.write(CodexHook.config_path, body)
    end


    # Drive codex headlessly in `repo`: bypass the interactive hook-trust prompt (unless
    # `bypass_trust: false`, the untrusted case — headless codex can't approve hooks), allow
    # tool use (workspace-write), keep reasoning cheap. Returns [combined_output, ok?].
    # Bounded so "needs network" never becomes "hangs the smoke layer".
    #
    # CODEX_HOME (the sandbox copy, set by the test) is inherited by the child, so codex
    # reads BOTH its borrowed auth and our global block from there — the real ~/.codex is
    # never consulted. HOME is briefly restored to the real one only as a belt-and-braces
    # for any HOME-relative path codex might still touch; the sandboxed
    # XDG_STATE_HOME/XDG_DATA_HOME stay inherited, which is what keeps the reporter writing
    # into the sandbox state dir AgentState reads.
    #
    # The child is spawned WITH cwd = repo (`chdir:`), NOT `codex -C repo`: switchboard
    # always launches the agent FROM the worktree root, and the reporter keys state by the
    # hook's `pwd -P` — so the cwd must be the worktree for the dot to land on it.
    #
    # CLAUDECODE / CLAUDE_CODE_SESSION_ID are UNSET for the child (env-hash-as-first-
    # array-element). This smoke simulates a TOP-LEVEL codex (the one switchboard launches
    # into a plain tmux shell, which carries neither marker); the #130 guard would otherwise
    # correctly suppress every reporter when this suite is itself run from inside a Claude
    # Code session. (That suppression is exactly what codex_hook_test's guard test asserts.)
    def run_codex(repo, prompt, bypass_trust: true)
      cmd = [{ "CLAUDECODE" => nil, "CLAUDE_CODE_SESSION_ID" => nil },
             "codex", "exec", prompt, *("--dangerously-bypass-hook-trust" if bypass_trust),
             "-s", "workspace-write", "-c", 'model_reasoning_effort="low"']
      saved_home = ENV["HOME"]
      ENV["HOME"] = Etc.getpwuid(Process.uid).dir
      io = IO.popen(cmd, err: %i[child out], chdir: repo)
      ENV["HOME"] = saved_home # child already spawned with real HOME; test stays sandboxed
      out = +""
      begin
        Timeout.timeout(240) { out << io.read }
      rescue Timeout::Error
        begin
          Process.kill("TERM", io.pid)
        rescue StandardError
          nil
        end
        return ["codex timed out after 240s", false]
      ensure
        io.close
      end
      [out, $?&.success?]
    rescue StandardError => e
      ENV["HOME"] = saved_home if saved_home
      ["#{e.class}: #{e.message}", false]
    end
  end
end
