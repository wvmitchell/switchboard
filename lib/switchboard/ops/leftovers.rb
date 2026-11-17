# frozen_string_literal: true

require "set"
require "find"
require_relative "../support/paths"
require_relative "../support/keyed_marker_store"

module Switchboard
  # Every per-workspace store, in one registry, so nothing a deleted workspace left on disk
  # goes unnoticed: doctor reports what `scan` finds and prune removes it with `clear`. A
  # new store gets a row here or a place in GLOBAL; test/leftovers_test.rb fails until it
  # has one.
  #
  # An entry is a leftover when the folder it belongs to is gone, or when that folder sits
  # inside a registered project's folder under the worktree root yet isn't at or under any
  # worktree git lists (a half-removed tree a late writer re-seeded). The second test runs
  # only when every project's strict listing succeeded; a failed listing must never make a
  # live workspace look deleted. Rows whose entries carry no path (worker claims, typing
  # locks) are leftovers once their pid is dead.
  module Leftovers
    GRACE = 3600 # doctor counts an entry only after this long, so a scan about to GC it never flaps the ✗
    TEMP_AGE = 3600 # a crashed writer's temp file this old, with a dead pid, is debris

    # Stores that hold nothing per workspace (or, for the PR cache, branch names that
    # aren't paths; delete drops its branches' badges itself with Pr.forget).
    # `reserve-*.lock` files in the creation dir outlive every record by design.
    # delete-traces holds `delete`'s crash reports, dropped after TRACE_AGE.
    GLOBAL = %w[collapse branch_fold full_header width prs latest.json sounds sb-agent-hook delete-traces].freeze
    TRACE_AGE = 7 * 86_400

    # file: the entry's file; path: the folder it belongs to (nil for pid-keyed rows);
    # pid: the owning process for pid-keyed rows; rec: a Creation record, with the registered
    # project names its drop rule was decided against.
    Item = Struct.new(:row, :file, :path, :pid, :rec, :projects, :mtime, keyword_init: true)

    # listed: realpaths of every worktree a registered project lists, or nil when a strict
    # listing failed; roots: each registered project's folder under the worktree root.
    Context = Struct.new(:projects, :listed, :roots, :now, keyword_init: true)

    MARKER_TMP = /\A\h+\.(\d+)\.tmp\z/ # KeyedMarkerStore.write
    AGENT_TMP = /\A\d+\.(\d+)\z/       # the sh reporter's "$key.$$"

    module_function

    # Row name => store directory. Names keep their own 30-day rule in Reconcile.prune_names
    # (a hand-moved worktree can still get its name back), so they are listed here for the
    # registry but never cleared here.
    def dirs
      {
        attention: Attention.state_dir,
        monitoring: Monitoring.state_dir,
        notify: Notify.state_dir,
        offstage_hold: OffstageHold.state_dir,
        agents: AgentState.state_dir,
        session_outcome: SessionName::Outcome.dir,
        session_owner: SessionName::Owner.dir,
        session_locks: File.join(SessionName::Outcome.dir, ".locks"),
        pending_delete: PendingDelete.state_dir,
        delete_receipt: DeleteReceipt.dir,
        creation: Creation.state_dir,
        names: Names.dir
      }
    end

    # Read-only: { row => [Item] } of every leftover. Doctor's view.
    def scan(config, now: Time.now)
      ctx = context(config, now)
      dirs.keys.to_h { |row| [row, items(row, ctx).select { |i| leftover?(i, ctx) } + temps(row, now)] }
    end

    # Removes every leftover (prune). Returns { row => count } of what was (or, dry_run,
    # would be) removed.
    def clear(config, dry_run: false, now: Time.now)
      sweep_traces(now) unless dry_run
      scan(config, now: now).transform_values do |found|
        found.count { |item| dry_run || remove(item, now) }
      end
    end

    # Delete's own pass: every entry that belongs to the workspace at `real`, whatever its
    # age, except the rows delete settles itself. Returns the files it couldn't remove.
    def clear_workspace(real, except: [])
      ctx = Context.new(projects: [], listed: nil, roots: [], now: Time.now)
      (dirs.keys - except - %i[session_locks names]).flat_map do |row|
        mine = items(row, ctx).select { |i| owned?(i, real) }
        mine.each { |i| File.delete(i.file) rescue nil }
        mine.map(&:file).select { |f| File.exist?(f) }
      end
    end

    # Worker claims carry only a pid, so theirs is found by the key of the realpath.
    def owned?(item, real)
      return File.basename(item.file) == KeyedMarkerStore.key(real) if item.row == :session_owner
      return item.rec["id"] && item.path && Paths.real_or_self(item.path) == real if item.row == :creation

      !item.path.nil? && under?(item.path, real)
    end

    # Receipts of deletes that stopped while git still lists their workspace: doctor names
    # each with the delete that finishes it.
    def interrupted(config)
      ctx = context(config, Time.now)
      return [] unless ctx.listed

      DeleteReceipt.all.reject { |r| DeleteReceipt.owner_alive?(r) }.select { |r| ctx.listed.include?(r["real"]) }
    end

    def sweep_traces(now)
      Dir.glob(File.join(Deletion.traces_dir, "*")).each do |f|
        File.delete(f) if now - File.mtime(f) > TRACE_AGE
      rescue StandardError
        next
      end
    end

    # Doctor's count: only entries left over for longer than GRACE.
    def settled(found, now: Time.now)
      found.transform_values { |items| items.count { |i| now - i.mtime > GRACE } }.reject { |_, n| n.zero? }
    end

    # Folders under a registered project's worktree root that git doesn't list. Never
    # removed automatically: doctor names each with the command to run.
    def stray_folders(config)
      ctx = context(config, Time.now)
      return [] unless ctx.listed

      ctx.roots.flat_map do |root|
        Dir.children(root).filter_map do |leaf|
          dir = File.join(root, leaf)
          next if File.symlink?(dir) || !File.directory?(dir)
          next if ctx.listed.any? { |w| under?(w, dir) || under?(dir, w) } || in_other_repo?(dir, root) || holds_a_checkout?(dir)

          dir
        end
      rescue StandardError
        []
      end
    end

    # "attention 1, agents 2", for doctor and prune.
    def breakdown(counts) = counts.map { |row, n| "#{row.to_s.tr('_', ' ')} #{n}" }.join(", ")

    def context(config, now)
      root = Paths.real_or_self(config.worktree_root)
      listed = Set.new
      projects = []
      config.projects.each do |p|
        projects << p["name"]
        trees = Git.worktrees(p["path"], strict: true) if p["path"] && Dir.exist?(p["path"])
        listed = nil if trees.nil?
        listed&.merge(trees.map { |w| Paths.real_or_self(w[:path]) })
      end
      # A name that sanitizes to nothing would make the worktree root itself a project folder.
      roots = projects.compact.map { |n| Placeholder.sanitize(n) }.reject(&:empty?)
                      .map { |leaf| File.join(root, leaf) }.select { |d| File.directory?(d) }
      Context.new(projects: projects.compact, listed: listed, roots: roots, now: now)
    rescue StandardError
      Context.new(projects: [], listed: nil, roots: [], now: now)
    end

    def items(row, ctx)
      dir = dirs.fetch(row)
      case row
      when :attention, :notify, :session_outcome, :offstage_hold
        markers(row, dir) { |content| content.split("\t").first }
      when :monitoring then markers(row, dir) { |content| Monitoring.decode(content).first }
      when :agents then agent_items(dir)
      when :session_owner then pid_items(row, dir) { |f| File.read(f)[/\A\d+/] }
      when :session_locks then pid_items(row, dir) { |f| File.basename(f)[/\A\d+\z/] }
      when :pending_delete then markers(row, dir) { nil }
      when :creation then creation_items(ctx)
      when :delete_receipt
        DeleteReceipt.all.map do |r|
          Item.new(row: row, file: DeleteReceipt.file(r["real"]), path: r["real"], rec: r, mtime: File.mtime(DeleteReceipt.file(r["real"])))
        rescue StandardError
          nil
        end.compact
      else []
      end
    end

    def markers(row, dir)
      KeyedMarkerStore.entries(dir).filter_map do |file, content, mtime|
        Item.new(row: row, file: file, path: yield(content), mtime: mtime)
      rescue StandardError # a marker that isn't valid UTF-8, say: skipped, as the sidebar's scan skips it
        nil
      end
    end

    # One line "<state>\t<cwd>\t<epoch>" per file; a torn or foreign file is skipped, as
    # AgentState skips it.
    def agent_items(dir)
      Dir.glob(File.join(dir, "*")).filter_map do |file|
        next unless File.file?(file) && !File.basename(file).match?(AGENT_TMP)

        state, cwd, epoch = File.read(file).chomp.split("\t", 3)
        next unless state && cwd && epoch && AgentState::STATES.include?(state)

        Item.new(row: :agents, file: file, path: cwd, mtime: File.mtime(file))
      rescue StandardError
        nil
      end
    end

    def pid_items(row, dir)
      Dir.glob(File.join(dir, "*")).filter_map do |file|
        next unless File.file?(file) && !File.basename(file).match?(MARKER_TMP)

        pid = yield(file) or next
        Item.new(row: row, file: file, pid: pid.to_i, mtime: File.mtime(file))
      rescue StandardError
        nil
      end
    end

    def creation_items(ctx)
      Creation.all.filter_map do |rec|
        file = Creation.file(rec["id"])
        Item.new(row: :creation, file: file, path: rec["path"], rec: rec, projects: ctx.projects, mtime: File.mtime(file))
      rescue StandardError
        nil
      end
    end

    # Anything that can't be decided (a corrupt pid, an unreadable record) is kept.
    def leftover?(item, ctx)
      decide(item, ctx)
    rescue StandardError
      false
    end

    def decide(item, ctx)
      case item.row
      when :pending_delete then ctx.now - item.mtime > PendingDelete::TTL
      when :session_owner, :session_locks then !ProcessIdentity.alive?(item.pid)
      when :creation then creation_leftover?(item.rec, ctx)
      # A dead owner's delete whose workspace git no longer lists: prune finishes it.
      when :delete_receipt then !ctx.listed.nil? && !DeleteReceipt.owner_alive?(item.rec) && !ctx.listed.include?(item.path)
      else orphaned?(item.path, ctx)
      end
    end

    # The same decision the sidebar's Creation.gc makes, with its owner-alive test.
    def creation_leftover?(rec, ctx)
      live = ->(r) { Creation.owner_alive?(r, ctx.now, ProcessIdentity.method(:same?)) }
      Creation.drop?(rec, ctx.projects, live)
    end

    def orphaned?(path, ctx)
      return false if path.nil? || path.empty?
      return true unless Dir.exist?(path)
      return false unless ctx.listed

      real = Paths.real_or_self(path)
      root = ctx.roots.find { |r| real.start_with?("#{r}/") } or return false
      ctx.listed.none? { |w| under?(real, w) } && !in_other_repo?(real, root)
    end

    # Is there a checkout anywhere inside `dir`? A folder that holds one is never stray,
    # whoever's it is.
    def holds_a_checkout?(dir)
      Find.find(dir) { |f| return true if File.basename(f) == ".git" && live_git?(f) }
      false
    rescue StandardError
      true
    end

    # A clone's `.git` folder, or a linked worktree's `.git` file whose admin dir still exists.
    def live_git?(dot)
      return true if File.directory?(dot)

      File.file?(dot) && File.directory?(File.expand_path(File.read(dot)[/\Agitdir: (.+)$/, 1].to_s, File.dirname(dot)))
    end

    # Is `path`, or a folder above it below `root`, a checkout git still knows: a clone, or
    # a worktree of another repository whose admin dir still exists? Such a folder isn't
    # ours to call stray, even though our projects don't list it.
    def in_other_repo?(path, root)
      dir = path
      while dir.start_with?("#{root}/")
        return true if live_git?(File.join(dir, ".git"))

        dir = File.dirname(dir)
      end
      false
    rescue StandardError
      true
    end

    # A crashed writer's temp file: its own store's naming, a dead pid, and old.
    def temps(row, now)
      pattern = row == :agents ? AGENT_TMP : MARKER_TMP
      return [] if %i[creation names].include?(row) # Creation.gc sweeps its own; Names' are cleaned by its writer

      Dir.glob(File.join(dirs.fetch(row), "*")).filter_map do |file|
        pid = File.basename(file)[pattern, 1] or next
        mtime = File.mtime(file)
        next if now - mtime <= TEMP_AGE || ProcessIdentity.alive?(pid.to_i)

        Item.new(row: row, file: file, pid: pid.to_i, mtime: mtime)
      rescue StandardError
        nil
      end
    end

    # True once the entry is gone. A Creation record is re-decided under its lock, so a
    # writer that changed it since the scan (an ack, a repath) wins.
    def remove(item, now)
      if item.row == :delete_receipt
        Deletion.resume(item.rec)
        return DeleteReceipt.read(item.path).nil?
      end

      if item.rec
        live = ->(r) { Creation.owner_alive?(r, now, ProcessIdentity.method(:same?)) }
        Creation.delete(item.rec["id"], wait: false) { |cur| Creation.drop?(cur, item.projects, live) }
      else
        File.delete(item.file)
      end
      !File.exist?(item.file)
    rescue StandardError
      !File.exist?(item.file)
    end

    def under?(path, root)
      path == root || path.start_with?("#{root}/")
    end
  end
end
