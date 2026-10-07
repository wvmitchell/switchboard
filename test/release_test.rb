# frozen_string_literal: true

require_relative "test_helper"
require_relative "../packaging/release"

module Switchboard
  # The pure half of the release workflow: a wrong version, empty notes, or a
  # formula left pointing at the old tag would only surface after a merge to main.
  class ReleaseTest < SandboxTest
    SHA = "a" * 64

    def test_version_matches_the_loaded_constant
      assert_equal VERSION, Release.version
    end

    def test_notes_split_title_and_body_at_the_next_entry
      log = <<~MD
        # Changelog

        ## [1.2.0] — shiny thing (2026-10-07)

        ### Added
        - the thing

        ## [1.1.0] — older (2026-10-01)
        - old
      MD
      title, body = Release.notes(log, "1.2.0")
      assert_equal "v1.2.0 — shiny thing", title
      assert_equal "### Added\n- the thing", body
    end

    def test_notes_for_the_last_entry_run_to_eof
      _title, body = Release.notes("## [0.1.0] - first (2026-01-01)\n\n- hi\n", "0.1.0")
      assert_equal "- hi", body
    end

    # A version prefix must not match a longer one (0.1.1 vs 0.1.10).
    def test_notes_match_the_exact_version
      log = "## [0.1.10] — later (2026-01-02)\n- ten\n## [0.1.1] — earlier (2026-01-01)\n- one\n"
      assert_equal ["v0.1.1 — earlier", "- one"], Release.notes(log, "0.1.1")
    end

    def test_notes_without_an_entry_raise
      assert_raises(RuntimeError) { Release.notes("## [0.1.0] — x (2026-01-01)\n", "0.2.0") }
    end

    # The real CHANGELOG's current version must have an entry, or release.yml fails.
    def test_the_current_version_has_release_notes
      title, body = Release.notes(File.read(File.join(Release::ROOT, "CHANGELOG.md")), Release.version)
      assert title.start_with?("v#{Release.version}")
      refute_empty body
    end

    def test_render_formula_points_url_and_sha_at_the_release
      out = Release.render_formula(template, "9.8.7", SHA)
      assert_includes out, %(url "https://github.com/wvmitchell/switchboard/archive/refs/tags/v9.8.7.tar.gz")
      assert_includes out, %(sha256 "#{SHA}")
      assert_includes out, %(head "https://github.com/wvmitchell/switchboard.git") # untouched
      RubyVM::InstructionSequence.compile(out) # still valid Ruby
    end

    def test_render_formula_rejects_a_bad_sha
      assert_raises(RuntimeError) { Release.render_formula(template, "1.0.0", "nope") }
    end

    # A drifted template (url line renamed) must fail loudly, not ship the old tag.
    def test_render_formula_requires_exactly_one_url_and_sha
      assert_raises(RuntimeError) { Release.render_formula(template.sub("  url ", "  # url "), "1.0.0", SHA) }
      assert_raises(RuntimeError) { Release.render_formula(template + %(  sha256 "x"\n), "1.0.0", SHA) }
    end

    private

    def template
      File.read(File.join(Release::ROOT, "packaging/homebrew/switchboard.rb"))
    end
  end
end
