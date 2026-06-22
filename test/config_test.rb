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

    # --- remove_project: the inverse write path (single source of truth) ------

    def test_remove_project_drops_the_named_entry_and_keeps_the_rest
      File.write(Config.path, YAML.dump("worktree_root" => "/mine", "projects" => [
                                          { "name" => "a", "path" => "/p" },
                                          { "name" => "b", "path" => "/q", "base" => "origin/dev" }
                                        ]))
      removed = Config.remove_project("a")
      data = YAML.safe_load_file(Config.path)
      assert_equal({ "name" => "a", "path" => "/p" }, removed, "returns the removed raw entry")
      assert_equal %w[b], data["projects"].map { |p| p["name"] }
      assert_equal "/mine", data["worktree_root"], "preserves the rest of the config"
      assert_equal "origin/dev", data["projects"].first["base"], "preserves the survivor's keys"
    end

    def test_remove_project_returns_nil_for_an_unknown_name
      File.write(Config.path, YAML.dump("projects" => [{ "name" => "a", "path" => "/p" }]))
      assert_nil Config.remove_project("nope")
      assert_equal %w[a], YAML.safe_load_file(Config.path)["projects"].map { |p| p["name"] },
                   "an unknown name leaves the config untouched"
    end

    def test_remove_project_returns_nil_when_no_config_exists
      refute Config.exist?
      assert_nil Config.remove_project("a")
    end

    # --- resolution accessors (extends #18's scaffold/add_project coverage) ---
    # The session_command chain is the part issue #10 specifically named and #18
    # didn't touch: global default, per-project override, empty->global fallback,
    # unknown project.

    # Build a Config from a raw hash written to the sandboxed config path.
    def cfg(data)
      File.write(Config.path, YAML.dump(data))
      Config.new
    end

    def test_worktree_root_defaults_and_expands
      assert_equal File.expand_path(Config::DEFAULT_ROOT), cfg({}).worktree_root
      assert_equal File.expand_path("/tmp/wt"), cfg("worktree_root" => "/tmp/wt").worktree_root
    end

    def test_projects_root_defaults_and_overrides
      assert_equal File.expand_path(Config::DEFAULT_PROJECTS_ROOT), cfg({}).projects_root
      assert_equal File.expand_path("/src"), cfg("projects_root" => "/src").projects_root
    end

    def test_base_defaults_to_origin_main_and_overrides
      assert_equal "origin/main", cfg({}).base
      assert_equal "origin/main", cfg("base" => "").base   # empty -> default
      assert_equal "main", cfg("base" => "main").base
    end

    def test_branch_prefix_is_nil_unless_set
      assert_nil cfg({}).branch_prefix
      assert_nil cfg("branch_prefix" => "").branch_prefix
      assert_equal "wvmitchell", cfg("branch_prefix" => "wvmitchell").branch_prefix
    end

    def test_agent_state_hooks_on_by_default_off_only_when_false
      assert cfg({}).agent_state_hooks?
      assert cfg("agent_state_hooks" => true).agent_state_hooks?
      refute cfg("agent_state_hooks" => false).agent_state_hooks?
    end

    def test_prune_on_launch_on_by_default_off_only_when_false
      assert cfg({}).prune_on_launch?
      assert cfg("prune_on_launch" => true).prune_on_launch?
      refute cfg("prune_on_launch" => false).prune_on_launch?
    end

    def test_session_command_global_is_nil_unless_set
      assert_nil cfg({}).session_command
      assert_nil cfg("session_command" => "").session_command
      assert_equal "claude", cfg("session_command" => "claude").session_command
    end

    def test_session_command_for_uses_global_default
      c = cfg("session_command" => "claude", "projects" => [{ "name" => "app", "path" => "/p" }])
      assert_equal "claude", c.session_command_for("app")
    end

    def test_session_command_for_honors_per_project_override
      c = cfg("session_command" => "claude",
              "projects" => [{ "name" => "app", "path" => "/p", "session_command" => "codex" }])
      assert_equal "codex", c.session_command_for("app")
    end

    def test_session_command_for_empty_override_falls_back_to_global
      c = cfg("session_command" => "claude",
              "projects" => [{ "name" => "app", "path" => "/p", "session_command" => "" }])
      assert_equal "claude", c.session_command_for("app")
    end

    def test_session_command_for_unknown_project_uses_global
      assert_equal "claude", cfg("session_command" => "claude", "projects" => []).session_command_for("nope")
    end

    def test_session_command_for_nil_when_no_global_and_no_override
      c = cfg("projects" => [{ "name" => "app", "path" => "/p" }])
      assert_nil c.session_command_for("app")
    end

    def test_projects_resolves_paths_and_base_ref
      c = cfg("base" => "origin/trunk",
              "projects" => [{ "name" => "a", "path" => "~/x" },
                             { "name" => "b", "path" => "/y", "base" => "main" }])
      a, b = c.projects
      assert_equal File.expand_path("~/x"), a["path"]
      assert_equal "origin/trunk", a["base_ref"] # inherits global base
      assert_equal "main", b["base_ref"]         # per-project base
    end

    def test_projects_skips_entries_missing_name_or_path
      c = cfg("projects" => [{ "name" => "ok", "path" => "/p" }, { "name" => "noPath" }, { "path" => "/noName" }])
      assert_equal ["ok"], c.projects.map { |p| p["name"] }
    end

    # --- sounds: global + per-project resolution (mirrors session_command) -----

    def test_sound_for_defaults_to_built_ins_and_on
      c = cfg({})
      assert c.sounds_enabled?
      assert_equal "train", c.sound_for(nil, :done)
      assert_equal "chime", c.sound_for(nil, :waiting)
    end

    def test_sounds_global_mute_via_enabled_false
      c = cfg("sounds" => { "enabled" => false })
      refute c.sounds_enabled?
      assert_nil c.sound_for(nil, :done)
    end

    def test_sounds_global_mute_via_bare_false
      c = cfg("sounds" => false)
      refute c.sounds_enabled?
      assert_nil c.sound_for(nil, :waiting)
    end

    def test_sound_for_global_override
      c = cfg("sounds" => { "done" => "/horn.wav" })
      assert_equal "/horn.wav", c.sound_for(nil, :done)
      assert_equal "chime", c.sound_for(nil, :waiting) # untouched key falls to default
    end

    def test_sound_for_blank_override_inherits_never_mutes
      # Per-state keys are override-or-inherit only; muting is enabled:false.
      c = cfg("sounds" => { "done" => "" })
      assert_equal "train", c.sound_for(nil, :done)
    end

    def test_sound_for_per_project_override
      c = cfg("sounds" => { "done" => "Glass" },
              "projects" => [{ "name" => "app", "path" => "/p", "sounds" => { "done" => "Hero" } }])
      assert_equal "Hero", c.sound_for("app", :done)     # per-project wins
      assert_equal "chime", c.sound_for("app", :waiting) # inherits global (here: default)
      assert_equal "Glass", c.sound_for(nil, :done)      # global, no project
    end

    def test_sounds_per_project_mute
      c = cfg("projects" => [{ "name" => "app", "path" => "/p", "sounds" => { "enabled" => false } }])
      refute c.sounds_enabled?("app")
      assert_nil c.sound_for("app", :done)
      assert c.sounds_enabled? # global still on
      assert_equal "train", c.sound_for(nil, :done)
    end

    def test_sounds_per_project_enable_overrides_global_mute
      c = cfg("sounds" => { "enabled" => false },
              "projects" => [{ "name" => "app", "path" => "/p", "sounds" => { "enabled" => true } }])
      assert c.sounds_enabled?("app")
      assert_equal "train", c.sound_for("app", :done)
      refute c.sounds_enabled?(nil) # global still muted
    end
  end
end
