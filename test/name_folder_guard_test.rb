# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # A workspace's folder never moves, so its name is no longer its folder name: anything
  # shown, matched or typed must use Worktree#display_name. In tests the names store is
  # usually empty, so a `File.basename(wt.path)` label passes by accident; this pins every
  # place lib/ derives a name from a path, by file. A new one fails here: use display_name,
  # or (for a path on disk, a file's own name) add it with its reason. Reads files only.
  class NameFolderGuardTest < Minitest::Test
    LIB = File.expand_path("../lib/switchboard", __dir__)
    PATTERN = /File\.basename\(|\.folder_name\b/

    ALLOWED = {
      "adapters/claude_sessions" => 1, # a process's argv[0]
      "adapters/hook_file" => 1,       # a hook script's own file name
      "cli" => 1,                      # `switchboard path` also accepts a folder name
      "ops/code_reload" => 1,          # a binary's name
      "ops/creator" => 4,              # shells and commands, not workspaces
      "ops/doctor" => 5,               # the binary, a branch leaf, and the folder beside its name
      "ops/installer" => 1,            # a symlink's name
      "ops/isolated_server" => 2,      # socket dirs and the tmux binary
      "ops/registrar" => 1,            # a repo's default project name
      "ops/rename" => 4,               # folders that block a name, and "back to the folder name"
      "ops/sandbox" => 1,              # a sandbox file named after its checkout
      "ops/session_name" => 1,         # display_name's own fallback
      "sidebar" => 1,                  # a state file's name
      "sidebar/render" => 1,           # the ⇅ view's label when its workspace has no row
      "state/creation" => 1,           # a record file's name
      "state/model" => 1,              # Worktree#folder_name itself
      "state/names" => 1               # the duplicate rule compares folder names
    }.freeze

    def counts
      Dir[File.join(LIB, "**", "*.rb")].sort.to_h do |f|
        [f.delete_prefix("#{LIB}/").delete_suffix(".rb"), File.read(f).scan(PATTERN).size]
      end.reject { |_, n| n.zero? }
    end

    def test_names_come_from_display_name_not_the_folder
      assert_equal ALLOWED, counts, "a name derived from a path: use Worktree#display_name, or add it here with its reason"
    end

    # Value: protects=the guard can fire; fails_when=PATTERN stops matching either form;
    # seam=none
    def test_the_pattern_catches_both_forms
      assert_equal 2, "File.basename(wt.path) + wt.folder_name".scan(PATTERN).size
    end
  end
end
