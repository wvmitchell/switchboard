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
    # up forever on the dir-exists GC alone.
    def test_a_stale_file_whose_dir_still_exists_is_reaped
      wt = worktree
      write_hook("done", wt, name: "old", epoch: Time.now.to_i - (AgentState::STALE_GC + 60))
      file = File.join(dir, "old")
      no_processes { AgentState.new.scan([wt]) }
      refute File.exist?(file), "a dir-exists file past STALE_GC is deleted"
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
        stub_method(Agents, :tmux_panes, -> { [["%1", wt]] }) do
          assert_equal :done, AgentState.new.scan([wt])[wt]
        end
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
