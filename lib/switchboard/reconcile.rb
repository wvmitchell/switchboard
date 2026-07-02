# frozen_string_literal: true

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
    # killed (or, in a dry run, that would be).
    Report = Struct.new(:reachable, :sb_count, :orphans, keyword_init: true)

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
    def prune(config, dry_run: false, now: Time.now.to_i)
      live = Tmux.sessions
      return Report.new(reachable: false, sb_count: 0, orphans: []) if live.nil?

      prefixes = []
      valid = []
      parents = []
      Model.new(config, with_dirty: false).projects.each do |project|
        names = project.worktrees.map { |w| Tmux.session_name(w) }
        next if names.empty?

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

      unless dry_run
        reap_bridges(parents)
        ClaudeHistory.reap_bridges # GC the rename bridges migrate leaves in ~/.claude/projects
      end

      orphaned = orphans(live, valid, prefixes, current: Tmux.session_of, now: now)
      orphaned.each { |name| Tmux.kill_session(name) } unless dry_run
      Report.new(reachable: true, sb_count: live.size, orphans: orphaned)
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
      # Never reap from inside the sandbox's isolated server (#126): sidebar_processes
      # is machine-global (`ps`) while live_pane_ttys is this-server-only, so every
      # REAL sidebar on the box would read as an orphan and get SIGTERM'd. The
      # sandbox's own leftovers are handled by IsolatedServer.sweep_stale instead.
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
    def real(path)
      File.realpath(path)
    rescue StandardError
      path
    end
  end
end
