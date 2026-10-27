# frozen_string_literal: true

require "json"

module Switchboard
  # The live Claude Code sessions in the tracked worktrees, read from the per-session
  # files Claude keeps at `<claude dir>/sessions/<pid>.json`. Two cues ride this one
  # read: the ⇅ phone link (RemoteLink, a `bridgeSessionId` in the file) and the ◷
  # "waiting on background work" dot (`offstage`, the file's `status`). SessionName reads
  # them too (`sessions_in`), stricter, because it types into the session's pane.
  #
  # The file is UNDOCUMENTED, so everything here fails closed: a shape we don't
  # recognize is no session, never a wrong one, and nothing raises (a raise inside the
  # sidebar's agent scan would blank every dot). Two of the file's fields lie after a
  # `switchboard rename`: `cwd` and `tmux` are startup stamps. So a live session is
  # placed by its KERNEL cwd (one batched lsof), which follows the moved dir; the
  # recorded `cwd` is only the fallback. Verified live against Claude Code 2.1.308-2.1.310.
  module ClaudeSessions
    PID_MAX = 2**31 - 1 # pid_t: past it Process.kill raises RangeError, which would blank every cue

    # `status` while work Claude started is still running after its turn ended: `busy`
    # for a background agent (Claude never rewrites it at the Stop), `shell` for a
    # background Bash or the Monitor tool. Exact strings only; anything else is no
    # evidence (probed live on 2.1.310).
    OFFSTAGE_STATUSES = %w[busy shell].freeze

    # The one that HOLDS the done chime: a background agent always reports back with a
    # follow-up turn. A background shell may never end (a dev server), so beside `shell`
    # the chime rings at the Stop as before and only the ◷ says work is still running.
    HANDOFF_STATUS = "busy"

    # Claude writes `done` 13-29ms BEFORE `idle` on a normal turn end, and a finished
    # background agent reads `idle` for ~15ms before its follow-up turn reads `busy`
    # again. A 3s scan lands in those windows ~1% of the time, so both edges wait this
    # long: ◷ only once the hook's `done` has settled, a hold matures only on a settled
    # `idle`.
    SETTLE = 2

    module_function

    # A test/override seam first (keeps the suite off the real ~/.claude), then
    # Claude's own dir — shared with ClaudeHistory so the two readers never disagree.
    def sessions_dir
      override = ENV["SWITCHBOARD_CLAUDE_SESSIONS_DIR"]
      return override unless override.nil? || override.empty?

      File.join(ClaudeHistory.claude_root, "sessions")
    end

    # Every session file. `base:` keeps the dir out of the pattern: a CLAUDE_CONFIG_DIR like
    # `~/cfg [work]` would otherwise read its brackets as glob syntax and match nothing.
    def session_files
      dir = sessions_dir
      Dir.glob("*.json", base: dir).map { |f| File.join(dir, f) }
    end

    # { ws_path => [record, …] } for the tracked worktrees with a LIVE session, or nil
    # when the scan itself failed (callers must not read "failed" as "no sessions": a
    # held chime would ring). `cheap:` is any off-screen scan (the sidebar passes
    # !@visible): kill(0) liveness and the recorded cwd, no `ps`/`lsof` — every hidden
    # pane warms whenever ANYTHING in the warm fingerprint moves, so the full check there
    # would spawn per pane. Its rare misses (a recycled pid, a rename onto an old name)
    # last until the pane's next visible scan. `records:` replaces the file read (RemoteLink
    # passes only the linked ones when it scans for itself).
    def scan(ws_paths, cheap: false, records: nil)
      # Bytes, not text: under tmux's C locale git hands us US-ASCII paths while the JSON
      # cwd is UTF-8, and comparing a non-ASCII pair raises.
      roots = ws_paths.each_with_object({}) do |p, h|
        h[real(p).b] = p
        h[p.to_s.b] ||= p
      end
      # Before any fork: only sessions whose recorded cwd is in a tracked worktree. `same?`
      # is one `ps` per session and lsof scales with the pid list, and a machine can run
      # a dozen Claudes outside switchboard (~125ms per scan for 15, measured). A renamed
      # workspace still passes: its recorded old path resolves through the bridge symlink.
      records = (records || self.records).select { |r| owner(r[:cwd].b, roots) || owner(real(r[:cwd]).b, roots) }
      return {} if records.empty?

      # kill(0) first in both modes: a dead leftover's file can sit there forever.
      live = records.select do |r|
        ProcessIdentity.alive?(r[:pid]) && (cheap || ProcessIdentity.same?(r[:pid], r[:proc_start]))
      end
      return {} if live.empty?

      cwds = cheap ? {} : Agents.cwds_of(live.map { |r| r[:pid] })
      live.each_with_object(Hash.new { |h, k| h[k] = [] }) do |r, out|
        ws = owner(real(cwds[r[:pid]] || r[:cwd]).b, roots) or next
        out[ws] << r
      end.to_h
    rescue StandardError
      nil
    end

    # Every LIVE interactive session working in `ws_path`, linked or not — what
    # SessionName renames — or nil when that can't be told. Stricter than `scan` on
    # purpose, since the caller types keys: `kind: "interactive"` only (an allowlist: a
    # background job or some other kind has no prompt of ours), the full pid + start-time
    # check, and the KERNEL cwd only (no recorded-cwd fallback, which can name another
    # workspace after a rename onto an old name). lsof placing none of the live sessions
    # means lsof failed, not that none is here: nil — and so does one lsof couldn't place
    # whose recorded cwd is in this workspace. One it couldn't place elsewhere (another
    # user's Claude, a process exiting mid-scan) isn't ours to wait on. A session in a
    # worktree NESTED inside this one (`claude --worktree` puts them under .claude/) is
    # its own session, not this workspace's.
    def sessions_in(ws_path)
      live = records.select do |s|
        s[:kind] == RemoteLink::INTERACTIVE && ProcessIdentity.alive?(s[:pid]) && ProcessIdentity.same?(s[:pid], s[:proc_start])
      end
      return [] if live.empty?

      root = real(ws_path).b
      cwds = Agents.cwds_of(live.map { |s| s[:pid] })
      return nil if cwds.empty?

      unplaced, placed = live.partition { |s| cwds[s[:pid]].nil? }
      return nil if unplaced.any? { |s| inside?(real(s[:cwd]).b, root) }

      placed.select { |s| own_session?(real(cwds[s[:pid]]).b, root) }
    rescue StandardError
      nil
    end

    def inside?(cwd, root)
      cwd == root || cwd.start_with?("#{root}/")
    end

    # Inside `root`, and no other git checkout (a `.git` dir or file) sits between.
    def own_session?(cwd, root)
      return false unless inside?(cwd, root)

      dir = cwd
      while dir != root
        return false if File.exist?(File.join(dir, ".git"))

        dir = File.dirname(dir)
      end
      true
    end

    # What a worktree's live sessions say about background work, for the scan's
    # `sessions` (one ws path's list): :offstage when any reads busy/shell, :idle when
    # every one reads an `idle` at least SETTLE old, else nil (no evidence either way —
    # missing/unknown status, a `waiting`, or an idle too fresh to trust).
    def activity(sessions, now: Time.now)
      return nil if sessions.nil? || sessions.empty?
      return :offstage if sessions.any? { |r| OFFSTAGE_STATUSES.include?(r[:status]) }

      :idle if sessions.all? { |r| settled_idle?(r, now) }
    end

    # The off-screen warm gate's view of the ◷: sorted [cwd, offstage 0/1, alive 0/1, pid]
    # for every session recorded in a tracked worktree. It moves when such a session starts
    # or stops running background work, not on churn that keeps it on the same side, and
    # never for a Claude outside switchboard. Stats only for unchanged files: `cache`
    # (owned by the caller) maps file => [[mtime, size, inode], record], like
    # RemoteLink.fingerprint.
    def fingerprint(cache, ws_paths)
      roots = ws_paths.each_with_object({}) { |p, h| h[real(p).b] = p; h[p.to_s.b] ||= p }
      files = session_files
      cache.select! { |f, _| files.include?(f) }
      files.filter_map do |f|
        st = File.stat(f)
        stamp = [st.mtime.to_f, st.size, st.ino]
        cache[f] = [stamp, record(read_json(f))] unless cache[f]&.first == stamp
        r = cache[f][1] or next
        next unless owner(r[:cwd].b, roots) || owner(real(r[:cwd]).b, roots)

        [r[:cwd], OFFSTAGE_STATUSES.include?(r[:status]) ? 1 : 0, ProcessIdentity.alive?(r[:pid]) ? 1 : 0, r[:pid]]
      rescue StandardError
        nil
      end.sort
    rescue StandardError
      nil
    end

    def settled_idle?(rec, now)
      rec[:status] == "idle" && rec[:status_at].is_a?(Numeric) &&
        now.to_f - (rec[:status_at] / 1000.0) >= SETTLE # statusUpdatedAt is epoch ms
    end

    # Every shaped session file, parsed. One odd file loses only itself.
    def records
      session_files.filter_map do |f|
        record(read_json(f))
      rescue StandardError
        nil
      end
    end

    # The fields every reader relies on — the scanner (record) and the canary
    # (RemoteLink.health) share it, so doctor can't count a file a cue would ignore. A pid
    # in 1..PID_MAX: kill(0, 0) / kill(0, -1) "succeed" (process group / every process),
    # past pid_t kill raises.
    def shaped?(data)
      data.is_a?(Hash) && data["pid"].is_a?(Integer) && data["pid"].between?(1, PID_MAX) && data["cwd"].is_a?(String)
    end

    # The fields we use from one session file, or nil when it isn't a shape we recognize.
    # `bridge_id` is the raw value; RemoteLink validates it.
    def record(data)
      return nil unless shaped?(data)

      name = data["name"]
      { pid: data["pid"], cwd: data["cwd"], bridge_id: data["bridgeSessionId"], kind: data["kind"].to_s,
        started_at: data["startedAt"], proc_start: data["procStart"].to_s,
        status: data["status"].to_s, status_at: data["statusUpdatedAt"],
        name: name.is_a?(String) ? name : nil } # SessionName confirms a rename by it
    end

    # UTF-8 whatever the locale: under tmux's C locale a default read is US-ASCII,
    # and a session named with a smart quote would fail to parse and lose its cues.
    def read_json(file)
      scrub_strings(JSON.parse(File.read(file, encoding: "UTF-8").scrub))
    rescue StandardError
      nil
    end

    # A \u escape decodes AFTER the scrub above, so a lone surrogate still parses to an
    # invalid string, and the first strip/gsub/match on it raises. Scrub every parsed
    # string: a bad field then reads as unrecognized, never as a crash.
    def scrub_strings(value)
      case value
      when String then value.scrub
      when Array then value.map { |v| scrub_strings(v) }
      when Hash then value.to_h { |k, v| [scrub_strings(k), scrub_strings(v)] }
      else value
      end
    end

    # The deepest tracked worktree at or above `cwd` (an agent launched in a subdir
    # still belongs to its worktree), as the caller's own path.
    def owner(cwd, roots)
      root = roots.keys.select { |r| cwd == r || cwd.start_with?("#{r}/") }.max_by(&:length)
      root && roots[root]
    end

    def real(path)
      File.realpath(path)
    rescue StandardError
      path
    end
  end
end
