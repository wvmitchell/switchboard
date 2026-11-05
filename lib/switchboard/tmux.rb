# frozen_string_literal: true

require "shellwords"
require "set"

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
    # A non-user key the sidebar maps to "shared view-state changed — repaint now",
    # broadcast to every OTHER sidebar when one toggles a collapse/fold/header so
    # off-screen panes update instantly (no switch-in flash). Distinct from C-l.
    WARM_POKE = "C-w"
    NOTIFY_MS = 2500 # the shortest a status-line notice stays up (see notify)
    INPUT_QUIET = 2  # seconds without input from any client before keys go to a pane (see panes_by_tty)

    module_function

    # The door for a tmux call made outside this module, so a test's stub of Tmux.system or IO.popen
    # intercepts it wherever the call lives. Whether tmux reported success.
    def run(*args) = system("tmux", "-u", *args, out: File::NULL, err: File::NULL)

    # What tmux printed, or nil when it failed or can't run.
    def query(*args)
      out = IO.popen(["tmux", "-u", *args], err: File::NULL, &:read)
      $?.success? ? out : nil
    rescue SystemCallError
      nil
    end
  end
end

require_relative "tmux/sessions"
require_relative "tmux/sidebar_panes"
require_relative "tmux/presence"
require_relative "tmux/notify"
require_relative "tmux/keys"
