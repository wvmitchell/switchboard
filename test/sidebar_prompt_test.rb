# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/sidebar_case"

module Switchboard
  # Sidebar::Prompt — the bottom-row raw-mode widget (#57): prompt_line and
  # its paste-safe edit_buffer token loop, Esc/Ctrl-C cancel, the dim hint,
  # and the width-safe prompt paint (issue #80).
  class SidebarPromptTest < SidebarCase
    # --- inline name prompts: raw-mode edit, Esc/Ctrl-C cancel (issue #68) ----

    # Drive prompt_line over a scripted key stream. draw_prompt is silenced so the
    # test never paints to the real tty; read_prompt_key pops the next scripted key.
    def drive_prompt(sb, keys)
      keys = keys.dup
      result = nil
      capture_stdout do # swallow prompt_line's ensure cursor-restore escape
        stub_method(sb, :draw_prompt, ->(*) {}) do
          stub_method(sb, :read_prompt_key, -> { keys.shift }) do
            result = sb.send(:prompt_line, "name")
          end
        end
      end
      result
    end

    def test_prompt_line_returns_the_typed_name_on_enter
      assert_equal "feat-x", drive_prompt(sidebar, ["f", "e", "a", "t", "-", "x", "\r"])
    end

    # The crux of #68: Esc reaches us as a byte in raw mode and cancels — the old
    # cooked gets swallowed it, leaving the prompt with no way out but killing the pane.
    def test_prompt_line_esc_cancels_returning_nil
      assert_nil drive_prompt(sidebar, ["a", "b", "\e"]), "Esc aborts the prompt"
    end

    def test_prompt_line_ctrl_c_cancels_returning_nil
      assert_nil drive_prompt(sidebar, ["a", "\x03"]), "Ctrl-C aborts (raw mode: a byte, not a signal)"
    end

    def test_prompt_line_backspace_trims_the_buffer
      assert_equal "ab", drive_prompt(sidebar, ["a", "b", "c", "\x7F", "\r"])
    end

    # An arrow key is a 3-byte burst — neither a bare Esc (cancel) nor a printable
    # byte (append) — so it's dropped, never mistaken for an Esc that would cancel.
    def test_prompt_line_ignores_escape_sequence_bursts
      assert_equal "ab", drive_prompt(sidebar, ["a", "\e[A", "b", "\r"])
    end

    # A paste (or fast key-repeat) lands as ONE multi-byte read — it must contribute
    # all its printable bytes, not be dropped whole. The `a` clone-URL / local-path
    # prompts are pasted, never typed; cooked gets buffered them, raw mode must too.
    def test_prompt_line_accepts_a_pasted_multibyte_chunk
      url = "git@github.com:wvmitchell/switchboard.git"
      assert_equal url, drive_prompt(sidebar, [url, "\r"])
    end

    # An arrow burst embedded mid-paste still drops whole — its "[A" bytes must not
    # leak into the name even though they're individually printable.
    def test_prompt_line_drops_an_arrow_burst_within_a_chunk
      assert_equal "ab", drive_prompt(sidebar, ["a\e[Ab", "\r"])
    end

    # A stray non-printable byte (a high 0x80, a lone control char) is dropped, never
    # appended or a crash — the same byte-level printable? guard the filter uses.
    def test_prompt_line_drops_a_stray_non_printable_byte
      assert_equal "ab", drive_prompt(sidebar, ["a", "\x80".b, "b", "\r"])
    end

    # Ctrl-U wipes the buffer; what's typed after is all that submits.
    def test_prompt_line_ctrl_u_clears_the_line
      assert_equal "new", drive_prompt(sidebar, ["o", "l", "d", "\x15", "n", "e", "w", "\r"])
    end

    # \n submits like \r (a pasted line ends in \n, not \r).
    def test_prompt_line_submits_on_a_bare_newline
      assert_equal "feat", drive_prompt(sidebar, ["f", "e", "a", "t", "\n"])
    end

    # A bare ↵ (and whitespace-only, stripped) yields "" — blank_input? treats that
    # as cancel too, so the old empty-enter escape hatch survives alongside Esc.
    def test_prompt_line_empty_enter_is_a_blank_cancel
      sb = sidebar
      assert_equal "", drive_prompt(sb, [" ", " ", "\r"]), "whitespace is stripped away"
      assert sb.send(:blank_input?, ""), "...and an empty result cancels"
    end

    def test_read_prompt_key_returns_nil_on_a_dead_pane
      sb = Sidebar.new
      r, w = IO.pipe
      w.close # reader at EOF — select wakes, read_nonblock raises EOFError
      with_stdin(r) { assert_nil sb.send(:read_prompt_key), "a closed pane cancels, never spins" }
    ensure
      r.close
    end

    def test_draw_prompt_advertises_esc_cancel_until_you_type
      sb = sidebar
      empty = capture_stdout { sb.send(:draw_prompt, "new workspace in app", "") }
      typed = capture_stdout { sb.send(:draw_prompt, "new workspace in app", "feat") }
      assert_includes empty, "esc cancel", "the escape hatch is advertised on an empty prompt (#68)"
      assert_includes empty, "new workspace in app", "...alongside the label"
      refute_includes typed, "esc cancel", "the hint clears once you start typing"
      assert_includes typed, "feat", "...showing the typed name instead"
    end

    # A long label + the dim "(esc cancel)" hint must stay within the 40-col pane:
    # an overflowing bottom row auto-wraps (DECAWM) and scrolls a stale prompt copy
    # into scrollback on every cancel→reopen (issue #80). winsize falls back to
    # [40, 40] under capture_stdout's StringIO, so cols == the real SIDEBAR_WIDTH.
    def test_draw_prompt_keeps_label_plus_hint_within_the_pane
      sb = sidebar
      out = capture_stdout { sb.send(:draw_prompt, "path to an existing git repo", "") }
      visible = out.gsub(/\e\[[0-9;?]*[A-Za-z]/, "") # strip every SGR / cursor-move / mode escape
      assert_operator visible.length, :<=, 40,
                      "the prompt + hint must fit 40 cols so the bottom row never wraps (#80)"
      assert_includes visible, "esc cancel", "...while still advertising the escape hatch"
    end

    # `n` (and filter-mode ↵-on-a-project) auto-names instantly — no prompt. It hands
    # Creator a BLANK name (⇒ a placeholder) and must never call prompt_line (#114).
    def test_create_auto_names_without_prompting
      sb = sidebar(nodes: [proj("app")], cursor: 0)
      seen = :unset
      stub_method(sb, :prompt_line, ->(*) { flunk "create must not prompt for a name (#114)" }) do
        stub_method(Creator, :create, lambda { |_cfg, project, name|
          seen = [project, name]
          nil # nil dest ⇒ no Tmux.go; reload closes out
        }) do
          stub_method(sb, :reload, -> {}) do
            capture_stdout { sb.send(:create) } # swallow the "creating…" status line
          end
        end
      end
      assert_equal ["app", ""], seen, "create hands Creator the project + a blank name (⇒ placeholder)"
    end

    # On a successful create, it drops you straight into the new worktree's session.
    def test_create_drops_into_the_new_workspace
      sb = sidebar(nodes: [proj("app")], cursor: 0)
      went_to = nil
      stub_method(Creator, :create, ->(*) { "/wt/wandering-finch" }) do
        stub_method(Tmux, :go, ->(wt, **) { went_to = wt.path }) do
          stub_method(sb, :reload, -> {}) do
            capture_stdout { sb.send(:create) } # swallow the "creating…" status line
          end
        end
      end
      assert_equal "/wt/wandering-finch", went_to, "a created workspace is switched into"
    end

    def test_rename_aborts_when_the_prompt_is_cancelled
      File.write(Config.path, YAML.dump("projects" => [{ "name" => "app", "path" => "/x" }]))
      sb = sidebar(nodes: [proj("app"), ws("alpha", path: "/wt/alpha")], cursor: 1)
      sb.instance_variable_set(:@config, Config.new)
      reloaded = false
      stub_method(sb, :prompt_line, ->(*) { nil }) do
        stub_method(sb, :reload, -> { reloaded = true }) do
          stub_method(Rename, :perform, ->(*) { flunk "no rename on cancel" }) do
            sb.send(:rename)
          end
        end
      end
      assert reloaded, "a cancelled rename returns to the tree"
    end

    # The sidebar shares the rename core with `switchboard rename` (Rename.perform)
    # and passes the highlighted workspace's project + path + the typed name.
    def test_rename_delegates_to_the_shared_rename_core
      File.write(Config.path, YAML.dump("projects" => [{ "name" => "app", "path" => "/x" }]))
      sb = sidebar(nodes: [proj("app"), ws("alpha", path: "/wt/alpha")], cursor: 1)
      sb.instance_variable_set(:@config, Config.new)
      seen = nil
      reloaded = false
      stub_method(sb, :prompt_line, ->(*) { "beta" }) do
        stub_method(sb, :reload, -> { reloaded = true }) do
          stub_method(Rename, :perform, lambda { |_cfg, project, old_path, name|
            seen = [project, old_path, name]
            Rename::Result.new(:ok, "/wt/beta")
          }) do
            sb.send(:rename)
          end
        end
      end
      assert_equal ["app", "/wt/alpha", "beta"], seen
      assert reloaded
    end

    # A failed rename flashes the reason on the bottom row (the CLI warns to stderr;
    # the sidebar can't, so a silent reload would hide the failure) then reloads.
    def test_rename_flashes_the_reason_on_failure
      File.write(Config.path, YAML.dump("projects" => [{ "name" => "app", "path" => "/x" }]))
      sb = sidebar(nodes: [proj("app"), ws("alpha", path: "/wt/alpha")], cursor: 1)
      sb.instance_variable_set(:@config, Config.new)
      flashed = nil
      reloaded = false
      stub_method(sb, :prompt_line, ->(*) { "beta" }) do
        stub_method(sb, :reload, -> { reloaded = true }) do
          stub_method(sb, :flash, ->(msg) { flashed = msg }) do
            stub_method(Rename, :perform, ->(*) { Rename::Result.new(:exists, "/wt/beta") }) do
              sb.send(:rename)
            end
          end
        end
      end
      assert_match(/already exists: beta/, flashed.to_s, "the failure reason is flashed")
      assert reloaded, "the sidebar still reloads after flashing"
    end

    # A successful rename does NOT flash — the reloaded tree is feedback enough.
    def test_rename_does_not_flash_on_success
      File.write(Config.path, YAML.dump("projects" => [{ "name" => "app", "path" => "/x" }]))
      sb = sidebar(nodes: [proj("app"), ws("alpha", path: "/wt/alpha")], cursor: 1)
      sb.instance_variable_set(:@config, Config.new)
      reloaded = false
      stub_method(sb, :prompt_line, ->(*) { "beta" }) do
        stub_method(sb, :reload, -> { reloaded = true }) do
          stub_method(sb, :flash, ->(*) { flunk "no flash on a successful rename" }) do
            stub_method(Rename, :perform, ->(*) { Rename::Result.new(:ok, "/wt/beta") }) do
              sb.send(:rename)
            end
          end
        end
      end
      assert reloaded
    end

    # rename_error maps each non-success status to a distinct message; success and
    # :unchanged return nil (no flash). Pins all arms so a typo can't slip through.
    def test_rename_error_maps_each_status
      sb = sidebar
      assert_match(/already exists: beta/, sb.send(:rename_error, Rename::Result.new(:exists, "/wt/beta")))
      assert_match(/branch beta already exists/, sb.send(:rename_error, Rename::Result.new(:branch_exists, "/wt/beta")))
      assert_match(/invalid name/,         sb.send(:rename_error, Rename::Result.new(:invalid, nil)))
      assert_match(/session rename failed/, sb.send(:rename_error, Rename::Result.new(:partial, "/wt/x")))
      assert_match(/rename failed/,        sb.send(:rename_error, Rename::Result.new(:failed, nil)))
      assert_nil sb.send(:rename_error, Rename::Result.new(:ok, "/wt/x")), "success doesn't flash"
      assert_nil sb.send(:rename_error, Rename::Result.new(:unchanged, "/wt/x")), "unchanged doesn't flash"
    end

    def test_add_local_aborts_when_the_prompt_is_cancelled
      sb = sidebar
      reloaded = false
      stub_method(sb, :prompt_line, ->(*) { nil }) do
        stub_method(sb, :reload, -> { reloaded = true }) do
          stub_method(Registrar, :register, ->(*) { flunk "nothing is registered on cancel" }) do
            sb.send(:add_local)
          end
        end
      end
      assert reloaded, "a cancelled add-local returns to the tree"
    end

    def test_add_clone_aborts_when_the_prompt_is_cancelled
      sb = sidebar
      reloaded = false
      stub_method(sb, :prompt_line, ->(*) { nil }) do
        stub_method(sb, :reload, -> { reloaded = true }) do
          stub_method(Registrar, :clone, ->(*) { flunk "nothing is cloned on cancel" }) do
            sb.send(:add_clone)
          end
        end
      end
      assert reloaded, "a cancelled add-clone returns to the tree"
    end
  end
end
