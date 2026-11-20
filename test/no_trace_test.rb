# frozen_string_literal: true

require_relative "test_helper"
require "open3"

module Switchboard
  # The guard behind "a delete leaves nothing": seed every per-workspace store for a real
  # worktree, delete it, then walk every place a store can write and look for anything
  # that still names it. The walk, not a list, is what catches a store added later.
  class NoTraceTest < SandboxTest
    def setup
      super
      @repo = temp_git_repo("app")
      @wt = path("worktrees", "app", "trace-me")
      FileUtils.mkdir_p(File.dirname(@wt))
      git(@repo, "worktree", "add", "-q", "-b", "trace-me", @wt)
      @real = File.realpath(@wt)
      File.write(Config.path, YAML.dump("worktree_root" => path("worktrees"), "base" => "main",
                                        "projects" => [{ "name" => "app", "path" => @repo }]))
    end

    def seed
      Names.write(@real, "renamed-trace", project: "app", branch: "trace-me")
      rec = Creation.create(project: "app", name: "trace-me", path: @wt, task: "t", via: "cli")
      Creation.update(rec["id"], state: "turn_done", worktree_added: true)
      PendingDelete.mark(path("elsewhere", "unrelated")) # an unrelated hide marker must survive
      Attention.mark(@wt)
      Order.set(@wt, 1.0)
      Monitoring.mark(@wt)
      Notify.mark(@wt)
      OffstageHold.hold(@wt, pid: Process.pid)
      SessionName::Outcome.record(@wt, "ceiling", "x")
      SessionName::Owner.claim(@wt)
      sub = File.join(@wt, "pkg")
      FileUtils.mkdir_p(sub)
      system({ "SWITCHBOARD_STATE_DIR" => AgentState.state_dir }, "sh", "-c", "cd #{Shellwords.escape(sub)} && sh #{Shellwords.escape(reporter)} done")
      # ∞ and ◷ would be [busy]: age them out the way a stopped monitor does.
      [Monitoring.state_dir].each { |d| Dir.glob(File.join(d, "*")).each { |f| File.utime(Time.now - 7200, Time.now - 7200, f) } }
      Dir.glob(File.join(OffstageHold.state_dir, "*")).each { |f| File.delete(f) }
      OffstageHold.hold(@wt, pid: Process.pid)
      MarkerBlock.atomic_write(Pr.cache_file("app"), JSON.dump(Pr::REPO_KEY => "o/app", "main" => nil,
                                                                "trace-me" => { "identifier" => "#7" }))
      rec
    end

    def reporter
      HookFile.ensure_script
      HookFile.script_path
    end

    def cksum(text) = Open3.capture2("cksum", stdin_data: text).first.split.first

    # Value: protects=no switchboard store keeps anything of a deleted workspace;
    # fails_when=a store's entry survives (or a new store is added outside Leftovers);
    # why_new=the no-orphans requirement; seam=tmux and the agent scan only
    def test_a_deleted_workspace_leaves_no_trace
      rec = seed
      refute_empty Dir.children(AgentState.state_dir), "precondition: the real reporter wrote a hook file"
      code = nil
      stub_method(Tmux, :sessions_strict, -> { [] }) do
        stub_method(Agents, :scan_pids, -> { {} }) do
          stub_method(Tmux, :broadcast_warm, ->(**) {}) do
            stub_method(Deletion, :busy, ->(_t) { nil }) do # the seeded ◷ hold is a live busy signal
              code = Deletion.run(Config.new, name: "renamed-trace").exit_code
            end
          end
        end
      end
      assert_equal 0, code

      skip = [@repo]
      keys = [KeyedMarkerStore.key(@real), cksum(@real), Names.key(@real)]
      hits = Dir.glob([path("**", "*"), File.join(@repo, ".git", "**", "*"), File.join(Dir.tmpdir, "switchboard", "**", "*")],
                      File::FNM_DOTMATCH).reject { |f| skip.any? { |s| f.start_with?("#{s}/") && !f.include?("/.git/") } }
                 .select { |f| File.file?(f) }.select do |f|
        next true if keys.include?(File.basename(f))

        body = File.read(f).b
        body.include?(@real.b) || body.include?(@wt.b) ||
          (body.include?("trace-me".b) && (f == Pr.cache_file("app") || (f.include?("/.git/") && !f.end_with?("ORIG_HEAD", "/logs/HEAD"))))
      rescue StandardError
        false
      end
      assert_empty hits, "these still name the deleted workspace"
      assert_nil Creation.find(rec["id"])
      assert_equal [Pr::REPO_KEY, "main"], Pr.for_project("app").keys, "only the deleted branch's badge goes"
      assert_equal 1, Dir.children(PendingDelete.state_dir).size, "the unrelated hide marker stays"
      refute_includes git(@repo, "worktree", "list"), "trace-me"
      refute_includes git(@repo, "branch", "--list"), "trace-me"
    end
  end
end
