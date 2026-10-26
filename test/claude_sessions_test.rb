# frozen_string_literal: true

require_relative "test_helper"
require "json"

module Switchboard
  # Claude's live session files → the ◷ evidence. Real files in the sandboxed sessions
  # dir; the live session is THIS test process (its real pid + lstart), so liveness runs
  # for real. lsof is stubbed only where a test needs a cwd the OS can't fake.
  class ClaudeSessionsTest < SandboxTest
    def setup
      super
      FileUtils.mkdir_p(ClaudeSessions.sessions_dir)
    end

    def wt(name)
      d = path("worktrees", name)
      FileUtils.mkdir_p(d)
      File.realpath(d)
    end

    def write_session(file, **over)
      data = { "pid" => Process.pid, "sessionId" => "s-#{file}", "cwd" => over.delete(:cwd),
               "startedAt" => 1_792_696_353_818, "procStart" => ProcessIdentity.start_of(Process.pid),
               "kind" => "interactive", "status" => "busy",
               "statusUpdatedAt" => (Time.now.to_f * 1000).to_i }.merge(over.transform_keys(&:to_s))
      data.delete_if { |_, v| v == :absent }
      File.write(File.join(ClaudeSessions.sessions_dir, "#{file}.json"), JSON.generate(data))
    end

    def scan(paths, **kw)
      stub_method(Agents, :cwds_of, ->(*) { {} }) { ClaudeSessions.scan(paths, **kw) }
    end

    def ms_ago(secs) = ((Time.now.to_f - secs) * 1000).to_i

    # --- scan ---------------------------------------------------------------

    def test_an_unlinked_session_is_kept_with_its_status
      w = wt("alpha")
      write_session("1", cwd: w, status: "shell")
      recs = scan([w])[w]
      assert_equal 1, recs.size
      assert_equal "shell", recs.first[:status]
      assert_nil recs.first[:bridge_id]
    end

    def test_a_dead_or_recycled_pid_is_no_session
      w = wt("alpha")
      write_session("dead", cwd: w, pid: 2**22 + 12_345)
      write_session("recycled", cwd: w, procStart: "Thu Jan  1 00:00:00 1970")
      assert_empty scan([w])
    end

    # Value: protects=a machine full of Claudes outside switchboard costs no fork; fails_when=the
    # tracked-cwd pre-filter goes or runs after liveness; why_new=the filter is new (D10); seam=none
    # (counts same?/lsof calls); no_claim=real fork counts
    def test_a_session_outside_every_tracked_worktree_is_never_ps_d_or_lsof_d
      w = wt("alpha")
      write_session("away", cwd: wt("elsewhere"))
      asked = []
      lsofed = []
      stub_method(ProcessIdentity, :same?, ->(pid, *) { asked << pid; true }) do
        stub_method(Agents, :cwds_of, ->(pids) { lsofed.concat(pids); {} }) do
          assert_empty ClaudeSessions.scan([w])
        end
      end
      assert_empty asked
      assert_empty lsofed
    end

    # Value: protects=the ⇅ and ◷ for a git-discovered worktree outside worktree_root; fails_when=the
    # filter keys on config roots instead of the tracked ws paths (Codex O4); why_new=new filter;
    # seam=none; no_claim=a real Conductor checkout
    def test_a_tracked_worktree_outside_worktree_root_keeps_its_session
      far = path("conductor", "repo", "ws1")
      FileUtils.mkdir_p(far)
      far = File.realpath(far)
      write_session("1", cwd: far)
      assert_equal [far], scan([wt("alpha"), far]).keys
    end

    def test_a_renamed_session_passes_the_filter_through_the_bridge_and_places_by_kernel_cwd
      b = wt("B")
      File.symlink(b, path("worktrees", "A"))
      write_session("1", cwd: path("worktrees", "A"))
      got = stub_method(Agents, :cwds_of, ->(pids) { pids.to_h { |p| [p, b] } }) { ClaudeSessions.scan([b]) }
      assert_equal [b], got.keys
    end

    def test_a_failed_scan_is_nil_not_empty
      stub_method(ClaudeSessions, :records, -> { raise "Claude changed its format" }) do
        assert_nil ClaudeSessions.scan([wt("alpha")])
      end
    end

    # Regression (D5-1): the ⇅ layer over the shared read gives exactly the links it gave
    # when it read the files itself — linked sessions only, unlinked/garbled/dead/untracked
    # dropped, newest first.
    def test_links_from_the_shared_read_equal_links_from_remote_link_s_own_read
      a = wt("alpha")
      b = wt("beta")
      write_session("old", cwd: a, startedAt: 100, bridgeSessionId: "session_old")
      write_session("new", cwd: a, startedAt: 300, bridgeSessionId: "session_new")
      write_session("unlinked", cwd: a, status: "shell")
      write_session("bad", cwd: b, bridgeSessionId: "not-a-bridge")
      write_session("dead", cwd: b, pid: 2**22 + 12_345, bridgeSessionId: "session_dead")
      write_session("away", cwd: wt("elsewhere"), bridgeSessionId: "session_away")
      File.write(File.join(ClaudeSessions.sessions_dir, "garbled.json"), "{not json")
      own, shared = stub_method(ProcessIdentity, :same?, ->(*) { true }) do
        stub_method(Agents, :cwds_of, ->(*) { {} }) do
          [RemoteLink.scan([a, b], stale_after: 7200),
           RemoteLink.scan([a, b], stale_after: 7200, sessions: ClaudeSessions.scan([a, b]))]
        end
      end
      assert_equal({ a => %w[session_new session_old] }, own.transform_values { |ls| ls.map(&:bridge_id) })
      assert_equal own, shared
    end

    # --- activity -----------------------------------------------------------

    def rec(status, at: ms_ago(10)) = { status: status, status_at: at }

    def test_busy_or_shell_is_offstage
      assert_equal :offstage, ClaudeSessions.activity([rec("busy")])
      assert_equal :offstage, ClaudeSessions.activity([rec("shell")])
      assert_equal :offstage, ClaudeSessions.activity([rec("idle"), rec("busy")]), "any busy session counts"
    end

    def test_only_a_settled_idle_is_idle
      assert_equal :idle, ClaudeSessions.activity([rec("idle", at: ms_ago(ClaudeSessions::SETTLE + 1))])
      assert_nil ClaudeSessions.activity([rec("idle", at: ms_ago(0.5))]), "the ~15ms idle blip before a follow-up turn"
      assert_nil ClaudeSessions.activity([rec("idle", at: nil)]), "no timestamp: no evidence"
    end

    def test_anything_else_is_no_evidence
      assert_nil ClaudeSessions.activity(nil)
      assert_nil ClaudeSessions.activity([])
      assert_nil ClaudeSessions.activity([rec("waiting")])
      assert_nil ClaudeSessions.activity([rec("")]), "missing status"
      assert_nil ClaudeSessions.activity([rec("Busy")]), "exact strings only"
    end
  end
end
