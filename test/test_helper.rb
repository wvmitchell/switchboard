# frozen_string_literal: true

# Zero-dependency test harness: Minitest ships with Ruby, so the suite honors
# switchboard's "stdlib only, no Gemfile" rule. Run a file directly
# (`ruby -Itest test/installer_test.rb`) or the whole suite via
# `ruby -Itest -e 'Dir["test/*_test.rb"].each { |f| require File.expand_path(f) }'`.
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "yaml"
require "shellwords"
require "stringio"

require_relative "../lib/switchboard"

module Switchboard
  # Isolates every test from real state: a throwaway tmpdir, env overrides for
  # the config + symlink dir, and TMUX unset so nothing ever touches a live
  # server. Restores the environment on teardown.
  class SandboxTest < Minitest::Test
    def setup
      @dir = Dir.mktmpdir("switchboard-test")
      @env = ENV.to_h
      ENV["SWITCHBOARD_CONFIG"] = File.join(@dir, "config.yml")
      ENV["SWITCHBOARD_BIN_DIR"] = File.join(@dir, "bin")
      ENV.delete("TMUX")
    end

    def teardown
      ENV.replace(@env)
      FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
    end

    def path(*parts)
      File.join(@dir, *parts)
    end
  end
end
