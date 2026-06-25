# frozen_string_literal: true

require "shellwords"

module Switchboard
  # tmux orchestration. Each worktree maps to a session; every session carries a
  # switchboard sidebar pane so the tree stays beside you as you switch.
  module Tmux
    SIDEBAR_TITLE = "sb-sidebar"
    SIDEBAR_WIDTH = 40
    HOME = "sb/home" # the persistent anchor session (see go_home)
    # tmux forbids "." and ":" in session names; whitespace would split our
    # space-delimited parses. One regex, shared by session_name + session_prefix
    # so the two can't drift (reconcile matches a session to its project by
    # prefix, so identical sanitization is load-bearing).
    SANITIZE = /[.:\s]/
    # A non-user key the sidebar maps to "re-read config + rebuild" — the
    # dedicated post-edit reload signal, distinct from C-l (the session-switch
    # refresh poke) so an ordinary switch never re-reads config off disk.
    RELOAD_CONFIG_POKE = "C-r"

    module_function

    # Switch to a worktree's session (creating it, with a sidebar, if needed).
    # `start` (config's session_command) is typed into the window only when the
    # session is first created — never on a re-switch into a live one. Non-exec
    # so callers (the sidebar loop) keep running.
    def go(worktree, start: nil)
      name = session_name(worktree)
      ensure_session(name, worktree.path, start)
      ensure_sidebar(name)      # reconcile every window to the saved @sb_sidebar flag
      sidebar = window_sidebar_pane(name) # the window we'll land on (nil if hidden)
      focus_work(name, sidebar) # land on the workspace's terminal, not its tree
      switch(name)              # may exec (attach) when launched outside tmux
      pin(sidebar)              # snap to fixed width at the now-current client size
    end

    # Switch to the persistent home session — switchboard's anchor and settings
    # base. Unlike a worktree session it maps to no worktree (it lives in $HOME,
    # so the tree — built from `git worktree list` — never lists it) and carries
    # its own sidebar, so landing here drops you into switchboard with the full
    # tree, not a bare shell. It's the fallback when you delete the session
    # you're in, and a stable launch target. Created lazily, the moment something
    # needs it. Lands focused on the tree — home is for navigating, not working.
    def go_home
      # Going home means "show me the navigator" — home is for navigating, not
      # working. Re-stamp the flag on so a session you'd hidden the sidebar in
      # never strands you on a bare shell (e.g. the post-delete fallback).
      set_sidebar_flag(HOME, "on")
      ensure_home
      sidebar = window_sidebar_pane(HOME)
      # Focus the tree before switch, so the exec/attach path keeps it too.
      system("tmux", "select-pane", "-t", sidebar, out: File::NULL, err: File::NULL) if sidebar
      switch(HOME) # may exec (attach) when launched outside tmux
      poke(sidebar) # force a fresh tree now (e.g. right after a delete)
      pin(sidebar)
    end

    def ensure_home
      ensure_session(HOME, home_dir)
      ensure_sidebar(HOME)
    end

    # Open an editor command in its OWN throwaway pane in the home session, beside
    # the sidebar, then land on it. The pane runs `command` as its foreground
    # process (tmux execs it via the shell) and closes on exit (:q) — so editing
    # config never types into a live shell (no idle guard, no pending-input
    # corruption, no shell-history leak). `command` carries its own
    # return-to-origin + reload trailer, so this stays a dumb "run it in a home
    # pane" primitive. Array-form spawn so `command` reaches tmux as one literal
    # arg (its `;`, spaces, and any `$EDITOR` are the inner shell's to parse, not
    # ours).
    #
    # We split the WORK pane explicitly, never the active pane: after go_home the
    # sidebar is the active pane, so the old `-t "#{HOME}:"` (active-pane target)
    # nested the editor *inside* the tree, and a stray zoom toggle made it flip
    # between full-screen and split. Splitting the work pane gives a deterministic
    # layout — sidebar at left, editor stacked above the home shell on the right
    # (`-b` = above, so it aligns with the tree's top; the shell keeps the bottom
    # 20%). `-p 80` (a percentage of the work pane) not `-l 80%`: the bare-`%`
    # form on `-l` needs tmux >= 3.1, but we support 3.0 (see installer), where it
    # would silently fail the split and leave `e` a dead key.
    def edit_in_home(command)
      ensure_home
      sidebar = window_sidebar_pane(HOME)
      # Only ever split the work pane. NO active-pane fallback: when home has no
      # work pane the active pane is the sidebar, and splitting it is exactly the
      # nest-in-the-tree bug this method exists to avoid.
      target = work_pane(HOME, sidebar)
      pane = target && IO.popen(
        ["tmux", "split-window", "-b", "-t", target, "-c", home_dir, "-p", "80", "-P", "-F", "#\{pane_id}", command],
        err: File::NULL, &:read
      ).to_s.strip
      if pane.nil? || pane.empty? # no work pane, or the split failed
        notify("switchboard: couldn't open the editor pane") # not a silent dead key
        return switch(HOME)                                  # at least land in home
      end

      pin(sidebar) # the split reflows the right column; keep the sidebar fixed-width
      switch(HOME) # land on the new (active) editor pane, beside the tree
    rescue StandardError
      switch(HOME) # IO.popen can raise (e.g. tmux missing); never crash the `e` keypress
    end

    # Home sits in $HOME: a neutral, always-present directory owned by no project.
    # Fall back to the cwd if $HOME is somehow unset — expand_path("~") would
    # itself raise without $HOME, so don't route the fallback through it.
    def home_dir
      File.expand_path(ENV["HOME"] || Dir.pwd)
    end

    def session_name(worktree)
      "sb/#{worktree.project}/#{worktree.leaf}".gsub(SANITIZE, "-")
    end

    # The session-name prefix shared by all of a project's worktrees. Reconcile
    # uses it to tell which live sessions belong to a project. Sanitized the same
    # way as session_name (per-char), so session_name always starts with it; the
    # trailing "/" keeps "app" from matching "app2".
    def session_prefix(project)
      "sb/#{project}/".gsub(SANITIZE, "-")
    end

    # Every live switchboard session as {name:, created:} (epoch seconds), or nil
    # if tmux is unreachable (no server) — distinct from [] (server up, none ours)
    # so callers can report honestly. The `-F` format is single-quoted with the
    # interpolation escaped (#\{...}); a bare #{} would be Ruby string
    # interpolation, not a tmux format, and silently yield junk.
    def sessions
      raw = `tmux list-sessions -F '#\{session_name}\t#\{session_created}' 2>/dev/null`
      return nil unless $?.success?

      sb_sessions(raw)
    end

    # Pure filter/parse over `tmux list-sessions` output: keep only sb/ sessions,
    # parse the trailing epoch. Split out so it's unit-testable without a server.
    def sb_sessions(raw)
      raw.to_s.lines.filter_map do |line|
        name, created = line.chomp.split("\t", 2)
        next if name.nil? || !name.start_with?("sb/")

        { name: name, created: created.to_i }
      end
    end

    # How many sidebar panes are live across every window of every session on the
    # running server. This is the count of `switchboard sidebar` processes that
    # SHOULD exist — doctor diffs it against the actual process count to surface
    # orphans (a sidebar that outlived its pane). nil if tmux is unreachable (no
    # server) — distinct from 0 (server up, no sidebars), so doctor stays honest.
    def sidebar_pane_count
      raw = `tmux list-panes -a -F '#\{pane_title}' 2>/dev/null`
      return nil unless $?.success?

      count_sidebar_panes(raw)
    end

    # Pure: count lines whose pane title is exactly SIDEBAR_TITLE. Split out so the
    # count logic is unit-testable without a server. Exact match (not include?) so a
    # work pane whose title merely contains the marker can't inflate the count.
    def count_sidebar_panes(raw)
      raw.to_s.lines.count { |line| line.strip == SIDEBAR_TITLE }
    end

    def ensure_session(name, dir, start = nil)
      return if has_session?(name)

      # Gate the start command on new-session actually succeeding. If a racing
      # process (a CLI switch and a sidebar in another pane are separate
      # processes) created the session first, new-session fails — and we must
      # NOT type the command into a session we didn't create, or it lands twice.
      created = system("tmux", "new-session", "-d", "-s", name, "-c", dir, out: File::NULL, err: File::NULL)
      system("tmux", "rename-window", "-t", name, "work", out: File::NULL, err: File::NULL)
      # Record the first-creation default (on) explicitly, so new windows in this
      # session inherit a sidebar via the after-new-window hook. Gated on `created`
      # for the same reason as run_in_session: never stamp a session we lost a race
      # to create.
      set_sidebar_flag(name, "on") if created
      run_in_session(name, start) if start && created
    end

    # Type a command into a freshly created session's window and run it — how
    # config's session_command auto-starts an agent. `-l` sends it as literal
    # text: without it, a value that matches a tmux key name (e.g. "Enter",
    # "C-l", "Space") would be interpreted as that key instead of typed. The
    # Enter that submits the line is a separate, deliberately-interpreted key.
    # chomp so a trailing newline (a YAML block scalar) doesn't double-submit.
    # tmux buffers the keys until the shell is ready.
    def run_in_session(name, command)
      system("tmux", "send-keys", "-t", name, "-l", command.chomp, out: File::NULL, err: File::NULL)
      system("tmux", "send-keys", "-t", name, "Enter", out: File::NULL, err: File::NULL)
    end

    def has_session?(name)
      system("tmux", "has-session", "-t", "=#{name}", out: File::NULL, err: File::NULL)
    end

    # The session a pane belongs to (this process's own pane by default), or nil.
    # Lets the sidebar tell whether the workspace it's deleting is the very
    # session it's running inside — the case that needs the home fallback.
    def session_of(pane = ENV["TMUX_PANE"])
      return nil unless pane

      name = `tmux display-message -p -t #{Shellwords.escape(pane)} '#\{session_name}' 2>/dev/null`.strip
      name.empty? ? nil : name
    end

    # Kill a worktree's session (if any) — used when deleting a workspace.
    def kill(worktree)
      kill_session(session_name(worktree))
    end

    # Kill a session by exact name. The "=" pins an exact match — a bare name is
    # a tmux prefix match, which would over-kill. Array form (no shell) so the
    # name can't inject. The single kill path for worktree delete, prune, and quit.
    def kill_session(name)
      system("tmux", "kill-session", "-t", "=#{name}", out: File::NULL, err: File::NULL)
    end

    # Tear down every switchboard session, the current one LAST so running this
    # from inside a session doesn't orphan the rest (our own session dies, taking
    # this process with it, only after the others are gone). Returns the names it
    # killed; [] when there's no server. The tested form of the README snippet.
    def kill_all
      live = sessions
      return [] if live.nil? || live.empty?

      names = live.map { |s| s[:name] }
      current = session_of
      (names - [current]).each { |name| kill_session(name) }
      kill_session(current) if current && names.include?(current)
      names
    end

    # Kill every live session belonging to one project — its `sb/<project>/`
    # prefix, one leaf deep (the same ownership test Reconcile.owned? uses, so a
    # project whose name is a prefix of another's never over-kills). Used when a
    # project is removed from the registry: its sessions would otherwise be
    # orphaned for good (prune reconciles only against *registered* projects, so
    # nothing left would ever reach them). The current session goes LAST, like
    # kill_all, so removing a project from inside one of its own worktrees doesn't
    # orphan its siblings. Returns the names it killed; [] when there's no server.
    def kill_project_sessions(project)
      live = sessions
      return [] if live.nil? || live.empty?

      prefix = session_prefix(project)
      names = live.map { |s| s[:name] }
                  .select { |n| n.start_with?(prefix) && !n[prefix.length..].include?("/") }
      current = session_of
      (names - [current]).each { |name| kill_session(name) }
      kill_session(current) if current && names.include?(current)
      names
    end

    # Rename a worktree's session in place — keeps any running agent/shell (and
    # its conversation) alive. Used on workspace rename.
    def rename_session(old_name, new_name)
      return if old_name == new_name

      system("tmux", "rename-session", "-t", "=#{old_name}", new_name, out: File::NULL, err: File::NULL)
    end

    def switch(name)
      if ENV["TMUX"]
        system("tmux", "switch-client", "-t", name)
      else
        exec("tmux", "attach-session", "-t", name)
      end
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
          system("tmux", "kill-pane", "-t", pane, out: File::NULL, err: File::NULL)
        end
      end
    end

    # Window ids of a session, oldest first. [] if the session is gone.
    def windows(session)
      `tmux list-windows -t #{Shellwords.escape(session)} -F '#\{window_id}' 2>/dev/null`
        .split("\n").map(&:strip).reject(&:empty?)
    end

    # The sidebar pane in a single window (or a session's active window when given
    # a session name) — NO -s, so it answers "does *this window* have one?" rather
    # than the old session-wide check that suppressed per-window spawns.
    def window_sidebar_pane(target)
      `tmux list-panes -t #{Shellwords.escape(target)} -F '#\{pane_id} #\{pane_title}' 2>/dev/null`
        .lines.find { |line| line.include?(SIDEBAR_TITLE) }&.split&.first
    end

    # The worktree a window's sidebar should sit in: its work pane's cwd. Each
    # worktree window's shell is cd'd to the worktree, so we read that back rather
    # than trust split-window's cwd inheritance (it takes the invoking client's
    # directory). Tab-delimited so paths with spaces survive the split.
    def window_work_dir(target)
      work_dir(`tmux list-panes -t #{Shellwords.escape(target)} -F '#\{pane_title}\t#\{pane_current_path}' 2>/dev/null`)
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
      out = `tmux display-message -p#{t} '#\{window_width}' 2>/dev/null`.strip
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
      system("tmux", "set-option", "-t", session, "@sb_sidebar", value, out: File::NULL, err: File::NULL)
    end

    # Raw flag value ("on"/"off"/""), "" when unset (the tmux "invalid option"
    # error lands on stderr, which we swallow).
    def sidebar_flag(session)
      `tmux show-options -v -t #{Shellwords.escape(session)} @sb_sidebar 2>/dev/null`.strip
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
      system("tmux", "select-pane", "-t", pane, out: File::NULL, err: File::NULL) if pane
    end

    # The pane id of a session's active (current-window) pane, or nil.
    def active_pane(name)
      id = `tmux display-message -p -t #{Shellwords.escape(name)} '#\{pane_id}' 2>/dev/null`.strip
      id.empty? ? nil : id
    end

    # The terminal pane to land on: the last-active non-sidebar pane if there is
    # one, else the first. Keeps you on the terminal you were actually using when
    # a workspace has several splits, instead of snapping to the leftmost.
    def work_pane(name, sidebar)
      panes = `tmux list-panes -t #{Shellwords.escape(name)} -F '#\{pane_id} #\{pane_last}' 2>/dev/null`
              .lines.map(&:split).reject { |id, _| id == sidebar }
      (panes.find { |_, last| last == "1" } || panes.first)&.first
    end

    # A pane's working directory (used to tell which worktree a session is in).
    def pane_path(pane)
      return unless pane

      path = `tmux display-message -p -t #{Shellwords.escape(pane)} '#\{pane_current_path}' 2>/dev/null`.strip
      path.empty? ? nil : path
    end

    # Re-assert the sidebar's width. Windows rescale panes proportionally on resize
    # (and aggressive-resize), which grows an absolute-width sidebar. Width defaults
    # to the shared, on-disk chosen value (Width.resolved) so every cross-session
    # caller pins to the user's width with no flash; the sidebar's own per-tick pin
    # passes its hydrated ivar to skip a disk read in the hot loop.
    def pin(pane, width = Width.resolved)
      return unless pane

      system("tmux", "resize-pane", "-t", pane, "-x", width.to_s, out: File::NULL, err: File::NULL)
    end

    # prefix-s is switchboard's ONE sidebar verb (the in-sidebar `h` is retired):
    # visible in the current window → DISMISS it session-wide; hidden → SUMMON it
    # and drop focus into the tree, so a single key is the whole round-trip
    # (summon → navigate → dismiss). Direction reads from the current window, so a
    # press in a session that's never shown one summons rather than dead-keys; the
    # intent is persisted on the session and reconciled across every window.
    def toggle_sidebar
      session = current_session or return
      if current_sidebar_pane               # visible here → dismiss for the whole session
        set_sidebar_flag(session, "off")
        reconcile_sidebars(session, false)
      else                                  # hidden here → summon every window, then enter the tree
        set_sidebar_flag(session, "on")
        reconcile_sidebars(session, true)
        focus_current_sidebar
      end
    end

    # Land focus on the current window's sidebar pane (just spawned by reconcile),
    # so summoning the tree leaves you ready to navigate instead of back on the
    # work pane — split-window -d never steals focus, so we redirect it here.
    # Best-effort: a missing pane (spawn failed) is a no-op.
    def focus_current_sidebar
      pane = current_sidebar_pane or return

      system("tmux", "select-pane", "-t", pane, out: File::NULL, err: File::NULL)
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

    # The session a window id belongs to ("" if it's gone).
    def session_of_window(window)
      `tmux display-message -p -t #{Shellwords.escape(window)} '#\{session_name}' 2>/dev/null`.strip
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

    # The session the invoking client is currently in ("" outside tmux). Resolves
    # against the current client, like poke_current_sidebar — fine for the single
    # attached client that prefix-s comes from.
    def current_session
      name = `tmux display-message -p '#\{session_name}' 2>/dev/null`.strip
      name.empty? ? nil : name
    end

    def current_sidebar_pane
      `tmux list-panes -F '#\{pane_id} #\{pane_title}' 2>/dev/null`
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
      system("tmux", "send-keys", "-t", pane, "C-l", out: File::NULL, err: File::NULL) if pane
    end

    # Poke a session's sidebar by session name (vs. poke's pane id). reload_config:
    # sends C-r (the dedicated config-reload signal) instead of C-l, so only a
    # real edit re-reads config off disk. Returns nil when the session has no
    # sidebar (e.g. it was killed mid-edit), so callers can fall back.
    def poke_sidebar_of(session, reload_config: false)
      pane = sidebar_pane(session) or return

      key = reload_config ? RELOAD_CONFIG_POKE : "C-l"
      system("tmux", "send-keys", "-t", pane, key, out: File::NULL, err: File::NULL)
    end

    # Surface a short message on tmux's status line — visible no matter which
    # pane has focus (a sidebar-only flash is missed when you're not on the tree).
    def notify(message)
      system("tmux", "display-message", message.to_s, out: File::NULL, err: File::NULL)
    end

    # Is this pane on the active window of an attached session (i.e. on screen)?
    def visible?(pane)
      return true unless pane

      out = `tmux display-message -p -t #{Shellwords.escape(pane)} '#\{window_active},#\{session_attached}' 2>/dev/null`.strip
      active, attached = out.split(",")
      active == "1" && attached.to_i.positive?
    end

    # The pane's pseudo-terminal (e.g. /dev/ttys007) — tmux's stable per-pane
    # identity, fixed for the pane's whole life. nil if the pane is gone (a
    # dead/unresolved -t target prints empty). %ids, by contrast, get RECYCLED onto
    # new panes, so the sidebar captures its pty once at startup and compares: when
    # the pane its id now names reports a different tty, that id was handed to
    # someone else and this process is an orphan (owns_pane?).
    def pane_tty(pane)
      return nil unless pane

      tty = `tmux display-message -p -t #{Shellwords.escape(pane)} '#\{pane_tty}' 2>/dev/null`.strip
      tty.empty? ? nil : tty
    end

    # Is this pane the one the user is actually driving — the active pane, on the
    # active window, of an attached session? (Stronger than visible?: a sidebar
    # split is visible while you type in the editor beside it, but not focused.)
    def focused?(pane)
      return true unless pane

      out = `tmux display-message -p -t #{Shellwords.escape(pane)} '#\{pane_active},#\{window_active},#\{session_attached}' 2>/dev/null`.strip
      pane_active, window_active, attached = out.split(",")
      pane_active == "1" && window_active == "1" && attached.to_i.positive?
    end

    # Ask tmux to deliver focus in/out to the program in a pane, so the sidebar
    # can dim its cursor the instant it loses focus. Idempotent, best-effort.
    def enable_focus_events
      system("tmux", "set", "-g", "focus-events", "on", out: File::NULL, err: File::NULL)
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
      cmd = +"tmux split-window -hb -d -l #{width} -P -F '#\{pane_id}'"
      cmd << " -t #{Shellwords.escape(target)}" if target
      cmd << " -c #{Shellwords.escape(dir)}" if dir
      cmd << " #{Shellwords.escape(bin)} sidebar"

      pane = `#{cmd} 2>/dev/null`.strip
      return if pane.empty?

      system("tmux", "select-pane", "-t", pane, "-T", SIDEBAR_TITLE, out: File::NULL, err: File::NULL)
      pane
    end
  end
end
