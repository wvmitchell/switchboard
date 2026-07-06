# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/sidebar_case"

module Switchboard
  # Sidebar::Input — bytes to actions (#57): the terminal-grammar tokenizer,
  # dispatch across read boundaries, the #108 configurable keymap, navigation,
  # and the / filter + ? help key modes. White-box via SidebarCase, like the
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
      # Carrying it would stall Esc (filter/prompt cancel) waiting for bytes that
      # never come — terminals deliver a sequence's bytes together, so a lone `\e`
      # is the key.
      assert_equal [[27]], tok("\e")
      assert_equal [[106], [27]], tok("j\e"), "a key then a bare Esc"
    end

    def test_tokenize_keeps_a_multibyte_csi_whole
      # A modified arrow `\e[1;5C` is one token now (old slicing chopped it into
      # stray bytes that could leak into the filter query).
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

    # A real capital-O still opens the repo, and a bare Esc still cancels filter
    # mode immediately — the parser narrows nothing a user actually types.
    def test_handle_leaves_genuine_O_and_bare_esc_intact
      sb = sidebar(nodes: [proj("app"), ws("a")])
      opened = false
      sb.define_singleton_method(:open_repo) { opened = true }

      sb.send(:handle, "O".b)
      assert opened, "a real O keypress still opens the repo"

      sb.send(:dispatch, "/") # enter filter mode (where bare Esc is meaningful)
      refute_nil sb.instance_variable_get(:@filter)
      sb.send(:handle, "\e".b)
      assert_nil sb.instance_variable_get(:@filter), "bare Esc still cancels filter mode"
    end

    # --- ? help overlay (issue #62) ------------------------------------------

    def help_of(sb) = sb.instance_variable_get(:@help)

    def test_question_mark_opens_the_help_overlay
      sb = sidebar(nodes: [proj("app"), ws("a")])
      refute help_of(sb), "help starts closed"
      sb.send(:dispatch, "?")
      assert help_of(sb), "? opens the overlay"
    end

    # While the overlay is open a real keystroke dismisses it and does NOTHING else —
    # no passthrough into the action that key would normally fire.
    def test_any_real_key_dismisses_help_without_side_effects
      sb = sidebar(nodes: [proj("app"), ws("a"), ws("b")], cursor: 0)
      sb.send(:dispatch, "?")
      assert_equal true, sb.send(:dispatch, "j"), "dispatch returns true (loop lives on)"
      refute help_of(sb), "j closed the overlay"
      assert_equal 0, cursor_of(sb), "...and did NOT also move the cursor"
    end

    # Even a typed q just closes the overlay — it never reaches the quit-all path.
    def test_q_in_help_closes_instead_of_quitting
      sb = sidebar(nodes: [proj("app"), ws("a")])
      sb.send(:dispatch, "?")
      assert_equal true, sb.send(:dispatch, "q"), "q in help doesn't quit the loop"
      refute help_of(sb), "q closed the overlay"
    end

    # The F1 robustness guard: a synthetic tmux byte (the C-l background/switch poke,
    # the C-r config poke, focus in/out) must NOT dismiss the overlay out from under
    # the reader — the gap that "any key dismisses" would have shipped.
    def test_synthetic_pokes_do_not_dismiss_help
      sb = sidebar(nodes: [proj("app"), ws("a")])
      sb.send(:dispatch, "?")
      ["\f", "\e[I", "\e[O", Sidebar::RELOAD_CONFIG_BYTE].each do |poke|
        sb.send(:dispatch, poke)
        assert help_of(sb), "#{poke.inspect} (a poke/focus byte) must not close help"
      end
    end

    # `?` while filtering is a query char, not a help trigger: the @filter guard sits
    # after the @help guard, and ? never reaches the normal table while filtering.
    def test_question_mark_in_filter_is_query_input_not_help
      sb = sidebar(nodes: [proj("app"), ws("a")])
      sb.send(:dispatch, "/")
      sb.send(:dispatch, "?")
      refute help_of(sb), "? in filter mode does not open help"
      assert_equal "?", sb.instance_variable_get(:@filter), "...it extends the query"
    end

    # The discoverability regression guard (the exact gap that motivated #62): the
    # overlay must list g/G, and every line must fit the pane width. (Stub the tmux
    # pane-key probe so the test stays offline and the row's width is exercised.)

    # j/k are vi movers in normal mode (down/up). They're NOT movers while
    # filtering — there a printable key is query input (test below) — so motion in
    # the tree is arrows / ^N / ^P / j / k, and in the filter arrows / ^N / ^P.
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

    # --- / filter mode (issue #60) -------------------------------------------

    # fzf-style fuzzy: a case-insensitive subsequence, order-sensitive, with an
    # empty query matching everything (so the bare-/ list is the full tree).
    def test_fuzzy_match_is_a_case_insensitive_subsequence
      assert Sidebar.fuzzy_match?("app-feat-branch", "afb"), "non-adjacent subsequence matches"
      assert Sidebar.fuzzy_match?("App-Feat", "af"), "case-insensitive"
      assert Sidebar.fuzzy_match?("anything", ""), "empty query matches everything"
      refute Sidebar.fuzzy_match?("app", "pa"), "order matters — not mere membership"
      refute Sidebar.fuzzy_match?("app", "appp"), "every query char must be consumed"
    end

    # / enters the mode with an empty query (matches everything), keeping the tree
    # grouped: project headers stay, and the cursor lands on the first row.
    def test_slash_enters_filter_mode_showing_the_grouped_tree
      sb = sidebar(nodes: [proj("app"), ws("alpha"), ws("beta"), proj("api"), ws("gamma", project: "api")])
      sb.send(:dispatch, "/")
      assert_equal "", sb.instance_variable_get(:@filter), "/ enters filter mode with an empty query"
      assert_equal %w[proj ws ws proj ws], rows_of(sb).map(&:kind), "headers stay, grouping the matches"
      assert_equal 0, cursor_of(sb), "the cursor lands on the first row on entry"
      assert_includes sb.send(:footer)[2], "3 matches", "the count pluralizes and excludes headers"
    end

    def test_typing_narrows_to_subsequence_matches_on_project_and_name
      sb = sidebar(nodes: [proj("app"), ws("alpha"), ws("beta"), proj("api"), ws("gamma", project: "api")])
      sb.send(:handle, "/alp")
      assert_equal %w[alpha], ws_names(sb), "the query narrows to matching workspaces"
    end

    # Matches stay under their own project header; a project with no match is dropped.
    def test_filter_keeps_matches_grouped_under_their_project_header
      sb = sidebar(nodes: [proj("app"), ws("alpha"), ws("beta"),
                           proj("api"), ws("alpha2", project: "api"), ws("zebra", project: "api")])
      sb.send(:handle, "/alpha")
      assert_equal %w[proj ws proj ws], rows_of(sb).map(&:kind), "each match sits under its header"
      assert_equal %w[app api], rows_of(sb).select { |n| n.kind == "proj" }.map(&:project)
      assert_equal %w[alpha alpha2], ws_names(sb), "only the matching workspaces show"
    end

    def test_filter_drops_a_project_when_neither_its_name_nor_workspaces_match
      sb = sidebar(nodes: [proj("app"), ws("alpha"), proj("api"), ws("zebra", project: "api")])
      sb.send(:handle, "/alpha")
      assert_equal %w[app], rows_of(sb).select { |n| n.kind == "proj" }.map(&:project),
                   "api's name doesn't match and neither does zebra, so it's dropped"
    end

    # A project whose NAME matches shows even with no matching workspaces (or none
    # at all) — that's how you reach an empty project to create its first workspace.
    def test_filter_keeps_a_name_matching_project_with_no_workspaces
      sb = sidebar(nodes: [proj("app"), ws("alpha"), proj("api")]) # api has no workspaces
      sb.send(:handle, "/api")
      assert_equal %w[api], rows_of(sb).select { |n| n.kind == "proj" }.map(&:project),
                   "api matches by name and shows, even with nothing under it"
      assert_empty ws_names(sb), "no workspace rows — just the header"
      assert_equal "proj", current_node(sb).kind, "cursor lands on the header (nothing else to select)"
    end

    # Branch-history rows aren't separate filter targets — switching to one is
    # identical to switching to its workspace, and a lone branch would orphan under
    # a header. So a query that matches only a branch yields nothing.
    def test_filter_excludes_branch_history_rows
      sb = sidebar(nodes: [proj("app"), ws("feat"), br("feature-y", last: true)])
      sb.send(:handle, "/feature-y") # matches only the branch row's text, not the ws
      refute(rows_of(sb).any? { |n| n.kind == "br" }, "branch rows never appear as filter matches")
      assert_empty rows_of(sb), "nothing else matched, so the result is empty"
    end

    # A zero-match query is empty and inert: 0-count footer, and ↵ opens nothing and
    # stays in filter mode (no crash, no clamp to a phantom row).
    def test_filter_with_no_matches_is_empty_and_inert
      sb = sidebar(nodes: [proj("app"), ws("alpha")])
      sb.send(:handle, "/zzz")
      assert_empty rows_of(sb)
      assert_includes sb.send(:footer)[2], "0 matches"
      stub_method(Tmux, :go, ->(*, **) { flunk "nothing to open on a zero-match query" }) do
        assert sb.send(:dispatch, "\r"), "↵ keeps the loop alive"
      end
      refute_nil sb.instance_variable_get(:@filter), "...and stays in filter mode"
    end

    # The cursor finds the first workspace match even when it's in a later project
    # (earlier projects dropped entirely or kept header-only).
    def test_filter_lands_on_the_first_match_in_a_later_project
      sb = sidebar(nodes: [proj("app"), ws("alpha"), proj("api"), ws("gamma", project: "api")])
      sb.send(:handle, "/gam")
      assert_equal "gamma", current_node(sb).name, "cursor jumps to the match in the second project"
    end

    # Esc restores the cursor to the workspace this session is in (cursor_to_current),
    # not wherever the filtered cursor sat.
    def test_esc_restores_the_cursor_to_the_current_workspace
      sb = sidebar(nodes: [proj("app"), ws("alpha", path: "/wt/alpha"), ws("beta", path: "/wt/beta")],
                   current_path: "/wt/beta")
      sb.send(:dispatch, "/") # cursor lands on the first row (the app header)
      assert_equal "proj", current_node(sb).kind
      sb.send(:dispatch, "\e")
      assert_nil sb.instance_variable_get(:@filter)
      assert_equal "beta", current_node(sb).name, "Esc lands back on the session's current workspace"
    end

    # The filter spans the whole tree, folds included — the whole point is reaching
    # any workspace fast, even one tucked inside a collapsed project.
    def test_filter_searches_across_collapsed_projects
      sb = sidebar(nodes: [proj("app"), ws("alpha"), ws("beta")], collapsed: ["app"])
      assert_equal 1, rows_of(sb).size, "collapsed: only the header shows in the normal tree"
      sb.send(:handle, "/beta")
      assert_equal %w[beta], ws_names(sb), "filter reaches into the folded project"
    end

    def test_esc_cancels_filter_and_restores_the_full_tree
      sb = sidebar(nodes: [proj("app"), ws("alpha"), ws("beta")])
      sb.send(:handle, "/be")
      assert_equal %w[beta], ws_names(sb)
      sb.send(:dispatch, "\e")
      assert_nil sb.instance_variable_get(:@filter), "Esc leaves filter mode"
      assert_equal 3, rows_of(sb).size, "the full collapse-aware tree is back"
    end

    def test_backspace_past_the_start_exits_filter_mode
      sb = sidebar(nodes: [proj("app"), ws("alpha"), ws("beta")])
      sb.send(:handle, "/be")
      sb.send(:dispatch, "\x7F")
      assert_equal "b", sb.instance_variable_get(:@filter), "backspace drops the last char"
      sb.send(:dispatch, "\x7F")
      assert_equal "", sb.instance_variable_get(:@filter), "...down to an empty query, still filtering"
      sb.send(:dispatch, "\x7F") # backspace past the start
      assert_nil sb.instance_variable_get(:@filter), "...and one more exits, like erasing the /"
      assert_equal 3, rows_of(sb).size, "the full tree is restored"
    end

    def test_enter_switches_to_the_match_and_leaves_filter_mode
      File.write(Config.path, YAML.dump("projects" => [{ "name" => "app", "path" => "/x" }]))
      sb = sidebar(nodes: [proj("app"), ws("alpha", path: "/wt/alpha"), ws("beta", path: "/wt/beta")])
      sb.instance_variable_set(:@config, Config.new)
      sb.send(:handle, "/beta")
      target = nil
      stub_method(Tmux, :go, ->(wt, start:) { target = wt }) { sb.send(:dispatch, "\r") }
      assert_equal "/wt/beta", target.path, "↵ switches to the highlighted match"
      assert_nil sb.instance_variable_get(:@filter), "...and drops back out of filter mode"
    end

    # The crux of the fzf-standard choice (#60): printable keys — j and k included —
    # are query input, so any name is reachable by typing. Motion is the arrows/^N^P.
    def test_j_and_k_are_query_input_not_motion_while_filtering
      sb = sidebar(nodes: [proj("app"), ws("jkl"), ws("beta")])
      sb.send(:dispatch, "/")
      sb.send(:dispatch, "j")
      assert_equal "j", sb.instance_variable_get(:@filter), "j extends the query rather than moving"
      assert_equal "jkl", current_node(sb).name, "and it narrowed to the jkl workspace"
    end

    # Only printable bytes extend the query — a stray control byte (e.g. a \f poke
    # that lands while you're filtering) is ignored, never appended or a crash.
    def test_filter_ignores_non_printable_bytes
      sb = sidebar(nodes: [proj("app"), ws("alpha")])
      sb.send(:dispatch, "/")
      sb.send(:dispatch, "a")
      sb.send(:dispatch, "\f")   # Ctrl-L poke byte
      sb.send(:dispatch, "\x01") # Ctrl-A
      sb.send(:dispatch, " ")    # space — the lower printable boundary (0x20), DOES append
      assert_equal "a ", sb.instance_variable_get(:@filter), "control bytes are ignored, space is kept"
    end

    def test_arrows_and_ctrl_np_move_within_the_filtered_set
      sb = sidebar(nodes: [proj("app"), ws("alpha"), ws("beta")])
      sb.send(:dispatch, "/") # empty query: cursor on the header (first row)
      assert_equal "proj", current_node(sb).kind, "starts on the first row, the header"
      sb.send(:dispatch, "\e[B")
      assert_equal "alpha", current_node(sb).name, "↓ moves onto the first workspace"
      sb.send(:dispatch, "\x0E")
      assert_equal "beta", current_node(sb).name, "^N moves to the next workspace"
      sb.send(:dispatch, "\x0E")
      assert_equal "beta", current_node(sb).name, "^N clamps at the last workspace"
      sb.send(:dispatch, "\e[A")
      assert_equal "alpha", current_node(sb).name, "↑ moves back up"
    end

    # Entry lands on the first row (the header); a query keystroke then snaps to the
    # first workspace match (fast type-then-↵ jump). Headers stay selectable via ↑.
    def test_filter_enters_on_the_first_row_then_snaps_to_a_match_on_typing
      sb = sidebar(nodes: [proj("app"), ws("a1"), ws("a2")])
      sb.send(:dispatch, "/")
      assert_equal "proj", current_node(sb).kind, "entry lands on the first row, the header"
      sb.send(:dispatch, "a") # a query keystroke snaps to the first match
      assert_equal "a1", current_node(sb).name, "typing snaps to the first workspace match"
      sb.send(:dispatch, "\e[A") # up onto the project header
      assert_equal "proj", current_node(sb).kind, "↑ can land on the project header"
      assert_equal "app", current_node(sb).project
    end

    # ↵ on a workspace switches; ↵ on a project header creates a new workspace there
    # (the project-level action) and leaves filter mode.
    def test_enter_on_a_project_header_in_filter_creates_a_workspace
      sb = sidebar(nodes: [proj("app"), ws("alpha")])
      sb.send(:dispatch, "/")
      sb.send(:dispatch, "\e[A") # up onto the app header
      assert_equal "proj", current_node(sb).kind, "cursor is on the project header"
      created_for = nil
      sb.define_singleton_method(:create) { |node = nil| created_for = node&.project }
      stub_method(Tmux, :go, ->(*, **) { flunk "should create, not switch" }) do
        sb.send(:dispatch, "\r")
      end
      assert_equal "app", created_for, "↵ on a project creates a new workspace there"
      assert_nil sb.instance_variable_get(:@filter), "...and leaves filter mode"
    end

    # No destructive key fires mid-search: q is just a query char, not a teardown.
    def test_q_does_not_quit_while_filtering
      sb = sidebar(nodes: [proj("app"), ws("alpha")])
      sb.send(:dispatch, "/")
      killed = false
      stub_method(Tmux, :kill_all, ->(*) { killed = true; [] }) do
        assert sb.send(:dispatch, "q"), "q keeps the loop alive in filter mode"
      end
      refute killed, "q types a query char rather than tearing down"
      assert_equal "q", sb.instance_variable_get(:@filter)
    end

    def test_filter_footer_echoes_the_query_and_the_in_mode_legend
      sb = sidebar(nodes: [proj("app"), ws("alpha"), ws("beta")])
      sb.send(:handle, "/be")
      foot = sb.send(:footer)
      assert_equal 3, foot.size, "filter mode keeps its 3-line legend (query + action + count) — it's live state, not key-teaching"
      assert_equal "/be", foot[0], "line 1 echoes the live query"
      assert_includes foot[1], "↵ open", "on a workspace, ↵ opens"
      assert_includes foot[1], "esc cancel"
      assert_includes foot[2], "1 match", "the count is workspaces only (header excluded), unpluralized at 1"
      foot.each { |l| assert l.length <= Tmux::SIDEBAR_WIDTH, "#{l.inspect} fits the #{Tmux::SIDEBAR_WIDTH}-col pane" }

      sb.send(:dispatch, "\e[A") # up onto the project header
      assert_includes sb.send(:footer)[1], "↵ new workspace", "on a project, ↵ creates"
    end

    # A background reload (tick/poke) rebuilds @nodes then recomputes — the active
    # filter must re-apply, not silently drop you back to the full tree.
    def test_a_rebuild_reapplies_the_active_filter
      sb = sidebar(nodes: [proj("app"), ws("alpha"), ws("beta")])
      sb.send(:handle, "/be")
      sb.send(:recompute_rows) # as a reload would, after rebuilding @nodes
      assert_equal %w[beta], ws_names(sb), "the filter still applies after a reload recompute"
    end
  end
end
