# frozen_string_literal: true

module Switchboard
  # Each worktree gets a tmux session named for it; switching is idempotent —
  # reuse the session if it already exists, otherwise scaffold it.
  module Tmux
    module_function

    def open(worktree)
      name = session_name(worktree)
      ensure_session(name, worktree.path)
      attach(name)
    end

    # tmux forbids "." and ":" in session names; keep it readable otherwise.
    def session_name(worktree)
      "sb/#{worktree.project}/#{worktree.leaf}".gsub(/[.:\s]/, "-")
    end

    def ensure_session(name, dir)
      return if system("tmux", "has-session", "-t", "=#{name}", out: File::NULL, err: File::NULL)

      system("tmux", "new-session", "-d", "-s", name, "-c", dir)
      system("tmux", "rename-window", "-t", name, "code", out: File::NULL, err: File::NULL)
    end

    def attach(name)
      if ENV["TMUX"]
        exec("tmux", "switch-client", "-t", name)
      else
        exec("tmux", "attach-session", "-t", name)
      end
    end
  end
end
