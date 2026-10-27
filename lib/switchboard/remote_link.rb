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
  # recognize is no link, never a wrong one, and nothing raises. Reading, liveness and
  # kernel-cwd placement live in ClaudeSessions (shared with the ◷ dot); this module is
  # the link layer on top: the bridge id, staleness, ordering, the URL, and `doctor`'s
  # `health` canary for a format change. Verified live against Claude Code 2.1.308.
  module RemoteLink
    URL_BASE = "https://claude.ai/code/"
    # The `status` values Claude writes (2.1.310): `shell` is a turn over with a background
    # shell still running, `waiting` a permission modal. SessionName types only on idle/shell.
    STATUSES = %w[idle busy shell waiting].freeze
    INTERACTIVE = "interactive"
    KINDS = [INTERACTIVE, "bg"].freeze # the `kind` values Claude writes (2.1.310)
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

    def sessions_dir
      ClaudeSessions.sessions_dir
    end

    def session_files
      ClaudeSessions.session_files
    end

    # { ws_path => [Link, …] } for the tracked worktrees with a LIVE linked session,
    # newest first by startedAt (procStart when that's missing), then pid. `stale_after` is seconds or
    # nil (off). Total: any failure is "no links". `sessions:` is a ClaudeSessions.scan the
    # caller already ran (the sidebar shares one per scan with the ◷ dot); without it this
    # scans the linked files itself. `cheap:` is as in ClaudeSessions.scan.
    def scan(ws_paths, stale_after:, now: Time.now, cheap: false, sessions: nil)
      sessions ||= ClaudeSessions.scan(ws_paths, cheap: cheap, records: linked_records)
      return {} unless sessions

      sessions.each_with_object({}) do |(ws, recs), out|
        links = recs.select { |r| linked?(r) }.map { |r| link(r, stale_after, now) }
        out[ws] = links.sort_by { |l| order_key(l) }.reverse unless links.empty?
      end
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
      # session-name sync's canaries: the status it gates on, the name it confirms by
      typed = same.select { |d| d["kind"] == INTERACTIVE } # only these get typed into
      unkind = same.count { |d| !KINDS.include?(d["kind"]) }
      odd = typed.count { |d| !STATUSES.include?(d["status"]) }
      unnamed = typed.count { |d| !d["name"].is_a?(String) }
      { dir: sessions_dir, files: parsed.size, shaped: shaped.size, alive: alive.size,
        drift: alive.size - same.size, linked: linked, verified: typed.size, odd_status: odd, unnamed: unnamed,
        matched: same.size, unknown_kind: unkind }
    rescue StandardError
      { dir: sessions_dir, files: 0, shaped: 0, alive: 0, drift: 0, linked: 0, verified: 0, odd_status: 0, unnamed: 0, matched: 0, unknown_kind: 0 }
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

    # Shared with the scanner (ClaudeSessions), so doctor counts exactly what a cue reads.
    def shaped?(data)
      ClaudeSessions.shaped?(data)
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
      rec = ClaudeSessions.record(data)
      rec if rec && linked?(rec)
    end

    def linked?(rec)
      rec[:bridge_id].is_a?(String) && rec[:bridge_id].match?(BRIDGE_ID)
    end

    def read_json(file)
      ClaudeSessions.read_json(file)
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
  end
end
