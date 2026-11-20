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
    # Value: protects=a scan that missed a process of ours, or this process, reads as
    # "couldn't check", never "nobody's in the tree"; fails_when=the completeness check
    # loosens (lsof exits 0 while leaving processes out); why_new=item 1 (D15); seam=none
    def test_an_incomplete_cwd_scan_is_nil
      me = Process.pid
      table = { me => { ppid: 1, uid: Process.uid, tty: "??", comm: "ruby" } }
      here = { me => Dir.pwd }
      scan = ->(found) { stub_method(Processes, :proc_cwds, -> { found }) { stub_method(Processes, :lsof_cwds, ->(*) { found }) { Processes.cwds(table) } } }
      assert_equal here, scan.call(here)
      assert_nil scan.call({ 1 => "/" }), "this process is missing"
      assert_nil scan.call({ me => "/somewhere/else" }), "this process at the wrong folder"
      assert_nil scan.call(nil), "lsof printed nothing"

      child = spawn("sleep 30")
      begin
        table[child] = { ppid: me, uid: Process.uid, tty: "??", comm: "sleep" }
        assert_nil scan.call(here), "a live process of ours the scan left out"
      ensure
        Process.kill("KILL", child)
        Process.wait(child)
      end
      assert_equal here, scan.call(here), "one that exited since the table is fine"
    end

    # Value: protects=lsof's -F cwd output is read per pid, \xNN escapes decoded; fails_when=
    # the p/n field parsing breaks; why_new=item 1 scans every process with it; seam=IO.popen
    def test_lsof_cwd_output_is_parsed
      out = "p12\nfcwd\nn/wt/a\np34\nfcwd\nn/wt/caf\\xc3\\xa9 b\n"
      stub_method(IO, :popen, ->(*, **) { out }) do
        assert_equal({ 12 => "/wt/a", 34 => "/wt/café b" }, Processes.lsof_cwds)
      end
    end

    # Value: protects=a real process started in a folder is found with its name and start,
    # on this platform's scan (/proc on Linux, lsof on a Mac), and the scan sees it gone;
    # fails_when=the platform scan or the tree match breaks; why_new=item 1; seam=none (our
    # own child, no tmux)
    def test_finds_a_real_process_running_in_a_folder
      dir = File.realpath(Dir.mktmpdir)
      child = Process.spawn("sleep", "30", chdir: dir)
      begin
        sleep 0.2
        found = Processes.in_tree(dir)
        refute_nil found, "the scan completed"
        hit = found.find { |p| p[:pid] == child }
        refute_nil hit, "found the child running in #{dir}"
        assert_equal "sleep", hit[:comm]
        assert_equal ProcessIdentity.start_of(child), hit[:start]
        assert Processes.detached?(hit) || hit[:tty].to_s.start_with?("tty", "pts")
      ensure
        Process.kill("KILL", child)
        Process.wait(child)
        FileUtils.rm_rf(dir)
      end
    end

    def test_subtree_follows_parents_to_a_root
      t = { 10 => { ppid: 1 }, 11 => { ppid: 10 }, 12 => { ppid: 11 }, 20 => { ppid: 1 } }
      assert Processes.subtree?(12, [10], t)
      assert Processes.subtree?(10, [10], t)
      refute Processes.subtree?(20, [10], t)
      refute Processes.subtree?(99, [10], t), "unknown pid"
    end

    # Value: protects=in_tree matches the folder and its subfolders only (not a sibling sharing
    # its prefix), skips this process and its parent and one that exited, and reads a live
    # process missing from the table as an incomplete scan; fails_when=the "/" boundary, the
    # self exclusion or the nil goes; why_new=only a real child is tested; seam=none
    def test_in_tree_matches_the_folder_only_and_skips_itself
      me = Process.pid
      shell = Process.ppid
      table = { me => { ppid: shell, uid: Process.uid, tty: "??", comm: "ruby" },
                shell => { ppid: 1, uid: Process.uid, tty: "ttys001", comm: "zsh" },
                50_001 => { ppid: 1, uid: Process.uid, tty: "??", comm: "/usr/bin/node" },
                50_002 => { ppid: 1, uid: Process.uid, tty: "??", comm: "sibling" },
                50_003 => { ppid: 1, uid: Process.uid, tty: "??", comm: "gone" },
                50_005 => { ppid: 1, uid: Process.uid, tty: "??", comm: "tmuxp" } }
      cwds = { me => "/wt/a", shell => "/wt/a", 50_001 => "/wt/a/src", 50_002 => "/wt/ab", 50_003 => "/wt/a", 50_005 => "/wt/a" }
      stub_method(ProcessIdentity, :start_of, ->(pid) { pid == 50_003 ? "" : "s#{pid}" }) do
        stub_method(ProcessIdentity, :alive?, ->(pid) { pid != 50_003 }) do
          found = Processes.in_tree("/wt/a", table: table, cwds: cwds).map { |p| p[:pid] }
          assert_equal [shell, 50_001, 50_005].sort, found.sort, "not itself; the shell that ran it still counts; not a sibling prefix; a tmux-named tool isn't tmux"
          assert_nil Processes.in_tree("/wt/a", table: table, cwds: nil), "no cwd scan"
        end
        stub_method(ProcessIdentity, :alive?, ->(_pid) { true }) do
          assert_nil Processes.in_tree("/wt/a", table: table, cwds: cwds), "running, but its start time can't be read"
          stub_method(Processes, :table, -> { table }) do
            assert_nil Processes.in_tree("/wt/a", table: table, cwds: cwds.except(50_003).merge(50_004 => "/wt/a")), "live but unlisted"
          end
        end
      end
    end

    # Value: protects=a tmux server whose start folder is the tree is never a process of the
    # workspace's (it carries every session); fails_when=the tmux exclusion goes; why_new=red
    # team (a forced delete could stop the developer's server); seam=cwds, table
    def test_a_tmux_server_is_never_in_the_tree
      me = Process.pid
      table = { me => { ppid: 1, uid: Process.uid, tty: "??", comm: "ruby" },
                70 => { ppid: 1, uid: Process.uid, tty: "??", comm: "/opt/homebrew/bin/tmux" },
                71 => { ppid: 1, uid: Process.uid, tty: "?", comm: "tmux: server" },
                72 => { ppid: 1, uid: Process.uid, tty: "??", comm: "puma" } }
      cwds = { me => Dir.pwd, 70 => "/wt/a", 71 => "/wt/a/sub", 72 => "/wt/a" }
      found = stub_method(ProcessIdentity, :start_of, ->(pid) { "start #{pid}" }) do
        Processes.in_tree("/wt/a", table: table, cwds: cwds)
      end
      assert_equal [72], found.map { |p| p[:pid] }
    end

    # Value: protects=a process of ours Linux won't show the cwd of (non-dumpable, like
    # ssh-agent) doesn't fail every scan, while one missing for another reason still does;
    # fails_when=EACCES counts as missing, or any error as hidden; why_new=red team (delete
    # unusable on Linux with ssh-agent); seam=File.readlink, /proc
    def test_a_process_linux_hides_is_unreadable_not_missing
      me = Process.pid
      child = spawn("sleep 30")
      table = { me => { ppid: 1, uid: Process.uid, tty: "??", comm: "ruby" }, child => { ppid: me, uid: Process.uid, tty: "??", comm: "ssh-agent" } }
      here = { me => Dir.pwd }
      read = File.method(:readlink)
      scan = lambda do |err|
        link = ->(path) { path == "/proc/#{child}/cwd" ? raise(err) : read.call(path) }
        stub_method(File, :directory?, ->(path) { path == "/proc/self" || File::Stat.new(path).directory? rescue false }) do
          stub_method(File, :readlink, link) { stub_method(Processes, :proc_cwds, -> { here }) { Processes.cwds(table) } }
        end
      end
      assert_equal here, scan.call(Errno::EACCES), "hidden by design"
      assert_nil scan.call(Errno::ENOENT), "missing for another reason fails closed"
    ensure
      Process.kill("KILL", child)
      Process.wait(child)
    end
  end
end
