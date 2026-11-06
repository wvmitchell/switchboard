# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/sidebar_case"

module Switchboard
  # Sidebar::Input — bytes to actions (#57): the terminal-grammar tokenizer,
  # dispatch across read boundaries, the #108 configurable keymap, navigation,
  # and the ? help key mode (the / search has test/sidebar_search_test.rb). White-box via SidebarCase, like the
  # rest of the sidebar suite.
  class SidebarInputTest < SidebarCase
    # --- navigation ----------------------------------------------------------

    def test_move_clamps_to_the_visible_rows
      sb = sidebar(nodes: [proj("app"), ws("a"), ws("b")])
      sb.send(:move, -1)
      assert_equal 0, cursor_of(sb), "can't move above the first row"
      sb.send(:move, 99)
      assert_equal 2, cursor_of(sb), "can't move past the last row"
    end

    def test_move_is_a_noop_with_no_rows
      sb = sidebar(nodes: [])
      sb.send(:move, 1)
      assert_equal 0, cursor_of(sb)
    end

    def test_toggle_collapse_hides_then_shows_a_projects_children
      sb = sidebar(nodes: [proj("app"), ws("a"), ws("b")])
      assert_equal 3, rows_of(sb).size
      sb.send(:toggle_collapse, "app")
      assert_equal 1, rows_of(sb).size, "collapsed project hides its workspaces"
      sb.send(:toggle_collapse, "app")
      assert_equal 3, rows_of(sb).size
    end

    def test_enter_on_a_project_header_collapses_it
      sb = sidebar(nodes: [proj("app"), ws("a")], cursor: 0)
      sb.send(:enter)
      assert_includes sb.instance_variable_get(:@collapsed), "app"
    end

    # The fold is shared, not per-process: toggling writes through to the on-disk
    # store so every other window's sidebar reflects it on its next reload.
    def test_toggle_collapse_writes_through_to_the_shared_store
      sb = sidebar(nodes: [proj("app"), ws("a")])
      sb.send(:toggle_collapse, "app")
      assert_includes Collapse.collapsed, "app", "collapse persists to the shared store"
      sb.send(:toggle_collapse, "app")
      refute_includes Collapse.collapsed, "app", "expand clears it from the shared store"
    end

    # The other half: a fresh sidebar hydrates its folds from the shared store on
    # rebuild — so a project you collapsed in one window comes up collapsed here.
    def test_rebuild_hydrates_folds_from_the_shared_store
      repo = temp_git_repo("app")
      File.write(Config.path, YAML.dump("projects" => [{ "name" => "app", "path" => repo }]))
      Collapse.collapse("app") # as if folded by another window's sidebar

      sb = sidebar(nodes: [])
      sb.instance_variable_set(:@config, Config.new)
      sb.send(:rebuild)
      assert_includes sb.instance_variable_get(:@collapsed), "app",
                      "rebuild picks up a fold another sidebar wrote"
    end

    # Same store-hydration contract for the full-header toggle: a flip in one
    # window is picked up by every other sidebar on its next rebuild.
    def test_rebuild_hydrates_the_full_header_flag_from_the_shared_store
      repo = temp_git_repo("app")
      File.write(Config.path, YAML.dump("projects" => [{ "name" => "app", "path" => repo }]))
      FullHeader.enable # as if another window's sidebar pressed H

      sb = sidebar(nodes: [])
      sb.instance_variable_set(:@config, Config.new)
      sb.send(:rebuild)
      assert sb.instance_variable_get(:@full_header),
             "rebuild picks up the full-header flag another sidebar wrote"
    end

    # --- vim-style counts (3j) -------------------------------------------------
    # An unbound digit builds a count that the next move uses; every other real key
    # uses it up, pokes leave it alone, focus-out drops it.

    def counted_tree(n = 15) = sidebar(nodes: [proj("app"), *(1..n).map { |i| ws("w#{i}") }])

    def press(sb, *keys) = keys.each { |k| assert sb.send(:handle, k), "#{k.inspect} kept the loop alive" }

    def test_a_count_moves_that_many_rows_and_clamps
      sb = counted_tree
      press(sb, "3j")
      assert_equal 3, cursor_of(sb)
      press(sb, "10k")
      assert_equal 0, cursor_of(sb), "10k from row 3 clamps at the top"
      press(sb, "99j")
      assert_equal 15, cursor_of(sb), "and at the bottom"
    end

    def test_a_count_survives_separate_reads
      sb = counted_tree
      press(sb, "1", "0", "j")
      assert_equal 10, cursor_of(sb)
    end

    def test_the_aliases_and_a_remapped_down_key_take_a_count
      sb = counted_tree
      press(sb, "2\e[B", "2\x0E")
      assert_equal 4, cursor_of(sb), "↓ and ^N"
      press(sb, "3\e[A", "1\x10")
      assert_equal 0, cursor_of(sb), "↑ and ^P"
      File.write(Config.path, YAML.dump("sidebar_keys" => { "down" => "x" }))
      sb = counted_tree
      press(sb, "4x")
      assert_equal 4, cursor_of(sb), "a remapped down key"
    end

    # Value: protects=a capped count digit never ends the run loop (handle returns its
    # dispatch result, false = quit); fails_when=count_digit returns nil past the cap;
    # why_new=Codex plan review; seam=none; no_claim=none beyond protects
    def test_the_count_caps_at_three_digits_without_ending_the_loop
      sb = counted_tree(150)
      press(sb, "1234j")
      assert_equal 123, cursor_of(sb)
    end

    def test_a_lone_zero_is_not_a_count
      sb = counted_tree
      press(sb, "0j")
      assert_equal 1, cursor_of(sb), "0 then j moves one"
      press(sb, "10j")
      assert_equal 11, cursor_of(sb), "but 0 extends a count"
    end

    def test_any_other_real_key_uses_up_the_count
      sb = counted_tree
      press(sb, "3\e", "j")
      assert_equal 1, cursor_of(sb), "Esc dropped the 3"
      sb = sidebar(nodes: multi_branch_tree)
      press(sb, "3z", "j")
      assert sb.instance_variable_get(:@fold_branches), "z still fired"
      assert_equal 1, cursor_of(sb), "and dropped the 3"
      sb = counted_tree
      press(sb, "3\e[C", "j")
      assert_equal 1, cursor_of(sb), "→ dropped it too"
    end

    def test_pokes_keep_a_count_and_focus_out_drops_it
      sb = counted_tree
      stub_method(sb, :reload_and_refresh, -> {}) do
        stub_method(sb, :warm_poke, -> {}) { press(sb, "3", "\f", "\x17", "j") }
      end
      assert_equal 3, cursor_of(sb), "a switch-in or warm poke can land mid-count"
      press(sb, "3", "\e[O", "j")
      assert_equal 4, cursor_of(sb), "leaving the pane dropped the 3"
    end

    # The regression contract: digits keep their meaning everywhere they had one.

    def test_bare_moves_still_move_one
      sb = counted_tree
      ["j", "\e[B", "\x0E"].each { |k| press(sb, k) }
      assert_equal 3, cursor_of(sb)
      ["k", "\e[A", "\x10"].each { |k| press(sb, k) }
      assert_equal 0, cursor_of(sb)
    end

    def test_a_digit_bound_in_sidebar_keys_fires_its_action_and_never_counts
      File.write(Config.path, YAML.dump("sidebar_keys" => { "toggle_branch_fold" => "3" }))
      sb = sidebar(nodes: multi_branch_tree)
      press(sb, "3j")
      assert sb.instance_variable_get(:@fold_branches), "3 fired its action"
      assert_equal 1, cursor_of(sb), "and j moved one"
      assert_nil sb.instance_variable_get(:@count)
    end

    def test_digits_are_query_text_while_typing_a_search
      sb = sidebar(nodes: [proj("app"), ws("v2-api"), ws("beta")])
      press(sb, "/2")
      assert_equal "2", sb.instance_variable_get(:@search).query
      assert_nil sb.instance_variable_get(:@count)
    end

    def test_a_digit_closes_the_help_overlay_without_starting_a_count
      sb = counted_tree
      press(sb, "?", "3", "j")
      refute sb.instance_variable_get(:@help)
      assert_equal 1, cursor_of(sb), "the 3 only closed help"
    end

    def test_digits_typed_with_n_become_the_task
      sb = sidebar(nodes: [proj("app")])
      tasks = []
      stub_method(Creator, :dispatch, ->(_c, _p, task) { tasks << task; :ok }) do
        stub_method(sb, :read_prompt_key, -> { flunk "the batch held the whole task" }) do
          capture_stdout { sb.send(:handle, "n42 fix\r") }
        end
      end
      assert_equal ["42 fix"], tasks
      assert_nil sb.instance_variable_get(:@count)
    end

    def test_digits_typed_with_r_become_the_new_name
      sb = sidebar(nodes: [proj("app"), ws("alpha")], cursor: 1)
      names = []
      stub_method(sb.instance_variable_get(:@config), :project, ->(*) { { "name" => "app" } }) do
        stub_method(Rename, :perform, ->(_c, _p, _path, name) { names << name; Rename::Result.new(:ok, nil, false) }) do
          stub_method(sb, :reload, ->(*) {}) do
            stub_method(sb, :read_prompt_key, -> { flunk "the batch held the whole name" }) do
              capture_stdout { sb.send(:handle, "rv2\r") }
            end
          end
        end
      end
      assert_equal ["v2"], names
    end

    # --- configurable in-sidebar keys (issue #108) ---------------------------
    # dispatch keys off the resolved @keymap (built in initialize from @config),
    # so a sidebar_keys remap re-binds the tree's keys. The structural aliases
    # (arrows / ^N / ^P / ^O) and reserved sequences (↵) are never remappable.

    def test_dispatch_honors_a_remapped_movement_key
      File.write(Config.path, YAML.dump("sidebar_keys" => { "down" => "x" }))
      sb = sidebar(nodes: [proj("app"), ws("a"), ws("b")])
      sb.send(:dispatch, "x")
      assert_equal 1, cursor_of(sb), "the remapped key moves down"
      sb.send(:dispatch, "j")
      assert_equal 1, cursor_of(sb), "the freed default no longer moves"
      sb.send(:dispatch, "\e[B")
      assert_equal 2, cursor_of(sb), "the ↓ arrow alias still moves, remap or not"
    end

    def test_dispatch_honors_a_remapped_action_key
      File.write(Config.path, YAML.dump("sidebar_keys" => { "toggle_branch_fold" => "f" }))
      sb = sidebar(nodes: multi_branch_tree)
      sb.send(:dispatch, "f")
      assert sb.instance_variable_get(:@fold_branches), "the remapped key fires the action"
      refute_equal :toggle_branch_fold, sb.instance_variable_get(:@keymap)["z"], "the old default is freed"
    end

    def test_dispatch_ignores_a_freed_or_unbound_key
      File.write(Config.path, YAML.dump("sidebar_keys" => { "down" => "x" })) # frees j
      sb = sidebar(nodes: [proj("app"), ws("a"), ws("b")])
      assert sb.send(:dispatch, "j"), "an unbound printable key is a harmless no-op (loop lives)"
      assert_equal 0, cursor_of(sb), "and does nothing"
    end

    def test_reserved_structural_keys_are_not_remappable
      # A printable override can't shadow Enter — valid_sidebar_key? forbids
      # binding to non-printables, so the structural ↵ case still runs.
      File.write(Config.path, YAML.dump("sidebar_keys" => { "new_workspace" => "c" }))
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a")], cursor: 1)
      sb.instance_variable_set(:@config, Config.new)
      switched = nil
      stub_method(Tmux, :go, ->(worktree, start:) { switched = worktree.path }) do
        sb.send(:dispatch, "\r")
      end
      assert_equal "/wt/a", switched, "↵ still switches regardless of any remap"
    end

    def test_help_overlay_reflects_a_remapped_key
      File.write(Config.path, YAML.dump("sidebar_keys" => { "new_workspace" => "c" }))
      sb = sidebar(nodes: [proj("app")])
      stub_method(Tmux, :pane_switch_keys, -> { [] }) do
        lines = sb.send(:help_lines, 40).map { |l| strip_ansi(l) }
        assert(lines.any? { |l| l.include?("new workspace") && l.start_with?("c") },
               "the overlay advertises the configured key, not the default n")
      end
    end

    def test_footer_help_hint_reflects_a_remapped_help_key
      File.write(Config.path, YAML.dump("sidebar_keys" => { "help" => "x" }))
      sb = sidebar(nodes: [proj("app"), ws("a")], cursor: 1)
      assert_includes sb.send(:footer)[0], "x help", "the persistent gateway shows the configured help key"
    end

    def test_footer_empty_tree_invite_reflects_a_remapped_add_key
      File.write(Config.path, YAML.dump("sidebar_keys" => { "add_project" => "p" }))
      assert_includes sidebar(nodes: []).send(:footer)[0], "p add a project"
    end

    # Drift guard: an action added to Keymap::ACTIONS with no matching `when`
    # arm in dispatch_action resolves in @keymap and is advertised in help/footer,
    # but pressing its key silently does nothing — a dead, advertised key. Pin
    # that every action has a dispatch arm (issue #108).
    def test_dispatch_action_handles_every_keymap_action
      src = File.read(File.expand_path("../lib/switchboard/sidebar/input.rb", __dir__))
      body = src[/def dispatch_action\b.*?\n    end\n/m]
      refute_nil body, "located the dispatch_action method body"
      Keymap::ACTIONS.each do |a|
        assert_includes body, ":#{a.name}",
                        "dispatch_action has no arm for :#{a.name} (ACTIONS/dispatch drift — its key would be a dead no-op)"
      end
    end

    # The headline "edit sidebar_keys via `e`, re-binds live" path: rebuild
    # re-resolves the keymap from the (possibly just-edited) @config, mirroring
    # the shared-store hydration tests. Without resolve_keymap in rebuild this
    # would not pick up the edit.
    def test_rebuild_reresolves_the_keymap_after_a_config_edit
      repo = temp_git_repo("app")
      File.write(Config.path, YAML.dump("projects" => [{ "name" => "app", "path" => repo }]))
      sb = sidebar(nodes: [])
      sb.instance_variable_set(:@config, Config.new)
      sb.send(:rebuild)
      assert_equal :new_workspace, sb.instance_variable_get(:@keymap)["n"], "default n binds before the edit"

      # as an `e` edit + Ctrl-R reload would: rewrite config, swap the fresh Config, rebuild
      File.write(Config.path, YAML.dump("projects" => [{ "name" => "app", "path" => repo }],
                                        "sidebar_keys" => { "new_workspace" => "c" }))
      sb.instance_variable_set(:@config, Config.new)
      sb.send(:rebuild)
      assert_equal :new_workspace, sb.instance_variable_get(:@keymap)["c"], "rebuild re-binds to the edited key"
      assert_nil sb.instance_variable_get(:@keymap)["n"], "the freed default no longer binds"
    end

    # --- tokenize: the terminal-input grammar parser -------------------------
    # The pure tokenizer behind handle. It replaced fixed-width slicing, which
    # orphaned an escape sequence's final byte when a read split it — a focus-out
    # `\e[O` cut after `\e[` left a bare `O` that dispatched as open_repo, throwing
    # you to the repo on GitHub right after creating a workspace. tokenize parses by
    # the real grammar and carries any incomplete trailing sequence instead.
    def tok(str)  = Sidebar::Input.tokenize(str.b).first.map(&:bytes)
    def rest(str) = Sidebar::Input.tokenize(str.b).last.bytes

    def test_tokenize_splits_a_whole_focus_burst_into_clean_tokens
      # 3 focus events, no boundary split: three complete CSIs, nothing carried.
      assert_equal [[27, 91, 79], [27, 91, 79], [27, 91, 79]], tok("\e[O\e[O\e[O")
      assert_empty rest("\e[O\e[O\e[O")
    end

    def test_tokenize_carries_an_incomplete_trailing_csi
      # The old read capped at 8 bytes (not a multiple of 3) and split the 3rd event.
      str = "\e[O\e[O\e["
      assert_equal [[27, 91, 79], [27, 91, 79]], tok(str), "two whole focus-outs emit"
      assert_equal [27, 91], rest(str), "the partial `\\e[` is carried, never orphaned"
      # Prepending the carry to the next read reassembles the whole sequence.
      assert_equal [[27, 91, 79]], tok("\e[O"), "carry + next byte => one focus-out"
    end

    def test_tokenize_never_emits_a_csi_final_byte_alone
      # The crux of the bug: `O` only ever appears as a CSI final (focus-out) or an
      # SS3 lead's byte, never on its own — so it can't be mistaken for open_repo.
      assert_equal [[27, 79]], tok("\eO"),  "`\\eO` (SS3 lead) keeps the O with the esc"
      assert_equal [[27, 79], [65]], tok("\eOA"), "SS3 arrow: O stays absorbed, A is harmless"
      assert_equal [[79]], tok("O"), "a genuine standalone O is its own key (open_repo)"
    end

    def test_tokenize_emits_a_lone_trailing_esc_as_the_esc_key
      # Carrying it would stall Esc (search/prompt cancel) waiting for bytes that
      # never come — terminals deliver a sequence's bytes together, so a lone `\e`
      # is the key.
      assert_equal [[27]], tok("\e")
      assert_equal [[106], [27]], tok("j\e"), "a key then a bare Esc"
    end

    def test_tokenize_keeps_a_multibyte_csi_whole
      # A modified arrow `\e[1;5C` is one token now (old slicing chopped it into
      # stray bytes that could leak into a search query).
      assert_equal [[27, 91, 49, 59, 53, 67]], tok("\e[1;5C")
      assert_equal [27, 91, 49, 59, 53], rest("\e[1;5"), "an unfinished one is carried"
    end

    def test_tokenize_recovers_a_control_key_after_a_split_csi
      # If a carried `\e[` is followed by a control byte (not a valid CSI final
      # 0x40-0x7E), the `\e[` is malformed — emit it inert and resume on the control
      # byte so a real key still fires. Without this the `\f` Ctrl-L reload poke
      # (and Enter, ^N, ^P, ^R) got swallowed into a junk token.
      assert_equal [[27, 91], [12]], tok("\e[\f"), "Ctrl-L reload survives a split \\e["
      assert_equal [[27, 91], [13]], tok("\e[\r"), "Enter survives too"
    end

    def test_tokenize_caps_the_carried_partial
      # An unterminated param run is garbage — drop it instead of growing @pending
      # without bound on a junk byte stream.
      assert_empty rest("\e[" + (";" * 5000)), "a too-long partial CSI is dropped, not carried"
      assert_equal [27, 91], rest("\e["), "a short partial is still carried normally"
    end

    # --- handle: dispatch across read boundaries (the open_repo bug) ----------
    # The reported symptom: after `n` creates a workspace, the focus-event flurry
    # from the session switch could land a stray `O` and open the repo on GitHub.
    def test_handle_reassembles_a_focus_burst_split_across_two_reads
      sb = sidebar(nodes: [proj("app"), ws("a")])
      opened = false
      sb.define_singleton_method(:open_repo) { opened = true }

      stream = "\e[O\e[O\e[O".b # the old fixed read sliced this mid-sequence
      sb.send(:handle, stream[0, 8]) # first read leaves a partial in @pending
      assert_equal [27, 91], sb.instance_variable_get(:@pending).bytes, "partial carried"
      sb.send(:handle, stream[8..]) # the remaining byte completes the carried sequence

      refute opened, "the reassembled sequence is focus-out, never open_repo"
      assert_empty sb.instance_variable_get(:@pending), "fully consumed"
    end

    # The mixed buffer the old 8-byte read mangled: a key then a focus burst, which
    # offset the slicing so the cap fell on a `\e` and the next read began `[O`.
    def test_handle_survives_a_key_then_a_focus_burst
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a")])
      opened = false
      sb.define_singleton_method(:open_repo) { opened = true }
      sb.instance_variable_set(:@cursor, 1) # on the workspace row

      sb.send(:handle, "j\e[O\e[O\e[O".b) # one read now (READ_BYTES), no boundary split
      refute opened, "no stray O even when a key precedes the focus burst"
    end

    # A real capital-O still opens the repo, and a bare Esc still cancels a search
    # immediately — the parser narrows nothing a user actually types.
    def test_handle_leaves_genuine_O_and_bare_esc_intact
      sb = sidebar(nodes: [proj("app"), ws("a")])
      opened = false
      sb.define_singleton_method(:open_repo) { opened = true }

      sb.send(:handle, "O".b)
      assert opened, "a real O keypress still opens the repo"

      sb.send(:dispatch, "/") # start a search (where bare Esc is meaningful)
      assert sb.instance_variable_get(:@search).typing?
      sb.send(:handle, "\e".b)
      refute sb.instance_variable_get(:@search).active?, "bare Esc still cancels the search"
    end

    # --- ? help overlay (issue #62) ------------------------------------------

    def help_of(sb) = sb.instance_variable_get(:@help)
    def help_page_of(sb) = sb.instance_variable_get(:@help_page)

    # help_key sizes the overlay from the pane, so pin the pane and skip the tmux
    # pane-key probe (offline). 100 rows = one page; 20 rows = several.
    def help_sidebar(rows: 100, **opts)
      sb = sidebar(nodes: [proj("app"), ws("a"), ws("b")], **opts)
      sb.instance_variable_set(:@pane_switch_keys, [])
      sb.define_singleton_method(:winsize) { [rows, 40] }
      sb
    end

    def test_question_mark_opens_the_help_overlay
      sb = sidebar(nodes: [proj("app"), ws("a")])
      refute help_of(sb), "help starts closed"
      sb.send(:dispatch, "?")
      assert help_of(sb), "? opens the overlay"
    end

    # While the overlay is open a real keystroke dismisses it and does NOTHING else —
    # no passthrough into the action that key would normally fire.
    def test_any_real_key_dismisses_help_without_side_effects
      sb = help_sidebar(cursor: 0)
      sb.send(:dispatch, "?")
      assert_equal true, sb.send(:dispatch, "j"), "dispatch returns true (loop lives on)"
      refute help_of(sb), "j closed the overlay"
      assert_equal 0, cursor_of(sb), "...and did NOT also move the cursor"
    end

    # Even a typed q just closes the overlay — it never reaches the quit-all path.
    def test_q_in_help_closes_instead_of_quitting
      sb = help_sidebar
      sb.send(:dispatch, "?")
      assert_equal true, sb.send(:dispatch, "q"), "q in help doesn't quit the loop"
      refute help_of(sb), "q closed the overlay"
    end

    # The F1 robustness guard: a synthetic tmux byte (the C-l background/switch poke,
    # the C-r config poke, focus in/out) must NOT dismiss the overlay out from under
    # the reader — the gap that "any key dismisses" would have shipped.
    def test_synthetic_pokes_do_not_dismiss_help
      sb = help_sidebar(rows: 20)
      sb.send(:dispatch, "?")
      sb.send(:dispatch, "\e[C")
      ["\f", "\e[I", "\e[O", Sidebar::RELOAD_CONFIG_BYTE, Sidebar::WARM_POKE_BYTE].each do |poke|
        sb.send(:dispatch, poke)
        assert help_of(sb), "#{poke.inspect} (a poke/focus byte) must not close help"
        assert_equal 1, help_page_of(sb), "#{poke.inspect} must not turn the page either"
      end
    end

    # A paged overlay: →/Space forward, ← back, clamped at both ends — a double-tap
    # on the last page can't close it, ← on page 1 can't either.
    def test_arrows_and_space_turn_help_pages_and_clamp
      sb = help_sidebar(rows: 20)
      count = sb.send(:help_pages, 20, 40).size
      assert_operator count, :>=, 3, "a 20-row pane needs several pages"
      sb.send(:dispatch, "?")
      sb.send(:dispatch, "\e[D")
      assert_equal 0, help_page_of(sb), "← on page 1 stays put"
      sb.send(:dispatch, "\e[C")
      sb.send(:dispatch, " ")
      assert_equal 2, help_page_of(sb), "→ and Space both turn forward"
      sb.send(:dispatch, "\e[D")
      assert_equal 1, help_page_of(sb), "← turns back"
      (count + 2).times { sb.send(:dispatch, " ") }
      (count + 2).times { sb.send(:dispatch, "\e[C") }
      assert_equal count - 1, help_page_of(sb), "Space and → stop at the last page"
      assert help_of(sb), "...and help is still open"
      sb.send(:dispatch, "j")
      refute help_of(sb), "any other key closes"
      sb.send(:dispatch, "?")
      assert_equal 0, help_page_of(sb), "help reopens on page 1"
    end

    # One page keeps "any key closes" exactly — Space and the arrows included.
    def test_space_closes_single_page_help
      ["\e[C", " ", "\e[D"].each do |key|
        sb = help_sidebar
        sb.send(:dispatch, "?")
        sb.send(:dispatch, key)
        refute help_of(sb), "#{key.inspect} closes a one-page overlay"
      end
    end

    # The pane can grow between a paint and the next key (no repaint for up to
    # REFRESH). An overlay that showed several pages keeps its paging keys: a → aimed
    # at "2/2" must not dismiss, or the rest of the burst reaches the tree and
    # resizes the pane (a persisted width). Covers both orders: painted, then keyed.
    def test_paging_keys_stay_sticky_when_the_pane_grows_to_one_page
      sb = help_sidebar(rows: 20)
      sb.send(:dispatch, "?")
      capture_stdout { sb.send(:render_help) } # painted as page 1 of several
      sb.define_singleton_method(:winsize) { [100, 40] }
      sb.send(:handle, "\e[C\e[C\e[D")
      assert help_of(sb), "a paging key on a painted multi-page overlay never closes it"
      refute sb.instance_variable_get(:@resized), "...and the burst never reaches the resize"
      assert_equal 0, help_page_of(sb)

      sb = help_sidebar(rows: 20)
      sb.send(:handle, "?\e[C")
      sb.define_singleton_method(:winsize) { [100, 40] }
      sb.send(:handle, "\e[C\e[C")
      assert help_of(sb), "paged by key, then grown: → still pages"
      refute sb.instance_variable_get(:@resized)
      sb.send(:dispatch, "j")
      refute help_of(sb), "another key still closes it"
    end

    # The sidebar dispatches a whole read before it renders again, so `?→` typed fast
    # arrives in one handle call with no render between. The page count must come from
    # the pane, not from a render that hasn't happened, or → would close help.
    def test_question_then_arrow_in_one_read_turns_the_page
      sb = help_sidebar(rows: 20)
      sb.send(:handle, "?\e[C")
      assert help_of(sb), "help is still open"
      assert_equal 1, help_page_of(sb), "→ turned to page 2"
    end

    # `?` while typing a search is a query char, not a help trigger: it never reaches
    # the normal table while typing.
    def test_question_mark_in_a_search_is_query_input_not_help
      sb = sidebar(nodes: [proj("app"), ws("a")])
      sb.send(:dispatch, "/")
      sb.send(:dispatch, "?")
      refute help_of(sb), "? while typing a search does not open help"
      assert_equal "?", sb.instance_variable_get(:@search).query, "...it extends the query"
    end

    # The discoverability regression guard (the exact gap that motivated #62): the
    # overlay must list g/G, and every line must fit the pane width. (Stub the tmux
    # pane-key probe so the test stays offline and the row's width is exercised.)

    # j/k are vi movers in the tree (down/up). While typing a search a printable key
    # is query input instead, and movement waits until the search is committed.
    def test_j_and_k_move_in_normal_mode
      sb = sidebar(nodes: [proj("app"), ws("a"), ws("b")])
      sb.send(:dispatch, "j")
      assert_equal 1, cursor_of(sb), "j moves down"
      sb.send(:dispatch, "j")
      assert_equal 2, cursor_of(sb), "...clamping at the last row"
      sb.send(:dispatch, "j")
      assert_equal 2, cursor_of(sb)
      sb.send(:dispatch, "k")
      assert_equal 1, cursor_of(sb), "k moves up"
    end

  end
end
