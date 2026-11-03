# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # Holds SandboxTest's env wall: a suite run inside a dispatched workspace (or the sandbox)
  # inherits SWITCHBOARD_BRIEF_FROM/TASK/SANDBOX, which change what the code under test does,
  # so setup drops them. A developer's opt-in to the suite itself (HARNESS_ENV, the
  # real-codex smoke) must survive, and teardown must put everything back.
  # A plain Minitest::Test, since it drives SandboxTest's own setup/teardown.
  class SandboxEnvTest < Minitest::Test
    LEAKED = %w[SWITCHBOARD_BRIEF_FROM SWITCHBOARD_TASK SWITCHBOARD_SANDBOX].freeze

    def setup
      @saved = ENV.to_h
    end

    def teardown
      ENV.replace(@saved)
    end

    def test_setup_drops_inherited_switchboard_vars_but_keeps_harness_opt_ins
      LEAKED.each { |k| ENV[k] = "leaked" }
      ENV["SWITCHBOARD_CODEX_SMOKE"] = "1"

      sandbox = SandboxTest.new("env-wall")
      sandbox.setup
      LEAKED.each { |k| refute ENV.key?(k), "#{k} leaked into the sandbox" }
      assert_equal "1", ENV["SWITCHBOARD_CODEX_SMOKE"], "the real-codex smoke opt-in was scrubbed"
    ensure
      sandbox&.teardown
      LEAKED.each { |k| assert_equal "leaked", ENV[k], "teardown didn't restore #{k}" }
    end
  end
end
