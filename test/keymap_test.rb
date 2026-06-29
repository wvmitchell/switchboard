# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # The action enum behind the configurable in-sidebar keys (issue #108). Keymap
  # is the single source of truth the sidebar's dispatch, the ? overlay, and
  # doctor all read, so its resolution (defaults, overrides, validity, collisions,
  # fixed aliases) is worth pinning directly. Pure given a Config, so these run
  # offline against a sandboxed config file.
  class KeymapTest < SandboxTest
    # Build a Config from a raw hash written to the sandboxed config path.
    def cfg(data = {})
      File.write(Config.path, YAML.dump(data))
      Config.new
    end

    def test_defaults_when_unset
      b = Keymap.bindings(cfg)
      assert_equal "j", b[:down]
      assert_equal "n", b[:new_workspace]
      assert_equal "?", b[:help]
      assert_equal Keymap::ACTIONS.map(&:name).sort, b.keys.sort, "every action resolves"
    end

    def test_defaults_constant_mirrors_actions
      assert_equal Keymap::ACTIONS.to_h { |a| [a.name, a.default] }, Keymap::DEFAULTS
      assert_equal Keymap::ACTIONS.map(&:default).uniq.size, Keymap::ACTIONS.size,
                   "the default keys are all distinct — defaults never collide with each other"
    end

    def test_override_rebinds_the_action_and_frees_the_old_key
      map = Keymap.dispatch_map(cfg("sidebar_keys" => { "new_workspace" => "c" }))
      assert_equal :new_workspace, map["c"], "the configured key fires the action"
      assert_nil map["n"], "the default key is no longer bound to it"
    end

    def test_invalid_override_falls_back_to_the_default
      # multi-char (a named key) and a non-string both degrade to the default.
      assert_equal "r", Keymap.bindings(cfg("sidebar_keys" => { "rename" => "foo" }))[:rename]
      assert_equal "d", Keymap.bindings(cfg("sidebar_keys" => { "delete" => 7 }))[:delete]
    end

    def test_collision_drops_the_later_action_and_records_it
      c = cfg("sidebar_keys" => { "delete" => "j" }) # j is down's default
      b = Keymap.bindings(c)
      assert_equal "j", b[:down], "the earlier action (down) keeps the key"
      assert_nil b[:delete], "the later action is left unbound rather than double-binding j"
      assert_equal [{ action: :delete, key: "j", winner: :down }], Keymap.collisions(c)
    end

    def test_clean_config_has_no_collisions
      assert_empty Keymap.collisions(cfg)
      assert_empty Keymap.collisions(cfg("sidebar_keys" => { "new_workspace" => "c" }))
    end

    def test_fixed_aliases_are_always_bound_and_uncollidable
      # Even with a wild remap, the structural movement aliases still resolve —
      # they're non-printable, so a printable override can't shadow them.
      map = Keymap.dispatch_map(cfg("sidebar_keys" => { "down" => "x" }))
      assert_equal :down, map["x"], "the override binds"
      assert_equal :down, map["\e[B"], "↓ still moves down"
      assert_equal :down, map["\x0E"], "^N still moves down"
      assert_equal :open_pr, map["\x0F"], "^O still opens the PR"
    end

    def test_dispatch_map_omits_collision_dropped_actions
      map = Keymap.dispatch_map(cfg("sidebar_keys" => { "delete" => "j" }))
      assert_equal :down, map["j"], "down wins the contested key"
      refute map.value?(:delete), "the dropped action has no key in the dispatch map"
    end

    def test_help_rows_reflect_a_remap
      rows = Keymap.help_rows(Keymap.bindings(cfg("sidebar_keys" => { "new_workspace" => "c" })))
      new_ws = rows.find { |_key, desc| desc == "new workspace (auto-named)" }
      assert_equal "c", new_ws.first, "the overlay shows the configured key, not the default"
    end

    def test_help_rows_show_an_em_dash_for_a_collision_dropped_action
      rows = Keymap.help_rows(Keymap.bindings(cfg("sidebar_keys" => { "delete" => "j" })))
      del = rows.find { |_key, desc| desc == "delete · remove" }
      assert_equal "—", del.first, "an unbound action reads as a dash, never a blank"
    end

    def test_help_rows_section_headings_have_a_blank_key
      rows = Keymap.help_rows(Keymap.bindings(cfg))
      assert(rows.any? { |key, desc| key.empty? && desc == "navigate" }, "headings carry an empty key")
    end

    # Drift guard: help_rows is a hand-authored layout, so an action added to
    # ACTIONS with no matching row would silently vanish from the ? overlay. Map
    # each action to a unique sentinel and assert every one surfaces in the
    # rendered rows — a forgotten action fails loudly here (issue #108).
    def test_help_rows_reference_every_action
      sentinels = Keymap::ACTIONS.to_h { |a| [a.name, "<#{a.name}>"] }
      rendered = Keymap.help_rows(sentinels).flatten.join("\n")
      Keymap::ACTIONS.each do |a|
        assert_includes rendered, "<#{a.name}>", "help_rows shows no row for :#{a.name} (ACTIONS/overlay drift)"
      end
    end

    # The collision tie-break is "earlier in ACTIONS wins" — pin the canonical
    # case the existing test doesn't isolate: TWO overrides landing on the same
    # novel key (not a default). `top` precedes `bottom` in ACTIONS, so top keeps
    # the contested key regardless of which value is the override.
    def test_collision_tiebreak_follows_actions_order
      c = cfg("sidebar_keys" => { "top" => "x", "bottom" => "x" })
      b = Keymap.bindings(c)
      assert_equal "x", b[:top], "the earlier ACTIONS entry keeps the contested key"
      assert_nil b[:bottom], "the later entry is dropped"
      assert_equal [{ action: :bottom, key: "x", winner: :top }], Keymap.collisions(c)
    end
  end
end
