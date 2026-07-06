# frozen_string_literal: true

require_relative "../test_helper"

module Switchboard
  # Shared base for the sidebar test files (#57 split the one 3.4k-line
  # SidebarTest along the lib concern seams). Carries the white-box scaffolding
  # every sidebar test builds on: the Tree::Node builders, the `sidebar(…)`
  # constructor that seeds a Sidebar's ivars the way the run loop would, the
  # ivar accessors, and the couple of generic capture helpers used across
  # concerns. Test files under test/sidebar_*_test.rb subclass this; bin/test
  # never auto-runs it (not a *_test.rb).
  class SidebarCase < SandboxTest
    # --- node + sidebar builders --------------------------------------------

    def proj(name)
      Tree::Node.new(kind: "proj", project: name, path: "/repos/#{name}")
    end

    def ws(name, project: "app", path: nil, pr: nil)
      Tree::Node.new(kind: "ws", project: project, path: path || "/wt/#{name}", name: name, pr: pr)
    end

    def br(branch, active: false, last: false)
      Tree::Node.new(kind: "br", project: "app", branch: branch, active: active, last: last)
    end

    def sidebar(nodes: [], collapsed: [], cursor: 0, agents: {}, focused: true,
                current_path: nil, pulse: 0, attention: [], monitoring: [])
      sb = Sidebar.new
      sb.instance_variable_set(:@nodes, nodes)
      sb.instance_variable_set(:@collapsed, Set.new(collapsed))
      sb.instance_variable_set(:@agents, agents)
      sb.instance_variable_set(:@attention, Set.new(attention))
      sb.instance_variable_set(:@monitoring, Set.new(monitoring))
      sb.instance_variable_set(:@focused, focused)
      sb.instance_variable_set(:@current_path, current_path)
      sb.instance_variable_set(:@pulse, pulse)
      sb.send(:recompute_rows)                      # derive @rows from @nodes/@collapsed
      sb.instance_variable_set(:@cursor, cursor)    # set after: recompute_rows clamps it
      sb
    end

    def expanded_ws(name = "feature", path: "/wt/a", branch: "feature")
      Tree::Node.new(kind: "ws", project: "app", path: path, name: name, branch: branch,
                     expanded: true)
    end

    # A multi-branch workspace mid-history: the expanded ws carries NO pr (the
    # active branch row owns the badge, #90), the active branch row carries it,
    # and a sibling ws rounds out the tree. Shared by the fold/keymap tests.
    def multi_branch_tree
      exp = expanded_ws("multi", path: "/wt/m", branch: "feat")
      act = br("feat", active: true); act[:path] = exp.path; act[:pr] = open_pr("#1234")
      old = br("old", last: true);    old[:path] = exp.path
      sib = ws("solo", path: "/wt/s", pr: open_pr("#9"))
      [proj("app"), exp, act, old, sib]
    end

    def cursor_of(sb)  = sb.instance_variable_get(:@cursor)
    def rows_of(sb)    = sb.instance_variable_get(:@rows)
    def offset_of(sb)  = sb.instance_variable_get(:@offset)
    def ws_names(sb)   = rows_of(sb).select { |n| n.kind == "ws" }.map(&:name)
    def current_node(sb) = rows_of(sb)[cursor_of(sb)]

    # --- generic capture helpers --------------------------------------------

    # A real directory inside the sandbox, realpath'd — attention markers key on
    # canonical paths, so tests that exercise them need paths that exist.
    def real_dir(sub)
      d = path(sub)
      FileUtils.mkdir_p(d)
      File.realpath(d)
    end

    def strip_ansi(str) = str.gsub(/\e\[[0-9;]*m/, "")

    def open_pr(id) = { "identifier" => id, "status" => "open" }

    def capture_stdout
      orig = $stdout
      $stdout = StringIO.new
      yield
      $stdout.string
    ensure
      $stdout = orig
    end
  end
end
