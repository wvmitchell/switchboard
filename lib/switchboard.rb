# frozen_string_literal: true

module Switchboard
  # An environment value as UTF-8. Under a C/POSIX locale Ruby hands ENV back as BINARY,
  # which can't be combined with the UTF-8 strings (hook commands, messages) built from it.
  def self.env(name) = ENV[name]&.dup&.force_encoding(Encoding::UTF_8)
end

require_relative "switchboard/version"
require_relative "switchboard/stable_path"
require_relative "switchboard/config"
require_relative "switchboard/editor"
require_relative "switchboard/git"
require_relative "switchboard/pr"
require_relative "switchboard/agents"
require_relative "switchboard/agent_state"
require_relative "switchboard/remote_link"
require_relative "switchboard/keyed_marker_store"
require_relative "switchboard/process_identity"
require_relative "switchboard/marker_block"
require_relative "switchboard/attention"
require_relative "switchboard/monitoring"
require_relative "switchboard/notify"
require_relative "switchboard/pending_delete"
require_relative "switchboard/creation"
require_relative "switchboard/collapse"
require_relative "switchboard/full_header"
require_relative "switchboard/branch_fold"
require_relative "switchboard/width"
require_relative "switchboard/keymap"
require_relative "switchboard/hook_file"
require_relative "switchboard/claude_hook"
require_relative "switchboard/codex_hook"
require_relative "switchboard/agent_hooks"
require_relative "switchboard/sound"
require_relative "switchboard/model"
require_relative "switchboard/view"
require_relative "switchboard/tree"
require_relative "switchboard/placeholder"
require_relative "switchboard/creator"
require_relative "switchboard/registrar"
require_relative "switchboard/latest_release"
require_relative "switchboard/installer"
require_relative "switchboard/upgrade"
require_relative "switchboard/tmux"
require_relative "switchboard/isolated_server"
require_relative "switchboard/claude_history"
require_relative "switchboard/rename"
require_relative "switchboard/rename_nudge"
require_relative "switchboard/monitoring_nudge"
require_relative "switchboard/reconcile"
require_relative "switchboard/sandbox"
require_relative "switchboard/sidebar"
require_relative "switchboard/cli"

# Keyboard-only, standalone switcher/creator over git worktrees. Reads its own
# config (no emdash/Conductor DB at runtime); discovers worktrees via git.
module Switchboard
end
