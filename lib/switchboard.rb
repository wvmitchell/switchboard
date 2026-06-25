# frozen_string_literal: true

require_relative "switchboard/version"
require_relative "switchboard/config"
require_relative "switchboard/editor"
require_relative "switchboard/git"
require_relative "switchboard/pr"
require_relative "switchboard/agents"
require_relative "switchboard/agent_state"
require_relative "switchboard/attention"
require_relative "switchboard/collapse"
require_relative "switchboard/full_header"
require_relative "switchboard/width"
require_relative "switchboard/hook"
require_relative "switchboard/sound"
require_relative "switchboard/model"
require_relative "switchboard/view"
require_relative "switchboard/tree"
require_relative "switchboard/creator"
require_relative "switchboard/registrar"
require_relative "switchboard/installer"
require_relative "switchboard/tmux"
require_relative "switchboard/reconcile"
require_relative "switchboard/sidebar"
require_relative "switchboard/cli"

# Keyboard-only, standalone switcher/creator over git worktrees. Reads its own
# config (no emdash/Conductor DB at runtime); discovers worktrees via git.
module Switchboard
end
