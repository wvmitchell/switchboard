# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/sidebar_case"

module Switchboard
  # The sidebar is now the only navigator (#17 removed the fzf picker), so its
  # navigation + rendering logic is the whole UX and worth pinning. It's a
  # stateful TUI with no E2E hook (needs a real tty), so we test white-box:
  # construct an instance, set the ivars the loop would, and drive the private
  # methods directly. The raw-tty primitives (read_key/setup/teardown/render-to-
  # stdout) stay out of scope — only the pure decisions are tested. The node/
  # sidebar builders live in SidebarCase (test/support/sidebar_case.rb), shared
  # by every sidebar_*_test.rb since the #57 split.
  class SidebarTest < SidebarCase
    # --- #57 split guards ------------------------------------------------------
    # Two failure modes of the concern split are silent by construction; these
    # make them loud, permanently.

    # Every sidebar test drives private methods via send, so the suite can't see a
    # visibility regression — a private method accidentally going public (or vice
    # versa) during a move would slip through. Pin the exact public lifecycle API.
    def test_sidebar_public_instance_api_is_pinned
      expected = %i[
        elapsed? frame_timeout lone_pane_handled monotonic owns_pane? pulsing?
        recheck_visibility run scan_due? set_visible sparkling? tick vis_poll_due?
      ]
      assert_equal expected, Sidebar.public_instance_methods(false).sort,
                   "the public run-loop surface moved — if deliberate, update this pin"
    end

    # A method moved into a concern module but accidentally LEFT in the class body
    # silently wins the method-resolution order: the module copy becomes dead code
    # and every test keeps passing against the class-body twin. Assert the sets
    # never intersect, for every concern module the split adds.
    def test_no_concern_module_method_is_shadowed_by_the_class_body
      own = Sidebar.instance_methods(false) + Sidebar.private_instance_methods(false)
      Sidebar.included_modules
             .select { |m| m.name.to_s.start_with?("Switchboard::Sidebar::") }
             .each do |mod|
        shadowed = (mod.instance_methods(false) + mod.private_instance_methods(false)) & own
        assert_empty shadowed, "#{mod} methods shadowed by a class-body twin (dead module code)"
      end
    end



    # The post-split core surface: the loop cadences + the concern parts, and the
    # two remaining class-level functions. A new core constant or singleton is a
    # deliberate act — update the pin with it (the concern parts each own theirs).
    def test_sidebar_core_constants_and_singletons_are_pinned
      expected = %i[
        Actions Edges IDLE Input NAV_TTL POKE_TTL PULSE Prompt REFRESH Render
        Rows TREE_TICKS VIS_POLL WARM_TTL
      ]
      assert_equal expected, Sidebar.constants(false).sort,
                   "the core constant set moved — if deliberate, update this pin"
      assert_equal %i[fuzzy_match? run], Sidebar.singleton_methods(false).sort,
                   "the class-level surface moved — if deliberate, update this pin"
    end








    # --- the #57 seam: refresh_agents -> Edges#on_scan -------------------------

    # The one seam the split created (pre-landing review): refresh_agents must
    # hydrate @monitoring and thread it — with @config/@current_path/@nodes —
    # into @edges.on_scan, and its broad rescue would mask a wiring break
    # SILENTLY (dots blank, suite green). Drive the REAL method end to end:
    # a monitored :done stays unbolded, an unmonitored one bolds.
    def test_refresh_agents_threads_hydrated_monitoring_into_the_edge_fanout
      a = real_dir("a")
      b = real_dir("b")
      sb = sidebar(nodes: [ws("a", path: a), ws("b", path: b)])
      sb.instance_variable_get(:@edges).instance_variable_set(:@prev_hook_states, { a => :thinking, b => :thinking })
      states = { a => :done, b => :done }
      as = Struct.new(:last_hook_states).new(states)
      as.define_singleton_method(:scan) { |_paths, hooks_only: false| states }
      sb.instance_variable_set(:@agent_state, as)
      Monitoring.mark(a)
      stub_method(Sound, :play, ->(*) {}) do
        assert sb.send(:refresh_agents, refresh_prs: false), "a clean scan returns true (rescue not tripped)"
      end
      marked = Attention.marked([a, b])
      refute_includes marked, a, "monitored :done suppressed through the hydrated @monitoring"
      assert_includes marked, b, "unmonitored completion still bolds"
      refute_empty sb.instance_variable_get(:@agents), "the happy path never blanks the dots"
    end

    # The edge -> diff-count ride the split rewired: refresh_diffs rides the
    # edge list on_scan RETURNS — one recount on an edge, none on a steady scan.
    def test_refresh_agents_rides_returned_edges_into_refresh_diffs
      a = real_dir("a")
      sb = sidebar(nodes: [ws("a", path: a)])
      sb.instance_variable_get(:@edges).instance_variable_set(:@prev_hook_states, { a => :thinking })
      states = { a => :done }
      as = Struct.new(:last_hook_states).new(states)
      as.define_singleton_method(:scan) { |_paths, hooks_only: false| states }
      sb.instance_variable_set(:@agent_state, as)
      recounts = 0
      sb.define_singleton_method(:refresh_diffs) { recounts += 1 }
      stub_method(Sound, :play, ->(*) {}) do
        sb.send(:refresh_agents, refresh_prs: false) # :thinking -> :done edge
        sb.send(:refresh_agents, refresh_prs: false) # steady :done — no edge
      end
      assert_equal 1, recounts, "diff counts recompute exactly on the edge"
    end

    # The maybe_refresh_prs delegator is the T2/T4 seam — pin that it actually
    # reaches the collaborator (its body runs under every sidebar-side stub).
    def test_maybe_refresh_prs_delegates_to_the_edge_collaborator
      sb = sidebar
      got = []
      sb.instance_variable_get(:@edges).define_singleton_method(:maybe_refresh_prs) { |p| got << p }
      sb.send(:maybe_refresh_prs, "app")
      assert_equal ["app"], got
    end

    # --- pane resize: ←/→ step the width (issue #78) -------------------------

    def width_of(sb) = sb.instance_variable_get(:@width)

    def test_left_and_right_step_the_pane_width
      sb = sidebar(nodes: [proj("app"), ws("a")])
      start = width_of(sb)
      sb.send(:dispatch, "\e[C") # →
      assert_equal start + Sidebar::WIDTH_STEP, width_of(sb), "→ widens by a step"
      assert sb.instance_variable_get(:@resized), "...and flags a pending commit"
      sb.send(:dispatch, "\e[D") # ←
      assert_equal start, width_of(sb), "← narrows back"
    end

    def test_resize_clamps_at_the_bounds
      sb = sidebar(nodes: [proj("app"), ws("a")])
      sb.instance_variable_set(:@width, Width::MAX)
      sb.send(:dispatch, "\e[C")
      assert_equal Width::MAX, width_of(sb), "→ at the max is a no-op"
      refute sb.instance_variable_get(:@resized), "...and queues no commit"
      sb.instance_variable_set(:@width, Width::MIN)
      sb.instance_variable_set(:@resized, false)
      sb.send(:dispatch, "\e[D")
      assert_equal Width::MIN, width_of(sb), "← at the min is a no-op"
      refute sb.instance_variable_get(:@resized)
    end

    # The held-key contract: handle drains a whole autorepeat burst flag-only (no
    # pin mid-drain), then commit_resize fires ONCE — one resize-pane + one disk
    # write for the burst, so holding the key stays smooth.
    def test_a_resize_burst_pins_and_persists_once
      sb = sidebar(nodes: [proj("app"), ws("a")])
      start = width_of(sb)
      pins = 0
      stub_method(sb, :pin_width, -> { pins += 1 }) do
        sb.send(:handle, "\e[C\e[C") # two →'s in one read, as autorepeat delivers
        assert_equal start + 2 * Sidebar::WIDTH_STEP, width_of(sb), "every token steps the width"
        assert_equal 0, pins, "handle is flag-only — no pin mid-burst"
        sb.send(:commit_resize)
      end
      assert_equal 1, pins, "the burst pins exactly once, post-drain"
      assert_equal start + 2 * Sidebar::WIDTH_STEP, Width.resolved, "...and persists once to the shared store"
      refute sb.instance_variable_get(:@resized), "the pending flag clears after commit"
    end

    # Same store-hydration contract as the folds and the full-header flag: a resize
    # in one window is picked up by every other sidebar on its next rebuild.
    def test_rebuild_hydrates_the_width_from_the_shared_store
      repo = temp_git_repo("app")
      File.write(Config.path, YAML.dump("projects" => [{ "name" => "app", "path" => repo }]))
      Width.set(58) # as if another window's sidebar resized

      sb = sidebar(nodes: [])
      sb.instance_variable_set(:@config, Config.new)
      sb.send(:rebuild)
      assert_equal 58, width_of(sb), "rebuild picks up the width another sidebar wrote"
    end

    # A peer window already pinned at the old width has @geom == its winsize, so
    # pin_if_resized would short-circuit and never apply a width another window set.
    # rebuild must invalidate @geom when the shared width changed, so the next
    # pin_if_resized re-pins this pane.
    def test_rebuild_invalidates_the_pin_cache_when_the_shared_width_changed
      repo = temp_git_repo("app")
      File.write(Config.path, YAML.dump("projects" => [{ "name" => "app", "path" => repo }]))
      Width.set(40)
      sb = sidebar(nodes: [])
      sb.instance_variable_set(:@config, Config.new)
      sb.send(:rebuild)                            # hydrate @width = 40
      sb.instance_variable_set(:@geom, [50, 40])   # as if pinned at the 40-col geometry
      Width.set(60)                                # another window resized
      sb.send(:rebuild)
      assert_nil sb.instance_variable_get(:@geom), "a changed shared width clears the pin cache so the pane re-pins"
      assert_equal 60, width_of(sb)
    end

    # A rebuild can fire mid-burst (a C-l/C-r poke byte arriving in the same read as a
    # ←/→), while a resize is stepped in memory but not yet committed. rebuild must NOT
    # rehydrate the old on-disk width over it, or the resize is silently dropped before
    # commit_resize can persist it.
    def test_rebuild_does_not_clobber_a_pending_uncommitted_resize
      repo = temp_git_repo("app")
      File.write(Config.path, YAML.dump("projects" => [{ "name" => "app", "path" => repo }]))
      Width.set(40)
      sb = sidebar(nodes: [])
      sb.instance_variable_set(:@config, Config.new)
      sb.send(:rebuild)                          # @width = 40
      sb.instance_variable_set(:@width, 42)      # a ←/→ stepped it, not yet committed
      sb.instance_variable_set(:@resized, true)
      sb.send(:rebuild)                          # a poke byte rebuilt mid-burst
      assert_equal 42, width_of(sb), "rebuild must not rehydrate over a pending resize"
    end

    # commit_resize nils @geom so a pin tmux refused (width didn't fit) is retried by
    # the next pin_if_resized instead of short-circuiting forever on the stale cache.
    def test_commit_resize_invalidates_the_pin_cache
      sb = sidebar(nodes: [proj("app"), ws("a")])
      sb.instance_variable_set(:@geom, [50, 40])
      sb.instance_variable_set(:@width, 60)
      stub_method(sb, :pin_width, -> { false }) do # simulate tmux refusing the resize
        sb.send(:commit_resize)
      end
      assert_nil sb.instance_variable_get(:@geom), "a committed resize clears @geom so a failed pin retries"
      refute sb.instance_variable_get(:@resized)
      assert_equal 60, Width.resolved, "...and still persists the chosen width"
    end

    def test_rebuild_keeps_the_pin_cache_when_width_is_unchanged
      repo = temp_git_repo("app")
      File.write(Config.path, YAML.dump("projects" => [{ "name" => "app", "path" => repo }]))
      Width.set(50)
      sb = sidebar(nodes: [])
      sb.instance_variable_set(:@config, Config.new)
      sb.send(:rebuild)                            # @width = 50
      sb.instance_variable_set(:@geom, [50, 50])
      sb.send(:rebuild)                            # width unchanged
      refute_nil sb.instance_variable_get(:@geom), "an unchanged width leaves the pin cache intact (no redundant re-pin)"
    end

    # ←/→ are inert while filtering (issue #60 keeps movement off j/k there; resize
    # stays off too) — they neither resize nor leak into the query.
    def test_resize_keys_are_inert_while_filtering
      sb = sidebar(nodes: [proj("app"), ws("a")])
      sb.send(:dispatch, "/")
      start = width_of(sb)
      sb.send(:dispatch, "\e[C")
      sb.send(:dispatch, "\e[D")
      assert_equal start, width_of(sb), "←/→ don't resize while filtering"
      refute sb.instance_variable_get(:@resized), "...and queue no commit"
      assert_equal "", sb.instance_variable_get(:@filter), "...nor leak into the query"
    end

    def test_jump_keys_stay_in_bounds_on_an_empty_tree
      sb = sidebar(nodes: [])
      sb.send(:dispatch, "G")
      assert_equal 0, cursor_of(sb), "G on an empty tree must not go negative"
      sb.send(:dispatch, "g")
      assert_equal 0, cursor_of(sb)
    end

    # A non-stop-token returns true so the buffer loop keeps running. Hide/show is
    # now prefix-s (Tmux.toggle_sidebar), so the sidebar has no in-loop hide key.
    def test_dispatch_movement_keeps_the_loop_alive
      sb = sidebar(nodes: [proj("app")])
      assert sb.send(:dispatch, "j"), "a non-stop-token keeps the loop alive"
    end

    # q tears down every sb/ session — but only after a y/N confirm. A confirmed
    # q kills all and exits the loop; an unconfirmed q kills nothing and keeps
    # the loop alive (so a stray q can't nuke everything by muscle memory).
    def test_q_quits_all_sessions_only_when_confirmed
      sb = sidebar(nodes: [proj("app")])
      killed = false
      stub_method(Tmux, :kill_all, ->(*) { killed = true; [] }) do
        stub_method(sb, :confirm, ->(*) { true }) do
          refute sb.send(:dispatch, "q"), "a confirmed q exits the loop"
        end
        assert killed, "a confirmed q tears down every session"

        killed = false
        stub_method(sb, :confirm, ->(*) { false }) do
          assert sb.send(:dispatch, "q"), "an unconfirmed q keeps the loop alive"
        end
        refute killed, "an unconfirmed q kills nothing"
      end
    end

    # A confirmed q wipes agent state before tearing down — killing every agent
    # at once leaves their last hook states stale, and a lingering :thinking would
    # otherwise read as a live, working agent on the next launch. An unconfirmed q
    # touches nothing.
    def test_q_clears_agent_state_before_teardown_only_when_confirmed
      sb = sidebar(nodes: [proj("app")])
      cleared = false
      stub_method(AgentState, :clear_all, -> { cleared = true }) do
        stub_method(Tmux, :kill_all, ->(*) { [] }) do
          stub_method(sb, :confirm, ->(*) { true }) { sb.send(:dispatch, "q") }
          assert cleared, "a confirmed q clears stale agent state"

          cleared = false
          stub_method(sb, :confirm, ->(*) { false }) { sb.send(:dispatch, "q") }
          refute cleared, "an unconfirmed q clears nothing"
        end
      end
    end

    def test_handle_processes_every_token_in_a_key_repeat_buffer
      sb = sidebar(nodes: [proj("app"), ws("a"), ws("b")])
      sb.send(:handle, "\x0E\x0E") # a held ^N arrives as one multi-byte read
      assert_equal 2, cursor_of(sb)
    end

    def test_handle_returns_false_when_a_token_quits
      sb = sidebar(nodes: [proj("app")])
      stub_method(Tmux, :kill_all, ->(*) { [] }) do
        stub_method(sb, :confirm, ->(*) { true }) do
          refute sb.send(:handle, "q"), "a confirmed q exits the loop"
        end
      end
    end

    # A stop-token (a confirmed q) must END the buffer loop — a key buffered after
    # it must NOT dispatch, so a fast `qd` can't fall through into delete.
    def test_handle_stops_at_a_stop_token_and_skips_the_rest
      sb = sidebar(nodes: [proj("app")])
      deleted = false
      stub_method(Tmux, :kill_all, ->(*) { [] }) do
        stub_method(sb, :confirm, ->(*) { true }) do
          stub_method(sb, :delete, ->(*) { deleted = true }) do
            refute sb.send(:handle, "qd"), "the stop-token still exits the loop"
          end
        end
      end
      refute deleted, "a key buffered after a confirmed q must not dispatch"
    end

    def test_locate_marks_the_workspace_the_pane_sits_in
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a"), ws("b", path: "/wt/b")])
      stub_method(Tmux, :pane_path, ->(_pane) { "/wt/b/sub" }) do
        sb.send(:locate)
      end
      assert_equal "/wt/b", sb.instance_variable_get(:@current_path)
    end

    # --- cursor follows "you are here" ---------------------------------------
    # Returning to the sidebar selects the workspace the session is in, not
    # wherever the cursor last sat (cursor_to_current). Edge-triggered on
    # focus-in / first paint, so it never fights j/k while you navigate.

    def test_cursor_to_current_lands_on_the_current_workspace
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a"), ws("b", path: "/wt/b")],
                   cursor: 0, current_path: "/wt/b")
      sb.send(:cursor_to_current)
      assert_equal 2, cursor_of(sb), "the cursor snaps to the workspace we're in"
    end

    def test_cursor_to_current_is_a_noop_at_home
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a")], cursor: 1, current_path: nil)
      sb.send(:cursor_to_current)
      assert_equal 1, cursor_of(sb), "no current workspace (home) -> leave the cursor put"
    end

    # A collapsed project hides its workspace rows, so there's no row to select —
    # leave the cursor where it is rather than jumping it somewhere arbitrary.
    def test_cursor_to_current_leaves_the_cursor_when_the_row_is_hidden
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a")], collapsed: ["app"],
                   cursor: 0, current_path: "/wt/a")
      sb.send(:cursor_to_current)
      assert_equal 0, cursor_of(sb), "a hidden (collapsed) workspace row can't be selected"
    end

    # The headline behavior: refocusing the sidebar selects "here". @visible is
    # already true so focus_in won't reload — just the cursor snap is exercised.
    def test_focus_in_selects_the_current_workspace
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a"), ws("b", path: "/wt/b")],
                   cursor: 1, current_path: "/wt/b", focused: false)
      sb.instance_variable_set(:@visible, true)
      sb.send(:dispatch, "\e[I")
      assert_equal 2, cursor_of(sb), "going back to the sidebar lands on the workspace we're in"
    end

    # --- bold until viewed (attention markers) -------------------------------
    # The edge-side marking lives in Edges (sidebar_edges_test.rb); what stays
    # here is the sidebar's half: locate clears the viewed workspace's bold, and
    # render bolds a marked row. The markers are real files in the sandbox, so
    # the canonicalization runs for real.

    # Viewing a workspace clears its bold immediately — on disk AND in the
    # in-memory set, so the un-bold shows this frame, not on the next scan.
    def test_locate_clears_the_viewed_workspaces_attention
      w = real_dir("w")
      Attention.mark(w)
      sb = sidebar(nodes: [proj("app"), ws("w", path: w)], attention: [w])
      sb.instance_variable_set(:@visible, true) # clearing bold means "viewing" — only on screen
      stub_method(Tmux, :pane_path, ->(_pane) { w }) do
        sb.send(:locate)
      end
      refute_includes sb.instance_variable_get(:@attention), w, "cleared from memory this frame"
      assert_empty Attention.marked([w]), "and cleared on disk"
    end












    # --- completion twinkle (the visual twin of the sound) -------------------
    # The deadline mechanics live in Edges (sidebar_edges_test.rb); here: the
    # sidebar's pulsing? rides the delegated sparkling? so an active twinkle
    # keeps the loop animating.

    def test_pulsing_wakes_for_an_active_sparkle_on_an_otherwise_steady_done
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a")], agents: { "/wt/a" => :done })
      sb.instance_variable_set(:@visible, true)
      sb.instance_variable_set(:@visible_rows, rows_of(sb))
      refute sb.send(:pulsing?), ":done alone is steady — the pane sleeps"

      sb.instance_variable_get(:@edges).send(:sparkle_for, ["/wt/a"], { "/wt/a" => :done })
      assert sb.send(:pulsing?), "an active sparkle keeps the loop animating until it settles"
    end





    # --- reconcile_on_launch (issue #7) --------------------------------------

    def test_reconcile_on_launch_prunes_with_the_sidebar_config
      sb = sidebar
      cfg = sb.instance_variable_get(:@config)
      got = :unset
      stub_method(Reconcile, :prune, ->(c, **) { got = c; nil }) do
        sb.send(:reconcile_on_launch)
      end
      assert_same cfg, got, "reconcile_on_launch passes the sidebar's @config to prune"
    end

    def test_reconcile_on_launch_swallows_errors
      sb = sidebar
      stub_method(Reconcile, :prune, ->(*) { raise "tmux exploded" }) do
        assert_nil sb.send(:reconcile_on_launch), "a prune failure must never crash the sidebar"
      end
    end

    # --- session-switch poke throttle (reload storm) -------------------------

    def test_reload_due_initially_then_throttled_then_due_again
      sb = sidebar
      assert sb.send(:reload_due?), "first reload (no prior) is always due"
      sb.instance_variable_set(:@last_reload, sb.send(:monotonic))
      refute sb.send(:reload_due?), "a reload within POKE_TTL is throttled"
      sb.instance_variable_set(:@last_reload, sb.send(:monotonic) - Sidebar::POKE_TTL - 1)
      assert sb.send(:reload_due?), "after the window it's due again"
    end

    # Resuming several sessions at once pokes each sidebar in quick succession;
    # the heavy git+capture-pane reload must fire at most once per POKE_TTL.
    def test_rapid_switch_pokes_coalesce_into_one_reload
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a")])
      reloads = 0
      sb.define_singleton_method(:reload) { |announce_sounds: true| reloads += 1; @last_reload = monotonic }
      sb.define_singleton_method(:locate) { nil }            # neutralize the tmux call
      sb.define_singleton_method(:maybe_refresh_prs) { |*| nil }
      stub_method(Tmux, :visible?, ->(*) { true }) do        # poked while on screen (session switch-in)
        sb.send(:reload_and_refresh) # due -> reloads
        sb.send(:reload_and_refresh) # within POKE_TTL -> locate only, no reload
        sb.send(:reload_and_refresh)
      end
      assert_equal 1, reloads, "rapid switch pokes coalesce into a single heavy reload"
    end

    # The switch-in poke is a catch-up: it must reload SILENTLY so stale
    # completions don't re-ring as you move between sessions (sound-chorus).
    def test_switch_poke_reloads_without_announcing_sounds
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a")])
      announced = :unset
      sb.define_singleton_method(:reload) { |announce_sounds: true| announced = announce_sounds; @last_reload = monotonic }
      sb.define_singleton_method(:locate) { nil }
      sb.define_singleton_method(:maybe_refresh_prs) { |*| nil }
      stub_method(Tmux, :visible?, ->(*) { true }) do
        sb.send(:reload_and_refresh)
      end
      refute announced, "a switch-in re-baselines silently, not ringing prior completions"
    end

    def test_poke_reloads_again_once_the_window_passes
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a")])
      reloads = 0
      sb.define_singleton_method(:reload) { |announce_sounds: true| reloads += 1; @last_reload = monotonic }
      sb.define_singleton_method(:locate) { nil }
      sb.define_singleton_method(:maybe_refresh_prs) { |*| nil }
      stub_method(Tmux, :visible?, ->(*) { true }) do
        sb.send(:reload_and_refresh)                                    # reload #1
        sb.instance_variable_set(:@last_reload, sb.send(:monotonic) - Sidebar::POKE_TTL - 1)
        sb.send(:reload_and_refresh)                                    # window passed -> reload #2
      end
      assert_equal 2, reloads
    end

    # --- tick: the catch-up vs continuous reload split (sound-chorus) ----------
    # tick is the headline entry point: switching INTO a session reappears its
    # sidebar (off-screen -> on-screen), and that reload must be SILENT. A
    # continuously-visible tick stays loud. Tmux.visible?/focused? are stubbed —
    # the raw tmux calls stay out of scope, the branch decision is what we pin.

    def test_tick_reappearing_from_offscreen_reloads_silently
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a")])
      sb.instance_variable_set(:@visible, false) # was off-screen, baseline frozen
      announced = :unset
      sb.define_singleton_method(:reload) { |announce_sounds: true| announced = announce_sounds }
      stub_method(Tmux, :focused?, ->(*) { false }) do
        stub_method(Tmux, :visible?, ->(*) { true }) do # now back on screen
          sb.send(:tick)
        end
      end
      refute announced, "reappearing re-baselines silently — stale completions don't re-ring"
      assert sb.instance_variable_get(:@visible), "tick records that we're now visible"
    end

    def test_tick_while_continuously_visible_keeps_ringing
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a")])
      sb.instance_variable_set(:@visible, true) # already on screen, never slept
      sb.instance_variable_set(:@ticks, 0)          # < TREE_TICKS -> refresh_agents path
      announce = :unset
      sb.define_singleton_method(:pin_width) { nil }
      sb.define_singleton_method(:refresh_agents) { |announce_sounds: true| announce = announce_sounds }
      stub_method(Tmux, :focused?, ->(*) { true }) do
        stub_method(Tmux, :visible?, ->(*) { true }) do
          sb.send(:tick)
        end
      end
      assert announce, "a live, continuously-visible scan still announces completions"
    end

    # --- off-screen pre-warm (prewarm) ----------------------------------------
    # An off-screen sidebar keeps its pane buffer warm (warm_reload + render) so a
    # later switch-in shows fresh content with no flash — but only when prewarm is
    # on, WARM_TTL has elapsed, and the change-gate fingerprint actually moved.
    # warm_reload/render are stubbed; the branch DECISION in tick is what we pin.

    # Drive an off-screen tick with the three warm inputs controlled. Returns
    # [warmed, rendered] counts. owns_pane? is true (no @pane_tty); window_panes≠1.
    def offscreen_tick(sb)
      warmed = rendered = 0
      sb.define_singleton_method(:warm_reload) { |_fp| warmed += 1 }
      sb.define_singleton_method(:render) { rendered += 1 }
      stub_method(Tmux, :focused?, ->(*) { false }) do
        stub_method(Tmux, :visible?, ->(*) { false }) do
          stub_method(Tmux, :window_panes, ->(*) { 2 }) do
            sb.send(:tick)
          end
        end
      end
      [warmed, rendered]
    end

    def offscreen_sidebar(warm_fp: "NEW", baseline: "OLD", last_warm: nil, prewarm: true)
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a")])
      sb.instance_variable_set(:@visible, false)
      sb.instance_variable_set(:@warm_fp, baseline)
      sb.instance_variable_set(:@last_warm, last_warm)
      sb.define_singleton_method(:warm_fingerprint) { warm_fp }
      sb.instance_variable_get(:@config).define_singleton_method(:prewarm?) { prewarm }
      sb
    end

    def test_offscreen_tick_warms_when_prewarm_on_ttl_elapsed_and_fingerprint_changed
      warmed, rendered = offscreen_tick(offscreen_sidebar(warm_fp: "NEW", baseline: "OLD", last_warm: nil))
      assert_equal 1, warmed, "off-screen + prewarm + WARM_TTL elapsed + changed -> one warm_reload"
      assert_equal 1, rendered, "...and one render to paint the off-screen buffer"
    end

    def test_offscreen_tick_skips_warm_when_fingerprint_unchanged
      warmed, = offscreen_tick(offscreen_sidebar(warm_fp: "SAME", baseline: "SAME", last_warm: nil))
      assert_equal 0, warmed, "nothing we draw changed -> stay dormant, no warm reload"
    end

    def test_offscreen_tick_skips_warm_within_warm_ttl
      # last_warm = now: WARM_TTL has NOT elapsed, so a change still doesn't warm yet.
      sb = offscreen_sidebar(warm_fp: "NEW", baseline: "OLD")
      sb.instance_variable_set(:@last_warm, sb.send(:monotonic))
      warmed, = offscreen_tick(sb)
      assert_equal 0, warmed, "WARM_TTL bounds the cadence — a recent warm short-circuits the next"
    end

    def test_offscreen_tick_skips_warm_when_prewarm_disabled
      warmed, = offscreen_tick(offscreen_sidebar(warm_fp: "NEW", baseline: "OLD", prewarm: false))
      assert_equal 0, warmed, "prewarm: false restores full dormancy — no off-screen work"
    end

    # warm_reload RUNS locate (so the warm frame carries the » "you are here" marker
    # and matches the switch-in frame — else every switch-in adds the marker and
    # flashes). But locate's attention-clear is @visible-gated, so an off-screen warm
    # sets @current_path without erasing bold you haven't seen yet.
    def test_warm_reload_runs_locate_for_marker_but_keeps_bold_off_screen
      Dir.mktmpdir do |wt|
        sb = sidebar(nodes: [proj("app"), ws("a", path: wt)])
        sb.instance_variable_set(:@visible, false) # off screen
        sb.define_singleton_method(:rebuild) { nil } # isolate from Model/git
        sb.define_singleton_method(:refresh_diffs) { nil }
        Attention.mark(wt)
        assert_includes Attention.scan, File.realpath(wt), "precondition: workspace is bold"
        stub_method(Tmux, :pane_path, ->(_) { wt }) do # locate resolves the current workspace
          sb.send(:warm_reload, "fp")
        end
        assert_equal wt, sb.instance_variable_get(:@current_path),
                     "warm runs locate so the warm frame carries the » marker (no switch-in flash)"
        assert_includes Attention.scan, File.realpath(wt),
                        "...but the @visible-gated clear means it must NOT erase bold off screen"
      end
    end

    # The locate @visible gate directly: off screen it sets @current_path (for the
    # marker) but keeps bold; on screen (actually viewing) it clears bold.
    def test_locate_clears_attention_only_when_visible
      Dir.mktmpdir do |wt|
        sb = sidebar(nodes: [proj("app"), ws("a", path: wt)])
        Attention.mark(wt)
        stub_method(Tmux, :pane_path, ->(_) { wt }) do
          sb.instance_variable_set(:@visible, false)
          sb.send(:locate)
          assert_equal wt, sb.instance_variable_get(:@current_path), "locate still resolves the workspace off screen"
          assert_includes Attention.scan, File.realpath(wt), "off screen: bold kept (not viewing)"
          sb.instance_variable_set(:@visible, true)
          sb.send(:locate)
          refute_includes Attention.scan, File.realpath(wt), "on screen (viewing): bold cleared"
        end
      end
    end

    # warm must stamp its own clock, never @last_reload — else a warm within POKE_TTL
    # of a switch-in would make reload_and_refresh skip its (warm-suppressed) PR refresh.
    def test_warm_reload_does_not_stamp_the_switch_in_throttle
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a")])
      sb.define_singleton_method(:rebuild) { nil }
      sb.define_singleton_method(:locate) { nil }
      sb.define_singleton_method(:refresh_diffs) { nil }
      sb.instance_variable_set(:@last_reload, nil)
      sb.send(:warm_reload, "fp")
      assert_nil sb.instance_variable_get(:@last_reload), "warm must not stamp the switch-in reload throttle"
      assert sb.send(:reload_due?), "...so a switch-in right after a warm still does its full reload + PR refresh"
      refute_nil sb.instance_variable_get(:@last_warm), "warm stamps its own @last_warm clock instead"
    end

    # The refresh_prs:false / announce_sounds:false plumbing itself is pinned in
    # sidebar_edges_test.rb (on_scan owns it); what stays here is that warm_reload
    # passes the quiet flags through refresh_agents at all (the tests around this
    # one drive the real path).

    def test_warm_reload_scans_hooks_only_skipping_process_fallback
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a")])
      sb.define_singleton_method(:rebuild) { nil }
      sb.define_singleton_method(:locate) { nil }
      sb.define_singleton_method(:refresh_diffs) { nil }
      stub_method(Agents, :active, ->(*) { flunk "warm must scan hooks-only — no tmux/pgrep/lsof fallback" }) do
        sb.send(:warm_reload, "fp")
      end
    end

    # Race guard (the stale-stuck bug): warm_reload must stamp the fingerprint the
    # CALLER measured before the scan — never a fresh one taken after — so a change
    # landing mid-warm leaves the baseline behind and the next tick re-warms.
    def test_warm_reload_stamps_the_passed_fingerprint_not_a_fresh_one
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a")])
      sb.define_singleton_method(:rebuild) { nil }
      sb.define_singleton_method(:locate) { nil }
      sb.define_singleton_method(:refresh_diffs) { nil }
      # If warm_reload ignored its arg and re-measured, it'd stamp "AFTER" and the
      # gate would think it's caught up; stamping the passed "BEFORE" keeps it honest.
      sb.define_singleton_method(:warm_fingerprint) { "AFTER" }
      sb.send(:warm_reload, "BEFORE")
      assert_equal "BEFORE", sb.instance_variable_get(:@warm_fp),
                   "warm stamps the pre-scan fingerprint, so a mid-warm change re-fires next tick"
    end

    # --- shared view-state propagation (collapse/fold/header repaint other sidebars) ---
    # Toggling shared view-state broadcasts a warm poke so OTHER (off-screen) sidebars
    # repaint the new state immediately — the fix for "collapse then switch still flashes".


    # The fingerprint backstop: shared view-state now moves the warm fingerprint, so
    # even a missed broadcast is caught by the next lazy warm tick.
    def test_warm_fingerprint_tracks_shared_view_state
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a")])
      base = sb.send(:warm_fingerprint)
      Collapse.collapse("app")
      refute_equal base, sb.send(:warm_fingerprint), "a project collapse moves the warm fingerprint"
      after_collapse = sb.send(:warm_fingerprint)
      FullHeader.enable
      refute_equal after_collapse, sb.send(:warm_fingerprint), "a full-header toggle moves it too"
    end

    # warm_poke (the C-w broadcast handler): off screen -> warm_reload + render;
    # on screen -> silent reload + render; prewarm:false off screen -> nothing.
    def test_warm_poke_offscreen_warm_reloads_and_renders
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a")])
      sb.instance_variable_set(:@visible, false)
      warmed = rendered = 0
      sb.define_singleton_method(:warm_reload) { |_fp| warmed += 1; true }
      sb.define_singleton_method(:render) { rendered += 1 }
      sb.send(:warm_poke)
      assert_equal 1, warmed, "off screen: paint the new view-state into the buffer"
      assert_equal 1, rendered
    end

    def test_warm_poke_visible_reloads_and_renders
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a")])
      sb.instance_variable_set(:@visible, true)
      reloaded = rendered = 0
      sb.define_singleton_method(:reload) { |announce_sounds: true| reloaded += 1 }
      sb.define_singleton_method(:render) { rendered += 1 }
      sb.send(:warm_poke)
      assert_equal 1, reloaded, "on screen: a silent reload shows the change immediately"
      assert_equal 1, rendered
    end

    def test_warm_poke_offscreen_respects_prewarm_off
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a")])
      sb.instance_variable_set(:@visible, false)
      sb.instance_variable_get(:@config).define_singleton_method(:prewarm?) { false }
      warmed = 0
      sb.define_singleton_method(:warm_reload) { |_fp| warmed += 1; true }
      sb.send(:warm_poke)
      assert_equal 0, warmed, "prewarm:false -> a warm poke does no off-screen work"
    end

    # --- visibility-aware loop (off-screen dormancy) --------------------------
    # @visible is the single on-screen flag: it gates render + pulse, and the poke
    # path re-samples it because C-l is overloaded (session switch-in vs background
    # PR-refresh to a pane we may have navigated away from).

    # The background PR-refresh poke can land on an OFF-screen pane (it's built to
    # survive navigation). A hidden poke must not reload or mark the pane visible —
    # that would reintroduce the off-screen work the whole change removes.
    def test_reload_and_refresh_skips_a_hidden_pane
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a")])
      reloads = 0
      sb.define_singleton_method(:reload) { |announce_sounds: true| reloads += 1 }
      sb.define_singleton_method(:locate) { nil }
      stub_method(Tmux, :visible?, ->(*) { false }) do
        sb.send(:reload_and_refresh)
      end
      assert_equal 0, reloads, "a poke to a hidden pane never reloads"
      refute sb.instance_variable_get(:@visible), "...and never marks the hidden pane visible"
    end

    def test_reload_and_refresh_marks_a_visible_poke_on_screen
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a")])
      sb.instance_variable_set(:@visible, false)
      sb.define_singleton_method(:reload) { |announce_sounds: true| @last_reload = monotonic }
      sb.define_singleton_method(:locate) { nil }
      sb.define_singleton_method(:maybe_refresh_prs) { |*| nil }
      stub_method(Tmux, :visible?, ->(*) { true }) do
        sb.send(:reload_and_refresh)
      end
      assert sb.instance_variable_get(:@visible), "a session switch-in poke marks the pane visible"
    end

    # Dedup: a poke switch-in already set @visible=true and reloaded, so the next
    # tick must NOT reload again. The off->on edge is consumed by the flag itself,
    # not a POKE_TTL window (POKE_TTL < REFRESH, so a window-based guard was racy).
    def test_tick_does_not_double_reload_after_a_poke
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a")])
      sb.instance_variable_set(:@visible, true) # poke already marked us visible
      sb.instance_variable_set(:@ticks, 0)
      reloads = 0
      sb.define_singleton_method(:reload) { |announce_sounds: true| reloads += 1 }
      sb.define_singleton_method(:pin_if_resized) { nil }
      sb.define_singleton_method(:refresh_agents) { |announce_sounds: true| nil }
      stub_method(Tmux, :focused?, ->(*) { true }) do
        stub_method(Tmux, :visible?, ->(*) { true }) do
          sb.send(:tick)
        end
      end
      assert_equal 0, reloads, "no catch-up reload when the poke already consumed the off->on edge"
    end

    # Off screen, tick must not spend a tmux call on focused? — that's half a dormant
    # pane's per-tick cost. focused? is short-circuited behind the visibility sample.
    def test_tick_skips_the_focused_shellout_when_offscreen
      sb = sidebar(nodes: [proj("app")])
      sb.instance_variable_set(:@visible, false)
      called = false
      stub_method(Tmux, :focused?, ->(*) { called = true; true }) do
        stub_method(Tmux, :visible?, ->(*) { false }) do
          sb.send(:tick)
        end
      end
      refute called, "off screen, tick must not call focused?"
      refute sb.instance_variable_get(:@focused), "off screen is never focused"
    end

    def test_frame_timeout_pulse_refresh_idle
      sb = sidebar(nodes: [ws("a", path: "/wt/a")], agents: { "/wt/a" => :thinking })
      sb.instance_variable_set(:@visible_rows, rows_of(sb))
      sb.instance_variable_set(:@visible, false)
      assert_equal Sidebar::IDLE, sb.send(:frame_timeout), "off screen sleeps on the long IDLE backstop"
      sb.instance_variable_set(:@visible, true)
      assert_equal Sidebar::PULSE, sb.send(:frame_timeout), "visible + a thinking dot pulses fast"
      sb.instance_variable_set(:@agents, { "/wt/a" => :done })
      assert_equal Sidebar::REFRESH, sb.send(:frame_timeout), "visible + a steady dot sits on REFRESH"
    end

    def test_recheck_visibility_samples_the_pane
      sb = sidebar
      sb.instance_variable_set(:@visible, true)
      stub_method(Tmux, :visible?, ->(*) { false }) do
        sb.send(:recheck_visibility)
      end
      refute sb.instance_variable_get(:@visible), "recheck flips @visible off when the pane left the screen"
    end

    def test_vis_poll_due_throttles
      sb = sidebar
      assert sb.send(:vis_poll_due?), "first visibility re-check is always due"
      refute sb.send(:vis_poll_due?), "...then throttled within VIS_POLL"
    end

    def test_focus_in_marks_visible_focused_and_catches_up_when_reappearing
      sb = sidebar(focused: false)
      sb.instance_variable_set(:@visible, false)
      reloads = 0
      sb.define_singleton_method(:reload) { |announce_sounds: true| reloads += 1 }
      sb.send(:dispatch, "\e[I")
      assert sb.instance_variable_get(:@visible), "focus-in proves the pane is on screen"
      assert sb.instance_variable_get(:@focused), "focus-in lights the cursor bar"
      assert_equal 1, reloads, "focus-in on a hidden pane (un-poked reappearance) silently catches up"
    end

    # focus-in on an already-visible pane is just a cursor-bar change — it must NOT
    # reload (the off->on edge isn't there), or every click into the tree would rescan.
    def test_focus_in_when_already_visible_does_not_reload
      sb = sidebar(focused: false)
      sb.instance_variable_set(:@visible, true)
      reloads = 0
      sb.define_singleton_method(:reload) { |announce_sounds: true| reloads += 1 }
      sb.send(:dispatch, "\e[I")
      assert_equal 0, reloads, "no reload when the pane was already on screen"
    end

    def test_pin_if_resized_pins_only_when_geometry_changes
      sb = sidebar
      pins = 0
      sb.define_singleton_method(:winsize) { [50, 40] }
      sb.define_singleton_method(:pin_width) { pins += 1; true }
      sb.send(:pin_if_resized) # @geom nil -> changed -> pin
      sb.send(:pin_if_resized) # same size -> no pin
      assert_equal 1, pins, "re-pins only when winsize differs from the cached geometry"
      sb.define_singleton_method(:winsize) { [50, 60] } # client resized
      sb.send(:pin_if_resized)
      assert_equal 2, pins, "a real geometry change re-pins"
    end

    # A failed pin (resize-pane errored, or tmux can't satisfy the width) must NOT
    # cache the drifted geometry, or we'd never retry.
    def test_pin_if_resized_does_not_cache_on_failure
      sb = sidebar
      attempts = 0
      sb.define_singleton_method(:winsize) { [50, 40] }
      sb.define_singleton_method(:pin_width) { attempts += 1; false }
      sb.send(:pin_if_resized)
      sb.send(:pin_if_resized)
      assert_equal 2, attempts, "a failed pin retries next tick instead of poisoning the cache"
    end

    # --- pane ownership: exit an orphaned sidebar (duplicate-sound fix) --------
    # tmux recycles %ids, so a sidebar that outlives its pane (the loop never died)
    # can have ENV["TMUX_PANE"] come to name a DIFFERENT, live pane. Left running it
    # reads that pane's visibility and rings completions in parallel with the real
    # owner — duplicate sounds. owns_pane? compares the pane's current pty against the
    # one captured at startup; tick returns false (→ loop exits) once they diverge.

    def test_tick_exits_when_pane_id_was_recycled_onto_another_pane
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a")])
      sb.instance_variable_set(:@pane_tty, "/dev/ttys007") # the pty we started on
      announced = false
      sb.define_singleton_method(:refresh_agents) { |announce_sounds: true| announced = true }
      # tmux now reports a different tty for our %id — it was handed to a new pane
      stub_method(Tmux, :pane_tty, ->(*) { "/dev/ttys099" }) do
        refute sb.send(:tick), "a recycled-id orphan asks the loop to exit"
      end
      refute announced, "...and never runs an announcing scan (no duplicate ring)"
    end

    # A nil pane_tty is ambiguous — pane gone OR a transient display-message failure —
    # so owns_pane? must NOT exit on it (that would self-terminate a healthy sidebar
    # whenever a tmux shell-out flakes). A dead-but-not-recycled pane reads visible?
    # false (silent), and gets reaped on a CONFIRMED tty mismatch once its id recycles.
    def test_tick_does_not_exit_on_a_nil_pane_tty
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a")])
      sb.instance_variable_set(:@pane_tty, "/dev/ttys007")
      sb.instance_variable_set(:@visible, false)
      stub_method(Tmux, :pane_tty, ->(*) { nil }) do # transient miss / pane gone, not recycled
        stub_method(Tmux, :focused?, ->(*) { false }) do
          stub_method(Tmux, :visible?, ->(*) { false }) do
            assert sb.send(:tick), "nil pane_tty is not proof of disownership — keep running"
          end
        end
      end
    end

    def test_tick_keeps_running_while_it_still_owns_its_pane
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a")])
      sb.instance_variable_set(:@pane_tty, "/dev/ttys007")
      sb.instance_variable_set(:@visible, true)
      sb.instance_variable_set(:@ticks, 0)
      sb.define_singleton_method(:pin_if_resized) { nil }
      sb.define_singleton_method(:refresh_agents) { |announce_sounds: true| nil }
      stub_method(Tmux, :pane_tty, ->(*) { "/dev/ttys007" }) do # still our pty
        stub_method(Tmux, :focused?, ->(*) { true }) do
          stub_method(Tmux, :visible?, ->(*) { true }) do
            assert sb.send(:tick), "the real owner keeps ticking"
          end
        end
      end
    end

    # No startup tty (launched outside tmux, or a unit test) ⇒ ownership is a no-op
    # and we never shell out to tmux to second-guess it.
    def test_tick_without_a_captured_pane_tty_never_self_exits
      sb = sidebar(nodes: [proj("app")])
      sb.instance_variable_set(:@visible, false)
      called = false
      stub_method(Tmux, :pane_tty, ->(*) { called = true; nil }) do
        stub_method(Tmux, :visible?, ->(*) { false }) do
          assert sb.send(:tick), "no captured pty -> tick never asks to exit"
        end
      end
      refute called, "owns_pane? short-circuits without a tmux call when @pane_tty is nil"
    end

    # #64: when the work pane closes, the sidebar is left the SOLE pane and tmux wedges it
    # full-width. The lone-pane check catches "alive but my sibling died" — a confirmed
    # window_panes == 1. From a workspace it falls home and asks the loop to exit (so the
    # wedged window closes); from home it self-heals in place (spawns a work shell) and
    # keeps running (the anchor survives). Acts ONLY on a confirmed 1, like owns_pane?.

    def test_tick_falls_home_and_exits_when_a_visible_workspace_sidebar_is_the_lone_pane
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a")]) # @home defaults to nil (a workspace)
      went_home = false
      stub_method(Tmux, :window_panes, ->(*) { 1 }) do # confirmed sole pane
        stub_method(Tmux, :visible?, ->(*) { true }) do # on screen -> falling home is the right move
          stub_method(Tmux, :go_home, -> { went_home = true }) do
            stub_method(Tmux, :ensure_work_pane, ->(*) { flunk "a workspace falls home, it does not self-heal in place" }) do
              refute sb.send(:tick), "a lone workspace sidebar asks the loop to exit"
            end
          end
        end
      end
      assert went_home, "...and falls home first so you land on the navigator"
    end

    # An OFF-SCREEN lone workspace sidebar must NOT fall home: go_home switch-clients the whole
    # client, so reaping from an off-screen pane would yank the user off the window they're
    # actually working in. It stays put and is reaped by focus-in when you switch back to it.
    def test_tick_does_not_yank_an_off_screen_lone_workspace_sidebar_home
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a")])
      sb.instance_variable_set(:@visible, false)
      stub_method(Tmux, :window_panes, ->(*) { 1 }) do # lone...
        stub_method(Tmux, :visible?, ->(*) { false }) do # ...but off screen
          stub_method(Tmux, :go_home, -> { flunk "an off-screen lone sidebar must not switch-client the user away" }) do
            assert sb.send(:tick), "off-screen lone workspace sidebar keeps running (focus-in reaps it on return)"
          end
        end
      end
    end

    def test_tick_self_heals_home_and_keeps_running_when_home_is_the_lone_pane
      sb = sidebar(nodes: [proj("app")])
      sb.instance_variable_set(:@home, true)   # this is home's sidebar
      sb.instance_variable_set(:@visible, false)
      healed = false
      stub_method(Tmux, :window_panes, ->(*) { 1 }) do
        stub_method(Tmux, :ensure_work_pane, ->(*) { healed = true }) do
          stub_method(Tmux, :go_home, -> { flunk "home self-heals in place — it never falls home into itself" }) do
            stub_method(Tmux, :visible?, ->(*) { false }) do
              assert sb.send(:tick), "home's lone sidebar keeps running (the anchor survives)"
            end
          end
        end
      end
      assert healed, "...after re-growing a work shell beside the tree"
    end

    def test_tick_keeps_running_on_a_transient_window_panes_miss
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a")])
      sb.instance_variable_set(:@visible, false)
      stub_method(Tmux, :window_panes, ->(*) { nil }) do # unknown != confirmed-1
        stub_method(Tmux, :go_home, -> { flunk "a nil count is not proof of a lone pane — don't fall home" }) do
          stub_method(Tmux, :visible?, ->(*) { false }) do
            assert sb.send(:tick), "a flaky window_panes keeps us running, like owns_pane?"
          end
        end
      end
    end

    def test_tick_keeps_running_when_a_work_pane_is_still_present
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a")])
      sb.instance_variable_set(:@visible, false)
      stub_method(Tmux, :window_panes, ->(*) { 2 }) do # sidebar + a live work pane
        stub_method(Tmux, :go_home, -> { flunk "two panes is not lone — keep running" }) do
          stub_method(Tmux, :visible?, ->(*) { false }) do
            assert sb.send(:tick), "a window with a work pane is healthy"
          end
        end
      end
    end

    # Focus-in is the FAST reap (#64): when the work pane closes the sidebar gains focus
    # (it became the active pane), so tmux sends focus-in. Catching the lone pane here
    # closes the wedge within a frame instead of up to one REFRESH tick.
    def test_focus_in_signals_loop_exit_when_the_work_sibling_just_closed
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a")])
      sb.instance_variable_set(:@visible, true) # already on screen -> focus_in won't reload
      went_home = false
      stub_method(Tmux, :window_panes, ->(*) { 1 }) do
        stub_method(Tmux, :visible?, ->(*) { true }) do # focus-in means we're on screen
          stub_method(Tmux, :go_home, -> { went_home = true }) do
            refute sb.send(:dispatch, "\e[I"), "a lone-pane focus-in tells the loop to exit"
          end
        end
      end
      assert went_home
    end

    def test_focus_in_is_a_normal_keep_running_focus_when_a_work_pane_remains
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a")])
      sb.instance_variable_set(:@visible, true)
      stub_method(Tmux, :window_panes, ->(*) { 2 }) do
        stub_method(Tmux, :go_home, -> { flunk "an ordinary focus-in must not fall home" }) do
          assert sb.send(:dispatch, "\e[I"), "navigating back to the sidebar keeps running"
        end
      end
    end

    # read_key separates a closed pane (EOF) from a spurious wakeup (nothing ready):
    # the run loop turns :eof into a clean exit so a dead pane can't busy-spin forever.
    def test_read_key_signals_eof_when_the_stream_is_closed
      sb = Sidebar.new
      r, w = IO.pipe
      w.close # reader is now at end-of-stream
      with_stdin(r) { assert_equal :eof, sb.send(:read_key) }
    ensure
      r.close
    end

    def test_read_key_is_nil_when_nothing_is_ready
      sb = Sidebar.new
      r, w = IO.pipe # open + empty -> read_nonblock raises WaitReadable
      with_stdin(r) { assert_nil sb.send(:read_key) }
    ensure
      r.close
      w.close
    end


    # --- pulsing?: animate only for thinking/waiting dots actually on screen ----

    def test_pulsing_wakes_for_thinking_or_waiting
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a")], agents: { "/wt/a" => :thinking })
      sb.instance_variable_set(:@visible, true)
      sb.instance_variable_set(:@visible_rows, rows_of(sb))
      assert sb.send(:pulsing?), "a visible thinking dot pulses"

      sb.instance_variable_set(:@agents, { "/wt/a" => :waiting })
      assert sb.send(:pulsing?), "a visible waiting dot pulses (the blink)"

      sb.instance_variable_set(:@agents, { "/wt/a" => :done })
      refute sb.send(:pulsing?), "a done dot is steady — no pulse"
    end

    def test_pulsing_ignores_offscreen_agents
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a"), ws("b", path: "/wt/b")],
                   agents: { "/wt/b" => :thinking })
      sb.instance_variable_set(:@visible, true)
      on_screen = ->(p) { rows_of(sb).select { |n| n.path == p } }

      sb.instance_variable_set(:@visible_rows, on_screen.call("/wt/a"))
      refute sb.send(:pulsing?), "a thinking dot scrolled off screen doesn't pulse"

      sb.instance_variable_set(:@visible_rows, on_screen.call("/wt/b"))
      assert sb.send(:pulsing?), "...but it pulses once it's on screen"
    end

    def test_pulsing_is_false_when_pane_hidden
      sb = sidebar(nodes: [ws("a", path: "/wt/a")], agents: { "/wt/a" => :thinking })
      sb.instance_variable_set(:@visible_rows, rows_of(sb))
      sb.instance_variable_set(:@visible, false)
      refute sb.send(:pulsing?), "a hidden pane never pulses, even with a thinking dot"
    end




  end
end
