# frozen_string_literal: true

module Switchboard
  # What's on screen and who's at the keyboard.
  module Tmux
    module_function

    # Is this pane on the active window of an attached session (i.e. on screen)?
    def visible?(pane)
      return true unless pane

      out = `tmux -u display-message -p -t #{Shellwords.escape(pane)} '#\{window_active},#\{session_attached}' 2>/dev/null`.strip
      active, attached = out.split(",")
      active == "1" && attached.to_i.positive?
    end

    # Positively off screen: tmux answered, and said so. Unlike `visible?`, a failed query is
    # not a yes, for a caller that would throw state away on the answer.
    def hidden?(pane)
      return false unless pane

      hidden_reply?(`tmux -u display-message -p -t #{Shellwords.escape(pane)} '#\{window_active},#\{session_attached}' 2>/dev/null`)
    end

    def hidden_reply?(out)
      active, attached = out.to_s.strip.split(",")
      return false unless %w[0 1].include?(active) && attached.to_s.match?(/\A\d+\z/)

      active == "0" || attached.to_i.zero?
    end

    # { bare tty => { pane:, focused:, recent_input:, last_input:, sessions:, in_mode:, synchronized:, width: } } for
    # every pane on the server, or nil when tmux is unreachable. SessionName finds an agent's
    # pane by its process's tty — a dispatched agent is the launcher's child, a grandchild of
    # the pane, so parent pids can't. Both gates a typist reads are TRI-state (unlike
    # `visible?`, which reads an empty reply as hidden), nil = couldn't tell, which a typist
    # must read as "someone may be keying here":
    # - focused: the active pane of the active window of an attached session — where a
    #   client's keys go. Unknown whenever the session has a client that can key some other
    #   pane (parse_clients' any_pane: iTerm2's tmux -CC, or a client's own active pane).
    # - last_input: the newest input epoch of any client or session (whole seconds), nil when
    #   unknown — back-out's proof that nobody touched a key since our line went in.
    # - sessions: every session's id, so a session killed since a snapshot reads as missing.
    # - recent_input: ANY client on the server had input (keys or mouse) in the last
    #   INPUT_QUIET seconds. Not focus: a scroll wheel or click lands on the pane under the
    #   pointer, someone mid-keystroke is about to move, and a send-keys binding in one
    #   session can type into another session's pane.
    # `in_mode` (copy/view mode — keys go to tmux, not the program), `synchronized`
    # (synchronize-panes — keys go to every pane in the window) and `width` are nil when
    # unreadable, too.
    def panes_by_tty
      raw = IO.popen(["tmux", "-u", "list-panes", "-a", "-F",
                      "\#{pane_id}\t\#{pane_tty}\t\#{window_active}\t\#{session_attached}\t\#{pane_in_mode}\t" \
                      "\#{pane_width}\t\#{pane_synchronized}\t\#{pane_active}\t\#{session_name}"],
                     err: File::NULL, &:read)
      return nil unless $?.success?

      clients = IO.popen(["tmux", "-u", "list-clients", "-F",
                          "\#{client_activity}\t\#{client_control_mode}\t\#{client_flags}\t\#{client_session}"],
                         err: File::NULL, &:read)
      clients = nil unless $?.success?
      sessions = IO.popen(["tmux", "-u", "list-sessions", "-F", "\#{session_id}\t\#{session_activity}"], err: File::NULL, &:read)
      parse_panes_by_tty(raw, clients, Time.now.to_i, sessions: $?.success? ? sessions : nil)
    rescue StandardError
      nil
    end

    # Pure: the list-panes rows (+ list-clients rows, nil = unreadable) → the map. A pane in
    # several (grouped) sessions is listed once per session: true if any row says so, else
    # unknown if any row is.
    def parse_panes_by_tty(raw, clients_raw = nil, now = Time.now.to_i, sessions: nil) # nil = unreadable: fails closed
      clients = parse_clients(clients_raw)
      latest = latest_input(clients)
      held = parse_sessions(sessions)
      ever = latest && held && [latest, held[:latest]].max # what a detach can't take back
      recent = latest && now - latest <= INPUT_QUIET # whole seconds: <= keeps the quiet at least INPUT_QUIET
      raw.to_s.lines.each_with_object({}) do |line, out|
        id, tty, active, attached, mode, width, synced, pane_active, session = line.chomp.split("\t", 9)
        tty = normalize_tty(tty)
        next unless tty && id.to_s.start_with?("%")

        seen = %w[0 1].include?(active) && attached.to_s.match?(/\A\d+\z/)
        vis = seen ? active == "1" && attached.to_i.positive? : nil
        info = clients&.[](session.to_s) || { any_pane: false } # no client on it
        any_pane = clients ? info[:any_pane] : nil
        focused = any_pane == false ? vis && flag(pane_active) : nil # hidden ⇒ false
        input = any_pane == false ? recent : nil
        last = any_pane == false ? ever : nil
        prev = out[tty]
        out[tty] = { pane: id, focused: merge_seen(prev, :focused, focused), recent_input: merge_seen(prev, :recent_input, input),
                     last_input: prev && (prev[:last_input].nil? || last.nil?) ? nil : [prev&.[](:last_input), last].compact.max,
                     sessions: held&.[](:ids), # server-wide, like last_input (a control client already reads unfocused: unknown)
                     in_mode: flag(mode), synchronized: flag(synced),
                     width: width.to_s.match?(/\A\d+\z/) ? width.to_i : nil }
      end
    end

    # Pure: list-clients rows → { session => { lasts: [input epoch or nil per client], any_pane: } }.
    # any_pane: a client of that session can key a pane other than the window's active one —
    # a control-mode client (it shows every pane and sends keys by %id) or one with its own
    # active pane (`active-pane`, a client flag some tmux 3.x releases have); nil if unreadable.
    # nil overall when the list itself was unreadable.
    def parse_clients(raw)
      return nil if raw.nil?

      raw.to_s.lines.each_with_object({}) do |line, out|
        activity, control, flags, session = line.chomp.split("\t", 4)
        return nil if session.nil? # a row cut short: whose client it is can't be told
        last = activity.to_s.match?(/\A\d+\z/) ? activity.to_i : nil
        ctl = flag(control)
        any_pane = ctl.nil? || flags.nil? ? nil : ctl || flags.split(",").include?("active-pane")
        prev = out[session.to_s]
        out[session.to_s] = { lasts: (prev ? prev[:lasts] : []) + [last], any_pane: merge_seen(prev, :any_pane, any_pane) }
      end
    end

    # Pure: the newest input epoch of ANY client (0 with no clients; nil when unreadable). Server-wide,
    # not per session: a send-keys binding in one session can type into another's pane.
    def latest_input(clients)
      return nil unless clients

      lasts = clients.values.flat_map { |c| c[:lasts] }
      lasts.include?(nil) ? nil : (lasts.max || 0)
    end

    # Pure: list-sessions rows → { ids: [session ids, sorted], latest: newest session_activity }, nil
    # when unreadable. A key stamps its session's activity too, and a session outlives the client
    # that typed in it: client_activity leaves with a detach, so latest_input alone can move
    # backward. Ids ($N) are never reused within a server, so a killed session is a missing id.
    def parse_sessions(raw)
      return nil if raw.nil?

      rows = raw.to_s.lines.map { |line| line.chomp.split("\t", 2) }
      return nil unless rows.all? { |id, at| id.to_s.match?(/\A\$\d+\z/) && at.to_s.match?(/\A\d+\z/) }

      { ids: rows.map(&:first).sort, latest: rows.map { |_, at| at.to_i }.max || 0 }
    end

    # A grouped pane's next row folded into the last: true wins, then unknown.
    def merge_seen(prev, key, now)
      return now unless prev
      return true if prev[key] == true || now == true

      prev[key].nil? || now.nil? ? nil : false
    end

    # A tmux 0/1 format flag as a boolean, or nil when it isn't one.
    def flag(raw)
      %w[0 1].include?(raw) ? raw == "1" : nil
    end

    # The pane's visible screen WITH its SGR escapes (SessionName tells a dim placeholder
    # from typed text by them), or nil when the capture failed.
    def capture_pane(pane)
      out = IO.popen(["tmux", "-u", "capture-pane", "-p", "-e", "-t", pane], err: File::NULL, &:read)
      $?.success? ? out.force_encoding(Encoding::UTF_8).scrub : nil
    rescue StandardError
      nil
    end

    # The pane's pseudo-terminal (e.g. /dev/ttys007) — tmux's stable per-pane
    # identity, fixed for the pane's whole life. nil if the pane is gone (a
    # dead/unresolved -t target prints empty). %ids, by contrast, get RECYCLED onto
    # new panes, so the sidebar captures its pty once at startup and compares: when
    # the pane its id now names reports a different tty, that id was handed to
    # someone else and this process is an orphan (owns_pane?).
    def pane_tty(pane)
      return nil unless pane

      tty = `tmux -u display-message -p -t #{Shellwords.escape(pane)} '#\{pane_tty}' 2>/dev/null`.strip
      tty.empty? ? nil : tty
    end

    # The pane count of the window containing `pane`, or nil when tmux gives no usable
    # answer (no/empty/garbled reply). nil is "unknown" — distinct from a real count —
    # so callers treat it as "don't act," the same transient-miss rule owns_pane? uses:
    # never self-terminate (or restructure) a window on a flaky shell-out. Drives the
    # #64 lone-pane check, where a confirmed 1 means the work sibling closed and the
    # sidebar would otherwise wedge the window full-width.
    def window_panes(pane)
      return nil unless pane

      parse_window_panes(`tmux -u display-message -p -t #{Shellwords.escape(pane)} '#\{window_panes}' 2>/dev/null`)
    end

    # Pure: a tmux count reply parsed to an Integer, or nil on an empty/garbled line.
    # Split out so the transient-miss parse is unit-testable without a server (the same
    # pure-helper pattern as count_sidebar_panes / sb_sessions). A non-numeric reply
    # (a stray warning, a non-UTF-8 byte) rescues to nil, not a raise — degrade, never
    # crash, and "unknown" reads as "don't act."
    def parse_window_panes(raw)
      out = raw.to_s.strip
      out.empty? ? nil : Integer(out, 10)
    rescue StandardError
      nil
    end

    # Is this pane the one the user is actually driving — the active pane, on the
    # active window, of an attached session? (Stronger than visible?: a sidebar
    # split is visible while you type in the editor beside it, but not focused.)
    def focused?(pane)
      return true unless pane

      out = `tmux -u display-message -p -t #{Shellwords.escape(pane)} '#\{pane_active},#\{window_active},#\{session_attached}' 2>/dev/null`.strip
      pane_active, window_active, attached = out.split(",")
      pane_active == "1" && window_active == "1" && attached.to_i.positive?
    end
  end
end
