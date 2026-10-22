# frozen_string_literal: true

require "json"
require "securerandom"
require "fileutils"
require_relative "keyed_marker_store"
require_relative "marker_block"
require_relative "process_identity"
require_relative "attention"

module Switchboard
  # The lifecycle of a background ("dispatched") workspace create: `n` writes a record,
  # a detached worker (Creator.work) builds the worktree, the launcher typed into the new
  # pane (Creator.launch) runs setup and starts the agent, and every sidebar renders and
  # pings from the record. It lives on disk for the same multi-process reason as
  # Attention/PendingDelete — but unlike those markers it is a small JSON record that
  # several processes MUTATE, so every write goes through `mutate`: a read-modify-write
  # under an exclusive flock on a per-record lock file, then an atomic temp+rename.
  # Readers stay lock-free (rename is atomic, so a read sees the old or the new record).
  # The lock is a SEPARATE file on purpose: locking the data file itself would lock the
  # inode the rename is about to replace.
  #
  #   queued → building → launching → ready → turn_done
  #     └────────┴───────────┴──→ failed            (and → canceled on quit / remove / d)
  #
  # A first turn that ends inside the launch grace goes launching → turn_done directly;
  # a hooked task whose agent exits before any Stop goes ready → turn_done (exit 0) or
  # ready → failed.
  #
  # `setup_ok` marks a build whose setup succeeded: a later failure or cancel (the agent
  # exiting fast, a quit mid-grace) no longer blocks the agent on re-entry.
  #
  # `acked` is a sticky flag, not a state: once you've viewed the workspace no ping
  # fires for it, however the build ends. The record's OWNER (pid + start time) is
  # whoever drives it — the worker through `building`, the launcher from `launching`
  # on — so GC can tell a slow build from a dead one without a TTL.
  module Creation
    module_function

    PRE_READY = %w[queued building launching].freeze
    SPAWN_GRACE = 30 # a queued record with no owner this long means the worker never started
    FIRST_TURN_MARGIN = 10
    FIRST_TURN_CEILING = 30 * 60
    # A pre-ready build whose owner can only be matched by pid (its start time was never
    # read) can't tell a live owner from a recycled pid; past this it's called dead.
    PID_ONLY_CEILING = 60 * 60
    ORPHAN_AGE = 60 # a lock/temp file with no record this old is debris

    # One table for every failure reason: the ≤14-col text on the ✘ row, and the
    # longer line shown on ↵ (flash) or printed in the pane. `%s` is the record's detail.
    REASONS = {
      "setup" => { row: "setup exit %s",
                   pane: "switchboard: setup failed (exit %s); fix it, then run your agent, or press d on the row" },
      "worktree_add" => { row: "worktree add", flash: "worktree add failed: %s" },
      "agent_exit" => { row: "agent exit %s",
                        pane: "switchboard: agent exited %s right after launch; check session_command" },
      "session" => { row: "no session", flash: "couldn't create the tmux session" },
      "config" => { row: "config error",
                    pane: "switchboard: couldn't read this project's config, so setup can't run; nothing started — fix config.yml, then press d and n again" },
      "interrupted" => { row: "interrupted", flash: "the build was interrupted; press d and try n again" },
      "didnt_start" => { row: "didn't start", flash: "the build never started; press d and try n again" }
    }.freeze

    NOTICES = {
      task_not_sent: "switchboard: task not sent; add {task} to session_command for this agent",
      reentry: "switchboard: setup did not succeed (%s), so switchboard won't start the agent here; finish setup and start it by hand, or press d on the row",
      reentry_canceled: "switchboard: this build was canceled before its agent started; finish setup and start it by hand, or press d",
      reentry_building: "switchboard: setup hasn't finished here, so the agent wasn't started; press d on the row, or run it once setup is done",
      no_agent: "switchboard: no session_command configured; task not sent",
      canceled: "switchboard: this build was canceled; its agent was not started"
    }.freeze

    def create(project:, name:, path:, task:, now: Time.now, server: current_server)
      id = "#{now.strftime('%Y%m%d%H%M%S')}-#{SecureRandom.hex(3)}"
      rec = { "id" => id, "project" => project, "name" => name, "path" => path, "task" => task.to_s,
              "state" => "queued", "worktree_added" => false, "hooked" => false, "acked" => false,
              "gen" => 0, "ring_gen" => 0, "rung_gen" => 0, "created_at" => now.to_f, "server" => server }
      write(rec) ? rec : nil
    end

    # The tmux server (socket path) a dispatch belongs to, from $TMUX — never a tmux
    # shell-out, so this can't reach some other server. nil outside tmux.
    def current_server
      s = ENV["TMUX"].to_s.split(",").first
      s.to_s.empty? ? nil : s
    end

    def find(id)
      read(file(id))
    end

    # Serialize name reservation per project across every process (each pane, each
    # worker's collision retry): picking a free placeholder and writing the record that
    # claims it must be one step, or two panes can pick the same name and the launcher
    # would claim the other one's task. Not re-entrant (flock per open file).
    def with_project_lock(project)
      FileUtils.mkdir_p(state_dir)
      File.open(File.join(state_dir, "reserve-#{KeyedMarkerStore.key(project)}.lock"), File::RDWR | File::CREAT, 0o644) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      end
    end

    # Every live record, oldest first. A torn/in-flight file is skipped this cycle.
    def all
      Dir.glob(File.join(state_dir, "*.json")).filter_map { |f| read(f) }.sort_by { |r| r["created_at"].to_f }
    rescue StandardError
      []
    end

    # The record for a worktree path, compared by realpath (an agent's cwd keeps the old
    # path after a rename — the bridge symlink resolves it to the new dir).
    # The NEWEST match wins: a finished record can outlive its tree and share a path
    # with a later build (a name reused by rename or a fresh placeholder), and only the
    # newest one is the build in this dir — the reservation lock keeps two in-flight.
    def for_path(path)
      real = real_path(path)
      all.reverse.find { |r| r["path"] && real_path(r["path"]) == real }
    end

    # Is the tree at `path` a build of ours that never got set up? Then a lock on it is
    # the one an interrupted `worktree add` left (git writes that lock's text in your
    # locale, so the record, not the text, says whose it is), and `d` may force past it.
    # A lock on any other workspace is yours and stays.
    def unfinished_at?(path)
      rec = for_path(path)
      rec ? unfinished?(rec) : false
    end

    # The one write primitive: read under the lock, hand the block a copy, write back
    # whatever it returns (nil aborts). Returns the written record or nil. `wait: false`
    # is for the sidebar's background writers (ring claims, GC, acks): they skip a record
    # another process is busy with rather than freeze the input loop — the next scan
    # gets it.
    def mutate(id, wait: true)
      # A stale id (a gone record) must not leave a fresh lock file behind for nothing.
      return nil unless File.exist?(file(id))

      File.open(lock_file(id), File::RDWR | File::CREAT, 0o644) do |lock|
        return nil unless lock.flock(wait ? File::LOCK_EX : File::LOCK_EX | File::LOCK_NB)
        rec = find(id)
        return nil unless rec

        out = yield(rec.dup)
        out && write(out) ? out : nil
      end
    rescue StandardError
      nil
    end

    # A state change, applied only if the current state is in `from` (so a racing
    # writer that already advanced the record wins and this no-ops). Bumps `gen`, and
    # stamps `ring_gen` when the new state is one that should ping.
    def transition(id, from:, to:, **fields)
      from = Array(from).map(&:to_s)
      mutate(id) do |rec|
        next nil unless from.include?(rec["state"])

        advance(rec, to.to_s, fields.transform_keys(&:to_s))
      end
    end

    # A locked field update that changes no state (ack, path, hooked). nil when the
    # record is gone or, with `unless_state`, when it's in one of those states.
    def update(id, unless_state: nil, wait: true, **fields)
      skip = Array(unless_state).map(&:to_s)
      mutate(id, wait: wait) do |rec|
        next nil if skip.include?(rec["state"])

        rec.merge(fields.transform_keys(&:to_s))
      end
    end

    def owner_fields(pid = Process.pid)
      { owner_pid: pid, owner_start: ProcessIdentity.start_of(pid) }
    end

    # The detail is shown in the sidebar and printed in the pane, and can carry git's or a
    # hook's raw output — strip control bytes so it can't smuggle terminal escapes.
    def mark_failed(id, reason, detail = nil, from: PRE_READY)
      transition(id, from: from, to: :failed, reason: reason, detail: detail&.to_s&.gsub(/[[:cntrl:]]/, " "))
    end

    # Sticky "you've seen it": no ping ever fires for an acked record.
    def ack(id, wait: true)
      update(id, wait: wait, acked: true)
    end

    def ack_path(path)
      rec = path && for_path(path)
      ack(rec["id"], wait: false) if rec && !rec["acked"]
    end

    # Teardown: flip every in-flight build in scope to canceled BEFORE sessions are
    # killed. The worker creates its session under this same lock, so a build is either
    # canceled before it makes a session or its session already exists to be killed.
    # Scoped to this tmux server: a quit here kills only this server's sessions, so it
    # must not cancel another server's builds (records from outside tmux, or written
    # before records carried a server, have none and stay in scope).
    def cancel_all(projects: nil, server: current_server)
      all.each do |rec|
        next if projects && !Array(projects).include?(rec["project"])
        next if server && rec["server"] && rec["server"] != server

        transition(rec["id"], from: PRE_READY, to: :canceled)
      end
    end

    # The launcher's ONE go-ahead for the agent, after setup succeeded: a single locked
    # step that records setup_ok and agent_started only if the build is still launching.
    # A missing record (GC'd), or one canceled or failed meanwhile, means nil: don't start.
    def authorize_launch(id, hooked: nil)
      mutate(id) do |rec|
        next nil unless rec["state"] == "launching"

        rec.merge({ "setup_ok" => true, "agent_started" => true }, hooked.nil? ? {} : { "hooked" => hooked })
      end
    end

    # A Stop hook ended a hooked task's first turn. From `ready`, or from `launching`
    # once the agent has started (a turn can end inside the launch grace) — never while
    # setup runs: a setup step that itself runs claude must not stamp the build done
    # and hide its own later failure.
    def stamp_first_turn(id)
      mutate(id) do |rec|
        live = rec["state"] == "ready" || (rec["state"] == "launching" && rec["agent_started"])
        # A bare create already rang at ready; its first Stop is an ordinary :done.
        next nil unless rec["hooked"] && !rec["task"].to_s.empty? && live

        advance(rec, "turn_done")
      end
    end

    # Can the workspace be renamed yet? Not while the worker still holds the old path
    # (queued/building) or setup runs in it (launching before the agent starts): the
    # setup env and the agent's chdir were computed from it.
    def renamable?(rec)
      return true unless rec

      !(%w[queued building].include?(rec["state"]) || (rec["state"] == "launching" && !rec["agent_started"]))
    end

    # Carry a record across a workspace rename. Matched by its raw path, or by the
    # realpath captured BEFORE the move: afterwards the old path is a bridge symlink
    # that resolves to the NEW dir, so comparing realpaths then would never match.
    def repath(old_path, old_real, new_path)
      # Newest first, like for_path: an older record can share the path.
      rec = all.reverse.find { |r| r["path"] == old_path || (r["path"] && real_path(r["path"]) == old_real) }
      update(rec["id"], path: new_path, name: File.basename(new_path)) if rec
    end

    # Does this record's latest transition deserve a ping? A bare create pings on ready;
    # a tasked create pings on its first turn when a Stop hook will report it, else on
    # ready; any failure pings. Queued/building/launching never do.
    def ringing?(rec)
      case rec["state"]
      when "ready" then rec["task"].to_s.empty? || !rec["hooked"]
      when "turn_done", "failed" then true
      else false
      end
    end

    def ring_due?(rec)
      !rec["acked"] && rec["ring_gen"].to_i > rec["rung_gen"].to_i
    end

    # Exactly-once ring: only the first pane to win this compare-and-set rings.
    # Returns the record when the caller should ring, nil otherwise.
    def claim_ring(id)
      mutate(id, wait: false) do |rec|
        next nil unless ring_due?(rec)

        rec.merge("rung_gen" => rec["ring_gen"], "rung_at" => Time.now.to_f)
      end
    end

    # Is this record still waiting to own its first-turn ping? While true, the
    # normal completion edge for the worktree stands aside so you hear one chime.
    # Once the turn_done ping has rung, it lets go after FIRST_TURN_MARGIN (that turn's
    # own :done edge can land a scan later) so the agent's LATER turns chime as usual.
    # And if the stamp never comes (a stale hook binary, a hook timeout), ownership
    # lapses after FIRST_TURN_CEILING so the workspace isn't muted forever.
    def owns_first_turn?(rec, now: Time.now)
      return false unless rec && rec["hooked"] && !rec["task"].to_s.empty? && !rec["acked"]

      case rec["state"]
      when "launching" then true
      when "ready" then now.to_f - rec["updated_at"].to_f <= FIRST_TURN_CEILING
      when "turn_done" then ring_due?(rec) || now.to_f - rec["rung_at"].to_f <= FIRST_TURN_MARGIN
      else false
      end
    end

    # GC, run from the sidebar's scans. Returns the surviving records.
    #   1. queued with no owner past SPAWN_GRACE → failed(didn't start)
    #   2. pre-ready whose owner is dead or recycled → failed(interrupted)
    #   3. a once-built worktree that's gone → dropped (it was deleted). Nothing in
    #      flight is ever dropped: rules 1–2 settle a dead build first
    #   4. acked + terminal, and canceled → dropped — EXCEPT a failed or canceled build
    #      whose worktree exists and whose setup never succeeded: the record stays until
    #      that worktree is deleted, and re-entering it opens a plain shell, not the agent.
    #      A canceled record also stays while its owner lives: a worker still inside
    #      `worktree add` must find it to record the tree it may have to keep
    #   5. a project no longer configured → dropped once it's no longer in flight (nothing
    #      renders or acks it), but only when handed a non-empty list, so a failed config
    #      read can't wipe every record
    # The drop is re-decided under the record lock, so a writer that changed the record
    # since our lock-free read (an ack, a repath) wins. GC never waits on a lock another
    # process holds — it gets that record next scan. `owners: false` skips rules 1–2
    # (their `ps` per in-flight build) for an off-screen pane's warm reload.
    def gc(now: Time.now, same: ProcessIdentity.method(:same?), projects: nil, owners: true)
      sweep_orphans(now)
      # Off screen (no `ps`), any owner counts as alive: a canceled record waits a scan.
      live = owners ? ->(r) { owner_alive?(r, now, same) } : ->(_r) { true }
      all.filter_map do |rec|
        rec = reap_dead_owner(rec, now, same) if owners && PRE_READY.include?(rec["state"])
        # A tree the worker never got to record (killed mid-add): record it now, so its
        # later deletion clears the row like any other (rule 3). Never while the build is
        # in flight — a live add's `.git` can still be rolled back, and the worker owns it.
        if !PRE_READY.include?(rec["state"]) && !rec["worktree_added"] && tree_on_disk?(rec)
          rec = update(rec["id"], wait: false, worktree_added: true) || rec
        end
        next if drop?(rec, projects, live) && delete(rec["id"], wait: false) { |cur| drop?(cur, projects, live) }

        rec
      end
    end

    # Lock and temp files whose record is gone (a crash mid-delete, a failed write) —
    # never a reservation lock, which outlives every record by design.
    def sweep_orphans(now)
      Dir.glob(File.join(state_dir, "*.{lock,sb-tmp}")).each do |f|
        base = File.basename(f)
        next if base.start_with?("reserve-")
        next if File.exist?(file(base.split(".").first))
        next if now - File.mtime(f) <= ORPHAN_AGE

        File.delete(f)
      rescue StandardError
        next
      end
    end

    # Rules 1–2: a pre-ready record whose builder is gone becomes a ✘. Rule 2 re-checks
    # under the lock — the owner may have just handed off to the launcher or advanced.
    def reap_dead_owner(rec, now, same)
      if rec["owner_pid"].nil?
        return rec if now.to_f - rec["created_at"].to_f <= SPAWN_GRACE

        return mark_failed(rec["id"], "didnt_start", from: "queued") || rec
      end
      return rec if owner_alive?(rec, now, same)

      mutate(rec["id"], wait: false) do |cur|
        next nil unless PRE_READY.include?(cur["state"]) && cur["owner_pid"] == rec["owner_pid"]

        advance(cur, "failed", "reason" => "interrupted")
      end || find(rec["id"]) || rec
    end

    # The one liveness test for a record's owner (GC's reap and its keep-canceled rule).
    # An unreadable start time — now, or when the owner was recorded (a transient `ps`
    # miss) — can't prove the owner is gone; only a dead pid can. Failing a healthy
    # build is worse than a late ✘.
    def owner_alive?(rec, now, same)
      return false unless rec["owner_pid"]
      return true if same.call(rec["owner_pid"], rec["owner_start"])

      unknown = rec["owner_start"].to_s.empty? || ProcessIdentity.start_of(rec["owner_pid"]).empty?
      pid_only_expired = rec["owner_start"].to_s.empty? && now.to_f - rec["created_at"].to_f > PID_ONLY_CEILING
      unknown && ProcessIdentity.alive?(rec["owner_pid"]) && !pid_only_expired
    end

    def drop?(rec, projects = nil, live = ->(_r) { false })
      # In flight, a missing tree is the worker's to report (a failed add rolled back):
      # dropping here would swallow its ✘ and the task with it.
      return false if PRE_READY.include?(rec["state"])
      return true if rec["worktree_added"] && rec["path"] && !Dir.exist?(rec["path"])
      # Before the project rule: an un-set-up tree still ON DISK stays guarded even if
      # its project is removed and later re-registered. Disk, not `worktree_added`: an add
      # killed mid-checkout, or a rollback git refused, leaves a tree the flag never saw.
      return false if unfinished?(rec) && tree_on_disk?(rec)
      return false if rec["state"] == "canceled" && rec["owner_pid"] && live.call(rec)
      return true if projects&.any? && !projects.include?(rec["project"]) && !PRE_READY.include?(rec["state"])
      return true if rec["state"] == "canceled"

      rec["acked"] && terminal?(rec)
    end

    # A checkout git could hand back as a workspace (a linked worktree's `.git` file).
    # A bare leftover dir without one can't be entered, so it needs no guard.
    def tree_on_disk?(rec)
      rec["path"] ? File.exist?(File.join(rec["path"], ".git")) : false
    end

    # A build that stopped before its setup succeeded: its worktree must never get the
    # agent. (A failure or cancel AFTER setup — a fast agent exit — leaves it usable.)
    def unfinished?(rec)
      %w[failed canceled].include?(rec["state"]) && !rec["setup_ok"]
    end

    # May a fresh session here start the agent? Only once setup has succeeded — a build
    # still in flight (its session died mid-setup) is no more set up than a failed one.
    def certified?(rec)
      rec.nil? || rec["setup_ok"] ? true : false
    end

    def terminal?(rec)
      case rec["state"]
      when "failed", "turn_done", "canceled" then true
      # a bare / hook-less ready is done; a hooked one waits for its first turn — unless
      # you've already looked, after which its ping can never fire anyway
      when "ready" then ringing?(rec) || rec["acked"]
      else false
      end
    end

    # The ✘ row's short reason (≤14 cols) and the full line for ↵ / the pane.
    def row_reason(rec)
      spec = REASONS[rec["reason"].to_s] or return "failed"
      format(spec[:row], rec["detail"].to_s)
    end

    def long_reason(rec)
      spec = REASONS[rec["reason"].to_s] or return "the build failed"
      format(spec[:flash] || spec[:pane], rec["detail"].to_s)
    end

    def notice(kind, *args)
      format(NOTICES.fetch(kind), *args)
    end

    # Under the record lock, so a writer that already read the record can't write it
    # back after we delete it; one still queued on the lock then finds nothing.
    # With a block, deletes only if it still says yes for the record as re-read under
    # the lock. True when this call deleted the record.
    def delete(id, wait: true)
      return false unless File.exist?(file(id))

      File.open(lock_file(id), File::RDWR | File::CREAT, 0o644) do |lock|
        return false unless lock.flock(wait ? File::LOCK_EX : File::LOCK_EX | File::LOCK_NB)
        cur = find(id)
        return false unless cur && (!block_given? || yield(cur))

        File.delete(file(id))
        File.delete(lock_file(id))
      end
      true
    rescue StandardError
      false
    end

    # Records are matched by realpath (the sidebar indexes its rows the same way).
    def real_path(path)
      File.realpath(path)
    rescue StandardError
      path
    end

    # --- internals ---------------------------------------------------------------

    # Apply a state change. A ringing one also bolds the row right here, from whichever
    # process made it (worker, launcher, Stop hook, GC): the bold must survive with no
    # sidebar on screen. Attention only marks an existing dir; a pre-worktree ✘ renders
    # its bold from the record instead.
    def advance(rec, to, fields = {})
      rec.merge!(fields)
      rec["state"] = to
      rec["gen"] = rec["gen"].to_i + 1
      rec["updated_at"] = Time.now.to_f
      if ringing?(rec)
        rec["ring_gen"] = rec["gen"]
        Attention.mark(rec["path"]) if rec["path"] && !rec["acked"]
      end
      rec
    end

    def write(rec)
      MarkerBlock.atomic_write(file(rec["id"]), JSON.generate(rec))
      true
    rescue StandardError
      false
    end

    # Always UTF-8: under a C locale (no LANG — a minimal shell, launchd) a task with a
    # smart quote or emoji would read as US-ASCII, fail to parse, and the build would
    # vanish as if torn.
    def read(path)
      raw = File.read(path, encoding: Encoding::UTF_8)
      raw.strip.empty? ? nil : JSON.parse(raw)
    rescue StandardError
      nil
    end

    def file(id)
      File.join(state_dir, "#{id}.json")
    end

    def lock_file(id)
      File.join(state_dir, "#{id}.lock")
    end

    def state_dir
      KeyedMarkerStore.dir("SWITCHBOARD_CREATION_DIR", "creation")
    end
  end
end
