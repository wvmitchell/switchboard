# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/sidebar_case"

module Switchboard
  # Sidebar::Edges — the agent-edge fanout extracted in #57. The subtlest
  # invariants of the whole sidebar live here, now testable without
  # constructing a Sidebar at all: which transitions count as a completion
  # (completion_edges), the sticky ensure-merged baseline, the announce_sounds
  # catch-up gate, the monitored-:done suppression, the sparkle deadlines, and
  # the per-project PR-spawn debounce. Sidebar-side integration (the delegator
  # seams, the returned-edges → refresh_diffs ride) stays in sidebar_test.rb.
  class SidebarEdgesTest < SidebarCase
    def edges(prev: nil)
      e = Sidebar::Edges.new
      e.instance_variable_set(:@prev_hook_states, prev) if prev
      e
    end

    # on_scan with inert defaults so each test names only what it exercises.
    def scan(e, now, nodes: [], monitoring: Set.new, config: Config.new,
             current_path: nil, announce_sounds: true, refresh_prs: true)
      e.on_scan(now, monitoring: monitoring, nodes: nodes, config: config,
                current_path: current_path,
                announce_sounds: announce_sounds, refresh_prs: refresh_prs)
    end

    # --- completion_edges: a worktree newly at a resting state (issue #19) ----

    def test_thinking_to_done_is_an_edge
      assert_equal ["/a"], Sidebar::Edges.completion_edges({ "/a" => :thinking }, { "/a" => :done })
    end

    def test_entering_waiting_is_an_edge
      assert_equal ["/a"], Sidebar::Edges.completion_edges({ "/a" => :thinking }, { "/a" => :waiting })
    end

    def test_first_appearance_at_done_is_not_an_edge
      # A path absent from prev is the agent announcing presence (SessionStart on a
      # freshly-created workspace reports :done) — it seeds the baseline, it does
      # not ring the completion sound or spawn a PR refresh. (The post-seed
      # completion sequence is covered by the on_scan integration tests.)
      assert_empty Sidebar::Edges.completion_edges({}, { "/a" => :done })
    end

    def test_steady_done_is_not_an_edge
      assert_empty Sidebar::Edges.completion_edges({ "/a" => :done }, { "/a" => :done })
    end

    def test_returning_to_thinking_is_not_an_edge
      assert_empty Sidebar::Edges.completion_edges({ "/a" => :done }, { "/a" => :thinking })
    end

    def test_aging_out_is_not_an_edge
      assert_empty Sidebar::Edges.completion_edges({ "/a" => :done }, {})
    end

    def test_only_changed_paths_count
      prev = { "/a" => :done, "/b" => :thinking }
      now  = { "/a" => :done, "/b" => :done }
      assert_equal ["/b"], Sidebar::Edges.completion_edges(prev, now)
    end

    # --- spawn_due?: per-project debounce (issue #19) ------------------------

    def test_spawn_due_when_never_spawned
      assert Sidebar::Edges.spawn_due?(nil, 100.0)
    end

    def test_not_spawn_due_within_window
      refute Sidebar::Edges.spawn_due?(100.0, 102.0, 5)
    end

    def test_spawn_due_after_window
      assert Sidebar::Edges.spawn_due?(100.0, 106.0, 5)
    end

    def test_spawn_due_exactly_at_window
      assert Sidebar::Edges.spawn_due?(100.0, 105.0, 5)
    end

    # --- on_scan: PR refresh + sound + mark + baseline ride the same edge -----

    def test_on_scan_skips_the_first_scan
      e = edges # no baseline yet
      prs = []
      sounds = []
      e.define_singleton_method(:maybe_refresh_prs) { |p| prs << p }
      ret = nil
      stub_method(Sound, :play, ->(spec, **) { sounds << spec }) do
        ret = scan(e, { "/wt/a" => :done }, nodes: [ws("a", path: "/wt/a")])
      end
      assert_empty prs, "no baseline -> no PR refresh on first scan"
      assert_empty sounds, "no baseline -> no sound on first scan"
      assert_empty ret, "no baseline -> no edges returned (nothing for the caller's diff ride)"
      assert_equal({ "/wt/a" => :done }, e.instance_variable_get(:@prev_hook_states))
    end

    def test_on_scan_dispatches_pr_and_sound_on_an_edge
      e = edges(prev: { "/wt/a" => :thinking })
      prs = []
      sounds = []
      e.define_singleton_method(:maybe_refresh_prs) { |p| prs << p }
      ret = nil
      stub_method(Sound, :play, ->(spec, **) { sounds << spec }) do
        ret = scan(e, { "/wt/a" => :done }, nodes: [ws("a", project: "app", path: "/wt/a")])
      end
      assert_equal ["app"], prs            # PR trigger survives the extraction
      assert_equal ["train"], sounds       # :done -> default train
      assert_equal ["/wt/a"], ret, "the edge list returns so the caller can ride it (diff refresh)"
      assert_equal({ "/wt/a" => :done }, e.instance_variable_get(:@prev_hook_states))
    end

    # A catch-up scan (switch-in / reappear) must NOT ring for a completion that
    # finished while that sidebar was off-screen — another sidebar already rang it.
    # The PR refresh and the baseline advance still ride: announce_sounds gates the
    # sound alone. This is the duplicate-notification fix (sound-chorus).
    def test_on_scan_silent_catch_up_holds_the_sound_but_keeps_pr_and_baseline
      e = edges(prev: { "/wt/a" => :thinking })
      prs = []
      sounds = []
      e.define_singleton_method(:maybe_refresh_prs) { |p| prs << p }
      stub_method(Sound, :play, ->(spec, **) { sounds << spec }) do
        scan(e, { "/wt/a" => :done }, nodes: [ws("a", project: "app", path: "/wt/a")],
                                      announce_sounds: false)
      end
      assert_empty sounds, "a catch-up re-baselines silently — another sidebar already rang"
      assert_equal ["app"], prs, "...but the PR refresh still rides the edge"
      assert_equal({ "/wt/a" => :done }, e.instance_variable_get(:@prev_hook_states),
                   "baseline advances so the next genuine completion still fires")
    end

    # After a silent switch-in, a completion that lands while we're actually here
    # rings as normal — the suppression is one scan, not a permanent mute.
    def test_silent_catch_up_then_a_live_completion_rings
      e = edges(prev: { "/wt/a" => :thinking })
      e.define_singleton_method(:maybe_refresh_prs) { |_p| }
      nodes = [ws("a", project: "app", path: "/wt/a")]
      sounds = []
      stub_method(Sound, :play, ->(spec, **) { sounds << spec }) do
        scan(e, { "/wt/a" => :done }, nodes: nodes, announce_sounds: false) # switch-in: stale completion, silent
        scan(e, { "/wt/a" => :thinking }, nodes: nodes)                     # a new turn begins
        scan(e, { "/wt/a" => :done }, nodes: nodes)                         # finishes while we watch -> rings
      end
      assert_equal ["train"], sounds
    end

    # The D12.4 return-path guarantee, half one: every consumer is individually
    # rescued, so a consumer fault can't eat the edge list the caller rides for
    # its diff refresh.
    def test_on_scan_returns_edges_and_advances_baseline_even_when_sound_raises
      e = edges(prev: { "/wt/a" => :thinking })
      e.define_singleton_method(:maybe_refresh_prs) { |_p| }
      ret = nil
      stub_method(Sound, :play, ->(*) { raise "boom" }) do
        ret = scan(e, { "/wt/a" => :waiting }, nodes: [ws("a", path: "/wt/a")]) # must not raise — play_sounds_for rescues
      end
      assert_equal ["/wt/a"], ret, "a rescued consumer fault still returns the edges"
      assert_equal({ "/wt/a" => :waiting }, e.instance_variable_get(:@prev_hook_states))
    end

    # ...and half two: if something DOES raise past the fanout, the ensure still
    # advances the baseline, so the caller's broad rescue (refresh_agents blanks
    # the dots for one scan) can't corrupt the next edge diff.
    def test_on_scan_raise_past_a_consumer_still_advances_the_baseline
      e = edges(prev: { "/wt/a" => :thinking })
      e.define_singleton_method(:refresh_prs_for) { |*| raise "boom" }
      assert_raises(RuntimeError) do
        scan(e, { "/wt/a" => :done }, nodes: [ws("a", path: "/wt/a")])
      end
      assert_equal({ "/wt/a" => :done }, e.instance_variable_get(:@prev_hook_states),
                   "the ensure advances the baseline even when the fanout raises")
    end

    def test_completion_fires_after_a_worktree_ages_out_and_returns
      # A tool running longer than PRESENCE_TTL ages the :thinking report out of
      # the live scan; then Stop reports :done. The sticky baseline keeps
      # :thinking, so the completion still fires — not mistaken for a first
      # appearance and swallowed.
      e = edges
      e.define_singleton_method(:maybe_refresh_prs) { |_p| }
      nodes = [ws("a", project: "app", path: "/wt/a")]
      sounds = []
      stub_method(Sound, :play, ->(spec, **) { sounds << spec }) do
        scan(e, { "/wt/a" => :thinking }, nodes: nodes) # seen thinking
        scan(e, {},                       nodes: nodes) # aged out of scan
        scan(e, { "/wt/a" => :done },     nodes: nodes) # completes
      end
      assert_equal ["train"], sounds
    end

    def test_restarted_session_after_aging_out_stays_silent
      # First appearance at :done (SessionStart) is silent and seeds the baseline.
      # After it ages out, a NEW session's SessionStart :done matches the
      # remembered :done — a non-change, so no spurious sound.
      e = edges
      e.define_singleton_method(:maybe_refresh_prs) { |_p| }
      nodes = [ws("a", project: "app", path: "/wt/a")]
      sounds = []
      stub_method(Sound, :play, ->(spec, **) { sounds << spec }) do
        scan(e, { "/wt/a" => :done }, nodes: nodes) # SessionStart (first)
        scan(e, {},                   nodes: nodes) # aged out
        scan(e, { "/wt/a" => :done }, nodes: nodes) # SessionStart (restart)
      end
      assert_empty sounds
    end

    # refresh_prs:false suppresses the off-screen PR-spawn fan-out (the warm path),
    # but on_scan still marks attention and advances the baseline (so switch-in
    # rings nothing stale).
    def test_on_scan_refresh_prs_false_suppresses_spawn_but_keeps_marks_and_baseline
      e = edges(prev: { "/wt/a" => :thinking })
      sprayed = marked = 0
      e.define_singleton_method(:refresh_prs_for) { |*| sprayed += 1 }
      e.define_singleton_method(:mark_attention_for) { |*| marked += 1 }
      scan(e, { "/wt/a" => :done }, nodes: [ws("a", path: "/wt/a")],
                                    announce_sounds: false, refresh_prs: false)
      assert_equal 0, sprayed, "refresh_prs:false suppresses the PR-spawn fan-out off screen"
      assert_equal 1, marked, "...but attention marking still runs"
      assert_equal :done, e.instance_variable_get(:@prev_hook_states)["/wt/a"],
                   "...and the baseline still advances"
    end

    def test_on_scan_default_still_spawns_pr_refresh
      e = edges(prev: { "/wt/a" => :thinking })
      sprayed = 0
      e.define_singleton_method(:refresh_prs_for) { |*| sprayed += 1 }
      e.define_singleton_method(:mark_attention_for) { |*| nil }
      scan(e, { "/wt/a" => :done }, nodes: [ws("a", path: "/wt/a")], announce_sounds: false)
      assert_equal 1, sprayed, "the default (switch-in/visible) path still fires the PR refresh"
    end

    # --- monitored (∞) suppression --------------------------------------------
    # The noise fix (thought experiment #2/#3): a monitored worktree's routine
    # :done is dropped from bold + sound; :waiting always surfaces; an unmonitored
    # :done rings.

    def test_suppress_completion_only_for_a_monitored_done
      e = edges
      monitoring = Set.new(["/wt/a"])
      assert e.send(:suppress_completion?, "/wt/a", :done, monitoring), "monitored :done is a routine tick"
      refute e.send(:suppress_completion?, "/wt/a", :waiting, monitoring), ":waiting always surfaces"
      refute e.send(:suppress_completion?, "/wt/b", :done, monitoring), "an unmonitored :done rings normally"
    end

    def test_monitored_done_edge_is_not_bolded_or_sounded
      e = edges(prev: { "/wt/a" => :thinking, "/wt/b" => :thinking })
      bolded = []
      sounded = []
      e.define_singleton_method(:mark_attention_for) { |paths, _cp| bolded.concat(paths) }
      e.define_singleton_method(:play_sounds_for) { |paths, _now, _nodes, _cfg| sounded.concat(paths) }
      scan(e, { "/wt/a" => :done, "/wt/b" => :done },
           monitoring: Set.new(["/wt/a"]), refresh_prs: false)
      assert_equal ["/wt/b"], bolded.sort,  "monitored :done suppressed from bold; the other still bolds"
      assert_equal ["/wt/b"], sounded.sort, "monitored :done suppressed from sound; the other still rings"
    end

    def test_monitored_waiting_edge_still_rings
      e = edges(prev: { "/wt/a" => :thinking })
      sounded = []
      e.define_singleton_method(:play_sounds_for) { |paths, _now, _nodes, _cfg| sounded.concat(paths) }
      e.define_singleton_method(:mark_attention_for) { |_paths, _cp| }
      scan(e, { "/wt/a" => :waiting }, monitoring: Set.new(["/wt/a"]), refresh_prs: false)
      assert_equal ["/wt/a"], sounded, "a monitor pausing for input still rings"
    end

    # --- attention marks (the visual twin) -------------------------------------

    # The edge marks every newly-resting workspace EXCEPT the one you're sitting in
    # — you're watching that one finish, so it needs no nudge.
    def test_mark_attention_for_marks_edges_except_the_viewed_one
      a = real_dir("a")
      b = real_dir("b")
      edges.send(:mark_attention_for, [a, b], a)
      marked = Attention.marked([a, b])
      refute_includes marked, a, "the workspace you're watching isn't bolded"
      assert_includes marked, b, "another workspace's completion is bolded"
    end

    # The completion edge (T1) wires through to a mark, the visual twin of the dot.
    def test_on_scan_marks_attention_on_an_edge
      w = real_dir("wt")
      e = edges(prev: { w => :thinking })
      stub_method(Sound, :play, ->(*) {}) do
        scan(e, { w => :done }, nodes: [ws("w", project: "app", path: w)], refresh_prs: false)
      end
      assert_includes Attention.marked([w]), w, "a completion edge bolds the workspace"
    end

    # --- completion twinkle (the sparkle deadlines) ----------------------------

    def test_sparkle_fires_only_on_done
      e = edges
      e.send(:sparkle_for, ["/wt/w"], { "/wt/w" => :waiting })
      refute e.sparkling?("/wt/w"), ":waiting already blinks — no twinkle"

      e.send(:sparkle_for, ["/wt/a"], { "/wt/a" => :done })
      assert e.sparkling?("/wt/a"), "a just-completed agent twinkles"
    end

    # The twinkle's lifetime is wall-clock (monotonic), NOT pulse units — which is
    # what stops it replaying on switch-back. The sidebar's @pulse barely advances
    # while a pane is off-screen, so a pulse-denominated deadline would stay live
    # ~48s hidden and re-twinkle on return; a wall-clock one lapses in real time —
    # proven here with a stubbed clock advancing past the window.
    def test_sparkle_settles_by_wall_clock_so_it_cannot_replay_on_return
      e = edges
      clock = 1000.0
      e.define_singleton_method(:monotonic) { clock }

      e.send(:sparkle_for, ["/wt/a"], { "/wt/a" => :done })
      assert e.sparkling?("/wt/a"), "twinkles right after completion"

      clock += Sidebar::Edges::SPARKLE_SECS + 1 # real time passes while the pane is off-screen
      refute e.sparkling?("/wt/a"), "expired by wall-clock — no replay"
      refute e.instance_variable_get(:@sparkles).key?("/wt/a"), "and self-GCs"
    end

    # --- play_sounds_for ---------------------------------------------------------

    def test_play_sounds_for_one_sound_per_worktree_mapped_by_state
      e = edges
      nodes = [ws("a", project: "app", path: "/wt/a"), ws("b", project: "app", path: "/wt/b")]
      sounds = []
      now = { "/wt/a" => :done, "/wt/b" => :waiting }
      stub_method(Sound, :play, ->(spec, **) { sounds << spec }) do
        e.send(:play_sounds_for, ["/wt/a", "/wt/b"], now, nodes, Config.new)
      end
      assert_equal %w[train chime], sounds # each distinct worktree heard, by state
    end

    def test_play_sounds_for_silent_when_muted
      File.write(Config.path, YAML.dump("sounds" => { "enabled" => false }))
      e = edges
      played = []
      stub_method(Sound, :play, ->(spec, **) { played << spec if spec }) do
        e.send(:play_sounds_for, ["/wt/a"], { "/wt/a" => :done }, [ws("a", path: "/wt/a")], Config.new)
      end
      assert_empty played # sound_for -> nil, so nothing is actually played
    end

    # --- refresh_stale_prs (T3, the idle backstop) -----------------------------

    # The cold-home cap: a stale-everything cache spawns at most
    # MAX_SPAWN_PER_RELOAD refreshes per reload; the rest catch up on later
    # reloads. Config arrives per call (never captured — see the class doc).
    def test_refresh_stale_prs_caps_spawns_per_reload
      cfg = Config.new
      cfg.define_singleton_method(:projects) { (1..5).map { |i| { "name" => "p#{i}" } } }
      e = edges
      spawned = []
      e.define_singleton_method(:maybe_refresh_prs) { |p| spawned << p }
      stub_method(Pr, :stale?, ->(*) { true }) { e.refresh_stale_prs(cfg) }
      assert_equal Sidebar::Edges::MAX_SPAWN_PER_RELOAD, spawned.size,
                   "a cold cache must not fan out one gh per project"
    end
  end
end
