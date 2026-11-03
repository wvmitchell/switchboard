# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # `switchboard new` and `switchboard projects`: the sidebar's `n` from the command line,
  # same project or another one. Every refusal happens before a record exists.
  class CLINewTest < SandboxTest
    def setup
      super
      write_config
      ENV["TMUX"] = "/tmp/fake-tmux,1,0"
    end

    def write_config(projects = nil, extra = {})
      projects ||= [{ "name" => "proj", "path" => path("repos", "proj"), "session_command" => "claude" },
                    { "name" => "govly", "path" => path("repos", "govly"), "session_command" => "claude" }]
      File.write(Config.path, YAML.dump({ "worktree_root" => path("wts"), "projects" => projects }.merge(extra)))
    end

    def wt(project, leaf = "fix-auth", primary: false)
      Worktree.new(project: project, path: path("wts", project, leaf), primary: primary)
    end

    # Run `new` with the shell-outs stubbed; returns [result, stdout, stderr, spawned ids].
    def run_new(args, here: wt("proj"), stdin: nil, spawn_ok: true)
      spawned = []
      result = out = err = nil
      stub_method(CLI, :config, -> { Config.new }) do
        stub_method(CLI, :current_worktree, ->(*) { here }) do
          stub_method(Tmux, :has_session?, ->(_n) { false }) do
            stub_method(Tmux, :broadcast_warm, ->(**_k) {}) do
              stub_method(Creator, :spawn_worker, ->(id) { spawned << id && spawn_ok }) do
                err = capture_err { out = capture { result = CLI.new_workspace(args, stdin: stdin || closed_pipe("")) } }
              end
            end
          end
        end
      end
      [result, out, err, spawned]
    end

    def closed_pipe(text)
      r, w = IO.pipe
      w.write(text)
      w.close
      r
    end

    def refused(args, **opts)
      result, _out, err, spawned = run_new(args, **opts)
      refute result, "must refuse"
      assert_empty Creation.all, "a refusal writes no record"
      assert_empty spawned
      err
    end

    # --- same project, cross project ---

    def test_dot_dispatches_a_sibling_in_this_project
      result, out, _err, spawned = run_new([".", "research gov-1234"])
      assert result
      rec = Creation.all.first
      assert_equal "proj", rec["project"]
      assert_equal "research gov-1234", rec["task"]
      assert_equal path("wts", "proj", rec["name"]), rec["path"]
      assert_equal [rec["id"]], spawned
      assert_match(/dispatched a new workspace in this project \(proj\): "#{rec['name']}"/, out)
      refute rec["acked"], "the ready chime is how you hear about it"
      assert_equal "cli", rec["brief_from"], "an agent wrote this brief"
    end

    def test_a_named_other_project_says_another_project
      result, out, = run_new(%w[govly plan])
      assert result
      rec = Creation.all.first
      assert_equal "govly", rec["project"]
      assert_equal path("wts", "govly", rec["name"]), rec["path"]
      assert_match(/in ANOTHER project \(govly, you're in proj\)/, out)
    end

    # Judged by where you ARE, not how the target was spelled.
    def test_naming_your_own_project_still_says_this_project
      _r, out, = run_new(%w[proj plan])
      assert_match(/in this project \(proj\)/, out)
    end

    def test_from_a_home_shell_it_just_names_the_target
      _r, out, = run_new(%w[govly plan], here: nil)
      assert_match(/dispatched a new workspace in govly: /, out)
    end

    def test_dot_from_the_primary_checkout_targets_that_project
      run_new([".", "plan"], here: wt("proj", "proj", primary: true))
      assert_equal "proj", Creation.all.first["project"]
    end

    # Never a second agent in an existing workspace: the caller's own tree is never handed out.
    def test_dot_never_reserves_the_callers_own_workspace
      FileUtils.mkdir_p(path("wts", "proj", "fix-auth"))
      names = %w[fix-auth calm-otter]
      stub_method(Placeholder, :generate, -> { names.shift }) { run_new([".", "plan"]) }
      assert_equal path("wts", "proj", "calm-otter"), Creation.all.first["path"]
    end

    # --- refusals ---

    def test_dot_outside_any_project_refuses
      assert_match(/not inside a registered project — name one: proj, govly/, refused([".", "plan"], here: nil))
    end

    # `new` never targets an existing workspace: a path is not a target, only a name or `.`.
    def test_a_workspace_path_is_never_a_target
      FileUtils.mkdir_p(path("wts", "proj", "fix-auth"))
      assert_match(/unknown project/, refused([path("wts", "proj", "fix-auth"), "plan"]))
    end

    def test_unknown_project_lists_the_registered_names
      assert_match(/unknown project "nope" — registered: proj, govly/, refused(%w[nope plan]))
    end

    def test_outside_tmux_refuses
      ENV.delete("TMUX")
      assert_match(/run this inside tmux/, refused(%w[govly plan]))
    end

    def test_unquoted_words_refuse
      assert_match(/too many arguments/, refused(%w[. research gov-1234 now]))
    end

    def test_dash_led_task_refuses_from_argv_and_stdin
      assert_match(/can't start with '-'/, refused([".", "--resume"]))
      assert_match(/can't start with '-'/, refused([".", "-"], stdin: closed_pipe("- research\n- plan\n")))
    end

    def test_nul_in_a_stdin_brief_refuses
      assert_match(/NUL byte/, refused([".", "-"], stdin: closed_pipe("plan\0it")))
    end

    def test_oversized_task_refuses
      assert_match(/limit is 64 KiB/, refused([".", "a" * 65_537]))
    end

    # The launcher would drop the brief in a pane nobody's watching (R9).
    def test_a_project_without_an_agent_refuses_a_task
      write_config([{ "name" => "proj", "path" => path("repos", "proj") }])
      assert_match(/no session_command configured; task not sent/, refused([".", "plan"]))
    end

    def test_an_agent_that_cant_take_the_task_refuses
      write_config([{ "name" => "proj", "path" => path("repos", "proj"), "session_command" => "aider" }])
      assert_match(/task not sent; add \{task\}/, refused([".", "plan"]))
    end

    def test_a_task_template_agent_is_accepted
      write_config([{ "name" => "proj", "path" => path("repos", "proj"), "session_command" => "aider --message {task}" }])
      assert run_new([".", "plan"]).first
    end

    def test_a_bare_create_needs_no_agent
      write_config([{ "name" => "proj", "path" => path("repos", "proj") }])
      assert run_new(["."]).first
      assert_equal "", Creation.all.first["task"]
      assert_nil Creation.all.first["brief_from"], "no brief, so your own first words are never labeled another agent's"
    end

    def test_a_failed_spawn_exits_nonzero_with_the_reason
      result, out, err, = run_new([".", "plan"], spawn_ok: false)
      refute result
      assert_match(/couldn't start the build worker/, err)
      refute_match(/dispatched/, out)
    end

    # Value: protects=a broken config refuses `new` with the parse error before any record; fails_when=the load_error guard is dropped or moved after dispatch_target (agent sees a misleading "unknown project"); why_new=only `projects` had a broken-config test; seam=none; no_claim=config parse wording
    def test_new_refuses_a_broken_config_with_the_parse_error
      File.write(Config.path, "projects: [unclosed")
      err = refused([".", "plan"])
      assert_match(/config failed to parse/, err)
    end

    # Value: protects=a name collision exhausting placeholder tries refuses with no spawn; fails_when=the :no_name check is removed or reordered after the Hash check (wrong message) or spawn is attempted; why_new=no test drives Creator.dispatch -> :no_name through `new`; seam=none (stubs an existing module method); no_claim=Creator's retry logic
    def test_no_free_name_refuses_without_spawning
      stub_method(Creator, :dispatch, ->(*) { :no_name }) do
        result, out, err, spawned = run_new([".", "plan"])
        refute result
        assert_match(/no free workspace name/, err)
        assert_empty spawned
        refute_match(/dispatched/, out)
      end
    end

    # Value: protects=a disk error while recording is a clean refusal, not a crash; fails_when=the SystemCallError rescue around Creator.dispatch is dropped; why_new=no test raises from dispatch; seam=none; no_claim=IOError variant
    def test_a_record_write_error_refuses_cleanly
      stub_method(Creator, :dispatch, ->(*) { raise Errno::ENOSPC }) do
        result, _out, err, spawned = run_new([".", "plan"])
        refute result
        assert_match(/couldn't record the dispatch/, err)
        assert_empty spawned
      end
    end

    # --- the task source ---

    def test_a_piped_brief_is_the_task_byte_exact
      brief = "Research gov-1234 and make a plan.\n\n\"Quotes\", $HOME and ✓ survive.\n"
      run_new(%w[govly -], stdin: closed_pipe(brief))
      assert_equal brief, Creation.all.first["task"]
    end

    # A C-locale shell hands ARGV over tagged binary; the validated brief is stored as UTF-8,
    # with no json encoding warning on the caller's stderr (json 3.0 would refuse it).
    def test_a_binary_tagged_argv_brief_is_stored_as_utf8
      result, _out, err, = run_new([".", "café ✓".b])
      assert result
      assert_equal "café ✓", Creation.all.first["task"]
      refute_match(/BINARY|encoding/, err)
    end

    def test_an_inherited_switchboard_task_is_never_read
      ENV["SWITCHBOARD_TASK"] = "the caller's own task"
      run_new(["."])
      assert_equal "", Creation.all.first["task"]
    end

    # --- switchboard projects ---

    def run_projects(args = [], here: wt("govly"))
      out = nil
      stub_method(CLI, :config, -> { Config.new }) do
        stub_method(CLI, :current_worktree, ->(*) { here }) { out = capture { @result = CLI.list_projects(args) } }
      end
      out
    end

    def test_projects_lists_in_config_order_and_marks_the_current_one
      lines = run_projects.lines
      assert_equal 2, lines.size
      assert_match(/\A  proj /, lines[0])
      assert_match(/\A\* govly /, lines[1])
      assert_includes lines[1], "~/repos/govly"
      assert_includes lines[1], "(base origin/main)"
    end

    def test_projects_marks_the_primary_checkout_too
      assert_match(/\A\* proj /, run_projects([], here: wt("proj", "proj", primary: true)).lines[0])
    end

    def test_projects_names_is_bare_names
      assert_equal "proj\ngovly\n", run_projects(["--names"])
    end

    def test_projects_with_none_registered
      write_config([])
      assert_match(/no projects registered/, run_projects)
      assert @result
    end

    def test_projects_refuses_a_broken_config
      File.write(Config.path, "projects: [unclosed")
      err = capture_err { run_projects }
      assert_match(/config failed to parse/, err)
      refute @result
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

    def capture_err
      err = StringIO.new
      orig = $stderr
      $stderr = err
      yield
      err.string
    ensure
      $stderr = orig
    end
  end
end
