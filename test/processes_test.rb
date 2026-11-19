# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # The process table delete reads to tell an agent from its helpers. Parsing runs on
  # captured `ps` output from both platforms; roots runs on hand-built tables.
  class ProcessesTest < Minitest::Test
    MACOS = <<~PS
          1     0     0 ??       /sbin/launchd
       2051  2028   501 ttys026  claude
       2492  2051   501 ttys026  npm exec @playwright/mcp@latest
      71347 71189   501 ??       /Applications/Claude.app/Contents/Frameworks/Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer)
    PS
    LINUX = <<~PS
          1     0     0 ?        systemd
        812   790  1000 pts/0    codex
    PS

    def test_parses_both_platforms_keeping_spaces_in_the_command
      t = Processes.parse(MACOS)
      assert_equal({ ppid: 2051, uid: 501, tty: "ttys026", comm: "npm exec @playwright/mcp@latest" }, t[2492])
      assert_equal "??", t[71_347][:tty]
      assert t[71_347][:comm].end_with?("Claude Helper (Renderer)")
      assert_equal({ ppid: 790, uid: 1000, tty: "pts/0", comm: "codex" }, Processes.parse(LINUX)[812])
    end

    def test_a_garbled_line_is_skipped_and_nothing_parsed_is_nil
      assert_equal [1], Processes.parse(" 1 0 0 ?? launchd\nnot a process line\n 2 x 0 ?? sh\n").keys
      assert_nil Processes.parse("")
    end

    def test_a_failed_ps_is_nil
      stub_method(IO, :popen, ->(*) { raise Errno::ENOENT }) { assert_nil Processes.table }
    end

    def test_reads_this_machine
      t = Processes.table
      assert_equal Process.ppid, t.fetch(Process.pid)[:ppid]
    end

    def row(ppid) = { ppid: ppid, uid: 501, tty: "??", comm: "x" }

    # Value: protects=an agent's helpers, however deep, aren't judged as agents; fails_when=
    # roots check only the direct parent; why_new=new; seam=none
    def test_roots_are_the_matched_pids_with_no_matched_ancestor
      table = { 10 => row(1), 11 => row(10), 12 => row(11), 13 => row(12), 20 => row(1) }
      assert_equal [10, 20], Processes.roots([10, 13, 20], table), "13 sits under 10 through two unmatched processes"
      assert_equal [13], Processes.roots([13], table)
    end

    def test_an_ancestry_the_table_cant_finish_is_nil
      assert_nil Processes.roots([13], { 13 => row(12) }), "the parent isn't in the table"
      assert_nil Processes.roots([99], { 13 => row(1) }), "the pid itself isn't"
      assert_nil Processes.roots([5], { 5 => row(6), 6 => row(5) }), "a loop"
    end

    # Value: protects=delete can tell a node-run Claude by its command line, and a pid that
    # exited isn't a failed read; fails_when=commands drops argv or reads an exited pid as
    # failure; why_new=new read; seam=none (real ps); no_claim=Linux ps
    def test_commands_reads_argv_and_skips_exited_pids
      child = spawn("sleep", "30")
      begin
        assert_equal %w[sleep 30], Processes.commands([child])[child]
      ensure
        Process.kill("KILL", child)
        Process.wait(child)
      end
      assert_equal({}, Processes.commands([child]), "exited")
      assert_equal({}, Processes.commands([]))
    end
  end
end
