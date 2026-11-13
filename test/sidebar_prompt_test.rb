# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/sidebar_case"

module Switchboard
  # Sidebar::Prompt — the bottom-row raw-mode widget (#57): prompt_line and
  # its paste-safe edit_buffer token loop, Esc/Ctrl-C cancel, the dim hint,
  # and the width-safe prompt paint (issue #80).
  class SidebarPromptTest < SidebarCase
    # --- one-key prompts: tmux's pokes and focus reports aren't an answer -----

    # Value: protects=a background poke can't answer y/N; fails_when=read_char returns a
    # poke as a key; why_new=confirm was only ever stubbed; seam=none; no_claim=real tmux
    # delivery (the delete smoke test sends a real C-w)
    def test_confirm_waits_through_every_poke_for_a_real_key
      Sidebar::Input::POKE_BYTES.each do |poke|
        { "y" => true, "Y" => true, "n" => false, "\e" => false }.each do |key, answer|
          said = nil
          with_reads(sb = sidebar, poke, key) { said = sb.send(:confirm, "delete x?") }
          assert_equal answer, said, "#{poke.inspect} then #{key.inspect}"
        end
      end
    end

    # Value: protects=a dead pane cancels instead of hanging; fails_when=the reader loops
    # past EOF; why_new=nothing read to EOF through confirm; seam=none; no_claim=none beyond protects
    def test_confirm_cancels_on_a_dead_pane_even_after_pokes
      said = :unset
      with_reads(sb = sidebar, "\x17", "\f") { said = sb.send(:confirm, "delete x?") }
      assert_equal false, said
    end

    # Value: protects=a sequence split across reads can't answer; fails_when=the reader
    # skips @pending; why_new=handle's split test doesn't reach read_char; seam=none;
    # no_claim=none beyond protects
    def test_a_split_focus_report_is_not_an_answer
      said = nil
      with_reads(sb = sidebar, "\e[", "O", "y") { said = sb.send(:confirm, "delete x?") }
      assert_equal true, said
      assert_empty sb.instance_variable_get(:@pending)
    end

    # Value: protects=an error stays readable; fails_when=flash stops using read_char or a
    # poke counts as its any key; why_new=flash only stubbed read_char; seam=none;
    # no_claim=none beyond protects
    def test_flash_stays_up_through_a_poke
      left = nil
      with_reads(sb = sidebar, "\x17", "\e[I", "x", "unread") do |reads|
        sb.send(:flash, "boom")
        left = reads.dup
      end
      assert_equal ["unread"], left, "only a real key dismisses it"
    end

    # Value: protects=the a menu survives a poke; fails_when=add reads a poke as its choice;
    # why_new=add had no input test; seam=none; no_claim=none beyond protects
    def test_the_add_menu_stays_up_through_a_poke
      sb = sidebar
      added = false
      sb.define_singleton_method(:add_local) { added = true }
      stub_method(sb, :poke, ->(_) { true }) do
        with_reads(sb, "\f", "l") { sb.send(:handle, "a") }
      end
      assert added, "the l after the poke picked local"
    end

    # Value: protects=a switch or config poke isn't lost to a prompt, and a long-open one
    # can't stall on replay; fails_when=held bytes are dropped or replayed one by one;
    # why_new=new behavior; seam=none; no_claim=the real cost of a reload (counted, not timed)
    def test_held_pokes_run_once_each_after_the_prompt_closes
      sb = sidebar
      events = []
      sb.define_singleton_method(:quit) do
        confirm("quit?")
        events << :closed
        true
      end
      stub_method(sb, :poke, ->(key) { events << key; true }) do
        with_reads(sb, "\x17", "\x17\x17", "\e[O", "\e[I", "\e[O", "\e[I", "x") { sb.send(:handle, "q") }
      end
      assert_equal [:closed, "\x17", "\e[O", "\e[I"], events, "one of each kind, however many arrived"

      # Only this script tells last-of-kind from first-of-kind: focus must end out.
      events.clear
      stub_method(sb, :poke, ->(key) { events << key; true }) do
        with_reads(sb, "\e[O", "\e[I", "\e[O", "x") { sb.send(:handle, "q") }
      end
      assert_equal [:closed, "\e[I", "\e[O"], events, "the last of each kind survives, so the final focus report runs last"
    end

    # Value: protects=walking away from a message or menu can't stop this sidebar's dots and
    # chimes; fails_when=flash or add waits through a focus-out; why_new=confirm's wait is
    # the opposite rule, tested above; seam=none; no_claim=real focus delivery (scripted reads)
    def test_a_message_and_the_add_menu_close_when_you_leave_the_pane
      left = nil
      with_reads(sb = sidebar, "\e[O", "unread") do |reads|
        sb.send(:flash, "boom")
        left = reads.dup
      end
      assert_equal ["unread"], left, "the focus-out closed the message"

      sb = sidebar
      events = []
      added = false
      sb.define_singleton_method(:add_local) { added = true }
      sb.define_singleton_method(:reload) { |**| events << :closed }
      stub_method(sb, :poke, ->(key) { events << key; true }) do
        with_reads(sb, "\e[O", "l") { sb.send(:handle, "a") }
      end
      refute added, "the menu had closed before the l"
      assert_equal [:closed, "\e[O"], events, "and the focus-out still ran, after it closed"
    end

    # Value: protects=keys batched around a confirm's answer never fire on the tree once it closes;
    # fails_when=read_char hands non-poke keys back to handle; why_new=actions_test covers only who
    # answers; seam=none; no_claim=none beyond protects
    def test_keys_batched_around_a_confirm_do_not_fire_after_it
      [["qj", "n"], ["q", "nj"]].each do |keys, read|
        sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a"), ws("b", path: "/wt/b")], cursor: 1)
        with_reads(sb, read) { assert sb.send(:handle, keys) }
        assert_equal 1, sb.instance_variable_get(:@cursor), "#{keys} + #{read}: the j never moved the cursor"
      end
    end

    # Value: protects=a poke batched behind the answer still runs after the prompt closes;
    # fails_when=read_char drops what it read past the key; why_new=every other script reads
    # the key alone; seam=none; no_claim=real tmux batching two bytes into one read
    def test_a_poke_batched_behind_the_answer_runs_after_the_prompt_closes
      sb = sidebar
      events = []
      sb.define_singleton_method(:reload) { |**| events << :closed }
      stub_method(sb, :poke, ->(key) { events << key; true }) do
        with_reads(sb, "x\x17") { sb.send(:handle, "a") }
      end
      assert_equal [:closed, "\x17"], events
    end

    # Value: protects=a read fault on the pane cancels a confirm instead of crashing the
    # sidebar; fails_when=read_char's rescue is removed; why_new=with_reads only simulates
    # EOF; seam=none; no_claim=which faults a real pane raises
    def test_confirm_cancels_when_the_read_raises
      sb = sidebar
      said = :unset
      stub_method(sb, :winsize, ->(*) { [24, 40] }) do
        stub_method(sb, :read_prompt_key, ->(*) { raise Errno::EIO }) do
          capture_stdout { said = sb.send(:confirm, "delete x?") }
        end
      end
      assert_equal false, said
    end

    # Value: protects=leaving the pane can't open GitHub; fails_when=a focus report is read
    # a byte at a time, leaving its O; why_new=the tokenizer tests never cross a prompt;
    # seam=none; no_claim=the browser actually opening (stubbed)
    def test_a_focus_out_during_a_prompt_cannot_fire_open_repo
      sb = sidebar
      opened = false
      sb.define_singleton_method(:open_repo) { opened = true }
      with_reads(sb, "\e[O", "n") { sb.send(:handle, "q") }
      refute opened
    end

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

    # Value: protects=the task prompt fences pastes (bracketed paste on, then off even on cancel) and drops input in flight after its ↵; fails_when=the drain or the ensure-off is dropped, so trailing paste bytes (`d`…`y`) reach the tree as keys or the pane stays in paste mode; why_new=paste tests call edit_buffer directly, never prompt_line's wrapper; seam=none; no_claim=terminal-side paste handling
    def test_the_task_prompt_fences_pastes_and_drains_what_followed_its_enter
      sb = sidebar
      r, w = IO.pipe
      w.write("dy") # the tail of an unbracketed paste, already in flight behind the ↵
      result = nil
      out = capture_stdout do
        stub_method(sb, :draw_prompt, ->(*, **) {}) do
          stub_method(sb, :read_prompt_key, -> { "fix it\r" }) do
            with_stdin(r) { result = sb.send(:prompt_line, "app task", task: true) }
          end
        end
      end
      assert_equal "fix it", result
      assert_raises(IO::WaitReadable, "nothing left for the tree to read as keys") { r.read_nonblock(16) }
      assert_includes out, "\e[?2004h", "pastes arrive fenced"
      assert_includes out, "\e[?2004l", "paste mode is switched back off"
      assert_operator out.index("\e[?2004h"), :<, out.index("\e[?2004l"), "...after it was switched on"

      cancel = capture_stdout do
        stub_method(sb, :draw_prompt, ->(*, **) {}) do
          stub_method(sb, :read_prompt_key, -> { "\e" }) { sb.send(:prompt_line, "app task", task: true) }
        end
      end
      assert_includes cancel, "\e[?2004l", "Esc leaves paste mode too"
    ensure
      r&.close
      w&.close
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

    # `n` asks for a TASK, never a name: #94/#114 deferred naming still holds (the
    # workspace gets a reserved placeholder), the prompt is what the agent should do.
    def test_create_prompts_for_a_task_and_reserves_a_placeholder
      File.write(Config.path, YAML.dump("projects" => [{ "name" => "app", "path" => "/x" }]))
      sb = sidebar(nodes: [proj("app")], cursor: 0)
      sb.instance_variable_set(:@config, Config.new)
      reserved = nil
      stub_method(sb, :prompt_line, ->(label, **) { label == "app task" ? "fix it" : flunk(label) }) do
        stub_method(Creator, :reserve, lambda { |_cfg, project|
          reserved = project
          nil # no free name ⇒ a flash, nothing recorded
        }) do
          stub_method(sb, :read_char, ->(**) {}) { capture_stdout { sb.send(:create) } }
        end
      end
      assert_equal "app", reserved
      assert_empty Creation.all
    end

    # The feature: creating NEVER drops you into the new workspace — it builds in the
    # background and pings you when it's ready.
    def test_create_never_switches_into_the_new_workspace
      File.write(Config.path, YAML.dump("worktree_root" => path("wts"), "projects" => [{ "name" => "app", "path" => "/x" }]))
      sb = sidebar(nodes: [proj("app")], cursor: 0)
      sb.instance_variable_set(:@config, Config.new)
      went = false
      dest = path("wts", "app", "wandering-finch")
      stub_method(sb, :prompt_line, ->(*_a, **_k) { "" }) do
        stub_method(Creator, :reserve, ->(*) { ["wandering-finch", dest] }) do
          stub_method(Creator, :spawn_worker, ->(_id) { true }) do
            stub_method(Tmux, :go, ->(*_a, **_k) { went = true }) do
              stub_method(Tmux, :broadcast_warm, ->(**_k) {}) do
                stub_method(sb, :reload, -> {}) { sb.send(:create) }
              end
            end
          end
        end
      end
      refute went, "dispatch must not switch you in"
      assert_equal "wandering-finch", Creation.all.first["name"]
      assert_nil Creation.all.first["brief_from"], "a task typed after `n` is the user's own"
    end

    # Value: protects=a worker that can't start is said out loud in the sidebar, not only a later
    # ✘; fails_when=the SPAWN_FAILED flash is dropped from create; why_new=only the true path was
    # stubbed; seam=none; no_claim=flash rendering
    def test_create_flashes_when_the_worker_cannot_start
      File.write(Config.path, YAML.dump("worktree_root" => path("wts"), "projects" => [{ "name" => "app", "path" => "/x" }]))
      sb = sidebar(nodes: [proj("app")], cursor: 0)
      sb.instance_variable_set(:@config, Config.new)
      flashed = []
      dest = path("wts", "app", "wandering-finch")
      stub_method(sb, :prompt_line, ->(*_a, **_k) { "" }) do
        stub_method(Creator, :reserve, ->(*) { ["wandering-finch", dest] }) do
          stub_method(Creator, :spawn_worker, ->(_id) { false }) do
            stub_method(sb, :flash, ->(msg) { flashed << msg }) do
              stub_method(Tmux, :broadcast_warm, ->(**_k) {}) do
                stub_method(sb, :reload, -> {}) { sb.send(:create) }
              end
            end
          end
        end
      end
      assert_equal [Creator::SPAWN_FAILED], flashed
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
            stub_method(Rename, :perform, ->(*) { Rename::Result.new(:exists, "/wt/alpha", nil, "beta", "workspace beta (/wt/beta)") }) do
              sb.send(:rename)
            end
          end
        end
      end
      assert_match(/beta is taken by workspace beta/, sb.send(:rename_error, Rename::Result.new(:exists, "/wt/a", nil, "beta", "workspace beta (/wt/b)")))
      assert_match(/branch wvm\/beta already exists/, sb.send(:rename_error, Rename::Result.new(:branch_exists, "/wt/a", nil, "beta", "wvm/beta")))
      assert_match(/invalid name/,         sb.send(:rename_error, Rename::Result.new(:invalid, "/wt/a")))
      assert_match(/kept its old name until you switch/, sb.send(:rename_error, Rename::Result.new(:partial, "/wt/x", nil, "x")))
      assert_match(/couldn't save the name: EACCES/, sb.send(:rename_error, Rename::Result.new(:failed, "/wt/a", nil, "a", "EACCES")))
      assert_match(/reload-sidebars/, sb.send(:rename_error, Rename::Result.new(:stale_peers, "/wt/a", nil, "a", ["%3"])))
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
