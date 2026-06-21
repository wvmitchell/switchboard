# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # The CLI dispatch logic that isn't just a pass-through to Installer: flag
  # parsing and the emdash-free `init`. (install/uninstall themselves are thin
  # delegations covered by InstallerTest; doctor's rows are ANSI formatting.)
  class CLITest < SandboxTest
    def test_flag_value_returns_the_value_after_the_flag
      assert_equal "/x.conf", CLI.flag_value(["--tmux-conf", "/x.conf"], "--tmux-conf")
    end

    def test_flag_value_is_nil_when_flag_absent
      assert_nil CLI.flag_value(["--no-tmux"], "--tmux-conf")
    end

    def test_flag_value_is_nil_when_flag_is_last_arg
      assert_nil CLI.flag_value(["--tmux-conf"], "--tmux-conf")
    end

    def test_init_writes_an_empty_config_when_absent
      out = capture { CLI.init }
      assert Config.exist?
      assert_equal Config.default_data, YAML.safe_load_file(Config.path)
      assert_includes out, "wrote"
    end

    def test_init_is_a_noop_when_config_exists
      File.write(Config.path, "worktree_root: /mine\nprojects: []\n")
      before = File.read(Config.path)
      out = capture { CLI.init }
      assert_equal before, File.read(Config.path)
      assert_includes out, "already exists"
    end

    # `refresh [name] [--poke PANE]` argument parsing.
    def test_refresh_args_parses_name_and_poke
      assert_equal ["proj", "%5"], CLI.refresh_args(["refresh", "proj", "--poke", "%5"])
    end

    def test_refresh_args_name_only
      assert_equal ["proj", nil], CLI.refresh_args(["refresh", "proj"])
    end

    def test_refresh_args_poke_without_name
      assert_equal [nil, "%5"], CLI.refresh_args(["refresh", "--poke", "%5"])
    end

    def test_refresh_args_bare
      assert_equal [nil, nil], CLI.refresh_args(["refresh"])
    end

    # refresh must never raise or touch tmux in the sandbox (TMUX unset), whether
    # the config is empty or the named project is unknown.
    def test_refresh_is_a_noop_on_empty_config
      File.write(Config.path, "worktree_root: /mine\nprojects: []\n")
      assert_nil CLI.refresh
    end

    def test_refresh_unknown_project_is_a_noop
      File.write(Config.path, "worktree_root: /mine\nprojects: []\n")
      assert_nil CLI.refresh("ghost")
    end

    # CLI memoizes its Config; clear it so each test reads its own sandbox config.
    def teardown
      CLI.instance_variable_set(:@config, nil)
      super
    end

    private

    def capture
      out = StringIO.new
      orig = $stdout
      $stdout = out
      yield
      out.string
    ensure
      $stdout = orig
    end
  end
end
