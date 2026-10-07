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

    # Value: protects=release.yml never tags an empty version; fails_when=the raise becomes a
    # nil return (the workflow would test refs/tags/v and `gh release create v`); why_new=only
    # the happy path read is tested; seam=none
    def test_version_without_a_constant_raises
      f = path("version.rb").tap { |p| File.write(p, "module X; end\n") }
      assert_raises(RuntimeError) { Release.version(f) }
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

    # Value: protects=the GitHub release title for `-`-separated and title-less headings;
    # fails_when=the separator/date stripping regresses (title "v1.0.0 — (2026-01-01)" or
    # a dangling "v1.0.0 — "); why_new=existing tests only assert titles for the `—` + date form; seam=none
    def test_notes_title_handles_a_hyphen_and_a_missing_title
      assert_equal "v0.1.0 — first", Release.notes("## [0.1.0] - first (2026-01-01)\n- hi\n", "0.1.0").first
      assert_equal "v1.0.0", Release.notes("## [1.0.0] (2026-01-01)\n- hi\n", "1.0.0").first
      assert_equal "v1.0.0", Release.notes("## [1.0.0]\n- hi\n", "1.0.0").first
    end

    # Value: protects=the argv/file contract release.yml calls (version, notes V TITLE NOTES,
    # formula V SHA → stdout); fails_when=the CLI swaps the title/notes files, reads the wrong
    # template, or drops a subcommand; why_new=other tests call the module, never the CLI the
    # workflow actually runs; seam=none
    def test_cli_subcommands_match_the_workflow_contract
      script = File.join(Release::ROOT, "packaging/release.rb")
      run = ->(*args) { IO.popen([RbConfig.ruby, script, *args], err: File::NULL, &:read) }
      v = Release.version
      assert_equal "#{v}\n", run.call("version")
      assert_equal "https://github.com/wvmitchell/switchboard/archive/refs/tags/v#{v}.tar.gz\n", run.call("tarball-url", v)

      title_file, notes_file = path("title.txt"), path("notes.md")
      run.call("notes", v, title_file, notes_file)
      expected_title, expected_body = Release.notes(File.read(File.join(Release::ROOT, "CHANGELOG.md")), v)
      assert_equal expected_title, File.read(title_file)
      assert_equal "#{expected_body}\n", File.read(notes_file)

      assert_equal Release.render_formula(template, "9.9.9", SHA), run.call("formula", "9.9.9", SHA)
      tagged = path("tagged-formula.rb").tap { |f| File.write(f, template.sub("desc ", "desc \"tagged\" # ")) }
      assert_includes run.call("formula", "9.9.9", SHA, tagged), %(desc "tagged")
      assert_equal "release=true\ntag_exists=false\ntap=true\nreason=new version\n", run.call("plan", "true", "true", "0.50.0", "", "false", "false")
      refute IO.popen([RbConfig.ruby, script, "bogus"], err: File::NULL, &:read).then { $?.success? }
    end

    # Value: protects=release.yml's positional `plan TIP GREEN VERSION LATEST TAGGED RELEASED`
    # reaching the right keywords; fails_when=the CLI swaps VERSION/LATEST or TAGGED/RELEASED, or
    # drops a non-empty LATEST (the backwards-tap guard silently bypassed in CI); why_new=the CLI
    # test passes an empty LATEST and false/false, so any such swap still prints the same; seam=none
    def test_cli_plan_maps_each_positional_arg
      script = File.join(Release::ROOT, "packaging/release.rb")
      plan = ->(*args) { IO.popen([RbConfig.ruby, script, "plan", *args], err: File::NULL, &:read) }
      assert_includes plan.call("true", "true", "1.2.0", "1.10.0", "false", "false"), "tap=false\nreason=version.rb (1.2.0) is behind"
      assert_equal "release=true\ntag_exists=true\ntap=true\nreason=tag exists without a Release; creating it\n",
                   plan.call("true", "true", "1.2.0", "1.2.0", "true", "false")
      assert_includes plan.call("false", "true", "1.2.0", "", "false", "false"), "reason=not main's tip"
      assert_includes plan.call("true", "false", "1.2.0", "", "false", "false"), "reason=waiting on every CI gate"
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

    # Value: protects=the tap never gets a checksum no download can match; fails_when=the
    # empty-digest guard is dropped (a failed curl hashes to it and is valid hex); why_new=the
    # bad-sha test only covers malformed strings; seam=none
    def test_render_formula_rejects_the_empty_file_digest
      assert_raises(RuntimeError) { Release.render_formula(template, "1.0.0", Release::EMPTY_SHA) }
    end

    # Value: protects=REPO and the template's url staying in step; fails_when=one is changed
    # without the other and the url silently stops being rewritten; why_new=the CLI test reads
    # tarball-url back from the same constant; seam=none
    def test_render_formula_rejects_a_template_for_another_repo
      other = template.sub("github.com/#{Release::REPO}/archive", "github.com/someone/else/archive")
      assert_raises(RuntimeError) { Release.render_formula(other, "1.0.0", SHA) }
    end

    # Value: protects=release.yml's skip/tag/heal decisions; fails_when=a non-tip or not-fully-
    # green commit acts, a version behind the newest tag moves the tap backwards, a released
    # version re-releases, or a tag without its Release is never repaired; why_new=the decision
    # used to be untested workflow shell; seam=none
    def test_plan_only_lets_a_fully_green_current_main_tip_act
      base = { tip: true, checks_green: true, version: "1.2.0", latest_tag: "1.1.0", tagged: false, released: false }
      table = [
        [{ tip: false },                                     [false, false, false]], # superseded commit
        [{ checks_green: false },                            [false, false, false]], # a gate not (yet) green
        [{ latest_tag: "1.10.0" },                           [false, false, false]], # behind the newest tag (semver, not string, order)
        [{},                                                 [true,  false, true]],  # new version
        [{ latest_tag: nil },                                [true,  false, true]],  # first release ever
        [{ latest_tag: "1.2.0", tagged: true },              [true,  true,  true]],  # tag without a Release: create it
        [{ latest_tag: "1.2.0", tagged: true, released: true }, [false, true, true]] # released: heal the tap only
      ]
      table.each do |overrides, want|
        got = Release.plan(**base.merge(overrides))
        assert_equal want, got.values_at(:release, :tag_exists, :tap), overrides.inspect
        refute_empty got[:reason]
      end
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
