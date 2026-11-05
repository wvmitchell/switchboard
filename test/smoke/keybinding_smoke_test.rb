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
      refute_includes line_for("g"), "old", "the record must not overwrite a newer binding"
    end

    private

    def bind_toggle_to(key)
      config = YAML.safe_load_file(ENV["SWITCHBOARD_CONFIG"])
      File.write(ENV["SWITCHBOARD_CONFIG"], YAML.dump(config.merge("tmux_keys" => { "toggle" => key })))
      run_bin("tmux-bind")
    end

    def line_for(key)
      tmux("list-keys", "-T", "prefix").lines.find { |l| l[/-T\s+prefix\s+(\S+)\s/, 1] == key }.to_s.strip
    end
  end
end
