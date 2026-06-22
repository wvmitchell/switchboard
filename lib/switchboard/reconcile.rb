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
      Model.new(config, with_dirty: false).projects.each do |project|
        names = project.worktrees.map { |w| Tmux.session_name(w) }
        next if names.empty?

        prefixes << Tmux.session_prefix(project.name)
        valid.concat(names)
      end

      orphaned = orphans(live, valid, prefixes, current: Tmux.session_of, now: now)
      orphaned.each { |name| Tmux.kill_session(name) } unless dry_run
      Report.new(reachable: true, sb_count: live.size, orphans: orphaned)
    end
  end
end
