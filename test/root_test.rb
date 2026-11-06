# frozen_string_literal: true

require_relative "test_helper"
require "rbconfig"

module Switchboard
  # Holds Switchboard::ROOT, the one place a file locates the install from its own position.
  # Every root here is checked against the repo as this test file sees it, never against
  # ROOT itself, so a root that drifted (a file moved a folder deeper) fails instead of
  # agreeing with itself. A drifted CodeReload root would make stale? true on every tick,
  # and every sidebar would re-exec forever.
  class RootTest < Minitest::Test
    REPO = File.realpath(File.expand_path("..", __dir__))
    LIB = File.join(REPO, "lib")

    # Each file that needs the root, and the expression that reports it. They must load on
    # their own: `switchboard install`'s helpers and standalone requires don't go through
    # lib/switchboard.rb.
    CONSUMERS = {
      "switchboard/ops/code_reload" => "Switchboard::CodeReload::LOADED_ROOT",
      "switchboard/ops/installer" => "Switchboard::Installer.real_root",
      "switchboard/ops/sandbox" => "Switchboard::Sandbox.checkout_root"
    }.freeze

    def test_root_is_the_repo_this_code_was_loaded_from
      assert_equal REPO, File.realpath(ROOT)
      assert File.file?(File.join(ROOT, "bin", "switchboard")), "ROOT holds bin/switchboard"
    end

    def test_each_consumer_loads_on_its_own_and_reports_the_repo
      CONSUMERS.each do |lib, expr|
        out = IO.popen([RbConfig.ruby, "-I#{LIB}", "-e", "require #{lib.inspect}; puts #{expr}"],
                       err: %i[child out], in: File::NULL, &:read)
        assert $?.success?, "#{lib} failed to load on its own: #{out}"
        assert_equal REPO, File.realpath(out.strip), "#{expr} after requiring only #{lib}"
      end
    end

    # Value: protects=every lib file loads with only its own requires, so lib/switchboard.rb's
    # order can't matter; fails_when=a load-time dependency is reachable only through the
    # umbrella; why_new=the standalone tests name 12 of 76 files, and agent_hooks and both
    # nudges were unguarded; seam=none; no_claim=a constant first used at call time
    def test_every_lib_file_loads_on_its_own
      files = Dir[File.join(LIB, "switchboard", "**", "*.rb")].map { _1.delete_prefix("#{LIB}/").delete_suffix(".rb") }.sort
      failed = files.each_slice(8).flat_map do |batch|
        batch.map do |lib|
          Thread.new do
            out = IO.popen([RbConfig.ruby, "-I#{LIB}", "-e", "require #{lib.inspect}"], err: %i[child out], in: File::NULL, &:read)
            "#{lib}: #{out}" unless $?.success?
          end
        end.map(&:value)
      end.compact
      assert_empty failed
    end

    def test_the_running_binary_is_not_stale_at_boot
      refute CodeReload.stale?(File.join(REPO, "bin", "switchboard")),
             "a freshly loaded sidebar must not see its own binary as moved code"
    end
  end
end
