# frozen_string_literal: true

require_relative "smoke_helper"

module Switchboard
  # Background dispatch (`n` → task → ↵) against a REAL tmux server: the contract the
  # offline suite can only stub. The worker really daemonizes and opens a DETACHED
  # session, the one typed line really runs `switchboard launch` in the pane's own
  # interactive shell, and the sidebar stays live the whole time.
  class DispatchSmokeTest < SmokeCase
    SLOW_SETUP = 3 # how long setup lingers once released

    # A setup that waits for a `.go` sentinel in the project (bounded at 30s), so a test
    # can hold the build in flight for as long as it needs instead of racing a fixed sleep;
    # an agent that records the task it was handed (via {task}, so any program opts in)
    # and then stays up past the launch grace like a real agent; and an rc alias for the
    # alias case — in both rc files, since the pane's shell is whatever tmux's
    # default-shell is ($SHELL: zsh locally, bash on the CI runner). Released by default.
    def write_project_and_config
      @project = temp_git_repo("proj")
      FileUtils.touch(go_file)
      %w[.zshrc .bashrc].each do |rcfile|
        File.open(File.join(ENV.fetch("HOME"), rcfile), "a") { |rc| rc.puts "alias dispatchagent='touch alias-ran'" }
      end
      File.write(ENV["SWITCHBOARD_CONFIG"], <<~YAML)
        worktree_root: #{path('worktrees')}
        base: main
        agent_state_hooks: false
        auto_rename: false
        background_presence: false
        worktree_creation_command: i=0; while [ ! -f "$SWITCHBOARD_PROJECT_PATH/.go" ] && [ $i -lt 300 ]; do sleep 0.1; i=$((i+1)); done; sleep #{SLOW_SETUP}; touch .setup-done
        session_command: printf '%s' {task} > .task; sleep 30
        projects:
          - name: proj
            path: #{@project}
      YAML
    end

    def new_worktree
      Dir.glob(File.join(path("worktrees"), "proj", "*")).find { |d| File.directory?(d) }
    end

    def go_file
      File.join(@project, ".go")
    end

    def test_the_sidebar_shows_the_build_in_flight_and_the_client_never_moves
      File.delete(go_file) # hold setup until we've seen the build in flight
      home_pane = sidebar_pane_ids(HOME).first
      sess = create_workspace(task: "first task")
      wt = new_worktree
      refute File.exist?(File.join(wt, ".setup-done")), "precondition: setup is still running"
      wait_until("home shows the ◌ building row while setup runs") { capture(home_pane).include?("◌") }
      assert_equal HOME, client_session
      refute_nil sess
    ensure
      FileUtils.touch(go_file) if @project
    end

    def test_the_agent_receives_the_task_byte_exact_after_setup
      task = %(it's "quoted" $HOME `tick` & done)
      create_workspace(task: task)
      wt = new_worktree
      wait_until("the agent wrote its task", timeout: SLOW_SETUP + 15) { File.exist?(File.join(wt, ".task")) }
      assert File.exist?(File.join(wt, ".setup-done")), "setup finished before the agent ran"
      assert_equal task, File.read(File.join(wt, ".task")), "the task arrives byte-exact through the pane's shell"
      wait_until("the build reaches ready once the agent outlives the grace", timeout: Creator::LAUNCH_GRACE + 10) do
        Creation.all.any? { |r| r["state"] == "ready" }
      end
    end

    # D14: the agent runs in the pane's own interactive shell, so an rc alias resolves —
    # exactly as when the command used to be typed into the pane.
    def test_an_rc_alias_resolves_as_the_session_command
      config = YAML.safe_load_file(ENV["SWITCHBOARD_CONFIG"])
      File.write(ENV["SWITCHBOARD_CONFIG"], YAML.dump(config.merge("session_command" => "dispatchagent",
                                                                   "worktree_creation_command" => nil)))
      create_workspace
      wt = new_worktree
      wait_until("the alias-based agent ran") { File.exist?(File.join(wt, "alias-ran")) }
    end

    # A multi-line paste into the task prompt (tmux's bracketed paste, as a real terminal
    # sends it) stays text: it neither submits on its first newline nor leaks into the
    # tree as keys — its `d`…`y` / `q`…`y` would delete a workspace / quit everything.
    def test_a_multiline_paste_into_the_task_prompt_stays_text
      pane = sidebar_pane_ids(HOME).first
      tmux!("send-keys", "-t", pane, "n")
      wait_until("the task prompt is open") { capture(pane).include?("task ›") }
      tmux!("set-buffer", "-b", "sbpaste", "fix the thing\nthen d y and q y\nend")
      tmux!("paste-buffer", "-p", "-d", "-b", "sbpaste", "-t", pane)
      wait_until("the whole paste lands on the prompt line") { capture(pane).include?("q y end") }
      assert_empty Creation.all, "the paste's newlines never submitted"
      tmux!("send-keys", "-t", pane, "Enter")
      rec = wait_until("one dispatch, from the real ↵") { Creation.all.first }
      assert_equal "fix the thing then d y and q y end", rec["task"]
      assert_equal 1, Creation.all.size
      assert_equal HOME, client_session, "no stray q/y quit or switched anything"
    end

    # Fail-closed for a COMPOUND session_command — the `;` leak the old typed chain had.
    def test_a_failing_setup_never_starts_a_compound_agent
      config = YAML.safe_load_file(ENV["SWITCHBOARD_CONFIG"])
      File.write(ENV["SWITCHBOARD_CONFIG"],
                 YAML.dump(config.merge("worktree_creation_command" => "cp /nonexistent/switchboard-missing .",
                                        "session_command" => "export X=1; touch agent-ran")))
      home_pane = sidebar_pane_ids(HOME).first
      create_workspace
      wt = new_worktree
      wait_until("home shows the ✘ failure") { capture(home_pane).include?("✘") }
      refute File.exist?(File.join(wt, "agent-ran")), "a failed setup must block even a compound agent command"
    end
  end
end
