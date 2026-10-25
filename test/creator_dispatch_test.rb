# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # The background dispatch path: the worker (Creator.work) against a real repo with tmux
  # stubbed, and the launcher (Creator.launch) running real `sh` setup scripts. The tmux
  # side — the session really opening detached, the line really being typed — is the
  # smoke layer's job (test/smoke/dispatch_smoke_test.rb).
  class CreatorDispatchTest < SandboxTest
    # Creator.launch shields INT/QUIT in its own (pane) process; these tests run it
    # in-process, so restore them or ^C stops working for the rest of the run.
    def setup
      super
      @saved_traps = %w[INT QUIT].to_h { |sig| [sig, trap(sig, "DEFAULT")] }
      @saved_traps.each { |sig, handler| trap(sig, handler) }
    end

    def teardown
      @saved_traps.each { |sig, handler| trap(sig, handler || "DEFAULT") }
      super
    end

    def config_for(repo, **extra)
      File.write(Config.path, YAML.dump({ "worktree_root" => path("wts"), "base" => "main",
                                          "projects" => [{ "name" => "proj", "path" => repo }] }.merge(extra)))
      Config.new
    end

    def dispatch(config, task: "fix the thing")
      name, dest = Creator.reserve(config, "proj")
      Creation.create(project: "proj", name: name, path: dest, task: task)
    end

    # Stand-in tmux: records the session and pretends the launcher claimed the build right
    # after it opened, so await_claim returns at once. The claim happens in ensure_sidebar,
    # NOT ensure_session: the worker calls ensure_session while holding the record's
    # flock, and a second flock from this same process would block forever (the real
    # launcher is another process and simply waits its turn).
    def with_fake_tmux(created: true, claim: true)
      calls = []
      ensure_session = lambda do |name, dir, start|
        calls << [name, dir, start]
        created
      end
      ensure_sidebar = lambda do |_name|
        rec = calls.last && Creation.for_path(calls.last[1])
        Creation.transition(rec["id"], from: :building, to: :launching, **Creation.owner_fields) if claim && rec
      end
      stub_method(Tmux, :ensure_session, ensure_session) do
        stub_method(Tmux, :ensure_sidebar, ensure_sidebar) do
          stub_method(Tmux, :broadcast_warm, ->(**_k) {}) { yield calls }
        end
      end
    end

    # --- reserve ---------------------------------------------------------------------

    def test_reserve_skips_names_held_by_in_flight_dispatches
      config = config_for(temp_git_repo("proj", origin: true))
      Creation.create(project: "proj", name: "taken-one", path: File.join(config.worktree_root, "proj", "taken-one"),
                      task: "")
      names = %w[taken-one free-one]
      stub_method(Placeholder, :generate, -> { names.shift }) do
        assert_equal "free-one", Creator.reserve(config, "proj").first,
                     "a pending dispatch's name is taken even though its dir doesn't exist yet"
      end
    end

    def test_reserve_skips_existing_branches
      repo = temp_git_repo("proj", origin: true)
      config = config_for(repo)
      git(repo, "branch", "has-branch")
      names = %w[has-branch open-name]
      stub_method(Placeholder, :generate, -> { names.shift }) do
        assert_equal "open-name", Creator.reserve(config, "proj").first
      end
    end

    # --- work -----------------------------------------------------------------------

    def test_work_builds_the_worktree_and_opens_a_detached_session_running_launch
      config = config_for(temp_git_repo("proj", origin: true))
      rec = dispatch(config)
      with_fake_tmux do |calls|
        Creator.work(config, rec["id"])
        found = Creation.find(rec["id"])
        assert found["worktree_added"]
        assert File.directory?(found["path"])
        assert_equal found["name"], Git.current_branch(found["path"])
        _, dir, start = calls.first
        assert_equal found["path"], dir
        assert_match(/ launch #{Regexp.escape(Shellwords.escape(found['path']))}\z/, start)
      end
    end

    def test_work_stops_if_canceled_before_the_session
      config = config_for(temp_git_repo("proj", origin: true))
      rec = dispatch(config)
      with_fake_tmux do |calls|
        stub_method(Creator, :hooked?, lambda { |*_a|
          Creation.cancel_all # quit lands mid-build
          false
        }) do
          Creator.work(config, rec["id"])
        end
        assert_empty calls, "a canceled build never opens a session"
        assert_equal "canceled", Creation.find(rec["id"])["state"]
      end
      refute_path_exists Creation.find(rec["id"])["path"], "and its untouched worktree is rolled back"
    end

    # A quit during the fetch: the worker must not go on to make the worktree.
    def test_work_stops_before_the_add_if_canceled_during_the_fetch
      repo = temp_git_repo("proj", origin: true)
      config = config_for(repo)
      rec = dispatch(config)
      added = false
      with_fake_tmux do |calls|
        stub_method(Git, :fetch_base, ->(*_a, **_k) { Creation.cancel_all }) do
          stub_method(Creator, :add_worktree, ->(*_a) { added = true }) { Creator.work(config, rec["id"]) }
        end
        assert_empty calls
      end
      refute added, "the post-fetch re-check stops it before git ever runs"
      refute_path_exists rec["path"]
      refute Git.branch_exists?(repo, rec["name"])
    end

    # A cancel that lands while `git worktree add` runs: the fresh tree is rolled back,
    # since no setup will ever run there.
    def test_work_discards_a_worktree_whose_build_was_canceled_mid_add
      repo = temp_git_repo("proj", origin: true)
      config = config_for(repo)
      rec = dispatch(config)
      real_add = Creator.method(:add_worktree)
      add = lambda do |*a|
        result = real_add.call(*a)
        Creation.cancel_all
        result
      end
      with_fake_tmux do |calls|
        stub_method(Creator, :add_worktree, add) { Creator.work(config, rec["id"]) }
        assert_empty calls
      end
      refute_path_exists rec["path"]
      refute Git.branch_exists?(repo, rec["name"])
    end

    # The same cancel, but something already wrote in the fresh tree (a checkout hook,
    # another tool): never force-delete it. It stays, and the record remembers the tree
    # exists so re-entry keeps the plain-shell guard.
    def test_work_keeps_a_canceled_tree_that_was_written_to
      repo = temp_git_repo("proj", origin: true)
      config = config_for(repo)
      rec = dispatch(config)
      real_add = Creator.method(:add_worktree)
      add = lambda do |*a|
        result = real_add.call(*a)
        File.write(File.join(a[3], "notes.txt"), "mine\n")
        Creation.cancel_all
        result
      end
      with_fake_tmux { stub_method(Creator, :add_worktree, add) { Creator.work(config, rec["id"]) } }
      assert_path_exists File.join(rec["path"], "notes.txt")
      found = Creation.find(rec["id"])
      assert found["worktree_added"]
      assert Creation.unfinished?(found)
    end

    def test_work_fails_a_build_for_a_project_removed_after_dispatch
      config = config_for(temp_git_repo("proj", origin: true))
      rec = Creation.create(project: "gone", name: "x", path: path("wts", "gone", "x"), task: "")
      with_fake_tmux { Creator.work(config, rec["id"]) }
      found = Creation.find(rec["id"])
      assert_equal %w[failed worktree_add], found.values_at("state", "reason")
      assert_equal "unknown project", found["detail"]
    end

    def test_work_fails_when_the_session_cannot_be_created
      config = config_for(temp_git_repo("proj", origin: true))
      rec = dispatch(config)
      with_fake_tmux(created: false, claim: false) { Creator.work(config, rec["id"]) }
      found = Creation.find(rec["id"])
      assert_equal "failed", found["state"]
      assert_equal "session", found["reason"]
    end

    def test_work_fails_with_gits_message_when_worktree_add_fails
      config = config_for(temp_git_repo("proj", origin: true), "base" => "no-such-ref")
      rec = dispatch(config)
      with_fake_tmux { Creator.work(config, rec["id"]) }
      found = Creation.find(rec["id"])
      assert_equal "failed", found["state"]
      assert_equal "worktree_add", found["reason"]
      refute_empty found["detail"].to_s
    end

    # Value: protects=a stalled checkout (hook, LFS smudge) fails the add at its deadline and its whole process group dies; fails_when=add_worktree drops the deadline or signals only git's pid, so the row sits on ◌ or a hook outlives the build; why_new=only fetch_base's timeout is tested; add_worktree's own deadline/group kill is not; seam=none; no_claim=the ✘ row rendering of the reason
    def test_a_stalled_worktree_add_times_out_and_kills_its_process_group
      repo = temp_git_repo("proj", origin: true)
      hooks = path("hooks")
      FileUtils.mkdir_p(hooks)
      pidfile = path("hook.pid")
      File.write(File.join(hooks, "post-checkout"), "#!/bin/sh\necho $$ > #{pidfile}\nexec sleep 30\n")
      File.chmod(0o755, File.join(hooks, "post-checkout"))
      git(repo, "config", "core.hooksPath", hooks)
      config = config_for(repo)
      started = Time.now
      ok, err = Creator.add_worktree(config, config.project("proj"), "slow-otter", path("wts", "slow-otter"), "main",
                                     timeout: 3)
      refute ok
      assert_equal "timed out after 3s", err
      assert_operator Time.now - started, :<, 10, "gave up at the deadline, not after the stalled hook"
      hook_pid = File.read(pidfile).to_i
      dead = 20.times.any? { ProcessIdentity.alive?(hook_pid) ? (sleep 0.1; false) : true }
      assert dead, "the hook git forked dies with the group, not just git"
    end

    # Value: protects=a canceled tree with a COMMIT past base (clean working tree) or an unresolvable base is never read as untouched; fails_when=untouched? checks only Git.clean? or commits_since returns 0 on a bad ref, so discard force-deletes committed work; why_new=keep-tests write an uncommitted file or stub untouched?; seam=none; no_claim=the discard call sites
    def test_untouched_only_for_a_clean_tree_with_nothing_past_its_base
      repo = temp_git_repo("proj", origin: true)
      dest = path("wt")
      git(repo, "worktree", "add", "-q", "--no-track", "-b", "fresh", dest, "main")
      assert Creator.untouched?(dest, "main"), "a fresh checkout is untouched"
      refute Creator.untouched?(dest, "no-such-ref"), "a base git can't resolve can't prove nothing would be lost"
      refute Creator.untouched?(dest, nil)
      git(dest, "commit", "-q", "--allow-empty", "-m", "agent work")
      refute Creator.untouched?(dest, "main"), "a committed-but-clean tree still holds work"
    end

    def test_work_retries_a_branch_collision_and_relabels_the_record
      repo = temp_git_repo("proj", origin: true)
      config = config_for(repo)
      rec = dispatch(config)
      git(repo, "branch", rec["name"]) # someone took the branch after we reserved it
      stub_method(Placeholder, :generate, -> { "second-try" }) do
        with_fake_tmux { Creator.work(config, rec["id"]) }
      end
      found = Creation.find(rec["id"])
      assert_equal "second-try", found["name"]
      assert found["worktree_added"]
    end

    # The retry's new name must dodge other in-flight dispatches too, not just git: two
    # records sharing a path would let the launcher claim the wrong one.
    def test_work_retry_skips_a_name_another_dispatch_reserved
      repo = temp_git_repo("proj", origin: true)
      config = config_for(repo)
      rec = dispatch(config)
      Creation.create(project: "proj", name: "second-try",
                      path: File.join(config.worktree_root, "proj", "second-try"), task: "")
      git(repo, "branch", rec["name"])
      names = %w[second-try third-try]
      stub_method(Placeholder, :generate, -> { names.shift || "fourth-try" }) do
        with_fake_tmux { Creator.work(config, rec["id"]) }
      end
      assert_equal "third-try", Creation.find(rec["id"])["name"]
    end

    # Two panes pressing `n` at once, both drawing the same placeholder: the reservation
    # lock makes "pick a free name" + "write the record" one step, so they can't both
    # claim it (the launcher would then run the wrong task). Branch lookups are slowed so
    # an unlocked version reliably interleaves.
    def test_concurrent_dispatches_never_share_a_name
      config = config_for(temp_git_repo("proj", origin: true))
      stub_method(Git, :branch_exists?, lambda { |*|
        sleep 0.2
        false
      }) do
        stub_method(Placeholder, :generate, -> { %w[same-name other-name][Creation.all.size] || "third-name" }) do
          pids = 2.times.map { fork { exit!(Creator.dispatch(config, "proj", "t").is_a?(Hash) ? 0 : 1) } }
          pids.each { |pid| Process.wait(pid) }
        end
      end
      paths = Creation.all.map { |r| r["path"] }
      assert_equal 2, paths.size
      assert_equal paths.uniq, paths, "each dispatch claimed its own name"
    end

    def test_work_stops_if_the_record_left_queued
      config = config_for(temp_git_repo("proj", origin: true))
      rec = dispatch(config)
      Creation.transition(rec["id"], from: :queued, to: :failed, reason: "didnt_start")
      with_fake_tmux do |calls|
        Creator.work(config, rec["id"])
        assert_empty calls, "a record GC already failed is never built"
      end
    end

    def test_await_claim_times_out_into_a_failure
      rec = Creation.create(project: "proj", name: "x", path: path("x"), task: "")
      Creation.transition(rec["id"], from: :queued, to: :building)
      t = Time.now
      clock = -> { t += 30 }
      refute Creator.await_claim(rec["id"], deadline: 60, poll: 0, clock: clock)
      assert_equal "didnt_start", Creation.find(rec["id"])["reason"]
    end

    # --- hooked ----------------------------------------------------------------------

    def hooked_worktree(config)
      dest = path("wts", "proj", "hooked")
      FileUtils.mkdir_p(dest)
      Creator.enable_hooks(config, "proj", dest)
      dest
    end

    def test_hooked_only_for_a_claude_command_with_its_hook_written
      config = config_for(temp_git_repo("proj", origin: true), "session_command" => "claude --dangerously-skip-permissions")
      assert Creator.hooked?(config, "proj", hooked_worktree(config))
    end

    def test_not_hooked_for_aider_even_with_default_hook_config
      config = config_for(temp_git_repo("proj", origin: true), "session_command" => "aider")
      refute Creator.hooked?(config, "proj", hooked_worktree(config)),
             "auto_rename wires the Claude hook, but aider never fires it"
    end

    def test_not_hooked_for_codex
      config = config_for(temp_git_repo("proj", origin: true), "session_command" => "codex")
      refute Creator.hooked?(config, "proj", path("anywhere"))
    end

    def test_not_hooked_when_the_hook_write_failed
      config = config_for(temp_git_repo("proj", origin: true), "session_command" => "claude")
      stub_method(ClaudeHook, :enabled?, ->(_wt) { false }) do
        refute Creator.hooked?(config, "proj", path("anywhere"))
      end
    end

    # --- the task contract (D9) --------------------------------------------------------

    def test_agent_program_skips_env_prefixes
      assert_equal "claude", Creator.agent_program("env FOO=1 BAR=2 /usr/local/bin/claude --x")
      assert_equal "aider", Creator.agent_program("aider --model x")
      assert_nil Creator.agent_program(false)
    end

    def test_agent_command_appends_for_simple_claude_and_codex
      assert_equal ['claude --x "$SWITCHBOARD_TASK"', nil], Creator.agent_command("claude --x", "do it")
      assert_equal ['codex "$SWITCHBOARD_TASK"', nil], Creator.agent_command("codex", "do it")
    end

    def test_agent_command_never_appends_to_aider_or_a_compound
      %w[aider claude;echo].each do |cmd|
        out, note = Creator.agent_command(cmd, "do it")
        assert_equal cmd, out
        assert_equal Creation.notice(:task_not_sent), note
      end
      assert_equal "export X=1; claude", Creator.agent_command("export X=1; claude", "do it").first
    end

    def test_agent_command_task_placeholder_opts_any_command_in
      assert_equal ['aider --message "$SWITCHBOARD_TASK"', nil], Creator.agent_command("aider --message {task}", "do it")
      assert_equal ["aider --message ", nil], Creator.agent_command("aider --message {task}", "")
    end

    # However {task} is written — bare, in its own quotes, or inside a longer quoted
    # string — the agent gets exactly ONE argument carrying the task byte-exact, through
    # a real shell, even when the task holds quotes, $, a glob and a newline.
    def test_task_placeholder_is_one_exact_argument_in_every_quote_context
      task = %(it's "quoted" $HOME * and\na newline)
      { "agent {task}" => task,
        'agent "{task}"' => task,
        "agent '{task}'" => task,
        'agent "fix: {task}"' => "fix: #{task}",
        "agent 'do {task} now'" => "do #{task} now" }.each do |template, want|
        cmd, = Creator.agent_command(template, task)
        script = "agent() { printf '%s\\0' \"$#\" \"$@\"; }; #{cmd}"
        out = IO.popen({ "SWITCHBOARD_TASK" => task }, ["sh", "-c", script], &:read)
        assert_equal ["1", want], out.split("\0"), template
      end
    end

    # A YAML block scalar leaves a trailing newline; appending after it would make the
    # task run as its OWN COMMAND once the agent exits. Comments, & and quoting likewise
    # can't take an auto-append.
    def test_auto_append_only_to_plain_word_commands
      assert_equal ['claude --x "$SWITCHBOARD_TASK"', nil], Creator.agent_command("claude --x\n", "t")
      ["claude # my agent", "claude &", %(claude --model "opus 4"), "claude $(echo x)"].each do |cmd|
        assert_equal [cmd, Creation.notice(:task_not_sent)], Creator.agent_command(cmd, "t"), cmd
      end
    end

    def test_agent_command_without_a_task_is_the_bare_command
      assert_equal ["claude", nil], Creator.agent_command("claude", "")
    end

    # No agent to hand the task to: say so in the pane rather than drop it silently.
    def test_agent_command_is_nil_for_a_disabled_session_command
      [nil, false, "", "  "].each do |c|
        assert_equal [nil, Creation.notice(:no_agent)], Creator.agent_command(c, "task")
        assert_equal [nil, nil], Creator.agent_command(c, "")
      end
    end

    def test_a_quoted_task_template_with_no_task_drops_its_empty_quotes
      assert_equal "claude ", Creator.agent_command("claude '{task}'", "").first
      assert_equal "claude  --x", Creator.agent_command(%(claude "{task}" --x), "").first
      assert_equal %(claude ''"$SWITCHBOARD_TASK"''), Creator.agent_command("claude '{task}'", "t").first
    end

    # --- launch ----------------------------------------------------------------------

    def built(config, task: "fix it")
      rec = dispatch(config, task: task)
      FileUtils.mkdir_p(rec["path"])
      Creation.transition(rec["id"], from: :queued, to: :building, **Creation.owner_fields)
      Creation.update(rec["id"], worktree_added: true)
      rec
    end

    def launch(config, rec)
      out = StringIO.new
      status = nil
      stub_method(Creator, :pane_shell, -> { "/bin/sh" }) do
        status = Creator.launch(config, rec["path"], out: out)
      end
      [status, out.string, Creation.find(rec["id"])]
    end

    def test_launch_fails_the_build_when_setup_fails_and_never_starts_the_agent
      config = config_for(temp_git_repo("proj", origin: true),
                          "worktree_creation_command" => "false", "session_command" => "touch AGENT_RAN")
      rec = built(config)
      status, out, found = launch(config, rec)
      assert_equal 1, status
      assert_equal "failed", found["state"]
      assert_equal "setup exit 1", Creation.row_reason(found)
      assert_includes out, "switchboard: setup failed (exit 1)"
      refute_path_exists File.join(rec["path"], "AGENT_RAN")
    end

    # The `;` leak the old typed chain had: `a && export X=1; claude` ran claude anyway.
    def test_launch_is_fail_closed_for_a_compound_session_command
      config = config_for(temp_git_repo("proj", origin: true),
                          "worktree_creation_command" => "exit 3", "session_command" => "export X=1; touch AGENT_RAN")
      rec = built(config)
      launch(config, rec)
      refute_path_exists File.join(rec["path"], "AGENT_RAN")
    end

    def test_setup_sees_the_task_and_both_paths
      script = 'printf "%s|%s|%s" "$SWITCHBOARD_TASK" "$SWITCHBOARD_WORKTREE_PATH" "$PWD" > seen'
      config = config_for(temp_git_repo("proj", origin: true), "worktree_creation_command" => script)
      rec = built(config, task: %(quote " and $dollar and `tick`))
      launch(config, rec)
      task, wt, pwd = File.read(File.join(rec["path"], "seen")).split("|")
      assert_equal %(quote " and $dollar and `tick`), task, "the task arrives byte-exact"
      assert_equal rec["path"], wt
      assert_equal File.realpath(rec["path"]), File.realpath(pwd)
    end

    # --- ported from the retired start_command tests (D11 regression contract) ---------

    def quick_launch(config, rec)
      stub_method(Creator, :pane_shell, -> { "/bin/sh" }) do
        Creator.launch(config, rec["path"], out: StringIO.new, grace: 0.2)
      end
      Creation.find(rec["id"])
    end

    def test_setup_runs_in_the_worktree_and_the_agent_only_after_it
      config = config_for(temp_git_repo("proj", origin: true),
                          "worktree_creation_command" => "echo setup >> order",
                          "session_command" => "echo agent >> order; sleep 0.5")
      rec = built(config)
      assert_equal "ready", quick_launch(config, rec)["state"]
      assert_equal %w[setup agent], File.readlines(File.join(rec["path"], "order"), chomp: true)
    end

    # The script reaches `sh -ec` as ONE argument, verbatim — a multi-line block with a
    # trailing comment stays valid shell, and `-e` stops it at the first failing step.
    def test_a_multiline_script_survives_verbatim
      script = "if true; then\n  touch made\nfi # trailing comment && touch never"
      config = config_for(temp_git_repo("proj", origin: true), "worktree_creation_command" => script)
      rec = built(config, task: "")
      quick_launch(config, rec)
      assert_path_exists File.join(rec["path"], "made")
      refute_path_exists File.join(rec["path"], "never")
    end

    def test_an_apostrophe_in_the_script_survives
      config = config_for(temp_git_repo("proj", origin: true), "worktree_creation_command" => %(echo "it's done" > out))
      rec = built(config, task: "")
      quick_launch(config, rec)
      assert_equal "it's done\n", File.read(File.join(rec["path"], "out"))
    end

    def test_setup_alone_with_no_session_command_is_ready
      config = config_for(temp_git_repo("proj", origin: true), "worktree_creation_command" => "touch setup-ran")
      rec = built(config, task: "")
      assert_equal "ready", quick_launch(config, rec)["state"]
      assert_path_exists File.join(rec["path"], "setup-ran")
    end

    def test_session_command_alone_runs_the_agent
      config = config_for(temp_git_repo("proj", origin: true), "session_command" => "touch agent-ran; sleep 0.5")
      rec = built(config, task: "")
      quick_launch(config, rec)
      assert_path_exists File.join(rec["path"], "agent-ran")
    end

    # `session_command: false` is the config's OFF idiom: no agent, and never the word
    # `false` run as a command after setup.
    def test_a_false_session_command_is_off
      config = config_for(temp_git_repo("proj", origin: true),
                          "session_command" => false, "worktree_creation_command" => "touch setup-ran")
      rec = built(config, task: "")
      found = quick_launch(config, rec)
      assert_equal "ready", found["state"], "no agent configured: a plain shell, ready"
      assert_path_exists File.join(rec["path"], "setup-ran")
    end

    def test_launch_with_no_agent_is_ready_at_once
      config = config_for(temp_git_repo("proj", origin: true))
      rec = built(config, task: "")
      status, _out, found = launch(config, rec)
      assert_equal 0, status
      assert_equal "ready", found["state"]
    end

    def test_launch_prints_task_not_sent_for_an_unknown_agent
      config = config_for(temp_git_repo("proj", origin: true), "session_command" => "true")
      rec = built(config)
      _status, out, = launch(config, rec)
      assert_includes out, "task not sent"
    end

    def test_an_agent_that_dies_in_the_grace_window_fails_the_build
      rec = Creation.create(project: "proj", name: "a", path: path("a"), task: "")
      FileUtils.mkdir_p(path("a"))
      Creation.transition(rec["id"], from: :queued, to: :launching)
      stub_method(Creator, :pane_shell, -> { "/bin/sh" }) do
        assert_equal 127, Creator.run_agent(rec["id"], "no-such-agent-xyz", path("a"), StringIO.new, grace: 2)
      end
      found = Creation.find(rec["id"])
      assert_equal "failed", found["state"]
      assert_equal "agent exit 127", Creation.row_reason(found)
    end

    def test_an_agent_that_survives_the_grace_window_is_ready
      rec = Creation.create(project: "proj", name: "b", path: path("b"), task: "")
      FileUtils.mkdir_p(path("b"))
      Creation.transition(rec["id"], from: :queued, to: :launching)
      seen = nil
      stub_method(Creator, :pane_shell, -> { "/bin/sh" }) do
        thread = Thread.new { Creator.run_agent(rec["id"], "sleep 3", path("b"), StringIO.new, grace: 0.3) }
        # Poll for the state to leave launching (a loaded CI box can be slow to get
        # there) rather than reading it after a fixed sleep.
        deadline = Time.now + 5
        sleep 0.05 while (seen = Creation.find(rec["id"])["state"]) == "launching" && Time.now < deadline
        thread.join
      end
      assert_equal "ready", seen
    end

    def test_launch_no_ops_on_a_canceled_build
      config = config_for(temp_git_repo("proj", origin: true), "session_command" => "touch AGENT_RAN")
      rec = built(config)
      Creation.cancel_all
      status, out, = launch(config, rec)
      assert_equal 0, status
      assert_includes out, "canceled"
      refute_path_exists File.join(rec["path"], "AGENT_RAN")
    end

    # A quit or d during setup cancels the record; the launcher must not then start the agent.
    def test_launch_skips_the_agent_when_canceled_during_setup
      config = config_for(temp_git_repo("proj", origin: true), "session_command" => "touch AGENT_RAN")
      rec = built(config)
      stub_method(Creator, :run_setup, lambda { |*_a|
        Creation.cancel_all
        0
      }) do
        status, out, found = launch(config, rec)
        assert_equal 0, status
        assert_includes out, "canceled"
        assert_equal "canceled", found["state"]
      end
      refute_path_exists File.join(rec["path"], "AGENT_RAN")
    end

    # A canceled build GC'd while setup ran leaves NO record when setup returns; that
    # must stop the launch, not read as "nothing says stop".
    def test_launch_never_starts_the_agent_when_the_record_vanished_during_setup
      config = config_for(temp_git_repo("proj", origin: true), "session_command" => "touch AGENT_RAN")
      rec = built(config)
      stub_method(Creator, :run_setup, lambda { |*_a|
        Creation.delete(rec["id"])
        0
      }) do
        _, out, = launch(config, rec)
        assert_includes out, "canceled"
      end
      refute_path_exists File.join(rec["path"], "AGENT_RAN")
    end

    # A config.yml we can't read can't say what setup to run: fail, don't certify setup.
    def test_launch_fails_on_an_unreadable_config_instead_of_skipping_setup
      config = config_for(temp_git_repo("proj", origin: true), "session_command" => "touch AGENT_RAN")
      rec = built(config)
      File.write(Config.path, "projects: [unclosed")
      status, out, found = launch(Config.new, rec)
      assert_equal 1, status
      assert_equal %w[failed config], found.values_at("state", "reason")
      refute found["setup_ok"]
      assert_includes out, "config"
      refute_path_exists File.join(rec["path"], "AGENT_RAN")
    end

    # Value: protects=a setup list YAML mangled (an unquoted `: ` turns a step into a map) fails the build instead of starting the agent with no setup; fails_when=launch treats an unusable setup value as "no setup" and certifies the tree; why_new=only an unparseable file and a removed project were covered; seam=none; no_claim=doctor surfacing the bad value
    def test_launch_fails_on_a_setup_it_reads_but_cannot_run
      steps = YAML.safe_load("- touch SETUP_RAN\n- echo \"Setup: complete\"\n")
      config = config_for(temp_git_repo("proj", origin: true), "session_command" => "touch AGENT_RAN",
                                                                "worktree_creation_command" => steps)
      rec = built(config)
      status, _out, found = launch(config, rec)
      assert_equal 1, status
      assert_equal %w[failed config], found.values_at("state", "reason")
      refute found["setup_ok"]
      refute_path_exists File.join(rec["path"], "AGENT_RAN")
    end

    # A project removed between dispatch and launch: its setup can't be known either.
    def test_launch_fails_closed_for_a_project_no_longer_configured
      config = config_for(temp_git_repo("proj", origin: true), "session_command" => "touch AGENT_RAN")
      rec = built(config)
      File.write(Config.path, YAML.dump("worktree_root" => path("wts"), "projects" => []))
      status, _out, found = launch(Config.new, rec)
      assert_equal 1, status
      assert_equal %w[failed config], found.values_at("state", "reason")
      refute_path_exists File.join(rec["path"], "AGENT_RAN")
    end

    # A setup killed by a signal has no exit status; it must still read as a failure,
    # never as "no setup configured".
    def test_a_setup_killed_by_a_signal_fails_closed
      config = config_for(temp_git_repo("proj", origin: true),
                          "worktree_creation_command" => "kill -TERM $$", "session_command" => "touch AGENT_RAN")
      rec = built(config)
      _status, _out, found = launch(config, rec)
      assert_equal %w[failed setup], found.values_at("state", "reason")
      refute found["setup_ok"]
      refute_path_exists File.join(rec["path"], "AGENT_RAN")
    end

    # git's success line names the base commit, whose subject can hold any bytes: a
    # good add must never be read as a failure (and rolled back) for its text.
    def test_a_successful_add_is_never_failed_by_its_output_text
      repo = temp_git_repo("proj", origin: true)
      git(repo, "commit", "-q", "--allow-empty", "-m", "caf\xE9 ✨".b.force_encoding("BINARY"))
      config = config_for(repo)
      saved = Encoding.default_external
      Encoding.default_external = Encoding::US_ASCII
      ok, err = Creator.add_worktree(config, config.project("proj"), "odd-subject", path("wts", "odd-subject"), "main")
      assert ok, err
      assert_path_exists path("wts", "odd-subject")
    ensure
      Encoding.default_external = saved if saved
    end

    # The rollback only removes a tree on OUR branch: anything else at that path is
    # someone else's.
    def test_undo_add_never_removes_a_tree_on_another_branch
      repo = temp_git_repo("proj", origin: true)
      config = config_for(repo)
      dest = path("wts", "theirs")
      git(repo, "worktree", "add", "-q", "-b", "theirs-branch", dest, "main")
      Creator.undo_add(config.project("proj"), dest, "ours", Git.rev_parse(repo, "main"))
      assert_path_exists dest
    end

    # Value: protects=a timed-out or hook-failed add still cleaning up fully; fails_when=the
    # rollback requires a clean tree (a half checkout reads dirty and would be stranded as a
    # ✘); why_new=R2 (D4) replaced the existence-only rollback; seam=none
    def test_undo_add_removes_a_half_checked_out_tree_and_its_branch
      repo = temp_git_repo("proj", origin: true)
      config = config_for(repo)
      dest = path("wts", "half")
      git(repo, "worktree", "add", "-q", "-b", "half", dest, "main")
      File.write(File.join(dest, "partial.bin"), "half a checkout") # dirty, nothing committed
      assert_nil Creator.undo_add(config.project("proj"), dest, "half", Git.rev_parse(repo, "main")), "nothing kept, nothing said"
      refute_path_exists dest
      refute Git.branch_exists?(repo, "half")
    end

    # Value: protects=commits are never force-deleted by a rollback; fails_when=undo_add
    # removes a tree or deletes a branch past base (the old existence-only -D); why_new=R2
    # (D4): a same-name branch can appear between the clash check and the add; seam=none
    def test_undo_add_keeps_anything_with_commits_past_base
      repo = temp_git_repo("proj", origin: true)
      config = config_for(repo)
      base = Git.rev_parse(repo, "main")
      dest = path("wts", "worked")
      git(repo, "worktree", "add", "-q", "-b", "worked", dest, "main")
      git(dest, "commit", "-q", "--allow-empty", "-m", "real work")
      note = Creator.undo_add(config.project("proj"), dest, "worked", base)
      assert_path_exists dest, "a tree with a commit stays"
      assert_equal "kept #{dest} (it has commits) and branch worked (its tree was kept)", note, "and the ✘ detail says why"
      assert Git.branch_exists?(repo, "worked")

      # A racing writer's same-name branch with its own commit, no tree at our path.
      other = path("wts", "racer-tmp")
      git(repo, "worktree", "add", "-q", "-b", "racer", other, "main")
      git(other, "commit", "-q", "--allow-empty", "-m", "theirs")
      git(repo, "worktree", "remove", other)
      note = Creator.undo_add(config.project("proj"), path("wts", "never-made"), "racer", base)
      assert Git.branch_exists?(repo, "racer"), "a branch past base is someone's work"
      assert_equal "kept branch racer (it moved off the base)", note
    end

    # Value: protects=a branch the rollback refused to delete being named on the ✘ row, not
    # left silently; fails_when=add_reserved drops undo_add's note from the failure detail;
    # why_new=plan item 2 ("say so in the failure detail"), D2 of the ship gate; seam=add_worktree
    def test_a_kept_branch_is_named_in_the_failure_detail
      repo = temp_git_repo("proj", origin: true)
      config = config_for(repo)
      rec = dispatch(config)
      branch = Creator.branch_for(config, rec["name"])
      tmp = path("wts", "racer-tmp")
      run_git = method(:git) # the stub runs with Creator as self
      racer = lambda do |_config, project, _name, _dest, base, **|
        # A racing writer cuts the same branch with its own commit, then the add fails.
        run_git.call(project["path"], "worktree", "add", "-q", "-b", branch, tmp, base)
        run_git.call(tmp, "commit", "-q", "--allow-empty", "-m", "theirs")
        run_git.call(project["path"], "worktree", "remove", tmp)
        [false, "a branch named '#{branch}' already exists"]
      end
      with_fake_tmux { stub_method(Creator, :add_worktree, racer) { Creator.work(config, rec["id"]) } }
      found = Creation.find(rec["id"])
      assert_equal "failed", found["state"]
      assert_includes found["detail"], "kept branch #{branch}"
      assert Git.branch_exists?(repo, branch)
    end

    # Value: protects=a tree the rollback failed to remove is reported and keeps its branch;
    # fails_when=undo_add drops the post-remove File.exist? check (returns nil and deletes the
    # branch under a surviving tree); why_new=ship review T1/S1; seam=Git.remove_worktree
    def test_undo_add_names_a_tree_it_could_not_remove_and_keeps_its_branch
      repo = temp_git_repo("proj", origin: true)
      config = config_for(repo)
      dest = path("wts", "stuck")
      git(repo, "worktree", "add", "-q", "-b", "stuck", dest, "main")
      note = stub_method(Git, :remove_worktree, ->(*, **) { false }) do
        Creator.undo_add(config.project("proj"), dest, "stuck", Git.rev_parse(repo, "main"))
      end
      assert_equal "kept #{dest} (couldn't remove it) and branch stuck (its tree was kept)", note
      assert_path_exists dest
      assert Git.branch_exists?(repo, "stuck"), "never delete the branch under a surviving tree"
    end

    # Value: protects=the timeout shape (git cut the branch, no tree yet) still cleans up;
    # fails_when=undo_add only deletes a branch alongside a tree; why_new=ship review S2; seam=none
    def test_undo_add_deletes_a_branch_left_without_a_tree
      repo = temp_git_repo("proj", origin: true)
      config = config_for(repo)
      git(repo, "branch", "orphan", "main")
      assert_nil Creator.undo_add(config.project("proj"), path("wts", "never-made"), "orphan", Git.rev_parse(repo, "main"))
      refute Git.branch_exists?(repo, "orphan")
    end

    # Value: protects=a racing writer's tree and branch (git says they already existed) are
    # never force-removed, even dirty and commitless, for every message our `add -b` can get;
    # fails_when=a *_PREEXISTED check misses a real git last line, or a path clash keeps our new
    # branch (git cuts it before refusing the path); why_new=ship
    # review D8 + cycle-2 testing (one hand-written message was the only row); seam=none
    def test_undo_add_keeps_what_git_says_was_already_there
      repo = temp_git_repo("proj", origin: true)
      config = config_for(repo)
      project = config.project("proj")
      base = Git.rev_parse(repo, "main")
      racers = {
        "tree and branch" => ->(dest, b) { git(repo, "worktree", "add", "-q", "-b", b, dest, "main") },
        "branch only" => ->(_dest, b) { git(repo, "branch", b, "main") },
        "plain dir" => ->(dest, _b) { FileUtils.mkdir_p(dest) }
      }
      racers.each_with_index do |(label, race), i|
        branch = "raced-#{i}"
        dest = path("wts", branch)
        race.call(dest, branch)
        File.write(File.join(dest, "their-edit.txt"), "uncommitted work") if File.directory?(dest)
        ok, err = Creator.add_worktree(config, project, branch, dest, base) # real git, real last line
        refute ok, label
        note = Creator.undo_add(project, dest, branch, base, err)
        assert_includes note.to_s, "(it was there before)", "#{label}: #{err}"
        assert_path_exists File.join(dest, "their-edit.txt"), label if File.directory?(dest)
        if label == "plain dir" # only the path was theirs: git had already cut OUR branch
          refute Git.branch_exists?(repo, branch), "#{label}: our just-cut branch is cleaned up"
          refute_includes note, "branch #{branch}", label
        else
          assert Git.branch_exists?(repo, branch), label
        end
      end
    end

    # Value: protects=a timeout (ours) still cleaning up a dirty, commitless tree (D4) while a
    # hook's output that merely mentions "already exists" doesn't count as a race; fails_when=
    # the race guards are unanchored or a timeout keeps the tree; why_new=cycle-2 maintainability; seam=none
    def test_undo_add_still_cleans_up_after_a_timeout_or_a_noisy_hook
      repo = temp_git_repo("proj", origin: true)
      config = config_for(repo)
      ["timed out after 120s", "post-checkout: 'node_modules' already exists, skipping"].each_with_index do |err, i|
        dest = path("wts", "ours-#{i}")
        git(repo, "worktree", "add", "-q", "-b", "ours-#{i}", dest, "main")
        File.write(File.join(dest, "partial.bin"), "half a checkout")
        assert_nil Creator.undo_add(config.project("proj"), dest, "ours-#{i}", Git.rev_parse(repo, "main"), err), err
        refute_path_exists dest, err
      end
    end

    # Value: protects=the branch is cut at the exact commit the rollback's proof uses, and an
    # unresolvable base keeps everything and says so; fails_when=add_reserved passes the ref
    # again or drops the nil-base note; why_new=cycle-2 testing; seam=add_worktree, Git.rev_parse
    def test_add_reserved_cuts_at_the_resolved_base_and_names_an_unknown_one
      repo = temp_git_repo("proj", origin: true)
      config = config_for(repo)
      rec = dispatch(config)
      seen = nil
      fail_add = ->(_c, _p, _n, _d, base, **) { seen = base; [false, "timed out after 120s"] }
      with_fake_tmux { stub_method(Creator, :add_worktree, fail_add) { Creator.work(config, rec["id"]) } }
      assert_equal Git.rev_parse(repo, config.project("proj")["base_ref"]), seen
      assert_match(/\A\h{40}\z/, seen)

      rec2 = dispatch(config)
      branch = Creator.branch_for(config, rec2["name"])
      run_git = method(:git)
      cut = ->(_c, project, _n, _d, base, **) { run_git.call(project["path"], "branch", branch, "main"); seen = base; [false, "timed out after 120s"] }
      with_fake_tmux do
        stub_method(Git, :rev_parse, ->(*) { nil }) { stub_method(Creator, :add_worktree, cut) { Creator.work(config, rec2["id"]) } }
      end
      assert_equal config.project("proj")["base_ref"], seen, "falls back to the ref"
      assert_includes Creation.find(rec2["id"])["detail"], "branch #{branch} (base commit unknown)"
      assert Git.branch_exists?(repo, branch)
    end

    # Value: protects=an unknown commit count keeps the tree and says so honestly; fails_when=
    # nil is labeled "(it has commits)" or the tree is removed; why_new=cycle-2 maintainability;
    # seam=Git.commits_since
    def test_undo_add_keeps_a_tree_whose_commits_it_could_not_count
      repo = temp_git_repo("proj", origin: true)
      config = config_for(repo)
      dest = path("wts", "unknown")
      git(repo, "worktree", "add", "-q", "-b", "unknown", dest, "main")
      note = stub_method(Git, :commits_since, ->(*) { nil }) do
        Creator.undo_add(config.project("proj"), dest, "unknown", Git.rev_parse(repo, "main"))
      end
      assert_includes note, "#{dest} (couldn't check its commits)"
      assert_path_exists dest
    end

    # Value: protects=a branch a hidden (unreadable-path) worktree may have checked out is
    # kept; fails_when=undo_add's free check ignores undecodable_worktrees?; why_new=D10;
    # seam=Git.undecodable_worktrees?
    def test_undo_add_keeps_a_branch_a_hidden_worktree_may_hold
      repo = temp_git_repo("proj", origin: true)
      config = config_for(repo)
      git(repo, "branch", "maybe", "main")
      note = stub_method(Git, :undecodable_worktrees?, ->(_repo) { true }) do
        Creator.undo_add(config.project("proj"), path("wts", "never"), "maybe", Git.rev_parse(repo, "main"))
      end
      assert_equal "kept branch maybe (a worktree's path couldn't be read)", note
      assert Git.branch_exists?(repo, "maybe")
    end

    # Value: protects=git's failure text reads English whatever its language, so the race
    # guard fires; fails_when=add_worktree drops LANGUAGE=en; why_new=D9; seam=Process.spawn
    def test_add_worktree_asks_git_for_english_messages
      repo = temp_git_repo("proj", origin: true)
      config = config_for(repo)
      env = nil
      real = Process.method(:spawn)
      spawn = ->(e, *_a, **_k) { env = e; real.call("true") }
      stub_method(Process, :spawn, spawn) do
        Creator.add_worktree(config, config.project("proj"), "lang", path("wts", "lang"), "main")
      end
      assert_equal "en", env["LANGUAGE"]
    end

    # Value: protects=a kept tree that isn't on our branch never decides the branch's fate or
    # its reason: the branch is judged on its own state; fails_when=undo_add ties "free" to
    # whether anything else was kept; why_new=ship cycle 3 (state-machines + maintainability)
    def test_undo_add_judges_the_branch_on_its_own_when_a_foreign_tree_is_kept
      repo = temp_git_repo("proj", origin: true)
      config = config_for(repo)
      project = config.project("proj")
      base = Git.rev_parse(repo, "main")
      run_git = method(:git)
      cases = {
        "free at base" => [->(_b) {}, nil],
        "moved" => [lambda { |b|
          tmp = path("wts", "mv-#{b}")
          run_git.call(repo, "worktree", "add", "-q", tmp, b)
          run_git.call(tmp, "commit", "-q", "--allow-empty", "-m", "moved")
          run_git.call(repo, "worktree", "remove", tmp)
        }, "it moved off the base"],
        "checked out elsewhere" => [->(b) { run_git.call(repo, "worktree", "add", "-q", path("wts", "co-#{b}"), b) }, "it's checked out"]
      }
      cases.each_with_index do |(label, (setup, why)), i|
        branch = "own-#{i}"
        git(repo, "branch", branch, "main")
        setup.call(branch)
        dest = path("wts", "plain-#{i}")
        FileUtils.mkdir_p(dest) # a non-git dir left by a timeout: not on our branch
        note = Creator.undo_add(project, dest, branch, base, "timed out after 120s")
        assert_path_exists dest, label
        assert_includes note, "#{dest} (not on this create's branch)", label
        if why
          assert_includes note, "branch #{branch} (#{why})", label
          assert Git.branch_exists?(repo, branch), label
        else
          refute_includes note, "branch #{branch}", "#{label}: a provably free branch is cleaned up"
          refute Git.branch_exists?(repo, branch), label
        end
      end
      git(repo, "branch", "hid", "main")
      dest = path("wts", "plain-hid")
      FileUtils.mkdir_p(dest)
      note = stub_method(Git, :undecodable_worktrees?, ->(_repo) { true }) { Creator.undo_add(project, dest, "hid", base) }
      assert_includes note, "branch hid (a worktree's path couldn't be read)"
    end

    # Value: protects=the branch check and the delete being one step; fails_when=delete_branch_at
    # loses update-ref's old-value guard (a tip that moved after the check gets deleted);
    # why_new=outside voice O1: check-then-`-D` still raced; seam=none
    def test_delete_branch_at_refuses_a_branch_that_moved
      repo = temp_git_repo("proj", origin: true)
      base = Git.rev_parse(repo, "main")
      git(repo, "branch", "moved", "main")
      tmp = path("wts", "mover")
      git(repo, "worktree", "add", "-q", tmp, "moved")
      git(tmp, "commit", "-q", "--allow-empty", "-m", "landed after the check")
      git(repo, "worktree", "remove", tmp)
      refute Git.delete_branch_at(repo, "moved", base)
      assert Git.branch_exists?(repo, "moved")
      git(repo, "branch", "still", "main")
      assert Git.delete_branch_at(repo, "still", base)
      refute Git.branch_exists?(repo, "still")
    end

    # Value: protects=no proof, no delete; fails_when=undo_add acts without a base commit or
    # deletes a branch another worktree has checked out; why_new=R2 (D4); seam=none
    def test_undo_add_deletes_nothing_without_a_base_or_while_the_branch_is_checked_out
      repo = temp_git_repo("proj", origin: true)
      config = config_for(repo)
      dest = path("wts", "nobase")
      git(repo, "worktree", "add", "-q", "-b", "nobase", dest, "main")
      note = Creator.undo_add(config.project("proj"), dest, "nobase", nil)
      assert_equal "kept #{dest} (base commit unknown) and branch nobase (base commit unknown)", note
      assert_path_exists dest
      assert Git.branch_exists?(repo, "nobase")

      elsewhere = path("wts", "elsewhere")
      git(repo, "worktree", "add", "-q", "-b", "shared", elsewhere, "main")
      Creator.undo_add(config.project("proj"), path("wts", "not-here"), "shared", Git.rev_parse(repo, "main"))
      assert Git.branch_exists?(repo, "shared"), "checked out in another worktree"
    end

    # Every fresh name collides: the build fails once with a clear reason and leaves
    # nothing behind.
    def test_add_reserved_gives_up_cleanly_when_no_name_is_free
      repo = temp_git_repo("proj", origin: true)
      config = config_for(repo)
      rec = dispatch(config)
      git(repo, "branch", rec["name"])
      git(repo, "branch", "taken")
      stub_method(Placeholder, :generate, -> { "taken" }) { with_fake_tmux { Creator.work(config, rec["id"]) } }
      found = Creation.find(rec["id"])
      assert_equal %w[failed worktree_add], found.values_at("state", "reason")
      assert_equal "no free workspace name", found["detail"]
      refute found["worktree_added"]
    end

    # A clean exit inside the grace is a hand-off (a wrapper that starts the agent
    # elsewhere) or a one-shot that finished — not "agent exit 0" ✘.
    def test_a_clean_exit_inside_the_grace_is_ready_not_failed
      config = config_for(temp_git_repo("proj", origin: true), "session_command" => "true")
      rec = built(config)
      _, _, found = launch(config, rec)
      assert_equal "ready", found["state"]
    end

    # GC can fail a build (e.g. read it as dead) before the typed launch line runs; the
    # pane then says why instead of silently giving a bare prompt.
    def test_launch_explains_a_build_that_already_failed
      config = config_for(temp_git_repo("proj", origin: true))
      rec = built(config)
      Creation.mark_failed(rec["id"], "interrupted")
      status, out, = launch(config, rec)
      assert_equal 0, status
      assert_includes out, "interrupted"
    end

    # Setup succeeded, then the agent exits inside the grace (or a quit lands then): the
    # build is ✘/canceled, but the tree IS set up, so re-entry may start the agent.
    def test_launch_marks_setup_ok_once_setup_succeeds
      config = config_for(temp_git_repo("proj", origin: true),
                          "worktree_creation_command" => "true", "session_command" => "exit 3")
      rec = built(config)
      _, _, found = launch(config, rec)
      assert_equal "failed", found["state"]
      assert found["setup_ok"]
      refute Creation.unfinished?(found), "a fast agent exit doesn't block the agent on re-entry"
    end

    # A one-shot agent whose first turn a Stop already stamped done, then exits inside the
    # grace: it finished, so no ✘ and no "failed" line in the pane.
    def test_run_agent_stays_quiet_when_the_turn_was_already_stamped_done
      rec = Creation.create(project: "proj", name: "b", path: path("b"), task: "t")
      FileUtils.mkdir_p(path("b"))
      Creation.transition(rec["id"], from: :queued, to: :turn_done)
      out = StringIO.new
      stub_method(Creator, :pane_shell, -> { "/bin/sh" }) { Creator.run_agent(rec["id"], "true", path("b"), out, grace: 2) }
      assert_equal "turn_done", Creation.find(rec["id"])["state"]
      assert_empty out.string
    end

    # The same, exiting non-zero: still finished, never a launch failure.
    def test_run_agent_stays_quiet_on_a_nonzero_exit_after_the_turn_was_stamped
      rec = Creation.create(project: "proj", name: "b", path: path("b"), task: "t")
      FileUtils.mkdir_p(path("b"))
      Creation.transition(rec["id"], from: :queued, to: :turn_done)
      out = StringIO.new
      stub_method(Creator, :pane_shell, -> { "/bin/sh" }) { Creator.run_agent(rec["id"], "exit 3", path("b"), out, grace: 2) }
      assert_equal "turn_done", Creation.find(rec["id"])["state"]
      assert_empty out.string
    end

    # A hooked task's agent that outlives the grace but exits before its first turn ends
    # gets no Stop, so its exit pings instead — never a silent `ready` that mutes the row.
    def test_an_agent_exiting_before_its_first_turn_pings_on_exit
      { "sleep 0.6; exit 3" => "failed", "sleep 0.6" => "turn_done" }.each do |cmd, want|
        rec = Creation.create(project: "proj", name: "h", path: path("h"), task: "t")
        FileUtils.mkdir_p(path("h"))
        Creation.transition(rec["id"], from: :queued, to: :launching, hooked: true)
        stub_method(Creator, :pane_shell, -> { "/bin/sh" }) do
          Creator.run_agent(rec["id"], cmd, path("h"), StringIO.new, grace: 0.2)
        end
        found = Creation.find(rec["id"])
        assert_equal want, found["state"], cmd
        assert Creation.ring_due?(found), "#{cmd}: the exit rings"
      end
    end

    # `hooked` is settled at launch from the command that runs: a task it can't deliver
    # never ends a turn, so the build must ping at ready like a bare create.
    def test_an_undelivered_task_is_not_hooked
      config = config_for(temp_git_repo("proj", origin: true), "session_command" => %(claude --model "opus"))
      rec = built(config)
      Creation.update(rec["id"], hooked: true) # the worker's first guess
      stub_method(ClaudeHook, :enabled?, ->(_d) { true }) do
        stub_method(Creator, :run_agent, ->(*_a, **_k) { 0 }) { launch(config, rec) }
      end
      found = Creation.find(rec["id"])
      refute found["hooked"]
      assert found["agent_started"]
    end

    # A quit that kills the session after the worker opened it but before the launcher
    # claimed it: nothing ever ran in the tree, so the worker removes it.
    def test_work_discards_a_tree_canceled_before_the_launcher_claimed_it
      repo = temp_git_repo("proj", origin: true)
      config = config_for(repo)
      rec = dispatch(config)
      with_fake_tmux(claim: false) do
        stub_method(Creator, :await_claim, ->(id, **_k) { Creation.cancel_all || id }) { Creator.work(config, rec["id"]) }
      end
      refute_path_exists rec["path"]
      refute Git.branch_exists?(repo, rec["name"])
    end

    # The post-claim discard is the worker's only: once the launcher owns the build, its
    # setup or agent may be running there.
    def test_work_never_discards_a_tree_the_launcher_already_claimed
      config = config_for(temp_git_repo("proj", origin: true))
      rec = dispatch(config)
      claim = lambda do |id, **_k|
        Creation.transition(id, from: :building, to: :launching, owner_pid: Process.pid + 1, owner_start: "x")
        Creation.cancel_all
        true
      end
      with_fake_tmux(claim: false) { stub_method(Creator, :await_claim, claim) { Creator.work(config, rec["id"]) } }
      assert_path_exists Creation.find(rec["id"])["path"]
    end

    # A live server socket is the normal case: the session opens.
    def test_work_opens_the_session_on_a_live_server
      require "socket"
      config = config_for(temp_git_repo("proj", origin: true))
      rec = dispatch(config)
      sock_dir = Dir.mktmpdir("s", "/tmp") # short: a socket path has a ~104-byte limit
      sock = UNIXServer.new(File.join(sock_dir, "live.sock"))
      Creation.update(rec["id"], server: File.join(sock_dir, "live.sock"))
      with_fake_tmux do |calls|
        Creator.work(config, rec["id"])
        assert_equal 1, calls.size
      end
    ensure
      sock&.close
      FileUtils.rm_rf(sock_dir) if sock_dir
    end

    # A rollback git refuses (a locked tree from a killed add) still leaves a tree: the
    # record must say so, or nothing guards it.
    def test_a_tree_the_rollback_could_not_remove_is_recorded
      repo = temp_git_repo("proj", origin: true)
      hooks = path("hooks")
      FileUtils.mkdir_p(hooks)
      File.write(File.join(hooks, "post-checkout"), "#!/bin/sh\nexit 1\n")
      File.chmod(0o755, File.join(hooks, "post-checkout"))
      git(repo, "config", "core.hooksPath", hooks)
      config = config_for(repo)
      rec = dispatch(config)
      stub_method(Creator, :undo_add, ->(*) {}) { with_fake_tmux { Creator.work(config, rec["id"]) } }
      found = Creation.find(rec["id"])
      assert_equal "failed", found["state"]
      assert found["worktree_added"], "the surviving tree is recorded"
    end

    # A hooked task whose agent exits 0 INSIDE the grace never finished a turn either.
    def test_a_clean_exit_inside_the_grace_pings_a_hooked_task
      rec = Creation.create(project: "proj", name: "q", path: path("q"), task: "t")
      FileUtils.mkdir_p(path("q"))
      Creation.transition(rec["id"], from: :queued, to: :launching, hooked: true)
      stub_method(Creator, :pane_shell, -> { "/bin/sh" }) { Creator.run_agent(rec["id"], "true", path("q"), StringIO.new, grace: 2) }
      assert_equal "turn_done", Creation.find(rec["id"])["state"]
    end

    # A cancel that landed while the agent ran: its exit changes nothing.
    def test_an_agent_exit_never_moves_a_canceled_build
      rec = Creation.create(project: "proj", name: "c", path: path("c"), task: "t")
      FileUtils.mkdir_p(path("c"))
      Creation.transition(rec["id"], from: :queued, to: :canceled, hooked: true)
      out = StringIO.new
      stub_method(Creator, :pane_shell, -> { "/bin/sh" }) { Creator.run_agent(rec["id"], "exit 4", path("c"), out, grace: 2) }
      assert_equal "canceled", Creation.find(rec["id"])["state"]
      assert_empty out.string
    end

    # The worker outlives a `tmux kill-server`; new-session on the dead socket would
    # start a headless server and run the agent with nobody attached.
    def test_work_never_opens_a_session_on_a_server_that_is_gone
      config = config_for(temp_git_repo("proj", origin: true))
      rec = dispatch(config)
      Creation.update(rec["id"], server: path("gone.sock"))
      with_fake_tmux(claim: false) do |calls|
        Creator.work(config, rec["id"])
        assert_empty calls
      end
      found = Creation.find(rec["id"])
      assert_equal %w[failed session], found.values_at("state", "reason")
    end

    # tmux that can't even be exec'd (system → nil) is a failed session, not a cancel.
    def test_work_fails_the_session_when_tmux_cannot_run
      config = config_for(temp_git_repo("proj", origin: true))
      rec = dispatch(config)
      with_fake_tmux(created: nil, claim: false) { Creator.work(config, rec["id"]) }
      assert_equal %w[failed session], Creation.find(rec["id"]).values_at("state", "reason")
    end

    # Only a name that was taken BEFORE the add is a collision. A checkout that fails on
    # its own (a hook, a filter) leaves the branch and even the tree behind; retrying it
    # as a collision would leak one per try. It's undone and fails once, with git's say.
    def test_a_failed_checkout_is_rolled_back_not_retried_as_a_collision
      repo = temp_git_repo("proj", origin: true)
      hooks = path("hooks")
      FileUtils.mkdir_p(hooks)
      # Value: protects=a failed add reports git's last line even when it holds non-UTF-8 bytes; fails_when=add_worktree reads the log as UTF-8 again, so the regex raises and the ✘ shows "invalid byte sequence"; why_new=only the SUCCESS path's odd bytes were tested; seam=none; no_claim=the ✘ row's rendering of the detail
      File.write(File.join(hooks, "post-checkout"), "#!/bin/sh\nprintf 'caf\\351 hook refused\\n' >&2\nexit 1\n")
      File.chmod(0o755, File.join(hooks, "post-checkout"))
      git(repo, "config", "core.hooksPath", hooks)
      config = config_for(repo)
      rec = dispatch(config)
      drawn = 0
      stub_method(Placeholder, :generate, -> { drawn += 1; "retry-#{drawn}" }) do
        with_fake_tmux { Creator.work(config, rec["id"]) }
      end
      found = Creation.find(rec["id"])
      assert_equal %w[failed worktree_add], found.values_at("state", "reason")
      assert_includes found["detail"], "hook refused", "git's own say, its odd byte scrubbed"
      assert_equal 0, drawn, "no fresh placeholder was drawn: it wasn't a collision"
      refute_path_exists rec["path"]
      refute Git.branch_exists?(repo, rec["name"])
    end

    def test_the_launch_line_starts_with_a_space_to_stay_out_of_history
      assert Creator.launch_line("/w/x").start_with?(" ")
    end

    def test_pane_shell_falls_back_to_shell_env
      stub_method(Process, :ppid, -> { 2_147_483_600 }) do
        ENV["SHELL"] = "/bin/zsh"
        assert_equal "/bin/zsh", Creator.pane_shell
      end
    end

    # nu/xonsh/elvish don't expand a POSIX "$VAR", so the task would arrive literal.
    def test_pane_shell_uses_sh_for_a_non_posix_shell
      stub_method(Process, :ppid, -> { 2_147_483_600 }) do
        ENV["SHELL"] = "/opt/homebrew/bin/nu"
        assert_equal "sh", Creator.pane_shell
      end
    end
  end
end
