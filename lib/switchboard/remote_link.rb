# frozen_string_literal: true

require "json"
require "set"
require "time"

module Switchboard
  # Which workspaces are reachable from your phone right now: a Claude session with
  # `/remote-control` (`/rc`) on. Observed, not declared (unlike the ∞ monitor dot) —
  # Claude already writes the truth. Every live session has
  # `<claude dir>/sessions/<pid>.json`, and `/rc` adds a `bridgeSessionId` to it
  # (removed on disconnect, re-keyed on reconnect); the link is
  # https://claude.ai/code/<bridgeSessionId>.
  #
  # That file is UNDOCUMENTED, so everything here fails closed: a shape we don't
  # recognize is no link, never a wrong one, and nothing raises (a raise inside the
  # sidebar's agent scan would blank every dot). `doctor` runs `health` as the canary
  # for a format change. Two of the file's fields lie after a `switchboard rename`:
  # `cwd` and `tmux` are startup stamps. So a live session is placed by its KERNEL cwd
  # (one batched lsof), which follows the moved dir; the recorded `cwd` is only the
  # fallback. Verified live against Claude Code 2.1.308.
  module RemoteLink
    URL_BASE = "https://claude.ai/code/"
    PID_MAX = 2**31 - 1 # pid_t: past it Process.kill raises RangeError, which would blank every link
    BRIDGE_ID = /\Asession_[A-Za-z0-9]{1,64}\z/ # bounded so a link URL always stays short

    # One linked session. `stale` = an interactive link idle past the configured
    # threshold (its ⇅ goes grey); a background job (`kind: "bg"`) is never stale —
    # idling is what background jobs do.
    Link = Struct.new(:pid, :bridge_id, :kind, :started_at, :stale, keyword_init: true) do
      def url
        URL_BASE + bridge_id
      end

      def bg?
        RemoteLink.bg_kind?(kind)
      end
    end

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

    # { ws_path => [Link, …] } for the tracked worktrees with a LIVE linked session,
    # newest first by startedAt (procStart when that's missing), then pid. `stale_after` is seconds or
    # nil (off). Total: any failure is "no links". `cheap:` is any off-screen scan (the
    # sidebar passes !@visible): kill(0) liveness and the recorded cwd, no `ps`/`lsof` —
    # every hidden pane warms whenever ANYTHING in the warm fingerprint moves, so the
    # full check there would spawn per pane. Its rare misses (a recycled pid, a rename
    # onto an old name) last until the pane's next visible scan.
    def scan(ws_paths, stale_after:, now: Time.now, cheap: false)
      records = linked_records
      return {} if records.empty?

      # kill(0) first in both modes: a dead leftover's file can sit there forever, and
      # `same?` forks a `ps` per call — every scan, on every visible pane.
      live = records.select do |r|
        ProcessIdentity.alive?(r[:pid]) && (cheap || ProcessIdentity.same?(r[:pid], r[:proc_start]))
      end
      return {} if live.empty?

      cwds = cheap ? {} : Agents.cwds_of(live.map { |r| r[:pid] })
      # Bytes, not text: under tmux's C locale git hands us US-ASCII paths while the JSON
      # cwd is UTF-8, and comparing a non-ASCII pair raises — which `scan`'s rescue turns
      # into "no links anywhere".
      roots = ws_paths.to_h { |p| [real(p).b, p] }
      live.each_with_object(Hash.new { |h, k| h[k] = [] }) do |r, out|
        ws = owner(real(cwds[r[:pid]] || r[:cwd]).b, roots) or next
        out[ws] << link(r, stale_after, now)
      end.transform_values { |links| links.sort_by { |l| order_key(l) }.reverse }
    rescue StandardError
      {}
    end

    # The off-screen warm gate's view: sorted [cwd, bridge-id, stale 0/1, alive 0/1, pid] for every
    # file carrying a bridge id — liveness is kill(0) only, no ps/lsof, so a hidden pane
    # pays one stat per file. Claude rewrites these files on every busy/idle flip of EVERY session on
    # the machine, so a dir-mtime fingerprint would wake every hidden sidebar for
    # unrelated work; this one moves only when a link appears, ends or goes stale.
    # `cache` (owned by the caller) maps file => [stamp, record]; only a file whose
    # stamp moved is re-parsed. The stamp is mtime + size + inode, not mtime alone:
    # ext4 mtimes tick every few ms, so a /rc toggle written in the same tick as a
    # status flip would read as unchanged — but adding/removing the bridge id changes
    # the size, and a whole-file rewrite changes the inode.
    def fingerprint(cache, stale_after:, now: Time.now)
      files = session_files
      cache.select! { |f, _| files.include?(f) }
      files.filter_map do |f|
        st = File.stat(f)
        stamp = [st.mtime.to_f, st.size, st.ino]
        cache[f] = [stamp, record(read_json(f))] unless cache[f]&.first == stamp
        r = cache[f][1] or next
        # alive? is kill(0), no subprocess: a linked Claude killed before it could remove
        # its file still moves the fingerprint, so hidden panes drop its ⇅ too.
        #
        # 0/1, not booleans, plus the pid: Array#sort can't order true against false, so two
        # files sharing cwd + bridge id (a crash leftover beside its resumed session) would raise.
        [r[:cwd], r[:bridge_id], stale?(r, stale_after, now) ? 1 : 0, ProcessIdentity.alive?(r[:pid]) ? 1 : 0, r[:pid]]
      rescue StandardError
        nil
      end.sort
    rescue StandardError
      nil
    end

    # The doctor canary. `files` session files read, `shaped` of them parse into the
    # fields we rely on (a drop to 0 with files present means Claude changed the
    # format), `alive` of those name a running Claude Code process (a recycled pid now
    # running something else is excluded), `drift` of THOSE whose recorded
    # procStart doesn't match `ps`, and `linked` live links. One drifted pid is
    # usually a crash leftover whose pid the OS recycled; a real procStart format
    # change fails every live session at once — so doctor alarms only on
    # drift == alive. A RENAMED bridge key is undetectable — it reads as "nothing linked".
    def health
      parsed = session_files.map { |f| read_json(f) }
      shaped = parsed.select { |d| shaped?(d) }
      running = shaped.select { |d| ProcessIdentity.alive?(d["pid"]) }
      claude = claude_pids(running.map { |d| d["pid"] })
      alive = running.select { |d| claude.include?(d["pid"]) } # a recycled pid running something else says nothing about Claude
      same = alive.select { |d| ProcessIdentity.same?(d["pid"], d["procStart"]) }
      linked = same.count { |d| d["bridgeSessionId"].to_s.match?(BRIDGE_ID) }
      { dir: sessions_dir, files: parsed.size, shaped: shaped.size, alive: alive.size,
        drift: alive.size - same.size, linked: linked }
    rescue StandardError
      { dir: sessions_dir, files: 0, shaped: 0, alive: 0, drift: 0, linked: 0 }
    end

    # Those of `pids` that are Claude Code processes, by executable name — argv[0] (`claude
    # …`, `claude bg-spare …`) or the script node runs. NOT a substring match: plenty of
    # processes merely mention ~/.claude in their arguments. One batched ps; doctor only.
    def claude_pids(pids)
      pids = pids.map(&:to_i).select(&:positive?)
      return Set.new if pids.empty?

      out = IO.popen({ "LC_ALL" => "C" }, ["ps", "-o", "pid=,command=", "-p", pids.join(",")], err: File::NULL, &:read)
      out.to_s.lines.each_with_object(Set.new) do |line, set|
        pid, *argv = line.split
        set << pid.to_i if argv.first(2).any? { |word| File.basename(word) == "claude" }
      end
    rescue StandardError
      Set.new
    end

    # Is any Claude Code running? Separates "no session files because nothing is open" (the
    # normal case: Claude removes its file on exit) from "files missing while Claude runs".
    def claude_running?
      pids = IO.popen(["pgrep", "-f", "claude"], err: File::NULL, &:read).to_s.split
      !claude_pids(pids).empty?
    rescue StandardError
      false
    end

    # The fields every reader relies on — the scanner (record) and the canary (health)
    # share it, so doctor can't count a file the glyph would ignore. A pid in 1..PID_MAX:
    # kill(0, 0) / kill(0, -1) "succeed" (process group / every process), past pid_t kill raises.
    def shaped?(data)
      data.is_a?(Hash) && data["pid"].is_a?(Integer) && data["pid"].between?(1, PID_MAX) && data["cwd"].is_a?(String)
    end

    def linked_records
      session_files.filter_map do |f|
        record(read_json(f))
      rescue StandardError
        nil # one odd file loses only its own link
      end
    end

    # The fields we use from one session file, or nil when it isn't a linked session
    # in a shape we recognize.
    def record(data)
      return nil unless shaped?(data)

      pid, cwd, bridge = data.values_at("pid", "cwd", "bridgeSessionId")
      return nil unless bridge.is_a?(String) && bridge.match?(BRIDGE_ID)

      { pid: pid, cwd: cwd, bridge_id: bridge, kind: data["kind"].to_s,
        started_at: data["startedAt"], proc_start: data["procStart"].to_s,
        status: data["status"].to_s, status_at: data["statusUpdatedAt"] }
    end

    # UTF-8 whatever the locale: under tmux's C locale a default read is US-ASCII,
    # and a session named with a smart quote would fail to parse and lose its link.
    def read_json(file)
      scrub_strings(JSON.parse(File.read(file, encoding: "UTF-8").scrub))
    rescue StandardError
      nil
    end

    # A \u escape decodes AFTER the scrub above, so a lone surrogate still parses to an
    # invalid string, and the first strip/gsub/match on it raises. Scrub every parsed
    # string: a bad field then reads as unrecognized (no link), never as a crash.
    def scrub_strings(value)
      case value
      when String then value.scrub
      when Array then value.map { |v| scrub_strings(v) }
      when Hash then value.to_h { |k, v| [scrub_strings(k), scrub_strings(v)] }
      else value
      end
    end

    # The one "background job" rule (Link#bg? and stale? both ask it).
    def bg_kind?(kind)
      kind == "bg"
    end

    def stale?(rec, stale_after, now)
      return false if stale_after.nil? || bg_kind?(rec[:kind]) || rec[:status] != "idle"
      return false unless rec[:status_at].is_a?(Numeric)

      now.to_f - (rec[:status_at] / 1000.0) > stale_after # statusUpdatedAt is epoch ms
    end

    def link(rec, stale_after, now)
      Link.new(pid: rec[:pid], bridge_id: rec[:bridge_id], kind: rec[:kind],
               started_at: start_ms(rec), stale: stale?(rec, stale_after, now))
    end

    # startedAt (epoch ms), else procStart parsed as UTC, else 0 — a bad ordering field
    # only demotes a link, never drops it.
    def start_ms(rec)
      return rec[:started_at] if rec[:started_at].is_a?(Numeric) && rec[:started_at].finite? # 1e400 parses to Infinity

      (Time.strptime("#{rec[:proc_start].squeeze(' ')} UTC", "%a %b %d %H:%M:%S %Y %Z").to_f * 1000).to_i
    rescue StandardError
      0
    end

    def order_key(link)
      [link.started_at, link.pid]
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
