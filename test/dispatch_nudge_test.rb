# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  class DispatchNudgeTest < Minitest::Test
    def test_decide_follows_the_setting_and_the_rename_sources
      RenameNudge::SOURCES.each { |src| assert DispatchNudge.decide(enabled: true, source: src), src }
      refute DispatchNudge.decide(enabled: false, source: "startup")
      refute DispatchNudge.decide(enabled: true, source: nil)
      refute DispatchNudge.decide(enabled: true, source: "bogus")
    end

    # `new` is for the user, never how an agent splits up its own work (R6).
    def test_message_keeps_subagents_separate_and_needs_an_explicit_ask
      msg = DispatchNudge.message
      assert_includes msg, "separate from subagents"
      assert_includes msg, "keep using your own subagent tools"
      assert_includes msg, "only when the user explicitly asks"
    end

    # The text quotes the verb's syntax; the real parser must accept every example, so the
    # instruction can't drift from the CLI.
    def test_every_example_in_the_message_parses
      examples = DispatchNudge.message.scan(/`switchboard new ([^`]+)`/).flatten
      assert_operator examples.size, :>=, 3
      examples.each do |ex|
        _target, _task, err = DispatchArgs.parse(Shellwords.split(ex))
        assert_nil err, "example `switchboard new #{ex}` must parse"
      end
    end

    def test_message_names_the_projects_verb_the_cli_routes
      assert_includes DispatchNudge.message, "`switchboard projects`"
      assert CLI.respond_to?(:list_projects)
    end
  end
end
