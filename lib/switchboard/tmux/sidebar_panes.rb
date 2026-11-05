# frozen_string_literal: true

module Switchboard
  # The sidebar and work panes in a window, and what pokes them.
  module Tmux
    module_function

    # How many sidebar panes are live across every window of every session on the
    # running server. This is the count of `switchboard sidebar` processes that
    # SHOULD exist — doctor diffs it against the actual process count to surface
    # orphans (a sidebar that outlived its pane). nil if tmux is unreachable (no
    # server) — distinct from 0 (server up, no sidebars), so doctor stays honest.
    def sidebar_pane_count
      raw = `tmux -u list-panes -a -F '#\{pane_title}' 2>/dev/null`
      return nil unless $?.success?

      count_sidebar_panes(raw)
    end

    # Pure: count lines whose pane title is exactly SIDEBAR_TITLE. Split out so the
    # count logic is unit-testable without a server. Exact match (not include?) so a
    # work pane whose title merely contains the marker can't inflate the count.
    def count_sidebar_panes(raw)
      raw.to_s.lines.count { |line| line.strip == SIDEBAR_TITLE }
    end

    # The tty of EVERY live pane on the running server (not just sidebar panes),
    # normalized to bare names ("/dev/" stripped) to match `ps -o tty=`. This is the
    # set of ttys a sidebar process could legitimately be sitting on; prune reaps the
    # sidebar processes whose tty ISN'T here (their pane is gone). All panes, not just
    # sidebar-titled ones, so a freshly-spawned sidebar whose pane isn't titled yet is
    # never mistaken for an orphan. nil when tmux is unreachable (no server) — distinct
    # from an empty set, so a transient miss can't read as "every sidebar is an orphan".
    def live_pane_ttys
      raw = `tmux -u list-panes -a -F '#\{pane_tty}' 2>/dev/null`
      return nil unless $?.success?

      parse_ttys(raw)
    end

    # Pure: bare tty names from a newline list of pane ttys. Split out so the
    # normalization is unit-testable without a server.
    def parse_ttys(raw)
      raw.to_s.lines.filter_map { |l| normalize_tty(l) }.to_set
    end

    # [[pid, tty], ...] for every running `switchboard sidebar` process THAT BELONGS TO
    # THIS server, tty normalized like live_pane_ttys. Scoped by PARENT pid: a sidebar is
    # a direct child of the tmux server that split-window'd it (spawn_sidebar execs the
    # binary as the pane command), so ppid == server_pid means it's ours. That scoping is
    # the STRUCTURAL guard that keeps this machine-global `ps` from ever reaching a
    # DIFFERENT server's sidebar — the dev's real one, when a throwaway smoke/sandbox
    # server runs a prune (the bug where the smoke suite SIGTERM'd live sidebars). A
    # foreign-server sidebar is filtered out here, so orphan_sidebar_pids never sees it.
    # One `ps` (not pgrep + per-pid lookups) so pid, ppid, tty arrive together; the
    # substring matches doctor's `pgrep -f 'switchboard sidebar'` so the two agree on what
    # a sidebar is. [] when ps is unavailable or the server pid is unreadable.
    def sidebar_processes
      parse_sidebar_processes(`ps -axo pid=,ppid=,tty=,command= 2>/dev/null`, server_pid)
    end

    # Pure: parse `ps -axo pid=,ppid=,tty=,command=` into [[pid, tty], ...] sidebar rows
    # OWNED BY owner_pid (their parent server). A nil owner_pid (server unreachable)
    # matches no parent → [] → reap nothing, the fail-safe direction. A wrong process-tree
    # assumption (an intervening shell, so ppid isn't the server) also just under-reaps —
    # never over-reaps. Split out so the parse + ownership filter are unit-testable.
    def parse_sidebar_processes(raw, owner_pid)
      raw.to_s.lines.filter_map do |line|
        pid, ppid, tty, cmd = line.strip.split(/\s+/, 4)
        next unless pid&.match?(/\A\d+\z/) && ppid&.match?(/\A\d+\z/) && cmd&.include?("switchboard sidebar")
        next unless owner_pid && ppid.to_i == owner_pid

        [pid.to_i, normalize_tty(tty)]
      end
    end

    # This server's own PID (tmux's `#{pid}`), or nil when no server is reachable — the
    # ownership key sidebar_processes scopes the reap to. Read once per reap, not per row.
    def server_pid
      out = `tmux -u display-message -p '#\{pid}' 2>/dev/null`.strip
      $?.success? && out.match?(/\A\d+\z/) ? out.to_i : nil
    end

    # A bare tty name ("/dev/ttys048" / "/dev/pts/3" -> "ttys048" / "pts/3"), or nil for
    # a no-tty marker ("??", "?", "-") or a blank — so a no-tty process never matches a
    # real pane tty. Bridges tmux's #{pane_tty} (/dev-prefixed) and ps's bare tty=.
    def normalize_tty(raw)
      t = raw.to_s.strip.sub(%r{\A/dev/}, "")
      return nil if t.empty? || %w[?? ? -].include?(t)

      t
    end

    # Bring every window of a session into line with its saved @sb_sidebar flag —
    # the one entry point for "make this session's sidebars match its intent."
    # Honors an explicit `off` (so switching back into a session you hid keeps it
    # hidden) and self-heals any window that drifted.
    def ensure_sidebar(name)
      reconcile_sidebars(name, sidebar_on?(name))
    end

    # Spawn-or-kill each window's sidebar so the whole session matches `on`.
    # Window-scoped throughout: per-window split into the right window id, and a
    # per-window presence check — that's the fix for "new window had no sidebar."
    # Dismiss (prefix-s) runs in its own run-shell process, not the sidebar's loop,
    # so killing the focused sidebar pane here is safe — tmux just moves focus to
    # the work pane.
    def reconcile_sidebars(session, on)
      windows(session).each do |window|
        pane = window_sidebar_pane(window)
        if on && !pane
          pin(spawn_sidebar(target: window))
        elsif !on && pane
          system("tmux", "-u", "kill-pane", "-t", pane, out: File::NULL, err: File::NULL)
        end
      end
    end

    # Window ids of a session, oldest first. [] if the session is gone.
    def windows(session)
      `tmux -u list-windows -t #{Shellwords.escape(session)} -F '#\{window_id}' 2>/dev/null`
        .split("\n").map(&:strip).reject(&:empty?)
    end

    # The sidebar pane in a single window (or a session's active window when given
    # a session name) — NO -s, so it answers "does *this window* have one?" rather
    # than the old session-wide check that suppressed per-window spawns.
    def window_sidebar_pane(target)
      `tmux -u list-panes -t #{Shellwords.escape(target)} -F '#\{pane_id} #\{pane_title}' 2>/dev/null`
        .lines.find { |line| line.include?(SIDEBAR_TITLE) }&.split&.first
    end

    # The worktree a window's sidebar should sit in: its work pane's cwd. Each
    # worktree window's shell is cd'd to the worktree, so we read that back rather
    # than trust split-window's cwd inheritance (it takes the invoking client's
    # directory). Tab-delimited so paths with spaces survive the split.
    def window_work_dir(target)
      work_dir(`tmux -u list-panes -t #{Shellwords.escape(target)} -F '#\{pane_title}\t#\{pane_current_path}' 2>/dev/null`)
    end

    # Pure: the first non-sidebar pane's cwd from `list-panes` output (one
    # "title<TAB>path" line per pane). Skips the sidebar by its title; nil when
    # there's no work pane, so spawn_sidebar just omits -c. Split out so it's
    # unit-testable without a server.
    def work_dir(raw)
      raw.to_s.lines.map { |line| line.chomp.split("\t", 2) }
         .reject { |title, _| title == SIDEBAR_TITLE }
         .dig(0, 1)
    end

    RESERVE_COLS = 12 # cols kept for the work pane when clamping the sidebar at spawn

    # The target window's column count, or nil when unknown (no -t = current window).
    # Used to clamp the spawn width so a saved width wider than the client can't make
    # split-window fail and leave the window with no sidebar.
    def window_cols(target = nil)
      t = target ? " -t #{Shellwords.escape(target)}" : ""
      out = `tmux -u display-message -p#{t} '#\{window_width}' 2>/dev/null`.strip
      out.empty? ? nil : Integer(out, 10)
    rescue StandardError
      nil
    end

    # Pure: the width to split the sidebar at — the saved width, but capped so the
    # work pane keeps RESERVE_COLS (else `split-window -l` fails on a client narrower
    # than the saved width and the window gets no sidebar at all). Unknown cols ⇒ the
    # saved width unchanged (the historic behavior). Floored at 1 so a pathologically
    # tiny window never yields a non-positive -l. Split out so it's testable serverless.
    def fit_width(saved, cols)
      return saved unless cols&.positive?

      [saved, [cols - RESERVE_COLS, 1].max].min
    end

    # --- per-session visibility flag (@sb_sidebar) ---------------------------
    # Stored on the tmux session itself, so it survives window churn and is the
    # source of truth for "should this session show a sidebar." Unset reads as on,
    # preserving the historic auto-show-on-switch behavior.

    def set_sidebar_flag(session, value)
      system("tmux", "-u", "set-option", "-t", session, "@sb_sidebar", value, out: File::NULL, err: File::NULL)
    end

    # Raw flag value ("on"/"off"/""), "" when unset (the tmux "invalid option"
    # error lands on stderr, which we swallow).
    def sidebar_flag(session)
      `tmux -u show-options -v -t #{Shellwords.escape(session)} @sb_sidebar 2>/dev/null`.strip
    end

    def sidebar_on?(session)
      sidebar_flag_on?(sidebar_flag(session))
    end

    # The pure decision, split out so it's unit-testable without tmux: only an
    # explicit "off" hides; unset ("") and "on" both show.
    def sidebar_flag_on?(value)
      value != "off"
    end

    # Select a session's terminal pane so switching lands you ready to type, not
    # on the tree. Only redirects when the active pane IS the sidebar — a real
    # terminal pane you'd left focused (even one of several splits) is kept. Runs
    # before switch/attach so it covers both switch-client and the exec path.
    def focus_work(name, sidebar)
      return unless sidebar && active_pane(name) == sidebar

      pane = work_pane(name, sidebar)
      system("tmux", "-u", "select-pane", "-t", pane, out: File::NULL, err: File::NULL) if pane
    end

    # The pane id of a session's active (current-window) pane, or nil.
    def active_pane(name)
      id = `tmux -u display-message -p -t #{Shellwords.escape(name)} '#\{pane_id}' 2>/dev/null`.strip
      id.empty? ? nil : id
    end

    # The terminal pane to land on: the last-active non-sidebar pane if there is
    # one, else the first. Keeps you on the terminal you were actually using when
    # a workspace has several splits, instead of snapping to the leftmost.
    def work_pane(name, sidebar)
      panes = `tmux -u list-panes -t #{Shellwords.escape(name)} -F '#\{pane_id} #\{pane_last}' 2>/dev/null`
              .lines.map(&:split).reject { |id, _| id == sidebar }
      (panes.find { |_, last| last == "1" } || panes.first)&.first
    end

    # A pane's working directory (used to tell which worktree a session is in).
    def pane_path(pane)
      return unless pane

      path = `tmux -u display-message -p -t #{Shellwords.escape(pane)} '#\{pane_current_path}' 2>/dev/null`.strip
      path.empty? ? nil : path
    end

    # Re-assert the sidebar's width. Windows rescale panes proportionally on resize
    # (and aggressive-resize), which grows an absolute-width sidebar. Width defaults
    # to the shared, on-disk chosen value (Width.resolved) so every cross-session
    # caller pins to the user's width with no flash; the sidebar's own per-tick pin
    # passes its hydrated ivar to skip a disk read in the hot loop.
    def pin(pane, width = Width.resolved)
      return unless pane

      system("tmux", "-u", "resize-pane", "-t", pane, "-x", width.to_s, out: File::NULL, err: File::NULL)
    end

    # prefix-s is switchboard's ONE sidebar verb (the in-sidebar `h` is retired):
    # visible in the current window → DISMISS it session-wide; hidden → SUMMON it
    # and drop focus into the tree, so a single key is the whole round-trip
    # (summon → navigate → dismiss). Direction reads from the current window, so a
    # press in a session that's never shown one summons rather than dead-keys; the
    # intent is persisted on the session and reconciled across every window.
    def toggle_sidebar
      here = current_session or return
      if current_sidebar_pane               # visible here → dismiss for the whole session
        set_sidebar_flag(here, "off")
        reconcile_sidebars(here, false)
      else                                  # hidden here → summon every window, then enter the tree
        set_sidebar_flag(here, "on")
        reconcile_sidebars(here, true)
        focus_current_sidebar
      end
    end

    # Land focus on the current window's sidebar pane (just spawned by reconcile),
    # so summoning the tree leaves you ready to navigate instead of back on the
    # work pane — split-window -d never steals focus, so we redirect it here.
    # Best-effort: a missing pane (spawn failed) is a no-op.
    def focus_current_sidebar
      pane = current_sidebar_pane or return

      system("tmux", "-u", "select-pane", "-t", pane, out: File::NULL, err: File::NULL)
    end

    # Give a freshly created window its sidebar if the session opts in — bound to
    # the after-new-window hook, which hands us the new window's id. Idempotent:
    # the title check means a racing `go`/reconcile can't double-spawn. (Spawning
    # is a split, which fires after-split-window — not this hook — so no loop.)
    def sidebar_sync(window)
      return if window.to_s.empty?

      session = session_of_window(window)
      return if session.empty? || !sidebar_on?(session) || window_sidebar_pane(window)

      pin(spawn_sidebar(target: window))
    end

    # Poke the sidebar of a specific window — bound to the session-window-changed
    # hook, which fires on a same-session window switch (client-session-changed only
    # covers session switches, so without this the newly-active window's sidebar,
    # asleep on its idle backstop, lags before refreshing). Gated to sb/ sessions so
    # the global hook is a cheap no-op on unrelated windows: one display-message, then
    # return. Reuses the C-l reload poke; no-op if that window has no sidebar.
    def poke_window(window)
      return if window.to_s.empty?
      return unless session_of_window(window).start_with?("sb/")

      poke(window_sidebar_pane(window))
    end

    def current_sidebar_pane
      `tmux -u list-panes -F '#\{pane_id} #\{pane_title}' 2>/dev/null`
        .lines.find { |line| line.include?(SIDEBAR_TITLE) }&.split&.first
    end

    # Tell the current window's sidebar to reload (bound to a session-change
    # hook, so switching sessions always lands on a fresh tree). Uses C-l (a
    # non-user key) since `r` is the rename action.
    def poke_current_sidebar
      poke(current_sidebar_pane)
    end

    # Tell a specific sidebar pane to reload (C-l, a non-user key — `r` renames).
    def poke(pane)
      system("tmux", "-u", "send-keys", "-t", pane, "C-l", out: File::NULL, err: File::NULL) if pane
    end

    # Broadcast the warm poke (C-w) to every sidebar pane except `except` — used when
    # one sidebar changes SHARED view-state (collapse / branch-fold / full-header) so
    # all the other (mostly off-screen) sidebars repaint to the new state immediately,
    # making a switch right after the toggle flash-free. Best-effort per pane; the
    # originating pane is skipped (it already re-rendered). No-op off a tmux server.
    def broadcast_warm(except: nil)
      all_sidebar_panes.each do |pane|
        next if pane == except

        system("tmux", "-u", "send-keys", "-t", pane, WARM_POKE, out: File::NULL, err: File::NULL)
      end
    end

    # Every live sidebar pane id across all sessions/windows (title == SIDEBAR_TITLE).
    def all_sidebar_panes
      `tmux -u list-panes -a -F '#\{pane_id} #\{pane_title}' 2>/dev/null`.lines.filter_map do |line|
        id, title = line.split(" ", 2)
        id if id && title.to_s.strip == SIDEBAR_TITLE
      end
    end

    # Every NON-sidebar pane across all sessions/windows as [id, path] — the
    # inverse of all_sidebar_panes. AgentState uses it to find (and capture-hash)
    # an agent's WORK pane. The pane is identified by NOT carrying SIDEBAR_TITLE,
    # never by command: an agent's pane_current_command is unreliable (Claude
    # reports its version, e.g. "2.1.201", not "claude"). Tab-delimited so a
    # title/path with spaces survives the split (titles are Claude's turn text).
    def work_panes
      parse_work_panes(`tmux -u list-panes -a -F '#\{pane_id}\t#\{pane_title}\t#\{pane_current_path}' 2>/dev/null`)
    rescue StandardError
      [] # degrade like every other shell-out — a raise here would blank every dot for a scan
    end

    # Pure: [id, path] rows from `list-panes` output, dropping sidebar-titled
    # panes. Split out so it's unit-testable without a server (like work_dir).
    def parse_work_panes(raw)
      raw.to_s.lines.filter_map do |line|
        id, title, path = line.chomp.split("\t", 3)
        [id, path] if id && path && title.to_s.strip != SIDEBAR_TITLE
      end
    end

    # Poke a session's sidebar by session name (vs. poke's pane id). reload_config:
    # sends C-r (the dedicated config-reload signal) instead of C-l, so only a
    # real edit re-reads config off disk. Returns nil when the session has no
    # sidebar (e.g. it was killed mid-edit), so callers can fall back.
    def poke_sidebar_of(session, reload_config: false)
      pane = window_sidebar_pane(session) or return

      poke = reload_config ? RELOAD_CONFIG_POKE : "C-l"
      system("tmux", "-u", "send-keys", "-t", pane, poke, out: File::NULL, err: File::NULL)
    end

    # Guarantee the session's active window isn't sidebar-only: if the sidebar is the
    # SOLE pane (its work sibling was closed), split a fresh shell beside it so it's
    # never wedged full-width (#64). Idempotent — a window that already has a work pane
    # short-circuits (window_panes != 1), so repeated calls are cheap no-ops. Used for
    # the home self-heal (a closed home work pane re-grows one, keeping the anchor
    # alive) and by go_home, so falling-home never lands on a wedged home. Returns the
    # new pane id, or nil when nothing was spawned.
    def ensure_work_pane(session, dir = nil)
      pane = window_sidebar_pane(session)
      return unless pane && window_panes(pane) == 1

      dir ||= window_work_dir(session) || home_dir
      work = `tmux -u split-window -h -d -P -F '#\{pane_id}' -t #{Shellwords.escape(session)} -c #{Shellwords.escape(dir)} 2>/dev/null`.strip
      pin(pane) # the split reflows the row; re-assert the sidebar's fixed width
      work.empty? ? nil : work
    end

    # Ask tmux to deliver focus in/out to the program in a pane, so the sidebar
    # can dim its cursor the instant it loses focus. Idempotent, best-effort.
    def enable_focus_events
      system("tmux", "-u", "set", "-g", "focus-events", "on", out: File::NULL, err: File::NULL)
    end

    # Split a narrow sidebar pane on the left running `switchboard sidebar`, and
    # return its pane id (nil on failure) so callers can pin it to width. `target`
    # may be a session or a specific window id; -d means spawning into another
    # window never steals focus from the pane you're in.
    def spawn_sidebar(target: nil, dir: nil)
      bin = ENV["SWITCHBOARD_BIN"]
      return unless bin

      # Pin the sidebar's cwd to the window's worktree. Without -c, split-window
      # adopts the *invoking client's* cwd (e.g. the primary checkout you switched
      # from), NOT the target pane's — which silently broke the "you are here"
      # highlight: `locate` matches the sidebar pane's path against the worktree
      # tree, and the client's path matches nothing. So read it back from the
      # window's work pane, which is reliably cd'd to the worktree.
      dir ||= target && window_work_dir(target)

      # -l fixes the new pane's width at split time (resize-after-split raced
      # and sometimes left it at the 50/50 default). Start at the saved width so a
      # freshly split pane never flashes the default before pin_if_resized corrects it,
      # but clamp it to the window so a width chosen on a wide client can't make the
      # split fail (and leave no sidebar) on a narrow one.
      width = fit_width(Width.resolved, window_cols(target))
      cmd = +"tmux -u split-window -hb -d -l #{width} -P -F '#\{pane_id}'"
      cmd << " -t #{Shellwords.escape(target)}" if target
      cmd << " -c #{Shellwords.escape(dir)}" if dir
      cmd << " #{Shellwords.escape(bin)} sidebar"

      pane = `#{cmd} 2>/dev/null`.strip
      return if pane.empty?

      system("tmux", "-u", "select-pane", "-t", pane, "-T", SIDEBAR_TITLE, out: File::NULL, err: File::NULL)
      pane
    end
  end
end
