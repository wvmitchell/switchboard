# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # The dot logic. AgentState.scan merges hook reports (exact) with a process
  # fallback. We drive it by writing reporter files into the sandboxed state dir
  # and stubbing the process scan, so the TTL freshness, deepest-cwd rule, and
  # garbage-collection all run for real without a live agent or tmux.
  class AgentStateTest < SandboxTest
    def dir
      ENV["SWITCHBOARD_STATE_DIR"]
    end

    def write_hook(state, cwd, epoch: Time.now.to_i, name: nil)
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, name || "hk-#{cwd.hash.abs}"), "#{state}\t#{cwd}\t#{epoch}\n")
    end

    # A real (existing, canonicalized) worktree dir — fresh_hook canonicalizes
    # both sides, so the hook cwd must be the realpath too.
    def worktree(sub = "wt")
      d = path(sub)
      FileUtils.mkdir_p(d)
      File.realpath(d)
    end

    # Silence the process fallback so only hook state is under test.
    def no_processes(&blk)
      stub_method(Agents, :active, ->(_paths) { Set.new }, &blk)
    end

    # An AgentState whose per-pane capture_hash is deterministic (no real tmux) —
    # yields the given values in order, the last repeating. Equal successive values
    # read as a STATIC pane, differing ones as a CHANGING pane, so a test drives the
    # interrupt-vs-working distinction without a live server. The monotonic clock is
    # stubbed to advance `clock_step` per call — default 3s (the REFRESH cadence), so a
    # second identical scan clears STATIC_MIN_AGE and downgrades as it would in the wild.
    def instance_capturing(*values, clock_step: 3.0)
      a = AgentState.new
      q = values.dup
      a.define_singleton_method(:capture_hash) { |_id| q.length > 1 ? q.shift : q.first }
      t = 0.0
      a.define_singleton_method(:monotonic) { t += clock_step }
      a
    end

    def test_a_fresh_hook_is_reported
      wt = worktree
      write_hook("thinking", wt)
      no_processes { assert_equal({ wt => :thinking }, AgentState.new.scan([wt])) }
    end

    def test_done_and_waiting_map_through
      a = worktree("a")
      b = worktree("b")
      write_hook("done", a)
      write_hook("waiting", b)
      no_processes do
        result = AgentState.new.scan([a, b])
        assert_equal :done, result[a]
        assert_equal :waiting, result[b]
      end
    end

    def test_a_stale_hook_ages_out
      wt = worktree
      write_hook("thinking", wt, epoch: Time.now.to_i - (AgentState::PRESENCE_TTL + 60))
      no_processes { assert_empty AgentState.new.scan([wt]) }
    end

    # Value: protects=a permission prompt left open past the TTL still stops the one-press search open; fails_when=last_waiting applies PRESENCE_TTL or reads anything but the latest report; why_new=a gone agent's ◆ ages out, its last prompt doesn't; seam=none; no_claim=a prompt no hook reported
    def test_a_waiting_report_counts_as_waiting_past_the_ttl_until_a_later_report
      wt = worktree
      write_hook("waiting", wt, epoch: Time.now.to_i - (AgentState::PRESENCE_TTL + 60))
      a = AgentState.new
      no_processes do
        refute_equal :waiting, a.scan([wt])[wt], "no agent left: the ◆ ages out"
        assert_equal Set[wt], a.last_waiting
        write_hook("done", wt)
        a.scan([wt])
      end
      assert_empty a.last_waiting, "a later report is the answer"
    end

    def with_agent(wt, &blk)
      stub_method(Agents, :active, ->(_paths) { Set[wt] }) do
        stub_method(Tmux, :work_panes, -> { {} }, &blk)
      end
    end

    # Value: protects=an open prompt keeps its ◆ past the TTL while its agent lives; fails_when=fresh_hook's TTL applies to :waiting again or the edge input drops it; why_new=the test above covers only a gone agent; seam=none; no_claim=Agents.active's pgrep/lsof (stubbed)
    def test_a_stale_waiting_report_stays_waiting_while_its_agent_lives
      wt = worktree
      write_hook("waiting", wt, epoch: Time.now.to_i - (AgentState::PRESENCE_TTL + 60))
      a = AgentState.new
      with_agent(wt) { assert_equal({ wt => :waiting }, a.scan([wt])) }
      assert_equal({ wt => :waiting }, a.last_hook_states, "answering it still ends in a normal done edge")
      assert_equal({ wt => :done }, a.stale_waiting, "the process fallback's verdict rides along for Presence")
    end

    # Value: protects=an off-screen frame keeps the ◆ the switch-in scan will show, and never a dead agent's; fails_when=hooks_only skips the stale-waiting branch or trusts a report no scan held; why_new=no hooks_only TTL test; seam=none; no_claim=real tmux
    def test_off_screen_a_stale_waiting_report_carries_on_only_if_the_last_scan_held_it
      wt = worktree
      write_hook("waiting", wt, epoch: Time.now.to_i - (AgentState::PRESENCE_TTL + 60))
      a = AgentState.new
      stub_method(Agents, :active, ->(_paths) { flunk "hooks_only never runs the process scan" }) do
        assert_empty a.scan([wt], hooks_only: true), "nothing vouched for this agent: no ◆"
      end
      with_agent(wt) { a.scan([wt]) }
      stub_method(Agents, :active, ->(_paths) { flunk "hooks_only never runs the process scan" }) do
        assert_equal({ wt => :waiting }, a.scan([wt], hooks_only: true))
        assert_equal({ wt => :waiting }, a.scan([wt], hooks_only: true), "and keeps carrying while off screen")
      end
      assert_equal({ wt => nil }, a.stale_waiting, "no fallback was computed off screen")
      no_processes { a.scan([wt]) }
      assert_empty a.scan([wt], hooks_only: true), "a visible scan that found no agent ends it"
    end

    # Value: protects=a prompt open over a weekend still shows ◆, and an idle agent's
    # `done` is still there for delete days later; fails_when=read_hooks age-deletes a
    # tracked worktree's report; why_new=delete trusts a `done` of any age; seam=none;
    # no_claim=Agents.active (stubbed)
    def test_a_tracked_worktrees_report_never_ages_out
      wt = worktree
      write_hook("waiting", wt, name: "weekend", epoch: Time.now.to_i - (8 * AgentState::STALE_GC))
      file = File.join(dir, "weekend")
      with_agent(wt) { assert_equal({ wt => :waiting }, AgentState.new.scan([wt])) }
      no_processes { assert_empty AgentState.new.scan([wt]), "no agent: nothing drawn" }
      assert File.exist?(file), "a tracked worktree's report outlives STALE_GC"
      no_processes { AgentState.new.scan([]) }
      refute File.exist?(file), "the same report from an untracked dir is reaped"
    end

    # Value: protects=a project whose tree failed to build for one scan keeps its old
    # reports; fails_when=keep_roots stops reaching read_hooks; why_new=the sidebar's scan
    # paths come from git, which can blink; seam=keep_roots (the sidebar passes its config);
    # no_claim=the sidebar's config wiring
    def test_a_report_under_a_kept_root_survives_a_scan_that_misses_it
      wt = worktree
      write_hook("done", wt, name: "old", epoch: Time.now.to_i - (2 * AgentState::STALE_GC))
      no_processes { AgentState.new(keep_roots: -> { [File.dirname(wt)] }).scan([]) }
      assert File.exist?(File.join(dir, "old")), "its root is the config's, so it stays"
    end

    # Value: protects=a killed agent's `thinking` still ages out in a tracked worktree, and a
    # kept report from a subdir the agent left doesn't outrank a newer one; fails_when=KEPT
    # stops gating the exemption, or latest_hook goes back to deepest-wins; why_new=reports
    # are now kept indefinitely; seam=none; no_claim=Agents.active (stubbed)
    def test_only_an_answer_or_an_idle_report_is_kept_and_the_freshest_wins
      wt = worktree
      write_hook("thinking", wt, name: "killed", epoch: Time.now.to_i - (2 * AgentState::STALE_GC))
      no_processes { AgentState.new.scan([wt]) }
      refute File.exist?(File.join(dir, "killed")), "a stale thinking is reaped even when tracked"

      sub = File.join(wt, "sub")
      FileUtils.mkdir_p(sub)
      write_hook("waiting", File.realpath(sub), name: "left", epoch: Time.now.to_i - (8 * AgentState::STALE_GC))
      write_hook("done", wt, name: "now")
      with_agent(wt) { assert_equal({ wt => :done }, AgentState.new.scan([wt])) }
    end

    def test_deepest_cwd_at_or_under_the_worktree_wins
      wt = worktree
      sub = File.join(wt, "sub")
      FileUtils.mkdir_p(sub)
      write_hook("done", wt, name: "shallow")
      write_hook("thinking", File.realpath(sub), name: "deep")
      no_processes { assert_equal :thinking, AgentState.new.scan([wt])[wt] }
    end

    # A rename leaves a bridge symlink (old -> new), so a running agent's stale
    # pre-move file (keyed by the old path, still resolvable through the symlink)
    # and its fresh post-move file both alias onto the new worktree. They collapse
    # to one entry, freshest kept — the stale state can't freeze the dot.
    def test_bridged_alias_reports_the_freshest_state
      wt = worktree("new")
      File.symlink(wt, path("old")) # the rename bridge
      write_hook("done", path("old"), epoch: Time.now.to_i - 300, name: "stale") # pre-move, via symlink
      write_hook("thinking", wt, epoch: Time.now.to_i, name: "fresh")            # post-move, direct
      no_processes { assert_equal :thinking, AgentState.new.scan([wt])[wt] }
    end

    def test_a_dead_worktrees_hook_file_is_garbage_collected
      write_hook("thinking", path("dead"), name: "ghost") # cwd never created
      file = File.join(dir, "ghost")
      no_processes { AgentState.new.scan([]) }
      refute File.exist?(file), "a hook whose worktree is gone gets cleaned up"
    end

    def test_a_torn_write_is_skipped_not_deleted
      FileUtils.mkdir_p(dir)
      file = File.join(dir, "torn")
      File.write(file, "thinking\t/some/where") # missing the epoch field
      no_processes { assert_empty AgentState.new.scan([worktree]) }
      assert File.exist?(file), "a mid-write read is skipped this cycle, never deleted"
    end

    # Age GC (the global codex hook writes a file per dir codex runs in): a file whose dir
    # STILL exists but is older than STALE_GC is reaped, so non-switchboard dirs don't pile
    # up forever on the dir-exists GC alone. Only an untracked dir's: a workspace's ages out
    # with its folder instead.
    def test_a_stale_file_whose_dir_still_exists_is_reaped
      stray = worktree("elsewhere")
      write_hook("done", stray, name: "old", epoch: Time.now.to_i - (AgentState::STALE_GC + 60))
      file = File.join(dir, "old")
      no_processes { AgentState.new.scan([worktree]) }
      refute File.exist?(file), "an untracked dir-exists file past STALE_GC is deleted"
    end

    # The carve-out: `age >` (not `.abs`) means a FUTURE-epoch / backward-clock file is not
    # reaped as stale — else a clock step would wrongly delete a just-written report.
    def test_a_future_epoch_file_is_not_reaped_as_stale
      wt = worktree
      write_hook("thinking", wt, name: "future", epoch: Time.now.to_i + 100_000)
      file = File.join(dir, "future")
      no_processes { AgentState.new.scan([wt]) }
      assert File.exist?(file), "a future-epoch file is not treated as stale"
    end

    def test_process_fallback_reports_done_when_no_hook
      wt = worktree
      stub_method(Agents, :active, ->(_paths) { Set[wt] }) do
        stub_method(Tmux, :work_panes, -> { [["%1", wt]] }) do
          assert_equal :done, AgentState.new.scan([wt])[wt] # first sighting has no baseline -> done
        end
      end
    end

    # REGRESSION (activity now rides pane_delta): a hook-less agent whose work pane
    # keeps changing between scans still reads :thinking, exactly as before the
    # refactor. Two scans on one instance so the second has a baseline to diff.
    def test_process_fallback_reports_thinking_when_pane_changes
      wt = worktree
      a = instance_capturing(1, 2) # scan1 seeds, scan2 sees a different hash -> changed
      stub_method(Agents, :active, ->(_paths) { Set[wt] }) do
        stub_method(Tmux, :work_panes, -> { [["%1", wt]] }) do
          a.scan([wt]) # baseline
          assert_equal :thinking, a.scan([wt])[wt]
        end
      end
    end

    # --- :thinking corroboration against pane liveness (the interrupt fix) -------

    # An agent interrupted mid-turn (Esc/Ctrl-C) fires no Stop hook, so its
    # :thinking file lingers fresh. Its work pane goes STATIC at the prompt, so the
    # second scan downgrades the dot to a resting :done — and, crucially, drops the
    # worktree from last_hook_states so the completion edge rings no false chime.
    def test_interrupted_thinking_pane_static_downgrades_to_done_silently
      wt = worktree
      write_hook("thinking", wt)
      a = instance_capturing(9) # constant hash => pane reads static once there's a baseline
      stub_method(Tmux, :work_panes, -> { [["%1", wt]] }) do
        assert_equal :thinking, a.scan([wt])[wt], "scan 1 has no baseline -> trusts the hook"
        assert_equal({ wt => :thinking }, a.last_hook_states)

        assert_equal :done, a.scan([wt])[wt], "scan 2 sees a static pane -> resting dot"
        assert_empty a.last_hook_states, "downgrade is render-only: absent from hook states -> no chime"
      end
    end

    # The distinguishing case: a genuinely working agent animates its TUI every
    # second, so the pane keeps changing and the dot stays :thinking (a long
    # think / long tool run is NOT mistaken for an interrupt).
    def test_working_thinking_pane_changes_stays_thinking
      wt = worktree
      write_hook("thinking", wt)
      a = instance_capturing(1, 2) # pane content differs across scans
      stub_method(Tmux, :work_panes, -> { [["%1", wt]] }) do
        a.scan([wt]) # baseline
        assert_equal :thinking, a.scan([wt])[wt]
        assert_equal({ wt => :thinking }, a.last_hook_states, "still a live hook state")
      end
    end

    # Fail-safe: with no SINGLE non-sidebar pane to hash (none found, or an
    # ambiguous multi-pane window), corroboration can't tell -> it keeps the exact
    # hook signal rather than invent a resting dot. This is the DEFAULT path on a
    # real Claude before pane detection, so it must never downgrade blindly.
    def test_thinking_with_no_single_work_pane_trusts_the_hook
      wt = worktree
      write_hook("thinking", wt)
      [[], [["%1", wt], ["%2", wt]]].each do |panes| # zero, then ambiguous
        a = instance_capturing(9)
        stub_method(Tmux, :work_panes, -> { panes }) do
          a.scan([wt]) # would-be baseline
          assert_equal :thinking, a.scan([wt])[wt], "panes=#{panes.inspect} -> trust the hook"
          assert_equal({ wt => :thinking }, a.last_hook_states)
        end
      end
    end

    # Fail-safe (adversarial F2): a FAILED capture-pane must not read as static. Before
    # the fix, capture_hash returned a CONSTANT ("".hash / 0) on failure, so two failed
    # captures compared equal -> :static -> a genuine :thinking downgraded to :done on a
    # mere tmux hiccup. Uses the REAL capture_hash against a pane id that exists in no
    # server (capture fails -> nil -> :unknown -> trust the hook).
    def test_thinking_survives_a_failed_pane_capture
      wt = worktree
      write_hook("thinking", wt)
      a = AgentState.new # real capture_hash; the stubbed work pane doesn't exist
      stub_method(Tmux, :work_panes, -> { [["%999999", wt]] }) do
        assert_equal :thinking, a.scan([wt])[wt], "scan 1"
        assert_equal :thinking, a.scan([wt])[wt], "scan 2 — a failed capture is not 'static'"
        assert_equal({ wt => :thinking }, a.last_hook_states, "still a live hook state, not downgraded")
      end
    end

    # Adversarial F4: a sub-REFRESH rescan (a background PR-poke or an action reload
    # landing a fraction of a second after the last scan) must NOT downgrade a pane
    # that merely hashed identical across that tiny gap — a still-animating agent can
    # show two equal frames 0.3s apart. Only content held identical for >=
    # STATIC_MIN_AGE is trusted as static; age runs from when the content first appeared.
    def test_a_rapid_rescan_does_not_downgrade_a_still_animating_pane
      wt = worktree
      write_hook("thinking", wt)
      a = AgentState.new
      a.define_singleton_method(:capture_hash) { |_id| 7 } # identical content every read
      clock = [0.0, 0.3, 0.9, 5.0]                          # seed, +0.3, +0.9, then a full gap
      a.define_singleton_method(:monotonic) { clock.shift }
      stub_method(Tmux, :work_panes, -> { [["%1", wt]] }) do
        assert_equal :thinking, a.scan([wt])[wt], "scan 1 seeds the content"
        assert_equal :thinking, a.scan([wt])[wt], "rapid rescan (+0.3s) — too soon to call static"
        assert_equal :thinking, a.scan([wt])[wt], "still rapid (+0.9s) — under STATIC_MIN_AGE"
        assert_equal :done, a.scan([wt])[wt], "content held past STATIC_MIN_AGE -> now static"
      end
    end

    # The warm/off-screen path must stay cheap: a hooks_only scan never corroborates
    # (never shells out to work_panes), it just trusts the reported :thinking.
    def test_hooks_only_thinking_skips_pane_corroboration
      wt = worktree
      write_hook("thinking", wt)
      stub_method(Tmux, :work_panes, -> { flunk "hooks_only must not corroborate against panes" }) do
        assert_equal({ wt => :thinking }, AgentState.new.scan([wt], hooks_only: true))
      end
    end

    # Only :thinking is corroborated. A resting :done/:waiting is trusted as-is even
    # when a static work pane is present (the pane can't distinguish waiting anyway).
    def test_resting_states_are_not_downgraded_by_a_static_pane
      a = worktree("a")
      b = worktree("b")
      write_hook("done", a)
      write_hook("waiting", b)
      inst = instance_capturing(9)
      stub_method(Tmux, :work_panes, -> { [["%1", a], ["%2", b]] }) do
        inst.scan([a, b])
        result = inst.scan([a, b])
        assert_equal :done, result[a]
        assert_equal :waiting, result[b]
      end
    end

    # hooks_only (the off-screen warm path) must never reach Agents.active — that's
    # the expensive tmux/pgrep/lsof scan the warm path exists to avoid.
    def test_hooks_only_scan_skips_the_process_fallback
      wt = worktree # no hook file -> would normally trigger the fallback
      called = false
      stub_method(Agents, :active, ->(_paths) { called = true; Set[wt] }) do
        assert_empty AgentState.new.scan([wt], hooks_only: true),
                     "hooks-only with no hook reports nothing — the process scan is skipped"
      end
      refute called, "hooks_only must not invoke the tmux/pgrep/lsof process scan"
    end

    def test_hooks_only_scan_still_reports_hook_state
      wt = worktree
      write_hook("thinking", wt)
      stub_method(Agents, :active, ->(_) { flunk "hooks_only must not touch the process scan" }) do
        assert_equal({ wt => :thinking }, AgentState.new.scan([wt], hooks_only: true))
      end
    end

    # clear_all wipes the state dir on quit — a fresh file is trusted as presence
    # without a liveness check, so tearing down every agent must drop their now-
    # stale states or a :thinking would read as a live, working agent for the TTL.
    def test_clear_all_wipes_every_hook_file
      a = worktree("a")
      b = worktree("b")
      write_hook("thinking", a, name: "one")
      write_hook("done", b, name: "two")
      AgentState.clear_all
      assert_empty Dir.glob(File.join(dir, "*")), "every state file is gone after quit"
      no_processes { assert_empty AgentState.new.scan([a, b]), "and the next scan shows no dots" }
    end

    def test_clear_all_is_a_noop_when_the_state_dir_is_missing
      refute Dir.exist?(dir), "no state dir written yet"
      AgentState.clear_all # must not raise
      refute Dir.exist?(dir)
    end

    # The `File.file?` guard skips a stray subdir (clear_all only deletes the flat
    # reporter files), and the per-file rescue means one undeletable entry can't
    # abort the sweep — so the rest still get wiped.
    def test_clear_all_skips_subdirs_and_isolates_per_file
      wt = worktree("a")
      write_hook("thinking", wt, name: "keep-not")
      FileUtils.mkdir_p(File.join(dir, "subdir")) # a directory entry, not a reporter file
      AgentState.clear_all
      refute File.exist?(File.join(dir, "keep-not")), "the flat reporter file is wiped"
      assert Dir.exist?(File.join(dir, "subdir")), "a subdir is skipped, not deleted"
    end
  end
end
