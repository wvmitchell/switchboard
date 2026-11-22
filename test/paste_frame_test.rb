# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # The contract every stdin reader is built on: what a read becomes once the frame has
  # seen it. Items render as [:keys, "…"] and [:text, "…", paste number].
  class PasteFrameTest < Minitest::Test
    Text = Sidebar::PasteFrame::Text

    def frame = Sidebar::PasteFrame.new

    def shape(items)
      items.map { |i| i.is_a?(Text) ? [:text, i.bytes, i.paste] : [:keys, i] }
    end

    # Feeds the reads in order (a split read is a full one, D12) and returns every item, adjacent pieces of one paste merged.
    def run_reads(f, reads)
      merged = []
      reads.each_with_index do |r, n|
        shape(f.feed(r.b, full: n < reads.size - 1, now: n * 0.1)).each do |item|
          last = merged.last
          if item.first == :text && last&.first == :text && last[2] == item[2]
            last[1] += item[1]
          elsif item.first == :keys && last&.first == :keys
            last[1] += item[1]
          else
            merged << item.dup
          end
        end
      end
      merged
    end

    WHOLE = "ab\e[200~x\ry\e[201~cd"
    WANT = [[:keys, "ab"], [:text, "x\ry", 1], [:keys, "cd"]].freeze

    def test_every_split_of_both_markers_reads_the_same
      (1...WHOLE.bytesize).each do |cut|
        f = frame
        assert_equal WANT, run_reads(f, [WHOLE.byteslice(0, cut), WHOLE.byteslice(cut..)]), "cut at #{cut}"
        assert f.idle?, "cut at #{cut}"
      end
    end

    def test_every_pair_of_splits_across_three_reads_reads_the_same
      n = WHOLE.bytesize
      (1...n).to_a.combination(2).each do |a, b|
        f = frame
        reads = [WHOLE.byteslice(0, a), WHOLE.byteslice(a, b - a), WHOLE.byteslice(b..)]
        assert_equal WANT, run_reads(f, reads), "cuts at #{a}, #{b}"
        assert f.idle?
      end
    end

    def test_a_paste_start_yields_a_text_even_when_empty
      items = frame.feed("j\e[200~".b, now: 0)
      assert_equal [[:keys, "j"], [:text, "", 1]], shape(items)
    end

    def test_a_trailing_lone_esc_is_held_only_when_the_read_was_full
      f = frame
      assert_equal [[:keys, "j\e"]], shape(f.feed("j\e".b, now: 0)), "a short read's \\e is the Esc key"
      assert f.idle?

      assert_equal [[:keys, "j"]], shape(f.feed("j\e".b, full: true, now: 0))
      refute f.idle?, "a full read's \\e may be the start of a split sequence"
      assert_equal [[:text, "hi", 1]], shape(f.feed("[200~hi".b, now: 0))
    end

    def test_a_start_prefix_of_two_or_more_bytes_is_held_outside_a_paste
      ["\e[", "\e[2", "\e[20", "\e[200"].each do |prefix|
        f = frame
        assert_empty f.feed(prefix.b, now: 0), prefix.inspect
        refute f.idle?
      end
    end

    def test_a_held_prefix_that_is_not_a_paste_comes_back_as_keys
      { ["\e[2", "~"] => "\e[2~", ["\e[20", "~"] => "\e[20~", ["\e[20", "x"] => "\e[20x", ["\e[", "\r"] => "\e[\r" }.each do |reads, keys|
        assert_equal [[:keys, keys]], run_reads(frame, reads), reads.inspect
      end
    end

    def test_inside_a_paste_any_end_prefix_is_held
      f = frame
      f.feed("\e[200~".b, now: 0)
      ["\e", "\e[", "\e[2", "\e[20", "\e[201"].each do |prefix|
        assert_equal [[:text, "a", 1]], shape(f.feed("a#{prefix}".b, now: 0)), prefix.inspect
        assert_equal [[:text, prefix + "b", 1]], shape(f.feed("b".b, now: 0)), "#{prefix.inspect} was text after all"
      end
    end

    def test_a_stray_end_marker_outside_a_paste_is_keys
      assert_equal [[:keys, "\e[201~"]], shape(frame.feed("\e[201~".b, now: 0))
    end

    def test_a_start_marker_inside_a_paste_is_text
      assert_equal [[:text, "a\e[200~b", 1]], shape(frame.feed("\e[200~a\e[200~b\e[201~".b, now: 0))
    end

    def test_pastes_are_numbered
      f = frame
      items = f.feed("\e[200~a\e[201~j\e[200~b\e[201~".b, now: 0)
      assert_equal [[:text, "a", 1], [:keys, "j"], [:text, "b", 2]], shape(items)
      assert_equal 2, f.pastes
    end

    def test_expire_ends_a_paste_only_after_five_quiet_seconds
      f = frame
      f.feed("\e[200~lost end".b, now: 10)
      refute f.expire(now: 14.9)
      assert f.open?
      assert f.expire(now: 15)
      assert f.idle?
      assert_equal [[:keys, "j"]], shape(f.feed("j".b, now: 16))
    end

    def test_every_byte_restarts_the_quiet_period
      f = frame
      f.feed("\e[200~a".b, now: 0)
      f.feed("\f".b, now: 4)
      refute f.expire(now: 8), "the poke was paste bytes, so it restarted the wait"
      assert f.expire(now: 9)
    end

    def test_expire_drops_held_bytes_including_a_lone_esc
      f = frame
      f.feed("\e".b, full: true, now: 0)
      assert f.expire(now: 5)
      assert f.idle?
      assert_equal [[:keys, "j"]], shape(f.feed("j".b, now: 6)), "the held \\e is gone, not replayed"
    end

    def test_an_idle_frame_has_nothing_to_expire
      refute frame.expire(now: 100)
    end

    def test_a_read_two_seconds_into_an_open_paste_is_stalled
      f = frame
      first = f.feed("\e[200~a".b, now: 0).last
      refute first.stalled
      refute f.feed("b".b, now: 1.9).last.stalled
      assert f.feed("c".b, now: 2).last.stalled
    end

    def test_a_paste_in_one_write_is_never_stalled
      refute frame.feed("\e[200~all of it\e[201~".b, now: 0).first.stalled
    end
  end
end
