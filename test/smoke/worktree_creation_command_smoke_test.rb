# frozen_string_literal: true

require_relative "smoke_helper"

module Switchboard
  # `worktree_creation_command` (#83) against a REAL tmux server: the runtime contract
  # the offline suite structurally cannot reach. Stubbing `Tmux.go` proves only that we
  # composed the right STRING — it never proves that string, typed into a real shell,
  # actually runs the setup in the new worktree, before the agent, and fail-closed. And
  # the `sh -ec` wrapper is new machinery: `session_command`'s track record doesn't
  # cover it, because nothing in switchboard typed a wrapped command before this.
  #
  # Both fixtures are chosen to DISCRIMINATE — each one fails if the implementation
  # regresses to the two designs the review rejected:
  #
  #   the `&&`-splice  ─▶ caught by the trailing `#` comment in the happy-path script:
  #                       spliced, `… # comment && touch .setup-ran && echo agent` puts
  #                       EVERYTHING after the `#` inside the comment, so neither the
  #                       second step nor the agent ever runs. (A bare multi-line script
  #                       would NOT catch it — "a\nb\nc" splices to "a && b && c", which
  #                       is perfectly valid shell.)
  #   dropping `-e`    ─▶ caught by failing on a real COMMAND (`cp` of a missing file)
  #                       rather than an explicit `exit 1` — an `exit` aborts the script
  #                       whether or not `-e` is set, so it would pin nothing. Without
  #                       `-e`, the `cp` failure is ignored, the last step still runs, and
  #                       sh exits 0 — so the agent starts and BOTH refutes below fire.
  #
  #   worktree_creation_command ──▶ sh -ec '<script>' ──┐
  #                                                     ├── && ──▶ session_command
  #   (a step fails here)  ─── set -e, non-zero ────────┘         (must NOT run)
  class WorktreeCreationCommandCase < SmokeCase
    # The setup script this case seeds (YAML, verbatim under the key).
    def setup_yaml = raise(NotImplementedError)

    # Base fixture + the two command knobs. session_command appends `agent`, so the
    # `.order` file records exactly what ran, in what order.
    def write_project_and_config
      @project = temp_git_repo("proj")
      File.write(ENV["SWITCHBOARD_CONFIG"], <<~YAML)
        worktree_root: #{path('worktrees')}
        base: main
        agent_state_hooks: false
        session_command: echo agent >> .order
        worktree_creation_command: #{setup_yaml}
        projects:
          - name: proj
            path: #{@project}
      YAML
    end

    # The one worktree `n` just made. Derived from disk, not the session name, so a
    # placeholder with an odd leaf can't break the lookup.
    def new_worktree
      Dir.glob(File.join(path("worktrees"), "proj", "*")).find { |d| File.directory?(d) }
    end

    def order_file = File.join(new_worktree.to_s, ".order")

    def order = File.exist?(order_file) ? File.read(order_file).split("\n") : []

    # Prove the typed chain has FINISHED, without a fixed sleep (SmokeCase's anti-flake
    # rule: every wait is a wait_until). The pane's tty queues this behind whatever is
    # already running, so once `sentinel` lands, the chain ahead of it is done — and any
    # `agent` append it was going to make has already happened. That turns the negative
    # assertions below into a real gate instead of a race.
    def wait_for_chain_to_drain(session)
      tmux!("send-keys", "-t", work_pane_id(session), "echo sentinel >> .order", "Enter")
      wait_until("the typed chain drained") { order.include?("sentinel") }
    end
  end

  # The happy path, seeded as a YAML LIST — the multi-step shape the review chose, which
  # `sh -ec` runs under `set -e`. The trailing `#` comment on the first step is the
  # splice-detector (see the class comment).
  class WorktreeCreationCommandSmokeTest < WorktreeCreationCommandCase
    # The first step is QUOTED so the `#` survives YAML — unquoted, ` #` starts a YAML
    # comment and the marker is stripped before the shell ever sees it (which silently
    # defeats the splice-detector this fixture exists to be). The last step copies out of
    # $SWITCHBOARD_PROJECT_PATH: a worktree has NO relative path to the project's checkout,
    # so this is the only way the feature's headline use case (bring the .env over) can be
    # written — and it must survive as a $VAR for the `sh` child to expand.
    def setup_yaml
      <<~YAML.chomp
        \n  - "echo setup >> .order   # bring the env over"
          - touch .setup-ran
          - cp "$SWITCHBOARD_PROJECT_PATH/.env" .
      YAML
    end

    # Seed a .env in the project's canonical checkout — the file a fresh worktree does NOT
    # inherit, which is the whole reason #83 exists.
    def write_project_and_config
      super
      File.write(File.join(@project, ".env"), "SECRET=from-the-main-checkout\n")
    end

    def test_setup_runs_in_the_new_worktree_before_the_agent
      create_workspace

      wait_until("the agent command ran") { order.include?("agent") }

      assert_equal %w[setup agent], order,
                   "the setup script runs IN the new worktree, and the agent starts only after it"
      assert_path_exists File.join(new_worktree, ".setup-ran"),
                         "every step of the list runs, in the worktree's own cwd — a `&&` splice " \
                         "would have buried this one (and the agent) inside the trailing # comment"
      assert_equal "SECRET=from-the-main-checkout\n", File.read(File.join(new_worktree, ".env")),
                   "$SWITCHBOARD_PROJECT_PATH reaches the script, so the untracked .env a new " \
                   "worktree never inherits can actually be copied over — the #83 use case"
    end
  end

  # Fail-closed, seeded as a multi-line BLOCK that fails on a real COMMAND. Proves three
  # things at once: the script reaches the shell intact, `set -e` stops it at the failing
  # step, and the non-zero exit short-circuits the `&&` so the agent never starts.
  class WorktreeCreationCommandFailureSmokeTest < WorktreeCreationCommandCase
    def setup_yaml
      <<~YAML.chomp
        |
          echo setup >> .order
          cp /nonexistent/switchboard-smoke-missing .
          echo unreachable >> .order
      YAML
    end

    def test_a_failing_setup_stops_the_script_and_blocks_the_agent
      session = create_workspace

      wait_until("the setup script ran") { order.include?("setup") }
      wait_for_chain_to_drain(session) # no fixed sleep: the refutes below need a real gate

      refute_includes order, "unreachable", "set -e stops the script at the failing step"
      refute_includes order, "agent",
                      "a failed setup must block the agent — it never opens on a half-built worktree"
      assert_equal %w[setup sentinel], order
    end
  end
end
