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
    # killed (or, in a dry run, that would be); names ⇒ stored names dropped because
    # their folder has been gone MISSING_TTL (nil when the store couldn't be read).
    Report = Struct.new(:reachable, :sb_count, :orphans, :names, keyword_init: true)

    module_function

    # Pure: of the live sessions, the ones that belong to a verified project
    # (match a prefix), are NOT backed by a worktree, are older than the grace window,
    # and aren't the session we're in. Backed means its creation path (`:real`, the
    # caller-resolved realpath of #{session_path}) is a live worktree, whatever the
    # session is called, so a rename mid-prune can never make a live session look
    # orphaned; a session whose path isn't a live worktree (one created at a path an old
    # rename moved away from) falls back to name matching against `valid`. No tmux/git
    # here, so the whole decision is unit-testable.
    #
    # The age check requires a POSITIVE created stamp: if tmux returned a blank /
    # unparsable `session_created` (`.to_i` → 0), we can't trust the age, so we
    # treat the session as too-fresh-to-judge and keep it rather than let a
    # garbled stamp read as "ancient" and bypass the grace guard.
    def orphans(live, valid, prefixes, current:, now:, grace: SESSION_GRACE, live_paths: Set.new)
      live.select do |s|
        name = s[:name]
        created = s[:created].to_i
        owned?(name, prefixes) &&
          !(s[:real] && live_paths.include?(s[:real])) &&
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
    # snapshot is as late as possible. Only VERIFIED projects contribute: Model already
    # drops missing-dir repos, and an empty or failed worktree list ⇒ skip — so a
    # moved/unreadable repo never makes its live sessions look orphaned. Each project is
    # decided and killed under its Creation.with_project_lock with a fresh session and
    # strict worktree read, so it serializes with Rename (which holds the same lock).
    def prune(config, dry_run: false, now: Time.now.to_i)
      report, live_paths, verified = prune_sessions(config, dry_run, now)
      report.names = prune_names(verified, live_paths, dry_run, now)
      report
    end

    def prune_sessions(config, dry_run, now)
      projects = Model.new(config, with_dirty: false).projects
      valid = []
      parents = []
      verified = []
      live_paths = Set.new
      projects.each do |project|
        names = project.worktrees.map { |w| Tmux.session_name(w) }
        # A listing git failed, or a worktree in it we couldn't read (non-UTF-8 path), would
        # make a live session look orphaned: leave the whole project alone.
        next if names.empty? || Git.worktrees(project.path, strict: true).nil?

        verified << [project.name, project.path]
        valid.concat(names)
        # Collect parent dirs of DEDICATED worktrees only. The primary checkout's
        # parent is the dir holding the main repo — switchboard doesn't own it and
        # must not sweep it. Compare by realpath, not the w.primary flag (which is
        # a raw-string match and misses a symlinked path, e.g. /var vs /private/var).
        repo = real(project.path)
        project.worktrees.each do |w|
          wt = real(w.path)
          live_paths << wt
          parents << File.dirname(wt) unless wt == repo
        end
      end

      first = Tmux.sessions
      return [Report.new(reachable: false, sb_count: 0, orphans: []), live_paths, verified] if first.nil?

      # Any configured project we couldn't verify (unreadable, empty, or a missing folder Model
      # drops) keeps its prefix out of reach too: another project's name may sanitize to it
      # (app.dev / app-dev).
      skipped = config.projects.reject { |p| verified.include?([p["name"], p["path"]]) }
                      .filter_map { |p| Tmux.session_prefix(p["name"]) if p["name"] }

      reap_bridges(parents) unless dry_run

      current = Tmux.session_of
      orphaned = verified.flat_map do |name, path|
        prune_project(name, path, valid, live_paths, skipped, current, now, dry_run)
      end.uniq
      [Report.new(reachable: true, sb_count: first.size, orphans: orphaned), live_paths, verified]
    end

    # One project's orphans, decided and killed under its lock from fresh reads.
    def prune_project(name, path, valid, live_paths, skipped, current, now, dry_run)
      Creation.with_project_lock(name) do
        live = Tmux.sessions or return []
        fresh = Git.worktrees(path, strict: true) or return []

        paths = live_paths | fresh.reject { |w| w[:bare] }.map { |w| real(w[:path]) }
        names = fresh.reject { |w| w[:bare] }.map { |w| Tmux.session_name(Worktree.new(project: name, path: w[:path])) }
        resolved = live.map { |s| s.merge(real: s[:path] && Paths.real_or_nil(s[:path])) }
        found = orphans(resolved, valid | names, [Tmux.session_prefix(name)] - skipped,
                        current: current, now: now, live_paths: paths)
        found.each { |n| Tmux.kill_session(n) } unless dry_run
        found
      end
    end

    # Stored names whose folder is gone: a verified project's entry gets `missing_since`
    # the first time, and is dropped once that's MISSING_TTL old (a hand-moved worktree
    # keeps its name long enough for doctor to point at it). A folder that came back
    # clears the mark. Never touches an unverified project's entries, and does nothing
    # when the store can't be read. The count dropped (or that would be), or nil.
    def prune_names(verified, live_paths, dry_run, now)
      status, map = Names.read_all
      return nil unless status == :ok

      projects = verified.map(&:first).to_set
      dropped = 0
      map.each_value do |e|
        next unless projects.include?(e.project)

        Creation.with_project_lock(e.project) do
          # Re-read under the lock: a rename may have rewritten the entry since the scan.
          fresh, now_map = Names.read_all
          e = fresh == :ok && now_map[e.real] or next
          if live_paths.include?(e.real) || File.directory?(e.real)
            rewrite(e, "") unless dry_run || e.missing_since.empty?
          elsif e.missing_since.empty?
            rewrite(e, now) unless dry_run
          elsif now - e.missing_since.to_i >= Names::MISSING_TTL
            dropped += 1
            Names.delete(e.real) unless dry_run
          end
        end
      end
      dropped
    end

    def rewrite(entry, missing_since)
      Names.write(entry.real, entry.name, project: entry.project, branch: entry.branch,
                                          named_at: entry.named_at, missing_since: missing_since)
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
