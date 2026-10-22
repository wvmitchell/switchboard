# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # The CLI seams of background dispatch: the Stop hook stamping a dispatched task's
  # first turn, quit canceling in-flight builds, and a rename carrying the record.
  class CLIDispatchTest < SandboxTest
    def setup
      super
      File.write(Config.path, YAML.dump("worktree_root" => path("wts"), "auto_rename" => true,
                                        "projects" => [{ "name" => "proj", "path" => "/p" }]))
    end

    def ready_record(dir, hooked: true)
      FileUtils.mkdir_p(dir)
      rec = Creation.create(project: "proj", name: File.basename(dir), path: dir, task: "do it")
      Creation.transition(rec["id"], from: :queued, to: :launching, hooked: hooked)
      Creation.transition(rec["id"], from: :launching, to: :ready)
      rec
    end

    def stop(worktree_dir, leaf: File.basename(worktree_dir))
      wt = Worktree.new(project: "proj", path: File.join(path("wts"), "proj", leaf), primary: false)
      stub_method(CLI, :current_worktree, ->(*) { wt }) do
        stub_method(CLI, :worktree_at, ->(_cwd) { worktree_dir }) do
          stub_method(CLI, :config, -> { Config.new }) do
            stub_method(CLI, :report_stop_state, ->(*) {}) do
              with_stdin(StringIO.new(%({"stop_hook_active":false,"cwd":"#{worktree_dir}/sub"}))) do
                capture { CLI.rename_nudge(["--stop"]) }
              end
            end
          end
        end
      end
    end

    def test_a_real_stop_stamps_the_first_turn
      rec = ready_record(path("wts", "proj", "fix-auth"))
      stop(path("wts", "proj", "fix-auth"))
      assert_equal "turn_done", Creation.find(rec["id"])["state"]
    end

    # On a placeholder, the first Stop is the rename-nudge BLOCK (the agent keeps going to
    # rename), so it must not ping; the real end of the turn comes on the next Stop.
    def test_the_rename_block_stop_does_not_stamp
      rec = ready_record(path("wts", "proj", "wandering-finch"))
      out = stop(path("wts", "proj", "wandering-finch"))
      assert_equal "block", JSON.parse(out)["decision"]
      assert_equal "ready", Creation.find(rec["id"])["state"]
    end

    # A first turn can end inside the launcher's 5s grace, while the record is still
    # launching (agent already started). That Stop must still own the ping, and the
    # launcher's later launching→ready must not bury it.
    def test_a_stop_inside_the_launch_grace_still_stamps
      dir = path("wts", "proj", "fix-auth")
      FileUtils.mkdir_p(dir)
      rec = Creation.create(project: "proj", name: "fix-auth", path: dir, task: "do it")
      Creation.transition(rec["id"], from: :queued, to: :launching, hooked: true, agent_started: true)
      stop(dir)
      refute Creation.transition(rec["id"], from: :launching, to: :ready), "the grace's ready no-ops"
      found = Creation.find(rec["id"])
      assert_equal "turn_done", found["state"]
      assert Creation.ring_due?(found)
    end

    # A setup step that itself runs claude fires a Stop while setup is still running; it
    # must not stamp the build done (and so hide setup's own later failure).
    def test_a_stop_during_setup_does_not_stamp
      dir = path("wts", "proj", "fix-auth")
      FileUtils.mkdir_p(dir)
      rec = Creation.create(project: "proj", name: "fix-auth", path: dir, task: "do it")
      Creation.transition(rec["id"], from: :queued, to: :launching, hooked: true) # agent not started
      stop(dir)
      assert_equal "launching", Creation.find(rec["id"])["state"]
      assert Creation.mark_failed(rec["id"], "setup", 1, from: "launching"), "setup's failure still lands"
    end

    def test_a_hookless_record_is_never_stamped
      rec = ready_record(path("wts", "proj", "fix-auth"), hooked: false)
      stop(path("wts", "proj", "fix-auth"))
      assert_equal "ready", Creation.find(rec["id"])["state"]
    end

    def test_quit_cancels_in_flight_builds_before_killing_sessions
      rec = Creation.create(project: "proj", name: "x", path: path("x"), task: "")
      state_at_kill = nil
      stub_method(Tmux, :kill_all, lambda {
        state_at_kill = Creation.find(rec["id"])&.dig("state")
        []
      }) { capture { CLI.quit } }
      assert_equal "canceled", state_at_kill, "the real cancel_all ran before any session was killed"
    end

    def test_launch_without_a_path_is_a_quiet_zero
      assert_equal 0, CLI.launch(nil)
    end

    private

    def capture
      out = StringIO.new
      orig = $stdout
      $stdout = out
      yield
      out.string
    ensure
      $stdout = orig
    end
  end
end
