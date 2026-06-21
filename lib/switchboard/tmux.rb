# frozen_string_literal: true

require "shellwords"

module Switchboard
  # tmux orchestration. Each worktree maps to a session; every session carries a
  # switchboard sidebar pane so the tree stays beside you as you switch.
  module Tmux
    SIDEBAR_TITLE = "sb-sidebar"
    SIDEBAR_WIDTH = 40
    HOME = "sb/home" # the persistent anchor session (see go_home)

    module_function

    # Switch to a worktree's session (creating it, with a sidebar, if needed).
    # `start` (config's session_command) is typed into the window only when the
    # session is first created — never on a re-switch into a live one. Non-exec
    # so callers (the sidebar loop) keep running.
    def go(worktree, start: nil)
      name = session_name(worktree)
      ensure_session(name, worktree.path, start)
      ensure_sidebar(name, worktree.path)
      sidebar = sidebar_pane(name)
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
      ensure_home
      sidebar = sidebar_pane(HOME)
      # Focus the tree before switch, so the exec/attach path keeps it too.
      system("tmux", "select-pane", "-t", sidebar, out: File::NULL, err: File::NULL) if sidebar
      switch(HOME) # may exec (attach) when launched outside tmux
      poke(sidebar) # force a fresh tree now (e.g. right after a delete)
      pin(sidebar)
    end

    def ensure_home
      ensure_session(HOME, home_dir)
      ensure_sidebar(HOME, home_dir)
    end

    # Home sits in $HOME: a neutral, always-present directory owned by no project.
    # Fall back to the cwd if $HOME is somehow unset — expand_path("~") would
    # itself raise without $HOME, so don't route the fallback through it.
    def home_dir
      File.expand_path(ENV["HOME"] || Dir.pwd)
    end

    # tmux forbids "." and ":" in session names.
    def session_name(worktree)
      "sb/#{worktree.project}/#{worktree.leaf}".gsub(/[.:\s]/, "-")
    end

    def ensure_session(name, dir, start = nil)
      return if has_session?(name)

      # Gate the start command on new-session actually succeeding. If a racing
      # process (a CLI switch and a sidebar in another pane are separate
      # processes) created the session first, new-session fails — and we must
      # NOT type the command into a session we didn't create, or it lands twice.
      created = system("tmux", "new-session", "-d", "-s", name, "-c", dir, out: File::NULL, err: File::NULL)
      system("tmux", "rename-window", "-t", name, "work", out: File::NULL, err: File::NULL)
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
      system("tmux", "kill-session", "-t", "=#{session_name(worktree)}", out: File::NULL, err: File::NULL)
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

    # Add a sidebar pane to a session's active window if it lacks one.
    def ensure_sidebar(name, dir)
      spawn_sidebar(target: name, dir: dir) unless sidebar_pane(name)
    end

    # Pane id of a session's sidebar, or nil. -s covers all the session's
    # windows so we never spawn a duplicate when one already exists elsewhere.
    def sidebar_pane(target)
      `tmux list-panes -s -t #{Shellwords.escape(target)} -F '#\{pane_id} #\{pane_title}' 2>/dev/null`
        .lines.find { |line| line.include?(SIDEBAR_TITLE) }&.split&.first
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

    # Re-assert the sidebar's fixed width. Windows rescale panes proportionally
    # on resize (and aggressive-resize), which grows an absolute-width sidebar.
    def pin(pane)
      return unless pane

      system("tmux", "resize-pane", "-t", pane, "-x", SIDEBAR_WIDTH.to_s, out: File::NULL, err: File::NULL)
    end

    # Toggle the sidebar in the CURRENT window — bound to a key.
    def toggle_sidebar
      pane = current_sidebar_pane
      pane ? system("tmux", "kill-pane", "-t", pane) : spawn_sidebar
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

    # Is this pane on the active window of an attached session (i.e. on screen)?
    def visible?(pane)
      return true unless pane

      out = `tmux display-message -p -t #{Shellwords.escape(pane)} '#\{window_active},#\{session_attached}' 2>/dev/null`.strip
      active, attached = out.split(",")
      active == "1" && attached.to_i.positive?
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

    # Split a narrow sidebar pane on the left running `switchboard sidebar`.
    def spawn_sidebar(target: nil, dir: nil)
      bin = ENV["SWITCHBOARD_BIN"]
      return unless bin

      # -l fixes the new pane's width at split time (resize-after-split raced
      # and sometimes left it at the 50/50 default).
      cmd = +"tmux split-window -hb -d -l #{SIDEBAR_WIDTH} -P -F '#\{pane_id}'"
      cmd << " -t #{Shellwords.escape(target)}" if target
      cmd << " -c #{Shellwords.escape(dir)}" if dir
      cmd << " #{Shellwords.escape(bin)} sidebar"

      pane = `#{cmd} 2>/dev/null`.strip
      return if pane.empty?

      system("tmux", "select-pane", "-t", pane, "-T", SIDEBAR_TITLE, out: File::NULL, err: File::NULL)
    end
  end
end
