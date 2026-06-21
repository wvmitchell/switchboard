# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # Config.scaffold / default_data — the single source of truth for an empty
  # config, shared by init, `config`, and install. The load-bearing guarantee is
  # "never clobber an existing file", since install runs scaffold unconditionally.
  class ConfigTest < SandboxTest
    def test_default_data_shape
      assert_equal({ "worktree_root" => Config::DEFAULT_ROOT, "projects" => [] }, Config.default_data)
    end

    def test_default_data_is_a_fresh_hash_each_call
      refute_same Config.default_data, Config.default_data
    end

    def test_scaffold_writes_empty_config_when_absent
      refute Config.exist?
      Config.scaffold
      assert Config.exist?
      assert_equal Config.default_data, YAML.safe_load_file(Config.path)
    end

    def test_scaffold_returns_the_path
      assert_equal Config.path, Config.scaffold
    end

    def test_scaffold_never_clobbers_an_existing_config
      File.write(Config.path, "worktree_root: /custom\nprojects:\n  - name: x\n    path: /p\n")
      before = File.read(Config.path)
      Config.scaffold
      assert_equal before, File.read(Config.path)
    end

    def test_scaffold_never_clobbers_a_malformed_config
      File.write(Config.path, "}{ definitely not yaml")
      Config.scaffold
      assert_equal "}{ definitely not yaml", File.read(Config.path)
    end

    def test_scaffold_never_clobbers_an_empty_file
      File.write(Config.path, "")
      Config.scaffold
      assert_equal "", File.read(Config.path)
    end

    # add_project shares default_data for its fresh-file fallback (changed in this
    # PR) — the single config-write path behind CLI add/clone and the sidebar.
    def test_add_project_writes_a_wellformed_config_when_absent
      refute Config.exist?
      entry = Config.add_project("app", "/repos/app", "origin/main")
      data = YAML.safe_load_file(Config.path)
      assert_equal Config::DEFAULT_ROOT, data["worktree_root"]
      assert_equal([{ "name" => "app", "path" => "/repos/app", "base" => "origin/main" }], data["projects"])
      assert_equal "app", entry["name"]
    end

    def test_add_project_appends_preserving_existing_projects
      File.write(Config.path, "worktree_root: /mine\nprojects:\n  - name: a\n    path: /p\n")
      Config.add_project("b", "/q")
      names = YAML.safe_load_file(Config.path)["projects"].map { |p| p["name"] }
      assert_equal %w[a b], names
    end
  end
end
