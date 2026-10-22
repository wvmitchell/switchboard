# frozen_string_literal: true

require "tempfile"
require "shellwords"

module Switchboard
  # Creates a new worktree (and its branch) for a project under the configured
  # worktree root, in the background: `reserve` picks a placeholder for the sidebar,
  # the detached worker (`work`) builds the worktree and its session, and the launcher
  # typed into that session (`launch`) runs setup and the agent. Lifecycle: creation.rb.
  module Creator
    module_function

    PLACEHOLDER_TRIES = 5 # bounded retries past a generated name already taken

    # Wire the per-worktree agent hooks (agent-state reporter + the #92 self-naming nudge
    # + the background-presence monitoring nudge/clears), scoped to this worktree, never
    # global. Enabled when ANY of dots / auto_rename / background_presence is on — each
    # resolved *per project* so a project that opts into just one (with the global off)
    # still gets the hook its runtime nudge needs. Best-effort: a hook-wiring hiccup must
    # never sink an otherwise-good worktree.
    def enable_hooks(config, project_name, dest)
      if config.agent_state_hooks? || config.auto_rename_for(project_name) ||
         config.background_presence_for(project_name)
        AgentHooks.enable(dest)
      end
      dest
    rescue StandardError
      dest
    end

    # --- background dispatch (`n` → task → ↵) -----------------------------------------
    #
    # The sidebar only RESERVES a name and writes a Creation record, then spawns
    # `switchboard create-workspace <id>` (Creator.work) and returns — nothing slow
    # touches the input loop. The worker builds the worktree and a DETACHED session
    # whose only typed line is `switchboard launch <dest>` (Creator.launch), which runs
    # setup and the agent in the pane. See creation.rb for the lifecycle.

    CLAIM_DEADLINE = 60 # worker waits this long for the launcher to start (slow shell rc)
    LAUNCH_GRACE = 5    # an agent that exits sooner never really launched
    FETCH_DEADLINE = 60 # a stalled fetch must not pin the row on ◌ (it's best-effort anyway)
    ADD_DEADLINE = 600  # generous: a big checkout (LFS, hooks) is legitimately slow
    CLAIM_POLL = 0.25
    SHELLS = %w[zsh bash fish sh dash ksh tcsh].freeze

    # A placeholder name free of dirs, branches AND in-flight dispatches (whose dirs
    # don't exist yet), so two quick `n`s — or two panes — can't pick the same one.
    # Returns [name, dest] or nil.
    def reserve(config, project_name)
      project = config.project(project_name) or return nil
      root = File.join(config.worktree_root, sanitize(project_name))
      pending = Creation.all.map { |r| r["path"] }
      PLACEHOLDER_TRIES.times do
        name = Placeholder.generate
        dest = File.join(root, name)
        # File.symlink? too: a rename leaves a bridge at the old placeholder path, and once
        # its target is deleted the dangling link reads as !exist? yet still blocks git.
        next if File.exist?(dest) || File.symlink?(dest) || pending.include?(dest) ||
                Git.branch_exists?(project["path"], branch_for(config, name)) ||
                stale_session?(project_name, dest) # a leftover sb/ session would swallow the launch line

        return [name, dest]
      end
      nil
    end

    # Reserve a name and write the record that claims it as ONE step under the project's
    # reservation lock, so two panes can never hand out the same placeholder. The
    # record, or :no_name / :no_record.
    def dispatch(config, project_name, task)
      Creation.with_project_lock(project_name) do
        name, dest = reserve(config, project_name)
        next :no_name unless dest

        Creation.create(project: project_name, name: name, path: dest, task: task) || :no_record
      end
    end

    def stale_session?(project_name, dest)
      Tmux.has_session?(Tmux.session_name(Worktree.new(project: project_name, path: dest)))
    end

    # The detached worker. Owns the record (pid + start time) until the launcher claims
    # it, so GC can tell a slow build from a dead one; aborts the moment any of its
    # transitions no-ops (canceled by quit, or failed by GC).
    def work(config, id)
      rec = Creation.find(id) or return
      return unless Creation.transition(id, from: :queued, to: :building, **Creation.owner_fields)

      project = config.project(rec["project"])
      return Creation.mark_failed(id, "worktree_add", "unknown project") unless project

      Git.fetch_base(project["path"], project["base_ref"], timeout: FETCH_DEADLINE) # best-effort: offline builds off the last fetch
      return unless Creation.find(id)&.dig("state") == "building" # canceled during a slow fetch

      name, dest, err = add_reserved(config, project, rec)
      unless dest
        # A tree the rollback couldn't remove is still an un-set-up tree on disk.
        cur = Creation.find(id)
        Creation.update(id, worktree_added: true) if cur && File.exist?(cur["path"].to_s)
        return Creation.mark_failed(id, "worktree_add", err)
      end

      unless Creation.update(id, unless_state: %w[canceled failed], name: name, path: dest, worktree_added: true)
        # Canceled mid-add. A tree we can't prove untouched stays — then record that it
        # exists, so GC keeps the guard that re-enters it as a plain shell.
        Creation.update(id, name: name, path: dest, worktree_added: true) unless discard(config, project, name, dest)
        return
      end

      enable_hooks(config, rec["project"], dest) # dots/nudges for ANY agent, typed by hand or not
      # A first guess, so a setup step running claude doesn't chime; the launcher
      # decides for real from the command it runs.
      Creation.update(id, hooked: hooked?(config, rec["project"], dest))
      unless open_session(id, rec["project"], dest)
        # canceled before the session existed: like mid-add, nothing ever ran in it
        discard(config, project, name, dest) if Creation.find(id)&.dig("state") == "canceled"
        return
      end

      await_claim(id)
      # Canceled before the launcher claimed it (quit killed the session first): nothing
      # ran there either. A claimed build is the launcher's, so only our own record.
      cur = Creation.find(id)
      discard(config, project, name, dest) if cur&.dig("state") == "canceled" && cur["owner_pid"] == Process.pid
    end

    # git worktree add for the reserved name, retrying past a dir/branch collision with
    # a fresh placeholder (the row re-labels itself). [name, dest, nil] or [nil, nil, msg].
    #
    # A collision is what existed BEFORE the add. git cuts the branch before checkout, and
    # a failing post-checkout hook still leaves a full tree, so "it exists now" would read
    # every other failure as a collision and leak a branch (or a whole un-set-up tree)
    # per retry. Anything else is undone and fails with git's message.
    def add_reserved(config, project, rec)
      name = rec["name"]
      dest = rec["path"]
      err = nil
      PLACEHOLDER_TRIES.times do
        branch = branch_for(config, name)
        clash = File.exist?(dest) || File.symlink?(dest) || Git.branch_exists?(project["path"], branch)
        ok, err = add_worktree(config, project, name, dest, project["base_ref"]) unless clash
        return [name, dest, nil] if ok

        unless clash
          undo_add(project, dest, branch)
          break
        end

        # Under the same reservation lock as `n`: the new name must dodge other in-flight
        # dispatches too, or two records would share a path and the launcher claim the
        # wrong one.
        name, dest = Creation.with_project_lock(rec["project"]) do
          picked = reserve(config, rec["project"])
          picked && Creation.update(rec["id"], name: picked[0], path: picked[1]) ? picked : nil
        end
        break unless dest
      end
      [nil, nil, err || "no free workspace name"]
    end

    # Roll back a failed add that we started from a clean slate: an un-set-up tree left
    # behind would re-enter with the agent. Only a tree on OUR branch is ours to remove
    # (a racing writer's isn't); -D refuses a branch still checked out anywhere.
    def undo_add(project, dest, branch)
      if File.exist?(dest) && Git.current_branch(dest) == branch
        Git.remove_worktree(project["path"], dest, force: true, locked: true)
      end
      Git.delete_branch(project["path"], branch, force: true) if Git.branch_exists?(project["path"], branch)
    end

    # `--no-track` so a branch cut from a remote-tracking base (origin/main) does NOT
    # inherit it as an upstream — a configured upstream means a real `git push -u`, the
    # signal rename's `pushed?` gate uses to leave a branch alone (#94). Returns
    # [ok, git's last line] so a failure can say why on the ✘ row.
    #
    # Bounded and prompt-free like the fetch: a stalled LFS smudge or checkout hook must
    # not pin the row on ◌ with no way out but `d`.
    def add_worktree(config, project, name, dest, base, timeout: ADD_DEADLINE)
      Tempfile.create("sb-add") do |log|
        pid = Process.spawn({ "GIT_TERMINAL_PROMPT" => "0" },
                            "git", "-C", project["path"], "worktree", "add", "--no-track",
                            "-b", branch_for(config, name), dest, base,
                            in: File::NULL, out: log, err: log, pgroup: true)
        status = ProcessIdentity.wait_within(pid, timeout)
        unless status
          ProcessIdentity.terminate_group(pid)
          return [false, "timed out after #{timeout}s"]
        end
        return [true, nil] if status.success?

        # Only a failure is read, and binary-safe: git's text (a commit subject, a hook's
        # output) can be any bytes in any locale, and a raise here would undo a good add.
        log.rewind
        last = log.read.b.lines.last.to_s.force_encoding(Encoding::UTF_8).scrub("?")
        [false, last.strip.sub(/\Afatal: /, "")]
      end
    rescue StandardError => e
      [false, e.message]
    end

    # Undo a worktree this worker just made — forcing only once it's PROVEN untouched
    # (clean, nothing committed past its base): a checkout hook, another tool, or you may
    # already have written there. Anything else stays put — the canceled record keeps
    # re-entry on a plain shell until you delete it. True when it was removed.
    def discard(config, project, name, dest)
      return false unless untouched?(dest, project["base_ref"])

      Git.remove_worktree(project["path"], dest, force: true)
      Git.delete_branch(project["path"], branch_for(config, name), force: true)
      true
    end

    def untouched?(dest, base)
      Git.clean?(dest) && Git.commits_since(dest, base)&.zero?
    end

    def branch_for(config, name)
      [config.branch_prefix, name].compact.join("/")
    end

    # The cancel check and new-session run under the record lock, so quit's cancel and
    # this create serialize: either we see canceled and stop, or the session exists
    # before quit goes looking for sessions to kill (D17).
    #
    # Never onto a server that's gone: this daemon outlives a `tmux kill-server`, and
    # new-session on its stale $TMUX socket would start a fresh, headless server and
    # run the agent there with nobody attached.
    def open_session(id, project_name, dest)
      name = Tmux.session_name(Worktree.new(project: project_name, path: dest))
      ran = false
      created = false
      gone = false
      Creation.mutate(id) do |cur|
        next nil unless cur["state"] == "building"

        ran = true
        gone = cur["server"] && !File.socket?(cur["server"])
        created = Tmux.ensure_session(name, dest, launch_line(dest)) unless gone
        cur
      end
      return false unless ran # canceled or failed under us

      unless created
        Creation.mark_failed(id, "session", gone ? "the tmux server is gone" : nil, from: "building")
        return false
      end

      Tmux.ensure_sidebar(name)
      Tmux.broadcast_warm
      true
    end

    # The ONE line typed into the new pane: absolute, escaped, shell-neutral (fish too).
    def launch_line(dest)
      bin = ENV["SWITCHBOARD_BIN"] || "switchboard"
      # Leading space: kept out of history under HIST_IGNORE_SPACE / ignorespace, so ↑
      # recalls your own commands, not a launcher that would no-op if re-run.
      " #{Shellwords.escape(bin)} launch #{Shellwords.escape(dest)}"
    end

    def await_claim(id, deadline: CLAIM_DEADLINE, poll: CLAIM_POLL, clock: -> { Time.now })
      stop = clock.call + deadline
      while clock.call < stop
        return true unless Creation.find(id)&.fetch("state", nil) == "building"

        sleep poll
      end
      Creation.mark_failed(id, "didnt_start", from: "building")
      false
    end

    # Will a Stop hook report this agent's first turn? Only a plain `claude` command whose
    # per-worktree hook really got written (enable_hooks is best-effort, so check the
    # file, not the call). Codex's trust can't be verified (D18) and anything else has no
    # hook, so those ping when the agent launches instead.
    def hooked?(config, project_name, dest)
      hooked_command?(config.session_command_for(project_name), dest)
    end

    def hooked_command?(cmd, dest)
      agent_program(cmd) == "claude" && ClaudeHook.enabled?(dest)
    end

    # The program a session_command runs: first word after any `VAR=v` / `env` prefix.
    def agent_program(cmd)
      return nil unless cmd.is_a?(String)

      words = split_words(cmd).drop_while { |w| w == "env" || w.match?(/\A\w+=/) }
      words.first && File.basename(words.first)
    end

    def split_words(cmd)
      Shellwords.split(cmd)
    rescue ArgumentError # unbalanced quotes: fall back to whitespace words
      cmd.split
    end

    # What the launcher runs for the agent: [command or nil, notice or nil]. The task
    # travels in $SWITCHBOARD_TASK, never interpolated, so quotes/$/newlines are safe in
    # every shell. Auto-append only for a simple claude/codex command — aider's positional
    # args are FILES, and `claude; echo` would append to echo — else `{task}` opts in.
    def agent_command(cmd, task)
      unless cmd.is_a?(String) && !cmd.strip.empty?
        return [nil, task.empty? ? nil : Creation.notice(:no_agent)]
      end
      return [substitute_task(cmd, !task.empty?), nil] if cmd.include?("{task}")
      return [cmd, nil] if task.empty?
      return ["#{cmd.strip} \"$SWITCHBOARD_TASK\"", nil] if appendable?(cmd)

      [cmd, Creation.notice(:task_not_sent)]
    end

    # Auto-append only to a command made of plain words — an allowlist, not a denylist
    # of shell syntax: a trailing newline (a YAML block scalar), a `# comment`, `&`, a
    # redirect, quotes or `$(…)` would each put the appended task somewhere else (a
    # newline makes it run as its own COMMAND after the agent exits). Anything fancier
    # opts in with `{task}`, or gets the "task not sent" notice.
    def appendable?(cmd)
      %w[claude codex].include?(agent_program(cmd)) && cmd.strip.match?(%r{\A[\w@%+=:,./ -]+\z})
    end

    # Replace each `{task}` with the task variable, quoted to suit where it sits: bare →
    # "$SWITCHBOARD_TASK"; inside "…" → $SWITCHBOARD_TASK (already quoted); inside '…' →
    # close, splice the double-quoted variable, reopen. So the task is one argument to
    # the command the pane's shell runs, in sh, bash, zsh and fish alike. That shell
    # expands it: a command that hands its text to ANOTHER shell (`bash -lc '…'`, `ssh
    # host …`) re-parses the task as code, so such a command must reference
    # "$SWITCHBOARD_TASK" itself instead of {task}. No task → nothing, and a quoted
    # `'{task}'` drops its now-empty quotes rather than pass an empty argument.
    def substitute_task(cmd, present)
      out = +""
      quote = nil
      i = 0
      while i < cmd.length
        if cmd[i, 6] == "{task}"
          if !present && quote && out.end_with?(quote) && out[-2] != "\\" && cmd[i + 6] == quote
            out.chop!
            quote = nil
            i += 7
            next
          end
          out << task_ref(quote) if present
          i += 6
          next
        end
        c = cmd[i]
        if c == "\\" && quote != "'"
          out << cmd[i, 2]
          i += 2
          next
        end
        quote = if quote.nil? && %w[' "].include?(c) then c
                elsif quote == c then nil
                else quote
                end
        out << c
        i += 1
      end
      out
    end

    def task_ref(quote)
      case quote
      when '"' then "$SWITCHBOARD_TASK"
      when "'" then %('"$SWITCHBOARD_TASK"')
      else '"$SWITCHBOARD_TASK"'
      end
    end

    # The launcher, typed into the new pane. It claims the record (taking ownership from
    # the worker), runs setup, then runs the agent as its CHILD so a launch-time crash
    # becomes a ✘ instead of a false "ready" (D13). Returns the exit status for the pane.
    def launch(config, dest, out: $stdout, grace: LAUNCH_GRACE)
      rec = Creation.for_path(dest)
      claimed = rec && Creation.transition(rec["id"], from: :building, to: :launching, **Creation.owner_fields)
      unless claimed
        notify_unclaimed(out, rec && Creation.find(rec["id"]))
        return 0
      end

      # A Ruby handler, not "IGNORE": an ignored signal is inherited across exec, and the
      # agent must still get its own ^C. The handler is reset in the child.
      %w[INT QUIT].each { |sig| trap(sig) {} }
      id = rec["id"]
      # A config we can't read can't say what setup to run; treating that as "no setup"
      # would certify an un-set-up tree and let a later re-entry start the agent on it.
      # Same for a setup it reads but can't run.
      if config.load_error || !config.project(rec["project"]) || config.setup_invalid?(rec["project"])
        Creation.mark_failed(id, "config", from: "launching")
        notify_pane(out, Creation.long_reason("reason" => "config"))
        return 1
      end

      ENV["SWITCHBOARD_TASK"] = rec["task"].to_s # setup sees it too (D10)
      status = run_setup(config, rec["project"], dest)
      unless status.nil? || status.zero?
        Creation.mark_failed(id, "setup", status, from: "launching")
        notify_pane(out, Creation.long_reason(Creation.find(id) || rec))
        return status
      end

      cmd, note = agent_command(config.session_command_for(rec["project"]), rec["task"].to_s)
      # The ONE go-ahead, atomically gated on the build still launching: a quit/d during
      # setup (canceled), a GC that dropped the record, or a failure all mean no agent.
      # `hooked` is settled here from the command that will actually run (the config may
      # have changed since the worker looked); an undelivered task never ends a turn.
      unless Creation.authorize_launch(id, hooked: note.nil? && hooked_command?(cmd, dest))
        notify_unclaimed(out, Creation.find(id), gone: :canceled)
        return 0
      end

      notify_pane(out, note) if note
      return run_agent(id, cmd, dest, out, grace: grace) if cmd

      Creation.transition(id, from: :launching, to: :ready) # no agent configured: a plain shell is ready
      0
    end

    def run_setup(config, project_name, dest)
      script = config.worktree_creation_command_for(project_name) or return nil
      env = { "SWITCHBOARD_PROJECT_PATH" => config.project(project_name)&.fetch("path", nil),
              "SWITCHBOARD_WORKTREE_PATH" => dest }.compact
      system(env, "sh", "-ec", script, chdir: dest)
      $?.exitstatus || 1
    end

    def run_agent(id, cmd, dest, out, grace: LAUNCH_GRACE)
      pid = Process.spawn(pane_shell, "-i", "-c", cmd, chdir: dest)
      status = ProcessIdentity.wait_within(pid, grace)
      if status&.success?
        # A clean exit inside the grace is a hand-off (a wrapper that starts the agent
        # elsewhere) or a one-shot that finished — not a launch failure.
        Creation.transition(id, from: :launching, to: :ready)
        agent_exited(id, status)
        return 0
      elsif status
        # No-ops when a Stop already stamped this turn done: then it finished.
        if Creation.mark_failed(id, "agent_exit", status.exitstatus || 1, from: "launching")
          notify_pane(out, Creation.long_reason(Creation.find(id) || {}))
        end
        return status.exitstatus || 1
      end

      Creation.transition(id, from: :launching, to: :ready)
      _, status = Process.wait2(pid)
      agent_exited(id, status)
      status.exitstatus || 0
    end

    # A hooked task still `ready` when its agent exits never finished a first turn: no
    # Stop will ever ping, so the exit does (and ends its hold on the row's chime).
    def agent_exited(id, status)
      rec = Creation.find(id)
      return unless rec && rec["hooked"] && !rec["task"].to_s.empty?

      if status.success? then Creation.transition(id, from: :ready, to: :turn_done)
      else Creation.mark_failed(id, "agent_exit", status.exitstatus || 1, from: "ready")
      end
    end

    # The pane's own interactive shell — the launcher's parent — so rc aliases and
    # functions resolve exactly as when the command used to be typed in (D14).
    def pane_shell
      comm = `ps -o comm= -p #{Process.ppid} 2>/dev/null`.strip.delete_prefix("-")
      exe = shell_path(comm) if SHELLS.include?(File.basename(comm))
      exe || ENV["SHELL"].then { |s| s if s && SHELLS.include?(File.basename(s)) } || "sh"
    end

    def shell_path(comm)
      return comm if comm.start_with?("/") && File.executable?(comm)

      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |d| File.join(d, File.basename(comm)) }
         .find { |p| File.executable?(p) }
    end

    def notify_pane(out, message)
      out.puts "\e[2m#{message}\e[0m"
      true
    end

    # Why the launcher won't go on: canceled, or already failed (e.g. GC read the build
    # as dead). No record at all is quiet at the claim (a re-typed line) but, after
    # setup, means GC dropped a canceled build (`gone:`).
    def notify_unclaimed(out, rec, gone: nil)
      case rec&.dig("state")
      when "canceled" then notify_pane(out, Creation.notice(:canceled))
      when "failed" then notify_pane(out, Creation.long_reason(rec))
      when nil then notify_pane(out, Creation.notice(gone)) if gone
      end
    end

    # Filesystem- and branch-safe: spaces become dashes, the char class drops
    # anything exotic, and ".", ".." and empty path segments are stripped so a
    # name can never climb out of (or absolute-jump around) the worktree root via
    # File.join — "../../etc" sanitizes to "etc", "/tmp/x" to "tmp/x", "." to "".
    def sanitize(name)
      cleaned = name.to_s.strip.gsub(/\s+/, "-").gsub(%r{[^\w./-]}, "")
      cleaned.split("/").reject { |seg| seg.empty? || seg == "." || seg == ".." }.join("/")
    end
  end
end
