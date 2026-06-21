# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # The pure decision helpers behind the background PR refresh (issue #19): which
  # agent transitions count as "a turn finished" (completion_edges), and the
  # per-project spawn debounce (spawn_due?). Both are class methods so the logic
  # is testable without standing up a TUI or spawning a process.
  class SidebarTest < Minitest::Test
    # --- completion_edges: a worktree newly at a resting state ---

    def test_thinking_to_done_is_an_edge
      assert_equal ["/a"], Sidebar.completion_edges({ "/a" => :thinking }, { "/a" => :done })
    end

    def test_entering_waiting_is_an_edge
      assert_equal ["/a"], Sidebar.completion_edges({ "/a" => :thinking }, { "/a" => :waiting })
    end

    def test_appearing_at_done_is_an_edge
      assert_equal ["/a"], Sidebar.completion_edges({}, { "/a" => :done })
    end

    def test_steady_done_is_not_an_edge
      assert_empty Sidebar.completion_edges({ "/a" => :done }, { "/a" => :done })
    end

    def test_returning_to_thinking_is_not_an_edge
      assert_empty Sidebar.completion_edges({ "/a" => :done }, { "/a" => :thinking })
    end

    def test_aging_out_is_not_an_edge
      assert_empty Sidebar.completion_edges({ "/a" => :done }, {})
    end

    def test_only_changed_paths_count
      prev = { "/a" => :done, "/b" => :thinking }
      now  = { "/a" => :done, "/b" => :done }
      assert_equal ["/b"], Sidebar.completion_edges(prev, now)
    end

    # --- spawn_due?: per-project debounce ---

    def test_spawn_due_when_never_spawned
      assert Sidebar.spawn_due?(nil, 100.0)
    end

    def test_not_spawn_due_within_window
      refute Sidebar.spawn_due?(100.0, 102.0, 5)
    end

    def test_spawn_due_after_window
      assert Sidebar.spawn_due?(100.0, 106.0, 5)
    end

    def test_spawn_due_exactly_at_window
      assert Sidebar.spawn_due?(100.0, 105.0, 5)
    end
  end
end
