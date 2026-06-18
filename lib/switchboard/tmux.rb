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

    def switch(name)
      if ENV["TMUX"]
        system("tmux", "switch-client", "-t", name)
      else
        exec("tmux", "attach-session", "-t", name)
      end
    end

    # Add a sidebar pane to a session's active window if it lacks one.
    def ensure_sidebar(name, dir)
      spawn_sidebar(target: name, dir: dir) unless sidebar_present?(name)
    end

    def sidebar_present?(target)
      panes(target).include?(SIDEBAR_TITLE)
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

    def panes(target)
      `tmux list-panes -t #{Shellwords.escape(target)} -F '#\{pane_title}' 2>/dev/null`
    end
  end
end
