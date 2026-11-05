# frozen_string_literal: true

module Switchboard
  # Sessions: finding, making, naming, switching and killing them.
  module Tmux
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
      ensure_work_pane(HOME) # if home's work pane was closed, re-grow one so we never land on a wedged (sidebar-only) home (#64)
      sidebar = window_sidebar_pane(HOME)
      # Focus the tree before switch, so the exec/attach path keeps it too.
      system("tmux", "-u", "select-pane", "-t", sidebar, out: File::NULL, err: File::NULL) if sidebar
      switch(HOME) # may exec (attach) when launched outside tmux
      poke(sidebar) # force a fresh tree now (e.g. right after a delete)
      pin(sidebar)
    end

    def ensure_home
      ensure_session(HOME, home_dir)
      ensure_sidebar(HOME)
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
      raw = `tmux -u list-sessions -F '#\{session_name}\t#\{session_created}' 2>/dev/null`
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

    # Returns whether THIS call created the session (false when it already existed or
    # new-session failed) — the dispatch worker fails its build on false.
    def ensure_session(name, dir, start = nil)
      return false if has_session?(name)

      # Gate the start command on new-session actually succeeding. If a racing
      # process (a CLI switch and a sidebar in another pane are separate
      # processes) created the session first, new-session fails — and we must
      # NOT type the command into a session we didn't create, or it lands twice.
      created = system(*new_session_cmd(name, dir), out: File::NULL, err: File::NULL)
      system("tmux", "-u", "rename-window", "-t", name, "work", out: File::NULL, err: File::NULL)
      # Record the first-creation default (on) explicitly, so new windows in this
      # session inherit a sidebar via the after-new-window hook. Gated on `created`
      # for the same reason as run_in_session: never stamp a session we lost a race
      # to create.
      set_sidebar_flag(name, "on") if created
      run_in_session(name, start) if start && created
      created == true # system's nil (tmux couldn't exec) is a failure too
    end

    # Build the `new-session` argv, sized to the current window when we can read
    # it. A detached session created with no -x/-y is born at tmux's 80x24
    # default, so the moment we switch a client into it tmux resizes the window
    # to the client and EVERY pane (the freshly split sidebar, the just-started
    # agent) visibly reflows — the "creating" flash. Building it at the final
    # on-screen size up front means the switch reveals a finished layout with
    # nothing to move. Off-tmux (the exec-attach launch path) the size is unknown
    # and omitted: the attach sizes the window anyway, same as before. Only a
    # POSITIVE pair is applied — a 0 dim (an openpty that came up 0x0, see the
    # smoke client) makes `new-session -x 0` fail outright ("width too small"),
    # which would turn a create that used to succeed at the 80x24 default into a
    # no-op; fall back to that default instead.
    def new_session_cmd(name, dir)
      cmd = ["tmux", "-u", "new-session", "-d", "-s", name, "-c", dir]
      w, h = current_window_size
      cmd.push("-x", w.to_s, "-y", h.to_s) if w&.positive? && h&.positive?
      cmd
    end

    # The on-screen size of the client's current window — the dimensions a
    # session we create detached will be resized to the instant a client switches
    # into it (see new_session_cmd). window_* (not client_*) because the client
    # height includes the status line the window doesn't, so sizing to the window
    # is an exact match — no off-by-the-status-bar reflow. [nil, nil] outside tmux
    # so the caller falls back to tmux's default sizing.
    def current_window_size
      return [nil, nil] unless ENV["TMUX"]

      parse_window_size(`tmux -u display-message -p '#\{window_width},#\{window_height}' 2>/dev/null`)
    end

    # Pure: a "W,H" reply parsed to [Integer, Integer], or [nil, nil] on an
    # empty/garbled line. Split out (like parse_window_panes) so it's unit-testable
    # without a server; a non-numeric field rescues to the nil pair, not a raise.
    def parse_window_size(raw)
      w, h = raw.to_s.strip.split(",")
      [Integer(w, 10), Integer(h, 10)]
    rescue StandardError
      [nil, nil]
    end

    # Type a command into a freshly created session's window and run it — how
    # config's session_command auto-starts an agent. `-l` sends it as literal
    # text: without it, a value that matches a tmux key name (e.g. "Enter",
    # "C-l", "Space") would be interpreted as that key instead of typed. The
    # Enter that submits the line is a separate, deliberately-interpreted key.
    # chomp so a trailing newline (a YAML block scalar) doesn't double-submit.
    # tmux buffers the keys until the shell is ready.
    def run_in_session(name, command)
      system("tmux", "-u", "send-keys", "-t", name, "-l", command.chomp, out: File::NULL, err: File::NULL)
      system("tmux", "-u", "send-keys", "-t", name, "Enter", out: File::NULL, err: File::NULL)
    end

    def has_session?(name)
      system("tmux", "-u", "has-session", "-t", "=#{name}", out: File::NULL, err: File::NULL)
    end

    # The session a pane belongs to (this process's own pane by default), or nil.
    # Lets the sidebar tell whether the workspace it's deleting is the very
    # session it's running inside — the case that needs the home fallback.
    def session_of(pane = ENV["TMUX_PANE"])
      return nil unless pane

      name = `tmux -u display-message -p -t #{Shellwords.escape(pane)} '#\{session_name}' 2>/dev/null`.strip
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
      system("tmux", "-u", "kill-session", "-t", "=#{name}", out: File::NULL, err: File::NULL)
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

      system("tmux", "-u", "rename-session", "-t", "=#{old_name}", new_name, out: File::NULL, err: File::NULL)
    end

    def switch(name)
      if ENV["TMUX"]
        system("tmux", "-u", "switch-client", "-t", name)
      else
        exec("tmux", "attach-session", "-t", name)
      end
    end

    # The session a window id belongs to ("" if it's gone).
    def session_of_window(window)
      `tmux -u display-message -p -t #{Shellwords.escape(window)} '#\{session_name}' 2>/dev/null`.strip
    end

    # The session the invoking client is currently in ("" outside tmux). Resolves
    # against the current client, like poke_current_sidebar — fine for the single
    # attached client that prefix-s comes from.
    def current_session
      name = `tmux -u display-message -p '#\{session_name}' 2>/dev/null`.strip
      name.empty? ? nil : name
    end
  end
end
