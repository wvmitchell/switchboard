# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # Proves the emdash removal is complete: the library loads without it, and no
  # runtime code references Emdash or sqlite3 anywhere in lib/. This is the test
  # that lets the install + emdash-removal ride in one PR without muddying which
  # half broke if something does.
  class SmokeTest < Minitest::Test
    def test_library_loads_and_installer_is_present
      assert defined?(Switchboard::Installer), "Installer should load"
      refute defined?(Switchboard::Emdash), "Emdash should be gone"
    end

    def test_no_runtime_emdash_or_sqlite_references_in_lib
      lib = File.expand_path("../lib", __dir__)
      offenders = Dir[File.join(lib, "**", "*.rb")].select do |file|
        File.readlines(file).any? do |line|
          code = line.sub(/#.*\z/, "") # ignore the peer-tool narrative comments
          code =~ /\bEmdash\b/ || code =~ /sqlite3/
        end
      end
      assert_empty offenders, "runtime emdash/sqlite3 references remain in: #{offenders}"
    end

    def test_emdash_file_is_deleted
      refute File.exist?(File.expand_path("../lib/switchboard/emdash.rb", __dir__))
    end

    def test_version_is_semver
      assert_match(/\A\d+\.\d+\.\d+/, Switchboard::VERSION)
    end
  end
end
