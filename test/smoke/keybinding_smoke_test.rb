# frozen_string_literal: true

require_relative "smoke_helper"
require "yaml"

module Switchboard
  class KeybindingSmokeTest < SmokeCase
    # Value: protects=a key you bound coming back, flags and quoting intact, after switchboard lets go
    # of it, and the record surviving a reload in between; fails_when=tmux mangles the line on its way
    # through an option and source-file, or a reload clears it; why_new=stubs can't show what real
    # tmux does to a quoted line; seam=none; no_claim=tmux versions other than the one running
    def test_moving_off_a_key_gives_back_what_was_there_even_after_a_reload
      tmux!("bind-key", "-r", "-T", "prefix", "g", "display-message", "a b; 'c' $d")
      mine = line_for("g")
      default_s = line_for("s")

      bind_toggle_to("g")
      assert_includes line_for("g"), "toggle-sidebar", "switchboard took the key"
      recorded = tmux("show-options", "-gqv", "@switchboard-toggle-displaced").strip
      assert_equal mine, recorded, "the whole line is recorded, unchanged"

      run_bin("tmux-bind") # what a tmux reload runs
      assert_equal recorded, tmux("show-options", "-gqv", "@switchboard-toggle-displaced").strip, "a reload keeps it"
      refute_empty tmux("show-options", "-gqv", "@switchboard-toggle-clobbered").strip, "doctor's record survives too"

      bind_toggle_to("s")
      assert_equal mine, line_for("g"), "the key is back as it was"
      assert_includes line_for("s"), "toggle-sidebar"
      refute_equal default_s, mine
    end

    # Value: protects=a binding you made after ours staying yours; fails_when=the restore skips its
    # still-ours check; why_new=a stale record would overwrite it; seam=none; no_claim=none beyond protects
    def test_a_binding_made_since_is_left_alone
      tmux!("bind-key", "-T", "prefix", "g", "display-message", "old")
      bind_toggle_to("g")
      tmux!("bind-key", "-T", "prefix", "g", "display-message", "newer")
      bind_toggle_to("s")
      assert_includes line_for("g"), "newer", "neither overwritten by the record nor unbound"
    end

    # Value: protects=a saved binding following its key when toggle and home trade keys; fails_when=
    # the leaving role clears the record and the new holder records nothing; why_new=seen in review;
    # seam=none; no_claim=none beyond protects
    def test_a_saved_binding_follows_its_key_through_a_swap
      tmux!("bind-key", "-T", "prefix", "g", "display-message", "mine")
      mine = line_for("g")
      bind_keys("toggle" => "g", "home" => "h")
      bind_keys("toggle" => "h", "home" => "g")
      bind_keys("toggle" => "b", "home" => "n")
      assert_equal mine, line_for("g")
    end

    # Value: protects=a key tmux lists under another spelling; fails_when=the config spelling is only
    # compared literally, so nothing is recorded; why_new=seen in review; seam=none; no_claim=every spelling
    def test_a_key_tmux_spells_differently_comes_back
      original = line_for("\\$")
      refute_empty original, "tmux binds prefix-$ by default"
      bind_toggle_to("$")
      bind_toggle_to("s")
      assert_equal original, line_for("\\$")
    end

    # Value: protects=uninstall leaving a key it already gave back; fails_when=the legacy unbind runs
    # unconditionally; why_new=seen in review; seam=none; no_claim=a real uninstall's tmux.conf edit
    def test_uninstall_leaves_a_restored_default_alone
      bind_toggle_to("t")
      restored = line_for("s")
      refute_includes restored, "toggle-sidebar"
      Installer.teardown_live
      assert_equal restored, line_for("s")
    end

    private

    def bind_toggle_to(key) = bind_keys("toggle" => key)

    def bind_keys(keys)
      config = YAML.safe_load_file(ENV["SWITCHBOARD_CONFIG"])
      File.write(ENV["SWITCHBOARD_CONFIG"], YAML.dump(config.merge("tmux_keys" => keys)))
      run_bin("tmux-bind")
    end

    def line_for(key)
      tmux("list-keys", "-T", "prefix").lines.find { |l| l[/-T\s+prefix\s+(\S+)\s/, 1] == key }.to_s.strip
    end
  end
end
