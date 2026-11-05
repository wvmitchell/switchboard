# frozen_string_literal: true

require "json"

module Switchboard
  # What switchboard prints and records when an agent's session hook calls it. The installed
  # hooks name the `rename-nudge` and `monitoring-nudge` verbs, so those never change.
  #
  # Two hard contracts (a hook runs on the critical path of a session boundary): ALWAYS exit
  # 0, and print ONLY the JSON or nothing. A stray byte on stdout (a warning, a partial
  # object, a backtrace) can poison an agent even at exit 0, so each entry's whole body is
  # rescued to silence and nothing else writes stdout.
  #
  # The workspace comes from the hook's cwd, not Dir.pwd, which the hook process doesn't
  # reliably inherit. The decisions live in the pure RenameNudge, DispatchNudge and
  # MonitoringNudge; this file wires the config, cwd and event payload around them.
  module HookCommands
    module_function

    # Agent hook entry (#92): nudge the agent to `switchboard rename` while this workspace
    # still has a generated placeholder name and `auto_rename` is on. Two events dispatch
    # here, selected by `--stop`:
    #   • SessionStart (no flag) — print an `additionalContext` instruction (the soft
    #     plant), gated on the event source. Rides alongside the sh state reporter. The
    #     agent-dispatch instruction (DispatchNudge) joins the same payload, so it reaches
    #     every hooked worktree with no new hook entry; each piece is built under its own
    #     rescue, so a fault in one never drops the other.
    #   • Stop (`--stop`) — see rename_nudge_stop: this command IS the Stop state reporter
    #     AND the backstop (the sh reporter is off the Stop event, hook_file.rb), so it can
    #     report `thinking` when it blocks instead of a racing `done`.
    def rename_nudge(args = [])
      payload = parse_hook_stdin
      cwd = hook_cwd(payload)

      return rename_nudge_stop(payload, cwd) if args.include?("--stop")

      config = Config.new
      wt = Model.workspace_at(config, cwd)
      return if wt.nil? || wt.primary # not a managed worktree, or the trunk checkout

      pieces = [rename_piece(config, wt, payload["source"]), dispatch_piece(config, wt, payload["source"])].compact
      puts RenameNudge.session_start_json(pieces.join("\n\n")) unless pieces.empty?
    rescue StandardError
      nil # a hook must never error a session boundary; emit nothing on any fault
    end

    # SessionStart / SessionEnd hook entry (the Layer-2 background-presence handler, wired
    # by HookFile.command_entries). Makes "monitoring" a per-session declaration: clears
    # this worktree's marker on a new/resumed/forked session boundary — so a resumed agent
    # (its old loop dead) must re-declare — and (re)plants the self-report nudge. The clear
    # and the nudge have DIFFERENT source gates on purpose (MonitoringNudge::CLEARS_ON /
    # NUDGES_ON): `compact` and `clear` do NOT clear here (compaction continues the same
    # process; /clear's SessionEnd already dropped the marker) but DO re-nudge (both drop the
    # original instruction from context). Gated on `background_presence`.
    def monitoring_nudge(args = [])
      payload = parse_hook_stdin
      config = Config.new

      wt = Model.workspace_at(config, hook_cwd(payload))
      return if wt.nil? || wt.primary
      return unless config.background_presence_for(wt.project)

      if args.include?("--end")
        Monitoring.clear(wt.path) # SessionEnd: the agent is gone, so it can't still be monitoring
        return
      end

      source = payload["source"]
      Monitoring.clear(wt.path) if MonitoringNudge.clears_on?(source) # new/resumed/forked process only
      puts MonitoringNudge.context_json if MonitoringNudge.nudges_on?(source) # + clear/compact: re-teach
    rescue StandardError
      nil # a hook must never error a session boundary; emit nothing on any fault
    end

    def rename_piece(config, wt, source)
      leaf = File.basename(wt.path)
      return nil unless RenameNudge.decide(auto_rename: config.auto_rename_for(wt.project),
                                           placeholder: Placeholder.generated?(leaf), source: source)

      RenameNudge.message(leaf)
    rescue StandardError
      nil
    end

    def dispatch_piece(config, wt, source)
      return nil unless DispatchNudge.decide(enabled: config.agent_dispatch_for(wt.project), source: source)

      # The env var lives as long as the agent. Resume, fork and compaction keep the
      # conversation that opened on the other agent's brief, so the label stays; only /clear
      # starts fresh, where the next first message is the user's own.
      DispatchNudge.message(brief_from_agent: ENV["SWITCHBOARD_BRIEF_FROM"] == "cli" && source != "clear")
    rescue StandardError
      nil
    end

    # The Stop event, unified: report the agent state ourselves (the job the sh reporter
    # does on every OTHER event) AND, when gated, block. Stop hooks run in parallel with
    # no ordering, so we can't have a sibling sh reporter writing `done` while we block —
    # it could record a forced-to-continue agent as finished and ring a false completion.
    # So we report `thinking` when blocking (accurate — the agent IS about to keep going)
    # and `done` otherwise. State is ALWAYS reported (every hooked worktree, even when not
    # a placeholder / auto_rename off), since the dot depends on it. `stop_block_leaf` is
    # fully rescued ⇒ any fault degrades to a plain `done`, never trapping the agent.
    def rename_nudge_stop(payload, cwd)
      leaf = stop_block_leaf(payload, cwd)
      report_stop_state(leaf ? "thinking" : "done")
      return puts(RenameNudge.stop_json(leaf)) if leaf

      stamp_first_turn(cwd)
    end

    # A dispatched task's first turn just ended (a real Stop, not the rename block —
    # that one reports "thinking"), so its Creation record can ping. Matched by
    # realpath: the agent's cwd keeps the pre-rename path. Hook-less records never
    # reach here, and one whose agent hasn't started, or that's already stamped or
    # bare, no-ops (Creation.stamp_first_turn).
    def stamp_first_turn(cwd)
      top = Git.toplevel(File.expand_path(cwd)) or return
      rec = Creation.for_path(top)
      Creation.stamp_first_turn(rec["id"]) if rec
    rescue StandardError
      nil
    end

    # The placeholder leaf this Stop should block on, or nil if it should NOT block (the
    # common case — and the safe default on any fault, so a glitch never blocks). The config
    # loads in here, not in rename_nudge, so a fault loading it still reports the state.
    def stop_block_leaf(payload, cwd)
      config = Config.new
      wt = Model.workspace_at(config, cwd)
      return nil if wt.nil? || wt.primary

      leaf = File.basename(wt.path)
      return nil unless RenameNudge.decide_stop(auto_rename: config.auto_rename_for(wt.project),
                                                placeholder: Placeholder.generated?(leaf),
                                                stop_hook_active: payload["stop_hook_active"])

      leaf
    rescue StandardError
      nil
    end

    # Report agent state by running the SAME sh reporter every other event uses. The
    # child inherits our cwd (the hook's invocation dir), so its `pwd -P`/cksum key
    # matches the file the other events write — no Ruby-side key reproduction, and its
    # stdout is suppressed so only our block JSON (if any) reaches the agent.
    def report_stop_state(state)
      system(HookFile.script_path, state, in: File::NULL, out: File::NULL, err: File::NULL)
    rescue StandardError
      nil
    end

    # The event JSON from stdin, or {} on anything empty/unreadable.
    def parse_hook_stdin
      raw = $stdin.read
      raw.to_s.strip.empty? ? {} : (JSON.parse(raw) || {})
    rescue StandardError
      {}
    end

    def hook_cwd(payload)
      cwd = payload["cwd"]
      cwd.is_a?(String) && !cwd.strip.empty? ? cwd : Dir.pwd
    end
  end
end
