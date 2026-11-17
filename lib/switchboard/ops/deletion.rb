# frozen_string_literal: true

require "fileutils"
require "securerandom"
require "shellwords"

module Switchboard
  # `switchboard delete`: remove a workspace and leave nothing switchboard owns behind,
  # safely enough for an agent to run unattended. Every check runs before anything changes
  # (a refusal changes nothing); then the receipt claims it, the session closes, the
  # checks run again, git removes the folder, and only once git no longer lists it does
  # `forget` drop its name, branches, record and every store entry. The sidebar's reaper
  # shares `forget` through Workspaces.remove!. A crash at any point leaves a receipt the
  # next delete (or prune) finishes.
  module Deletion
    ID = /\A\d{14}-\h{6}\z/
    TOKEN_FILE = "switchboard-creation"
    DOCS = "reference-cli.md#delete-"
    MAX_DETAIL = 20
    SIDEBAR_WAIT = 2.0
    RESUME_EXCEPT = %i[pending_delete delete_receipt creation names].freeze

    EXIT = {
      "not-found" => 1, "ambiguous" => 2, "names-unreadable" => 3,
      "primary" => 4, "inside" => 4, "not-yours" => 4, "building" => 4, "locked" => 4, "deleting" => 4,
      "listing-failed" => 4, "other-server" => 4, "tmux-unknown" => 4,
      "dirty" => 5, "unpushed" => 5, "branches-unknown" => 5, "busy" => 5,
      "remove-failed" => 6, "partial" => 7, "session-alive" => 8, "changed-during-delete" => 8,
      "usage" => 64, "failed" => 70
    }.freeze
    FORCEABLE = %w[dirty unpushed branches-unknown busy].freeze

    # token nil is success. lines: the plan (dry run) or what was removed and kept.
    Result = Struct.new(:token, :what, :changed, :fix, :details, :lines, keyword_init: true) do
      def ok? = token.nil?
      def exit_code = ok? ? 0 : EXIT.fetch(token)
    end

    # Everything preflight learned, captured before anything goes (the realpath stops
    # resolving once the folder is gone).
    Target = Struct.new(:project, :repo, :base, :path, :real, :name, :rec, :branches, :sessions,
                        :sidebars, :head, :force, keyword_init: true)

    module_function

    def run(config, name: nil, creation: nil, force: false, dry_run: false)
      return usage("name a workspace, or pass --creation <id>") if name.to_s.empty? && creation.nil?
      return usage("--creation takes the id `switchboard new` printed, like 20261116135217-a1b2c3") if creation && !creation.match?(ID)

      status, map, err = Names.read_all
      unless status == :ok
        return refuse("names-unreadable", "can't read the names store #{map}: #{err}", fix: "fix the permissions of #{map}, then retry")
      end

      listed = listings(config)
      return refuse("listing-failed", "couldn't list #{listed}'s worktrees", fix: "run `git worktree list` in #{listed} to see why, then retry") if listed.is_a?(String)

      # A live workspace always wins; only a name or record that no longer resolves can
      # mean a delete that stopped after its folder (or record) was gone.
      target = resolve(config, listed, name, creation)
      if target.is_a?(Result)
        return target unless %w[not-found not-yours].include?(target.token)

        interrupted = interrupted_for(listed, name, creation)
        return interrupted || target unless interrupted.is_a?(Hash)

        if DeleteReceipt.owner_alive?(interrupted)
          return refuse("deleting", "another delete of #{interrupted['path']} is running (pid #{interrupted['owner_pid']})",
                        fix: "retry at the next check (a dead owner's delete is taken over automatically)")
        end
        return dry_run ? Result.new(lines: ["would finish an interrupted delete of #{interrupted['path']}"]) : resume(interrupted)
      end

      target.force = force
      refusal = preflight(target)
      return refusal if refusal
      return Result.new(lines: plan_lines(target)) if dry_run

      execute(target)
    rescue StandardError => e
      crashed(e, target)
    end

    # --- resolution ---------------------------------------------------------------

    # { project name => [{ path:, real:, branch: }] } from strict listings, or the name of a
    # project whose listing failed (a failed listing could hide a second match).
    def listings(config)
      config.projects.each_with_object({}) do |p, out|
        next unless p["path"] && Dir.exist?(p["path"])

        trees = Git.worktrees(p["path"], strict: true)
        return p["name"] unless trees

        out[p["name"]] = trees.reject { |w| w[:bare] }.map { |w| w.merge(real: Paths.real_or_self(w[:path])) }
      end
    end

    # The receipt of a delete that stopped once git no longer listed its workspace, matched
    # by record id or by name; nil when none, a refusal when the name matches several.
    def interrupted_for(listed, name, creation)
      gone = DeleteReceipt.all.reject { |r| listed.values.flatten.any? { |w| w[:real] == r["real"] } }
      hits = gone.select do |r|
        next r["record"] == creation if creation

        project, leaf = name.include?("/") ? name.split("/", 2) : [nil, name]
        (project.nil? || r["project"] == project) && [r["name"], File.basename(r["path"])].include?(leaf)
      end
      return hits.first if hits.size <= 1

      refuse("ambiguous", "#{name} matches several interrupted deletes", fix: "name it as <project>/<name>",
                                                                        details: hits.map { |r| "#{r['project']}/#{r['name']}" })
    end

    def resolve(config, listed, name, creation)
      rec = nil
      if creation
        rec = Creation.find(creation)
        return refuse("not-yours", "no record #{creation} (already deleted, or never yours)", fix: "don't fall back to deleting by name; ask a human") unless rec
      end
      hits = name.to_s.empty? ? by_record(config, listed, rec) : by_name(config, listed, name)
      return refuse("not-found", "no workspace called #{name || creation}", fix: "check `switchboard path <project>/<name>`") if hits.empty?
      if hits.size > 1
        return refuse("ambiguous", "#{name} is in several projects", fix: "name it as <project>/<name>",
                                                                     details: hits.map { |t| "#{t.project}/#{t.name}" })
      end

      target = hits.first
      if target.real == Paths.real_or_self(target.repo)
        return refuse("primary", "#{target.path} is #{target.project}'s own checkout, not a workspace", fix: "ask a human")
      end

      rec ||= Creation.for_path(target.real)
      if creation
        mismatch = rec["project"] != target.project || Paths.real_or_self(rec["path"].to_s) != target.real
        return refuse("not-yours", "record #{creation} built #{rec['project']}/#{File.basename(rec['path'].to_s)}, not #{target.path}", fix: "don't fall back to deleting by name; ask a human") if mismatch
        return refuse("not-yours", "record #{creation} predates delete --creation", fix: "ask a human") if rec["token"].to_s.empty?
        return refuse("not-yours", "#{target.path} isn't the tree record #{creation} built", fix: "don't fall back to deleting by name; ask a human") unless token_matches?(target.path, rec)
      end
      target.rec = rec
      target
    end

    def by_name(config, listed, arg)
      project, name = arg.include?("/") ? arg.split("/", 2) : [nil, arg]
      targets(config, listed).select do |t|
        (project.nil? || t.project == project) && [t.name, File.basename(t.path)].include?(name)
      end.uniq(&:real)
    end

    def by_record(config, listed, rec)
      real = Paths.real_or_self(rec["path"].to_s)
      targets(config, listed).select { |t| t.project == rec["project"] && t.real == real }
    end

    def targets(config, listed)
      listed.flat_map do |project, trees|
        p = config.project(project)
        trees.map do |w|
          wt = Worktree.new(project: project, path: w[:path], branch: w[:branch])
          Target.new(project: project, repo: p["path"], base: p["base_ref"], path: w[:path], real: w[:real], name: wt.display_name)
        end
      end
    end

    # The live tree carries the token its record was stamped with: a tree re-created at
    # the same path can't, since git removes the whole admin dir with the worktree.
    def token_matches?(path, rec)
      admin = Git.admin_dir(path) or return false
      File.read(File.join(admin, TOKEN_FILE)).strip == rec["token"].to_s
    rescue StandardError
      false
    end

    # --- preflight ----------------------------------------------------------------

    # nil when it may proceed; otherwise the refusal. Changes nothing.
    def preflight(t)
      sessions = Tmux.sessions_strict
      return refuse("tmux-unknown", "tmux is running but couldn't list its sessions", fix: "check `tmux ls`, then retry") if sessions.nil?

      t.sessions = sessions.select { |s| s[:path] && Paths.real_or_nil(s[:path]) == t.real }
      panes = t.sessions.map { |s| Tmux.session_panes(s[:id]) }
      return refuse("tmux-unknown", "tmux couldn't list the panes of #{t.name}'s session", fix: "check `tmux ls`, then retry") if panes.any?(&:nil?)

      panes = panes.flatten
      t.sidebars = panes.select { |p| p[:sidebar] }.map { |p| [p[:pid], ProcessIdentity.start_of(p[:pid])] }
      inside = inside?(t, panes)
      return refuse("inside", "you're inside #{t.name} (#{inside})", fix: "run it from another workspace or a shell outside this one, or press d in the sidebar") if inside

      server = t.rec && t.rec["server"]
      if server && server != Creation.current_server
        return refuse("other-server", "#{t.name} was made on the tmux server #{server}", fix: "run the same command from a shell inside that tmux server")
      end
      if t.rec && Creation::PRE_READY.include?(t.rec["state"])
        return refuse("building", "#{t.name} is still being built", fix: "retry at the next check; still building after 10 minutes → ask a human")
      end

      receipt = DeleteReceipt.read(t.real)
      if receipt && DeleteReceipt.owner_alive?(receipt)
        return refuse("deleting", "another delete of #{t.path} is running (pid #{receipt['owner_pid']})", fix: "retry at the next check")
      end
      if !Git.lock_reason(t.path).nil? && !Creation.unfinished_at?(t.path)
        return refuse("locked", "#{t.path} is locked (git worktree lock)", fix: "`git worktree unlock #{Shellwords.escape(t.path)}` if you locked it on purpose and are done, else leave it")
      end

      t.branches = WorkspaceBranches.plan(t.repo, t.path, t.base, gc: false)
      safety(t)
    end

    # The checks --force covers (7–9). Run at preflight and again once the session is closed.
    def safety(t)
      lines = Git.status_lines(t.path)
      unless t.force
        return refuse("dirty", "#{t.path} has changes git status can't read", fix: "fix the repository, or ask a human (only a human approves --force)") if lines.nil?
        return refuse("dirty", "#{t.path} has uncommitted or untracked changes", fix: "commit or stash them, or ask a human (only a human approves --force)", details: lines) unless lines.empty?
      end

      t.head = Git.head(t.path)
      unless t.force
        if t.branches.nil? || t.head.nil?
          return refuse("branches-unknown", "can't tell which branches are #{t.name}'s own or whether their commits are safe",
                        fix: "ask a human (only a human approves --force)")
        end
        unpushed = unpushed(t)
        return unpushed if unpushed
      end

      busy = busy(t)
      return refuse("busy", "#{t.name} is in use: #{busy.first}", fix: "wait for it to finish and retry at the next check, or ask a human (only a human approves --force)", details: busy.drop(1)) if busy && !t.force

      nil
    end

    def unpushed(t)
      base = t.base if t.base && Git.rev_parse(t.repo, t.base)
      checks = t.branches.map { |e| [e.name, e.sha] }
      checks << ["HEAD", t.head] unless t.branches.any? { |e| e.sha == t.head }
      found = checks.filter_map do |label, sha|
        n = Git.unique_commits(t.repo, sha, base)
        return refuse("branches-unknown", "git couldn't count #{label}'s commits", fix: "ask a human (only a human approves --force)") if n.nil?

        "#{label}: #{n} commit(s), tip #{sha[0, 12]}, on neither #{base || 'a base (none set)'} nor a remote" if n.positive?
      end
      leaving = t.branches.map(&:name)
      history = Git.history_only_commits(t.path, t.repo, base, leaving)
      return refuse("branches-unknown", "git couldn't read #{t.name}'s history log", fix: "ask a human (only a human approves --force)") if history.nil?

      found << "#{history} commit(s) only its history log (reflog) reaches; they'd be lost with it" if history.positive?
      subs = Git.submodule_unpushed(t.path)
      return refuse("branches-unknown", "git couldn't check #{t.name}'s submodules", fix: "ask a human (only a human approves --force)") if subs.nil?

      found << "#{subs} commit(s) in its submodules are on none of their remotes" if subs.positive?
      return nil if found.empty?

      refuse("unpushed", found.first, fix: "push it (`git push -u origin <branch>`), or ask a human (only a human approves --force)", details: found.drop(1))
    end

    # Every reason someone may still be using it, or nil. A scan that fails counts as busy.
    def busy(t)
      reasons = []
      hooks = hook_states(t.real)
      newest = hooks.max_by { |_, _, epoch| epoch }
      fresh = newest && Time.now.to_i - newest[2] <= AgentState::PRESENCE_TTL
      reasons << "an agent is #{newest[0]} in #{newest[1]}" if fresh && newest[0] != "done"

      cwds = Agents.scan
      if cwds.nil?
        reasons << "couldn't scan for running agents"
      elsif cwds.any? { |c| under?(Paths.real_or_self(c), t.real) } && !(fresh && newest[0] == "done")
        reasons << "an agent process runs in it with no fresh idle state"
      end
      reasons << "∞ monitoring is live" if monitoring?(t.real)
      reasons << "a ◷ hold waits on background work" if KeyedMarkerStore.entries(OffstageHold.state_dir).any? { |_, c, _| c.split("\t").first == t.real }
      t.sessions.each do |s|
        clients = Tmux.session_clients(s[:id])
        reasons << (clients ? "client #{clients.join(', ')} attached to #{s[:name]}" : "tmux couldn't list #{s[:name]}'s clients") if clients.nil? || clients.any?
      end
      reasons.empty? ? nil : reasons
    end

    # [state, cwd, epoch] for every hook report at or under `real`, read without collecting.
    def hook_states(real)
      Dir.glob(File.join(AgentState.state_dir, "*")).filter_map do |f|
        state, cwd, epoch = File.read(f).chomp.split("\t", 3)
        next unless AgentState::STATES.include?(state) && cwd && epoch

        [state, cwd, epoch.to_i] if under?(Paths.real_or_self(cwd), real)
      rescue StandardError
        nil
      end
    end

    def monitoring?(real)
      KeyedMarkerStore.entries(Monitoring.state_dir).any? do |_, content, mtime|
        path, ttl = Monitoring.decode(content)
        path == real && Time.now - mtime <= ttl
      end
    end

    # Why the caller is inside the target, or nil: its cwd, its tmux pane's session, or an
    # ancestor process that's one of the session's panes (an agent's tool shell can run with
    # TMUX_PANE stripped and another cwd, and still die with that session).
    def inside?(t, panes)
      return "your current directory" if under?(Paths.real_or_self(Dir.pwd), t.real)

      current = ENV["TMUX"] && ENV["TMUX_PANE"] && Tmux.session_of
      return "your tmux pane is in its session" if current && t.sessions.any? { |s| s[:name] == current }

      pids = panes.map { |p| p[:pid] }
      "a parent process is one of its panes" if (ancestors & pids).any?
    end

    def ancestors
      chain = []
      pid = Process.ppid
      64.times do
        break if pid <= 1 || chain.include?(pid)

        chain << pid
        pid = IO.popen(["ps", "-o", "ppid=", "-p", pid.to_s], err: File::NULL, &:read).to_i
      end
      chain
    end

    # --- the delete ---------------------------------------------------------------

    def execute(t)
      old = { "HUP" => trap("HUP", "IGNORE"), "INT" => trap("INT", "IGNORE") }
      receipt = claim(t)
      return receipt if receipt.is_a?(Result)

      Creation.ack(t.rec["id"]) if t.rec # deleted on purpose: no ✘ or chime
      closed = close_session(t)
      return abandon(t, closed) if closed.is_a?(Result)

      advance(receipt, "session_closed")
      t.sessions = [] # gone now: the re-check asks only about what could still write
      again = safety(t)
      return abandon(t, refuse("changed-during-delete", "#{t.name} changed after the check: #{again.what}",
                               changed: "its session is closed and its record acknowledged",
                               fix: "the agent in it was stopped; open it to see what changed (`claude --continue` there resumes it), then retry or ask a human")) if again
      return abandon(t, changed_head(t)) if !t.force && !token_ok?(t)

      removed = remove_folder(t, receipt)
      return removed if removed.is_a?(Result)

      finish(receipt, residue: removed)
    ensure
      old&.each { |sig, handler| trap(sig, handler || "DEFAULT") }
    end

    def token_ok?(t)
      t.rec.nil? || t.rec["token"].to_s.empty? || token_matches?(t.path, t.rec)
    end

    def changed_head(t)
      refuse("changed-during-delete", "#{t.name} is no longer the tree its record built", changed: "its session is closed", fix: "ask a human")
    end

    # Step 2: under the project lock, re-check for a live delete, then write the receipt and
    # only then hide the row everywhere.
    def claim(t)
      Creation.with_project_lock(t.project) do
        cur = DeleteReceipt.read(t.real)
        next refuse("deleting", "another delete of #{t.path} is running (pid #{cur['owner_pid']})", fix: "retry at the next check") if cur && DeleteReceipt.owner_alive?(cur)

        receipt = {
          "path" => t.path, "real" => t.real, "project" => t.project, "repo" => t.repo, "name" => t.name,
          "record" => t.rec&.dig("id"), "token" => t.rec&.dig("token"), "server" => Creation.current_server,
          "branches" => (t.branches || []).map { |e| "#{e.sha}:#{e.name}" }, "phase" => "claimed", "deleted" => []
        }.merge(DeleteReceipt.owner)
        next refuse("failed", "couldn't write the delete receipt in #{DeleteReceipt.dir}", fix: "check that folder's permissions, then retry") unless DeleteReceipt.write(receipt)

        PendingDelete.mark(t.path)
        receipt
      end
    end

    def advance(receipt, phase)
      receipt["phase"] = phase
      DeleteReceipt.write(receipt) or raise "couldn't update the delete receipt"
    end

    # A check after the claim failed: un-hide the row and drop the receipt.
    def abandon(t, result)
      PendingDelete.clear(t.path)
      DeleteReceipt.delete(t.real)
      result
    end

    # Step 4: kill every session of the workspace by id, stop before the folder if one
    # survives, then give its sidebars a moment and TERM any that are still the same process.
    def close_session(t, wait: true)
      t.sessions.each do |s|
        Tmux.send_clients_home(s[:id]) # only a forced delete gets here with someone attached
        Tmux.kill_session_id(s[:id])
      end
      left = Tmux.sessions_strict
      alive = left.nil? ? t.sessions : t.sessions.select { |s| left.any? { |l| l[:id] == s[:id] } }
      unless alive.empty?
        return refuse("session-alive", "#{alive.map { |s| s[:name] }.join(', ')} didn't close",
                      changed: "its record is acknowledged; the folder was not touched",
                      fix: "`tmux kill-session -t =#{alive.first[:name]}`, then retry")
      end
      return true unless wait

      deadline = Time.now + SIDEBAR_WAIT
      sleep 0.1 while Time.now < deadline && t.sidebars.any? { |pid, start| ProcessIdentity.same?(pid, start) }
      t.sidebars.each do |pid, start|
        Process.kill("TERM", pid) if pid != Process.pid && ProcessIdentity.same?(pid, start)
      rescue StandardError
        nil
      end
      true
    end

    # Step 5. Unforced, git itself refuses a file written after the re-check. Returns the
    # list of kept-on-purpose lines (a residue folder), or the refusal.
    def remove_folder(t, receipt)
      return abandon(t, changed_head(t)) if Git.head(t.path) != t.head && Dir.exist?(t.path)

      if Dir.exist?(t.path)
        unfinished = Creation.unfinished_at?(t.path)
        ok, err = Git.remove_worktree_reporting(t.repo, t.path, force: t.force, locked: unfinished)
        ok, err = Git.remove_worktree_reporting(t.repo, t.path, force: true) if !ok && !t.force && err.match?(Git::SUBMODULE_REFUSAL)
        if !ok && !t.force && err.include?("--force")
          return abandon(t, refuse("changed-during-delete", "git found changes in #{t.path} after the check",
                                   changed: "its session is closed and its record acknowledged",
                                   fix: "open it to see what changed, then retry or ask a human", details: err.lines(chomp: true)))
        end
      else
        drop_admin_dir(t)
      end

      trees = Git.worktrees(t.repo, strict: true)
      if trees.nil?
        return refuse("remove-failed", "couldn't confirm git removed #{t.path}", changed: "its session is closed",
                                                                                 fix: "retry the same command once; fails again → ask a human")
      end
      if trees.any? { |w| Paths.real_or_self(w[:path]) == t.real || w[:path] == t.path }
        return abandon(t, refuse("remove-failed", "git didn't remove #{t.path}", changed: "its session is closed; the workspace still shows",
                                                                                  fix: "retry the same command once; fails again → ask a human with git's message",
                                                                                  details: err.to_s.lines(chomp: true)))
      end
      advance(receipt, "removed")
      return [] unless File.exist?(t.path)

      ["#{t.path} (git no longer lists it, but files are left: `rm -rf #{Shellwords.escape(t.path)}`)"]
    end

    # A folder gone by hand while git still lists it: `worktree prune` is repo-wide, so only
    # this tree's own admin dir goes, once its gitdir proves it ours.
    def drop_admin_dir(t)
      common = Git.common_dir(t.repo) or return
      Dir.glob(File.join(common, "worktrees", "*")).each do |admin|
        FileUtils.rm_rf(admin) if admin_of?(admin, t)
      end
    end

    def admin_of?(admin, t)
      return false unless File.read(File.join(admin, "gitdir")).strip == File.join(t.path, ".git")
      return true if t.rec.nil? || t.rec["token"].to_s.empty?

      File.read(File.join(admin, TOKEN_FILE)).strip == t.rec["token"]
    rescue StandardError
      false
    end

    # Step 6, from the receipt alone, so a resumed delete and prune use it too. Only runs
    # once git no longer lists the workspace. Each step is independent: a failure is
    # collected, not fatal, and keeps the receipt for the next try.
    def forget(receipt)
      real = receipt["real"]
      removed = []
      kept = []
      failed = []
      Creation.with_project_lock(receipt["project"]) do
        status, map = Names.read_all
        if status != :ok
          failed << "name (the names store #{map} can't be read)"
        elsif map[real]
          Names.delete(real)
          again, now = Names.read_all
          again == :ok && !now.key?(real) ? removed << "name #{map[real].name}" : failed << "name #{map[real].name}"
        end
        branches(receipt, removed, kept, failed)
        project = receipt["project"].to_s
        unless project.empty? || Pr.forget(project, receipt["deleted"], receipt["repo"], branch_limit: Config.new.max_branch_history)
          failed << "PR badges for #{receipt['deleted'].join(', ')}"
        end
        stuck = Leftovers.clear_workspace(real, except: RESUME_EXCEPT)
        failed.concat(stuck.map { |f| "marker #{f}" })
        rec = receipt["record"] && Creation.find(receipt["record"])
        if rec
          Creation.delete(rec["id"])
          Creation.find(rec["id"]) ? failed << "record #{rec['id']}" : removed << "record #{rec['id']}"
        end
      end
      late = Leftovers.clear_workspace(real, except: RESUME_EXCEPT) # a writer past its check just before the folder went
      failed.concat(late.map { |f| "marker #{f}" })
      [removed, kept, failed]
    end

    # Each planned branch, deleted at its pinned sha after a fresh check that no worktree
    # has it checked out or is rebasing it (update-ref lacks branch -D's guard). Appended to
    # the receipt as it goes.
    def branches(receipt, removed, kept, failed)
      receipt["branches"].each do |pair|
        sha, name = pair.split(":", 2)
        next if receipt["deleted"].include?(name)

        tip = Git.rev_parse(receipt["repo"], "refs/heads/#{name}")
        if tip.nil?
          receipt["deleted"] << name
          next
        end
        trees = Git.worktrees(receipt["repo"], strict: true)
        rebasing = Git.rebasing_branches(receipt["repo"])
        if trees.nil? || rebasing.nil?
          failed << "branch #{name} (couldn't check whether it's in use)"
        elsif trees.any? { |w| w[:branch] == name } || rebasing.include?(name)
          kept << "branch #{name} (another workspace uses it)"
        elsif tip != sha
          kept << "branch #{name} (it moved since the check)"
        elsif Git.delete_branch_at(receipt["repo"], name, sha)
          removed << "branch #{name}"
          receipt["deleted"] << name
          DeleteReceipt.write(receipt)
        else
          failed << "branch #{name}"
        end
      end
    end

    # Finish a delete whose folder git no longer lists: forget, un-hide, and drop the
    # receipt unless something failed. `residue`: files git left behind, never removed here.
    def finish(receipt, residue: [])
      removed, kept, failed = forget(receipt)
      PendingDelete.clear(receipt["path"])
      failed.concat(residue)
      DeleteReceipt.delete(receipt["real"]) if failed.empty?
      Tmux.broadcast_warm
      report(receipt, removed, kept, failed)
    end

    # A dead owner's receipt whose folder git no longer lists: take it over under the lock,
    # then finish step 6. Prune calls it too.
    def resume(receipt)
      # Its own repo decides, not the registered projects: a reaper's repo may not be one.
      trees = Git.worktrees(receipt["repo"].to_s, strict: true)
      if trees.nil? || trees.any? { |w| Paths.real_or_self(w[:path]) == receipt["real"] || w[:path] == receipt["path"] }
        return refuse("listing-failed", "can't confirm git no longer lists #{receipt['path']}",
                      fix: "run `git worktree list` in #{receipt['repo']}; if it's listed, delete it by name")
      end

      taken = Creation.with_project_lock(receipt["project"]) do
        cur = DeleteReceipt.read(receipt["real"]) || receipt
        next nil if DeleteReceipt.owner_alive?(cur)

        cur.merge!(DeleteReceipt.owner)
        DeleteReceipt.write(cur) ? cur : nil
      end
      return refuse("deleting", "another delete of #{receipt['path']} took it over", fix: "retry at the next check") unless taken

      finish(taken)
    end

    def report(receipt, removed, kept, failed)
      lines = ["removed: folder #{receipt['path']}", *removed.map { |r| "removed: #{r}" }, *kept.map { |k| "kept: #{k}" }]
      history = claude_history(receipt["real"])
      lines << "kept: history #{history} (Claude's own)" if history
      return Result.new(lines: lines) if failed.empty?

      Result.new(token: "partial", what: "#{receipt['path']} is gone, but #{failed.size} item(s) were left",
                 changed: "the folder is removed", fix: "`switchboard prune` finishes it, or remove each item below",
                 details: failed, lines: lines)
    end

    # Claude's transcript folder for this path, if there is one. Kept: it's Claude's.
    def claude_history(real)
      dir = File.join(ClaudeSessions.claude_root, "projects", real.gsub(/[^a-zA-Z0-9]/, "-"))
      File.directory?(dir) ? dir : nil
    rescue StandardError
      nil
    end

    def plan_lines(t)
      lines = ["would remove: folder #{t.path}"]
      t.sessions.each { |s| lines << "would remove: session #{s[:name]}" }
      lines << "no session" if t.sessions.empty?
      (t.branches || []).each { |e| lines << "would remove: branch #{e.name} #{e.merged ? '✓' : '!'}" }
      lines << "would keep: every branch (which are its own can't be told)" if t.branches.nil?
      lines << "would remove: record #{t.rec['id']}" if t.rec
      lines << "would remove: its name and every marker switchboard keeps for it"
      ignored = Git.ignored_paths(t.path) - [".claude/settings.local.json"] # switchboard's own hook wiring
      unless ignored.empty?
        shown = ignored.first(10).join(", ")
        lines << "would remove: ignored files git doesn't track (#{shown}#{ignored.size > 10 ? ", … #{ignored.size - 10} more" : ''})"
      end
      history = claude_history(t.real)
      lines << "would keep: history #{history} (Claude's own)" if history
      lines
    end

    # --- results ------------------------------------------------------------------

    def refuse(token, what, fix:, changed: "none", details: [])
      Result.new(token: token, what: what, changed: changed, fix: fix, details: Array(details))
    end

    def usage(what) = refuse("usage", what, fix: "switchboard delete <name> | <project>/<name> [--creation <id>] [--force] [-n]")

    # The first stderr line, then bounded, escaped detail lines.
    def message(result)
      head = "[#{result.token}] #{result.what}; changed: #{result.changed}; fix: #{result.fix} (#{DOCS}#{result.token})"
      details = result.details.first(MAX_DETAIL).map { |l| "  #{escape(l)}" }
      details << "  … #{result.details.size - MAX_DETAIL} more" if result.details.size > MAX_DETAIL
      [escape(head), *details]
    end

    def escape(text) = text.to_s.scrub.gsub(/[\x00-\x08\x0b-\x1f\x7f]/) { |c| format("\\x%02x", c.ord) }

    def traces_dir = Paths.state("SWITCHBOARD_DELETE_TRACES_DIR", "delete-traces")

    def crashed(error, target)
      trace = File.join(traces_dir, "#{Time.now.strftime('%Y%m%d%H%M%S')}-#{Process.pid}.txt")
      begin
        FileUtils.mkdir_p(traces_dir)
        File.write(trace, ([error.full_message(highlight: false)] + [DeleteReceipt.read(target&.real.to_s).to_s]).join("\n"))
      rescue StandardError
        trace = "(couldn't write one)"
      end
      receipt = target && DeleteReceipt.read(target.real)
      refuse("failed", "unexpected error: #{error.message}", changed: receipt ? "reached #{receipt['phase']}" : "unknown",
                                                              fix: "run `switchboard doctor`; trace: #{trace}")
    end

    def under?(path, root) = path == root || path.start_with?("#{root}/")
  end
end
