# frozen_string_literal: true

require "shellwords"

module Switchboard
  # tmux orchestration. Each worktree maps to a session; every session carries a
  # switchboard sidebar pane so the tree stays beside you as you switch.
  module Tmux
    SIDEBAR_TITLE = "sb-sidebar"
    SIDEBAR_WIDTH = 40

    module_function

    # Switch to a worktree's session (creating it, with a sidebar, if needed).
    # Non-exec so callers (the sidebar loop) keep running.
    def go(worktree)
      name = session_name(worktree)
      ensure_session(name, worktree.path)
      ensure_sidebar(name, worktree.path)
      switch(name)
      pin(sidebar_pane(name)) # snap to fixed width at the now-current client size
    end

    # tmux forbids "." and ":" in session names.
    def session_name(worktree)
      "sb/#{worktree.project}/#{worktree.leaf}".gsub(/[.:\s]/, "-")
    end

    def ensure_session(name, dir)
      return if has_session?(name)

      system("tmux", "new-session", "-d", "-s", name, "-c", dir, out: File::NULL, err: File::NULL)
      system("tmux", "rename-window", "-t", name, "work", out: File::NULL, err: File::NULL)
    end

    def has_session?(name)
      system("tmux", "has-session", "-t", "=#{name}", out: File::NULL, err: File::NULL)
    end

    # Kill a worktree's session (if any) — used when deleting a workspace.
    def kill(worktree)
      system("tmux", "kill-session", "-t", "=#{session_name(worktree)}", out: File::NULL, err: File::NULL)
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

    # Pane id of a session's sidebar, or nil.
    def sidebar_pane(target)
      `tmux list-panes -t #{Shellwords.escape(target)} -F '#\{pane_id} #\{pane_title}' 2>/dev/null`
        .lines.find { |line| line.include?(SIDEBAR_TITLE) }&.split&.first
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
    # hook, so switching sessions always lands on a fresh tree).
    def poke_current_sidebar
      pane = current_sidebar_pane
      system("tmux", "send-keys", "-t", pane, "r", out: File::NULL, err: File::NULL) if pane
    end

    # Is this pane on the active window of an attached session (i.e. on screen)?
    def visible?(pane)
      return true unless pane

      out = `tmux display-message -p -t #{Shellwords.escape(pane)} '#\{window_active},#\{session_attached}' 2>/dev/null`.strip
      active, attached = out.split(",")
      active == "1" && attached.to_i.positive?
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
