# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # QR.matrix — the sidebar's zero-gem QR encoder. The fixtures under test/fixtures/qr
  # come from `qrencode -8 -l M` (an independent encoder), one per mask with the mask
  # forced here, so a bug in data placement, Reed-Solomon, interleaving or the format
  # bits can't hide behind the mask choice. Which mask gets chosen is pinned separately
  # by the hand-worked penalty cases: encoders legitimately differ there
  # (libqrencode#220), so the suite never asserts another encoder's pick.
  class QRTest < Minitest::Test
    FIXTURES = Dir[File.join(__dir__, "fixtures", "qr", "*.txt")].sort

    def fixture(path)
      header, data, *rows = File.read(path).lines.map(&:chomp)
      [data, header[/mask (\d)/, 1].to_i, header[/version (\d)/, 1].to_i, rows.map { |r| r.chars.map { |c| c == "1" } }]
    end

    def test_fixtures_cover_every_mask_and_version
      masks = FIXTURES.map { |f| fixture(f)[1] }.uniq.sort
      versions = FIXTURES.map { |f| fixture(f)[2] }.uniq.sort
      assert_equal (0..7).to_a, masks
      assert_equal (1..6).to_a, versions
    end

    def test_every_fixture_matches_module_for_module
      FIXTURES.each do |f|
        data, mask, version, expected = fixture(f)
        got = QR.matrix(data, mask: mask)
        assert_equal QR.size(version), got.size, File.basename(f)
        assert_equal expected, got, "#{File.basename(f)}: #{data.bytesize} bytes, mask #{mask}"
      end
    end

    def test_picks_the_smallest_version_that_fits
      assert_equal 21, QR.matrix("").size, "empty still makes a v1 code"
      assert_equal 33, QR.matrix("x" * 62).size, "62 bytes is the most v4-M holds"
      assert_equal 37, QR.matrix("x" * 63).size
      assert_equal 41, QR.matrix("x" * 106).size, "106 bytes is the most v6-M holds"
      assert_equal 33, QR.matrix("https://claude.ai/code/session_01AbCdEfGhJkMnPqRsTuVwXy").size,
                   "today's 55-byte link URL is a v4 code"
    end

    def test_too_long_is_nil_not_a_raise
      assert_nil QR.matrix("x" * 107)
      assert_nil QR.matrix("x" * 10_000)
    end

    def test_encodes_the_utf8_bytes_whatever_the_string_encoding
      assert_equal QR.matrix("⇅ smart “quote”".b), QR.matrix("⇅ smart “quote”")
      assert_equal QR.matrix("abc".encode(Encoding::US_ASCII)), QR.matrix("abc")
    end

    def test_auto_mask_is_the_lowest_penalty_with_ties_to_the_lower_mask
      ["https://claude.ai/code/session_01AbCdEfGhJkMnPqRsTuVwXy", "rc:1", "x" * 100].each do |s|
        scored = (0..7).map { |m| [QR.penalty(QR.matrix(s, mask: m)), m] }
        best = scored.min.last
        assert_equal QR.matrix(s, mask: best), QR.matrix(s), s
      end
    end

    def test_penalty_runs_scores_five_or_more_in_a_line
      assert_equal 0, QR.penalty_runs([[true] * 4 + [false]])
      assert_equal 3, QR.penalty_runs([[true] * 5])
      assert_equal 5, QR.penalty_runs([[true] * 7])
      assert_equal 7, QR.penalty_runs([[false] * 5 + [true] + [false] * 6]), "a run of 5 (3) and a run of 6 (4)"
      assert_equal 6, QR.penalty_runs([[true]] * 5 + [[false]] + [[true]] * 5), "columns count too"
    end

    def test_penalty_blocks_scores_each_same_colored_two_by_two
      assert_equal 3, QR.penalty_blocks([[true, true], [true, true]])
      assert_equal 0, QR.penalty_blocks([[true, false], [false, true]])
      assert_equal 12, QR.penalty_blocks(Array.new(3) { [false] * 3 }), "overlapping blocks all count"
    end

    def test_penalty_finders_scores_the_finder_like_pattern_with_four_light
      pattern = [true, false, true, true, true, false, true]
      assert_equal 40, QR.penalty_finders([pattern + [false] * 4])
      assert_equal 40, QR.penalty_finders([[false] * 4 + pattern])
      assert_equal 0, QR.penalty_finders([pattern + [false] * 3 + [true]]), "only three light"
      assert_equal 80, QR.penalty_finders([[false] * 4 + pattern + [false] * 4]), "both sides, both windows"
    end

    def test_penalty_balance_scores_each_full_five_percent_off_half
      grid = ->(dark, total) { [Array.new(total) { |i| i < dark }] }
      assert_equal 0, QR.penalty_balance(grid.call(10, 20))
      assert_equal 10, QR.penalty_balance(grid.call(11, 20)), "55%"
      assert_equal 10, QR.penalty_balance(grid.call(9, 20)), "45%"
      assert_equal 0, QR.penalty_balance(grid.call(27, 50)), "54% rounds down"
      assert_equal 40, QR.penalty_balance(grid.call(14, 20)), "70%"
    end

    def test_penalty_is_the_four_rules_summed
      g = QR.matrix("rc:1", mask: 3)
      assert_equal QR.penalty_runs(g) + QR.penalty_blocks(g) + QR.penalty_finders(g) + QR.penalty_balance(g),
                   QR.penalty(g)
    end
  end
end
