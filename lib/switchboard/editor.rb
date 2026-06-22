# frozen_string_literal: true

module Switchboard
  # Resolves which editor to launch — shared by the CLI `config`/`edit` command
  # and the sidebar's `e` action so the choice can't drift between the two.
  module Editor
    module_function

    # $VISUAL/$EDITOR, treating an exported-but-empty value as unset — an empty
    # string is truthy in Ruby, so a bare `||` chain would pick it and try to
    # exec the config file itself. Falls back to vi.
    def command
      [ENV["VISUAL"], ENV["EDITOR"]].find { |e| e && !e.empty? } || "vi"
    end
  end
end
