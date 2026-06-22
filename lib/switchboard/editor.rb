# frozen_string_literal: true

module Switchboard
  # Resolves which editor to launch — shared by the CLI `config`/`edit` command
  # and the sidebar's `e` action so the choice can't drift between the two.
  module Editor
    module_function

    # $VISUAL/$EDITOR, treating an exported-but-empty value as unset — an empty
    # string is truthy in Ruby, so a bare `||` chain would pick it and try to
    # exec the config file itself. Falls back to vi. Resolved in THIS process —
    # right for the CLI `config` command, which runs the editor in the shell you
    # typed it from.
    def command
      [ENV["VISUAL"], ENV["EDITOR"]].find { |e| e && !e.empty? } || "vi"
    end

    # The same precedence + empty-is-unset rule, but as a shell expression the
    # SPAWNED shell evaluates rather than this process. The sidebar's `e` runs the
    # editor in a freshly-split tmux pane; resolving there picks up an EDITOR set
    # after this long-lived sidebar process started (e.g. `tmux setenv -g`), which
    # a value baked from #command at process start would miss. `:-` is shell for
    # "unset or empty", matching #command's guard.
    SHELL_COMMAND = "${VISUAL:-${EDITOR:-vi}}"
  end
end
