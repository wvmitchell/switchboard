# frozen_string_literal: true

require_relative "../support/paths"

module Switchboard
  # Owns the tmux session lifecycle: reconciles the live `sb/` sessions against
  # the worktrees git actually has, killing the orphans a deleted/moved/crashed
  # worktree leaves behind. The `sb/` prefix is switchboard's ownership signal
  # (no separate registry); `sb/home` maps to no worktree, so it never matches a
  # project prefix and is never pruned.
  module Reconcile
    # Don't prune a session younger than this (seconds). A session created just
    # before a reconcile may not be in the model snapshot yet; killing it would
    # take a live agent down with it. The grace window, not "it self-heals", is
    # what makes the launch race safe.
    SESSION_GRACE = 10

    # The reconcile outcome, so the CLI can report honestly: reachable=false ⇒ no
    # tmux server; sb_count ⇒ how many sb/ sessions exist; orphans ⇒ the names
    # killed (or, in a dry run, that would be); history ⇒ what happened to Claude's
    # transcript folders (a ClaudeHistory::Summary, nil when not run).
    Report = Struct.new(:reachable, :sb_count, :orphans, :history, keyword_init: true)

    module_function

    # Pure: of the live sessions, the ones that belong to a verified project
    # (match a prefix), are NOT backed by a worktree (absent from the union of
    # valid names), are older than the grace window, and aren't the session
    # we're in. No tmux/git here, so the whole decision is unit-testable.
    #
    # The age check requires a POSITIVE created stamp: if tmux returned a blank /
    # unparsable `session_created` (`.to_i` → 0), we can't trust the age, so we
    # treat the session as too-fresh-to-judge and keep it rather than let a
    # garbled stamp read as "ancient" and bypass the grace guard.
    def orphans(live, valid, prefixes, current:, now:, grace: SESSION_GRACE)
      live.select do |s|
        name = s[:name]
        created = s[:created].to_i
        owned?(name, prefixes) &&
          !valid.include?(name) &&
          created.positive? && now - created >= grace &&
          name != current
      end.map { |s| s[:name] }
    end

    # A session belongs to a verified project only if what follows the matched
    # prefix is a single leaf — no further "/". A real worktree leaf is a
    # basename, so a session like sb/app/x/feat (project "app/x") is NOT claimed
    # by project "app" (prefix sb/app/); it's left alone, not wrongly pruned.
    def owned?(name, prefixes)
      prefixes.any? { |p| name.start_with?(p) && !name[p.length..].include?("/") }
    end

    # Reconcile and, unless dry_run, kill. Builds its own fresh Model so the
    # snapshot is as late as possible (narrows the create-vs-reconcile race).
    # Only VERIFIED projects contribute: Model already drops missing-dir repos,
    # and an empty worktree list (git failed / no primary) ⇒ skip — so a
    # moved/unreadable repo never makes its live sessions look orphaned. The diff
    # is against the UNION of all verified valid names, so two projects whose
    # names sanitize to the same prefix protect each other's sessions.
    #
    # `catch_up_history:` also tidies Claude's transcript folders (ClaudeHistory), last and
    # with or without a tmux server (prune from a plain shell is the usual recovery). Last,
    # because a rename waits on the history lock between moving its worktree and renaming
    # its session: work between the sessions read and the worktree listing would widen
    # that window into a kill. The sidebar's launch prune passes false: no history work in
    # a UI process.
    def prune(config, dry_run: false, now: Time.now.to_i, catch_up_history: true)
      report = prune_sessions(config, dry_run, now)
      report.history = prune_history(config, Model.new(config, with_dirty: false).projects, dry_run, Time.at(now)) if catch_up_history
      report
    end

    def prune_sessions(config, dry_run, now)
      live = Tmux.sessions
      return Report.new(reachable: false, sb_count: 0, orphans: []) if live.nil?

      projects = Model.new(config, with_dirty: false).projects
      prefixes = []
      valid = []
      parents = []
      verified = []
      projects.each do |project|
        names = project.worktrees.map { |w| Tmux.session_name(w) }
        # A listing git failed, or a worktree in it we couldn't read (non-UTF-8 path), would
        # make a live session look orphaned: leave the whole project alone.
        next if names.empty? || Git.worktrees(project.path, strict: true).nil?

        verified << [project.name, project.path]
        prefixes << Tmux.session_prefix(project.name)
        valid.concat(names)
        # Collect parent dirs of DEDICATED worktrees only. The primary checkout's
        # parent is the dir holding the main repo — switchboard doesn't own it and
        # must not sweep it. Compare by realpath, not the w.primary flag (which is
        # a raw-string match and misses a symlinked path, e.g. /var vs /private/var).
        repo = real(project.path)
        project.worktrees.each do |w|
          wt = real(w.path)
          parents << File.dirname(wt) unless wt == repo
        end
      end

      # Any configured project we couldn't verify (unreadable, empty, or a missing folder Model
      # drops) keeps its prefix out of reach too: another project's name may sanitize to it
      # (app.dev / app-dev).
      skipped = config.projects.reject { |p| verified.include?([p["name"], p["path"]]) }
                      .filter_map { |p| Tmux.session_prefix(p["name"]) if p["name"] }

      reap_bridges(parents) unless dry_run

      orphaned = orphans(live, valid, prefixes - skipped, current: Tmux.session_of, now: now)
      orphaned.each { |name| Tmux.kill_session(name) } unless dry_run
      Report.new(reachable: true, sb_count: live.size, orphans: orphaned)
    end

    # Sweep the projects bridges older versions left, link what renamed workspaces' old
    # keys gained since, and reap dangling projects bridges. A dry run changes nothing and
    # counts what it would do.
    def prune_history(config, projects, dry_run, now)
      pairs = history_pairs(config, projects: projects)
      owned = owned_prefixes(config, projects: projects)
      return preview_history(pairs, owned) if dry_run

      sum = ClaudeHistory.sweep(owned: owned, now: now)
      caught = ClaudeHistory.catch_up(pairs, now: now)
      sum.linked += caught.linked
      sum.clashes.concat(caught.clashes)
      ClaudeHistory.reap_bridges(owned: owned)
      ClaudeHistory.trim_log
      sum
    rescue StandardError
      nil
    end

    def preview_history(pairs, owned)
      sum = ClaudeHistory::Summary.zero
      sum.converted = ClaudeHistory.sweep_candidates(owned: owned).size # converted or deleted: decided at run time
      ClaudeHistory.inspect_pairs(pairs).each do |p|
        sum.linked += p[:missing]
        sum.clashes.concat(p[:clashes])
      end
      sum
    end

    # [old_path, new_path] for each worktree bridge (the symlink a rename leaves at the old
    # path) that still resolves to a live worktree: a renamed workspace's history pairs.
    def history_pairs(config, projects: nil)
      projects ||= Model.new(config, with_dirty: false).projects
      live = projects.flat_map { |p| p.worktrees.map { |w| real(w.path) } }.to_set
      worktree_parents(config, projects).flat_map do |dir|
        Dir.children(dir).filter_map do |name|
          bridge = File.join(dir, name)
          target = File.symlink?(bridge) && Paths.real_or_nil(bridge)
          [bridge, target] if target && live.include?(target)
        end
      rescue StandardError
        []
      end
    end

    # The encoded key prefixes of switchboard's own workspaces: history cleanup touches
    # nothing in Claude's projects folder outside them.
    def owned_prefixes(config, projects: nil)
      projects ||= Model.new(config, with_dirty: false).projects
      # Only folders under worktree_root: a worktree git found elsewhere (~/code/x-wt) would
      # otherwise claim every key under ~/code.
      root = "#{Paths.real_or_self(config.worktree_root)}/"
      worktree_parents(config, projects).select { |dir| "#{dir}/".start_with?(root) }
                                        .map { |dir| "#{ClaudeHistory.encode(dir)}-" }
    end

    # Where each project's dedicated worktrees live: the configured worktree root and any
    # parent a dedicated worktree actually sits in (never the primary checkout's parent).
    def worktree_parents(config, projects)
      configured = config.projects.filter_map do |p|
        Paths.real_or_nil(File.join(config.worktree_root, Placeholder.sanitize(p["name"]))) if p["name"]
      end
      found = projects.flat_map do |project|
        repo = real(project.path)
        project.worktrees.filter_map { |w| File.dirname(real(w.path)) unless real(w.path) == repo }
      end
      (configured + found).uniq.select { |d| File.directory?(d) }
    end

    # Pure: which running sidebar PIDs are orphans — their tty is not among the live
    # pane ttys, so no pane on the server owns them. No tmux/ps here, so the decision is
    # unit-testable.
    #
    # nil OR EMPTY live_ttys reaps NOTHING — this guard is load-bearing, not paranoia. A
    # nil is tmux unreachable; an EMPTY set means list-panes succeeded but enumerated no
    # pane, which on a live server is impossible (a server with no panes has already
    # exited), so it can only be a partial/garbled read. Without that guard an empty set
    # makes EVERY sidebar match "no live pane" and we'd reap every one at once — the
    # whole-server-wipe a flaky shell-out must never trigger. Same house rule as
    # owns_pane?: degrade, never act, on a miss.
    def orphan_sidebar_pids(processes, live_ttys)
      return [] if live_ttys.nil? || live_ttys.empty?

      processes.reject { |_pid, tty| live_ttys.include?(tty) }.map(&:first)
    end

    # Reap orphaned sidebar PROCESSES — a `switchboard sidebar` whose pane is gone
    # (an interrupted run, a hard server kill). A different orphan than the sessions
    # above: those are sb/ sessions with no worktree; these are processes with no pane.
    # Worth reaping in the same sweep because tmux RECYCLES pane ids, so a straggler can
    # be handed a live pane and double-fire completion sounds (the bug owns_pane? guards
    # at runtime — this clears the ones already stranded). Returns the reaped pids (or,
    # dry_run, the ones it would). SIGTERM, not KILL: orphan_sidebar_pids already
    # excludes every process that owns a pane, so nothing healthy is in range, but TERM
    # still lets a misjudged one run its own teardown.
    def reap_sidebars(dry_run: false)
      # Two layers keep this machine-global `ps` reap from ever killing the dev's REAL
      # sidebar: sidebar_processes scopes to THIS server's children by ppid (the structural
      # guard — a foreign server's sidebar is out of range), and this env guard
      # short-circuits entirely inside an isolated throwaway server — the `sandbox` command
      # (#126) or the real-tmux smoke layer (SmokeCase). A throwaway server has no orphans
      # worth reaping and its leftovers are cleaned by IsolatedServer.sweep_stale /
      # teardown's kill-server, so skip.
      return [] if ENV["SWITCHBOARD_SANDBOX"]

      pids = orphan_sidebar_pids(Tmux.sidebar_processes, Tmux.live_pane_ttys)
      # Per-pid rescue: a pid that died between the listing and the kill (ESRCH) is
      # already what we wanted — skip it, don't abort reaping the rest.
      pids.each { |pid| kill_quietly(pid) } unless dry_run
      pids
    end

    # SIGTERM a pid, swallowing the ESRCH of one that already exited (the kill race) and
    # any EPERM — a failed signal degrades to "left running", never crashes the prune.
    def kill_quietly(pid)
      Process.kill("TERM", pid)
    rescue StandardError
      nil
    end

    # Remove rename bridges (the old -> new symlinks Git.move_worktree leaves) once
    # they dangle — i.e. the renamed worktree they pointed at is itself gone.
    # Scoped to dedicated-worktree parent dirs (never the main repo's parent), and
    # only ever deletes a symlink whose target no longer exists, so it can't touch
    # a real worktree or a live bridge that a moved-but-still-running agent needs.
    def reap_bridges(parent_dirs)
      parent_dirs.uniq.each do |dir|
        Dir.children(dir).each do |name|
          path = File.join(dir, name)
          File.delete(path) if File.symlink?(path) && !File.exist?(path)
        end
      rescue StandardError
        next
      end
    rescue StandardError
      nil
    end

    # Canonicalize for comparison; raw path on failure (a vanished worktree).
    def real(path) = Paths.real_or_self(path)
  end
end
