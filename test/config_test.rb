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

    # The scaffold is an annotated template so a fresh install discovers the optional
    # knobs in the file itself. The invariant: only worktree_root + projects are
    # active, so it parses to exactly default_data (commented knobs change nothing).
    def test_scaffold_template_parses_to_default_data
      assert_equal Config.default_data, YAML.safe_load(Config::SCAFFOLD_TEMPLATE),
                   "commented knobs must not change the effective config"
    end

    def test_scaffold_template_advertises_the_optional_knobs
      %w[tmux_keys sidebar_keys sounds session_command base prune_on_launch projects_root auto_rename diff_counts prewarm].each do |knob|
        assert_includes Config::SCAFFOLD_TEMPLATE, knob, "a fresh config should advertise #{knob}"
      end
    end

    def test_scaffold_writes_the_annotated_template_but_parses_to_defaults
      Config.scaffold
      body = File.read(Config.path)
      assert_includes body, "tmux_keys", "the written file shows the keybinding knob"
      assert_includes body, "# switchboard config", "and the header pointer to the README"
      assert_equal Config.default_data, YAML.safe_load_file(Config.path), "but still parses to the defaults"
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

    # A user-typed surrounding slash must be stripped — switchboard owns the
    # separator, so "wvmitchell/" would otherwise build the invalid ref
    # "wvmitchell//<name>" and silently break every create + rename.
    def test_branch_prefix_strips_surrounding_slashes
      assert_equal "wvmitchell", cfg("branch_prefix" => "wvmitchell/").branch_prefix
      assert_equal "wvmitchell", cfg("branch_prefix" => "wvmitchell//").branch_prefix
      assert_equal "wvmitchell", cfg("branch_prefix" => "/wvmitchell/").branch_prefix
      assert_equal "team/wvmitchell", cfg("branch_prefix" => "team/wvmitchell/").branch_prefix
      assert_nil cfg("branch_prefix" => "/").branch_prefix
    end

    def test_agent_state_hooks_on_by_default_off_only_when_false
      assert cfg({}).agent_state_hooks?
      assert cfg("agent_state_hooks" => true).agent_state_hooks?
      refute cfg("agent_state_hooks" => false).agent_state_hooks?
    end

    def test_auto_rename_on_by_default_off_only_when_false
      assert cfg({}).auto_rename?
      assert cfg("auto_rename" => true).auto_rename?
      refute cfg("auto_rename" => false).auto_rename?
    end

    # The global×project matrix: an explicit per-project value wins; absent inherits.
    def test_auto_rename_for_resolution_matrix
      proj = ->(extra) { { "projects" => [{ "name" => "p", "path" => "/p" }.merge(extra)] } }
      # per-project false beats global true; per-project true beats global false
      refute cfg(proj.call("auto_rename" => false).merge("auto_rename" => true)).auto_rename_for("p")
      assert cfg(proj.call("auto_rename" => true).merge("auto_rename" => false)).auto_rename_for("p")
      # no per-project key -> inherit the global
      assert cfg(proj.call({}).merge("auto_rename" => true)).auto_rename_for("p")
      refute cfg(proj.call({}).merge("auto_rename" => false)).auto_rename_for("p")
      # nothing set anywhere -> on (inherits the global default)
      assert cfg(proj.call({})).auto_rename_for("p")
    end

    def test_prune_on_launch_on_by_default_off_only_when_false
      assert cfg({}).prune_on_launch?
      assert cfg("prune_on_launch" => true).prune_on_launch?
      refute cfg("prune_on_launch" => false).prune_on_launch?
    end

    def test_prewarm_on_by_default_off_only_when_false
      assert cfg({}).prewarm?
      assert cfg("prewarm" => true).prewarm?
      refute cfg("prewarm" => false).prewarm?
    end

    def test_diff_counts_on_by_default_off_only_when_false
      assert cfg({}).diff_counts?
      assert cfg("diff_counts" => true).diff_counts?
      refute cfg("diff_counts" => false).diff_counts?
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

    # --- tmux_keys: configurable toggle/home keys (issue #15) ------------------

    def test_tmux_key_defaults_when_unset
      assert_equal "s", cfg({}).tmux_key("toggle")
      assert_nil cfg({}).tmux_key("home"), "home is unbound by default"
    end

    def test_tmux_key_uses_configured_values
      c = cfg("tmux_keys" => { "toggle" => "b", "home" => "H" })
      assert_equal "b", c.tmux_key("toggle")
      assert_equal "H", c.tmux_key("home")
    end

    def test_tmux_key_trims_and_accepts_modifier_and_named_keys
      assert_equal "C-Space", cfg("tmux_keys" => { "toggle" => "C-Space" }).tmux_key("toggle")
      assert_equal "F1", cfg("tmux_keys" => { "toggle" => " F1 " }).tmux_key("toggle"), "trims whitespace"
    end

    def test_tmux_key_falls_back_on_empty_or_whitespace
      assert_equal "s", cfg("tmux_keys" => { "toggle" => "" }).tmux_key("toggle")
      assert_equal "s", cfg("tmux_keys" => { "toggle" => "   " }).tmux_key("toggle")
    end

    def test_tmux_key_falls_back_on_invalid_token
      assert_equal "s", cfg("tmux_keys" => { "toggle" => "a b" }).tmux_key("toggle"), "internal space rejected"
      assert_equal "s", cfg("tmux_keys" => { "toggle" => "x\"y" }).tmux_key("toggle"), "quote rejected"
      assert_nil cfg("tmux_keys" => { "home" => "a b" }).tmux_key("home"), "invalid home -> unbound"
    end

    def test_tmux_key_rejects_non_string_yaml_types
      # YAML can hand us ints/bools/arrays/hashes; only strings are valid keys.
      assert_equal "s", cfg("tmux_keys" => { "toggle" => 1 }).tmux_key("toggle")
      assert_equal "s", cfg("tmux_keys" => { "toggle" => true }).tmux_key("toggle")
      assert_equal "s", cfg("tmux_keys" => { "toggle" => %w[a b] }).tmux_key("toggle")
    end

    def test_tmux_key_falls_back_when_tmux_keys_not_a_hash
      assert_equal "s", cfg("tmux_keys" => "nonsense").tmux_key("toggle")
      assert_nil cfg("tmux_keys" => "nonsense").tmux_key("home")
    end

    def test_tmux_key_drops_home_colliding_with_toggle
      c = cfg("tmux_keys" => { "toggle" => "b", "home" => "b" })
      assert_equal "b", c.tmux_key("toggle")
      assert_nil c.tmux_key("home"), "one key can't carry two actions; toggle wins"
    end

    def test_tmux_key_drops_home_colliding_with_default_toggle
      # home == the *default* toggle (s) should still collide.
      c = cfg("tmux_keys" => { "home" => "s" })
      assert_equal "s", c.tmux_key("toggle")
      assert_nil c.tmux_key("home")
    end

    def test_raw_tmux_key_returns_unvalidated_value
      c = cfg("tmux_keys" => { "toggle" => "a b" })
      assert_equal "a b", c.raw_tmux_key("toggle"), "raw value for doctor to show"
      assert_nil cfg({}).raw_tmux_key("toggle")
    end

    def test_valid_tmux_key_predicate
      c = cfg({})
      assert c.valid_tmux_key?("s")
      assert c.valid_tmux_key?("C-x")
      assert c.valid_tmux_key?("NPage")
      refute c.valid_tmux_key?(""), "empty"
      refute c.valid_tmux_key?("a b"), "whitespace"
      refute c.valid_tmux_key?("a'b"), "single quote"
      refute c.valid_tmux_key?(1), "non-string"
      refute c.valid_tmux_key?(nil), "nil"
    end

    # --- sidebar_keys: configurable in-sidebar keys (issue #108) ---------------

    def test_raw_sidebar_key_returns_unvalidated_value
      c = cfg("sidebar_keys" => { "new_workspace" => "c", "rename" => "foo" })
      assert_equal "c", c.raw_sidebar_key("new_workspace")
      assert_equal "foo", c.raw_sidebar_key("rename"), "raw (even invalid) value for doctor to show"
      assert_nil c.raw_sidebar_key("delete"), "unset action -> nil"
      assert_nil cfg({}).raw_sidebar_key("delete"), "no sidebar_keys block -> nil"
    end

    def test_raw_sidebar_key_accepts_symbol_or_string_action
      c = cfg("sidebar_keys" => { "quit" => "x" })
      assert_equal "x", c.raw_sidebar_key(:quit), "Keymap passes symbols; Config normalizes"
      assert_equal "x", c.raw_sidebar_key("quit")
    end

    def test_raw_sidebar_key_when_block_not_a_hash
      assert_nil cfg("sidebar_keys" => "nonsense").raw_sidebar_key("quit")
    end

    def test_valid_sidebar_key_predicate
      c = cfg({})
      assert c.valid_sidebar_key?("j"), "single printable ASCII char"
      assert c.valid_sidebar_key?("/")
      assert c.valid_sidebar_key?("?")
      assert c.valid_sidebar_key?(" "), "space is a printable single byte"
      refute c.valid_sidebar_key?("jk"), "more than one char (a named key) is rejected"
      refute c.valid_sidebar_key?(""), "empty"
      refute c.valid_sidebar_key?("\t"), "control char (non-printable)"
      refute c.valid_sidebar_key?("\e"), "Esc is reserved structurally"
      refute c.valid_sidebar_key?("é"), "multi-byte char is rejected"
      refute c.valid_sidebar_key?(1), "non-string"
      refute c.valid_sidebar_key?(nil), "nil"
    end

    # --- malformed config degrades instead of crashing (decision #5) -----------

    def test_malformed_config_degrades_to_empty_with_load_error
      File.write(Config.path, "}{ definitely not yaml")
      c = Config.new
      assert c.load_error, "records why it failed to parse"
      assert_equal "s", c.tmux_key("toggle"), "still resolves defaults"
      assert_equal [], c.projects, "every consumer degrades, none crash"
    end

    def test_valid_config_has_no_load_error
      assert_nil cfg("worktree_root" => "/x").load_error
    end
  end
end
