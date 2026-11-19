# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

module Switchboard
  # Agents.scan_pids is delete's strict process scan: a read that fails must say so, never
  # "nobody is here". pgrep and lsof are faked per command, each with a real exit status.
  class AgentsTest < Minitest::Test
    # { "pgrep" => [output, exit status], "lsof" => [...] }
    def with_commands(results, &blk)
      popen = lambda do |argv, **, &read|
        out, status = results.fetch(argv.first)
        system("exit #{status}") # sets $? the way the real command would
        read.call(StringIO.new(out))
      end
      stub_method(IO, :popen, popen, &blk)
    end

    # Value: protects=a failed process scan never reads as "nobody is in the workspace",
    # so a working agent's folder isn't deleted; fails_when=the pgrep exit check loosens, or
    # cwds_of_strict returns {} when lsof prints nothing for live pids; why_new=every
    # delete test stubs scan_pids and the smoke test only reaches success; seam=none;
    # no_claim=real pgrep/lsof output formats (the smoke test runs them)
    def test_a_scan_that_fails_is_nil_and_an_empty_one_is_empty
      with_commands("pgrep" => ["", 2]) { assert_nil Agents.scan_pids, "pgrep errored" }
      with_commands("pgrep" => ["", 1]) { assert_equal({}, Agents.scan_pids, "no match") }
      with_commands("pgrep" => ["#{Process.pid}\n", 0]) { assert_equal({}, Agents.scan_pids, "only this process") }

      child = spawn("sleep 30")
      begin
        with_commands("pgrep" => ["#{child}\n", 0], "lsof" => ["", 1]) do
          assert_nil Agents.scan_pids, "lsof printed nothing for a live pid"
        end
        with_commands("pgrep" => ["#{child}\n", 0], "lsof" => ["p#{child}\nn/wt/a\n", 0]) do
          assert_equal({ child => "/wt/a" }, Agents.scan_pids)
        end
      ensure
        Process.kill("KILL", child)
        Process.wait(child)
      end
      with_commands("pgrep" => ["#{child}\n", 0], "lsof" => ["", 1]) do
        assert_equal({}, Agents.scan_pids, "the pid exited between pgrep and lsof")
      end
    end
  end
end
