# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # Tree.nodes turns the Model's project->worktree tree into the flat, ordered
  # Node list the sidebar draws. Pure given a model, so we feed it a hand-built
  # double and stub Git.branch_history (the only shell-out, via lineage) — no real
  # repos. Invariants under test: row order, primary always filtered out, and a
  # multi-branch workspace expanding into inline branch rows.
  class TreeTest < Minitest::Test
    # Minimal stand-in for Model: Tree only calls #projects and #pr_for.
    class FakeModel
      def initialize(projects, prs = {})
        @projects = projects
        @prs = prs
      end
      attr_reader :projects

      def pr_for(branch)
        @prs[branch]
      end
    end

    def wt(path:, branch:, primary: false, dirty: false, pr: nil)
      Worktree.new(project: "app", path: path, branch: branch, dirty: dirty, pr: pr,
                   base: nil, primary: primary)
    end

    def project(worktrees)
      Project.new(name: "app", path: "/repos/app", base_ref: "origin/main", worktrees: worktrees)
    end

    def no_history(&blk)
      stub_method(Git, :branch_history, ->(_path, limit:, cache: nil) { [] }, &blk)
    end

    def test_nodes_list_project_then_workspaces_and_skip_primary
      model = FakeModel.new([project([
        wt(path: "/repos/app", branch: "main", primary: true), # trunk checkout
        wt(path: "/wt/a", branch: "a"),
        wt(path: "/wt/b", branch: "b")
      ])])
      no_history do
        nodes = Tree.nodes(model)
        assert_equal %w[proj ws ws], nodes.map(&:kind)
        assert_equal "app", nodes[0].project
        assert_equal %w[a b], nodes[1..].map(&:name) # display_name = dir leaf
        ws_paths = nodes.select { |n| n.kind == "ws" }.map(&:path)
        refute_includes ws_paths, "/repos/app", "primary must be filtered out of workspaces"
      end
    end

    def test_single_branch_workspace_does_not_expand
      model = FakeModel.new([project([wt(path: "/wt/a", branch: "solo")])])
      no_history do
        assert_equal %w[proj ws], Tree.nodes(model).map(&:kind)
      end
    end

    def test_multi_branch_workspace_expands_into_branch_rows
      model = FakeModel.new([project([wt(path: "/wt/a", branch: "feature")])])
      stub_method(Git, :branch_history, ->(_path, limit:, cache: nil) { %w[feature main] }) do
        nodes = Tree.nodes(model)
        assert_equal %w[proj ws br br], nodes.map(&:kind)
        br = nodes.select { |n| n.kind == "br" }
        assert_equal %w[feature main], br.map(&:branch)
        assert br[0].active, "current branch is marked active"
        refute br[1].active
        assert br[1].last, "last branch is flagged for the tree glyph"
        refute br[0].last
      end
    end

    def test_branch_rows_carry_pr_from_model
      model = FakeModel.new([project([wt(path: "/wt/a", branch: "feature")])],
                            "main" => { "identifier" => "#5" })
      stub_method(Git, :branch_history, ->(_path, limit:, cache: nil) { %w[feature main] }) do
        main = Tree.nodes(model).find { |n| n.kind == "br" && n.branch == "main" }
        assert_equal({ "identifier" => "#5" }, main.pr)
      end
    end

    def test_lineage_caps_at_max_branches_and_appends_current
      seen_limit = nil
      stub_method(Git, :branch_history, ->(_path, limit:, cache: nil) { seen_limit = limit; %w[x y] }) do
        line = Tree.lineage(wt(path: "/wt/a", branch: "z"))
        assert_equal Tree::MAX_BRANCHES, seen_limit
        assert_equal %w[x y z], line # current appended via dedup union
      end
    end
  end
end
