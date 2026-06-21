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

    def test_process_fallback_reports_done_when_no_hook
      wt = worktree
      stub_method(Agents, :active, ->(_paths) { Set[wt] }) do
        stub_method(Agents, :tmux_panes, -> { [["%1", wt]] }) do
          assert_equal :done, AgentState.new.scan([wt])[wt]
        end
      end
    end
  end
end
