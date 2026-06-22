# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # Sound: player selection, spec resolution, the diagnostic status used by
  # doctor/CLI, WAV synthesis correctness, and the no-op/degrade guards on play.
  # The real spawn (run) and PATH probe (which) are the only seams stubbed — no
  # audio is ever played and no real player is required, so the suite stays
  # offline. WAV bytes are parsed and asserted field-by-field, not just "exists".
  class SoundTest < SandboxTest
    # --- player selection ----------------------------------------------------

    def test_player_argv_picks_the_only_installed_player
      stub_method(Sound, :which, ->(bin) { bin == "paplay" }) do
        assert_equal ["paplay"], Sound.player_argv
      end
    end

    def test_player_argv_carries_per_player_flags
      stub_method(Sound, :which, ->(bin) { bin == "aplay" }) do
        assert_equal ["aplay", "-q"], Sound.player_argv
      end
      stub_method(Sound, :which, ->(bin) { bin == "ffplay" }) do
        assert_equal ["ffplay", "-nodisp", "-autoexit", "-loglevel", "quiet"], Sound.player_argv
      end
    end

    def test_player_argv_honors_preference_order
      # afplay and paplay both present -> afplay (first in PLAYERS) wins.
      stub_method(Sound, :which, ->(bin) { %w[afplay paplay].include?(bin) }) do
        assert_equal ["afplay"], Sound.player_argv
      end
    end

    def test_player_argv_nil_when_no_player_on_path
      stub_method(Sound, :which, ->(_bin) { false }) do
        assert_nil Sound.player_argv
      end
    end

    # --- resolve -------------------------------------------------------------

    def test_resolve_builtin_materializes_versioned_wav
      path = Sound.resolve("train")
      assert path.end_with?("train.v#{Sound::ASSET_VERSION}.wav")
      assert File.exist?(path)
      assert_equal Sound.asset_dir, File.dirname(path)
    end

    def test_resolve_variant_builtin_materializes_versioned_wav
      path = Sound.resolve("train_2")
      assert path.end_with?("train_2.v#{Sound::ASSET_VERSION}.wav")
      assert File.exist?(path)
      assert_equal Sound.asset_dir, File.dirname(path)
    end

    def test_status_ok_for_variant_builtin
      assert_equal :ok, Sound.status("chime_3")
    end

    def test_resolve_expands_path_specs
      assert_equal File.expand_path("/tmp/horn.wav"), Sound.resolve("/tmp/horn.wav")
      assert_equal File.expand_path("~/horn.aiff"), Sound.resolve("~/horn.aiff")
    end

    def test_resolve_unknown_bare_name_is_nil
      # No slash, not a builtin, and no such macOS system sound -> nil (and nil
      # on Linux too, where the system path doesn't exist).
      assert_nil Sound.resolve("Definitely_Not_A_Sound_zzz")
    end

    # --- status (doctor/CLI diagnostic) --------------------------------------

    def test_status_muted_for_blank
      assert_equal :muted, Sound.status(nil)
      assert_equal :muted, Sound.status("")
      assert_equal :muted, Sound.status("   ")
    end

    def test_status_ok_for_builtin
      assert_equal :ok, Sound.status("train")
    end

    def test_status_ok_for_existing_file_and_missing_for_absent
      file = path("real.wav")
      File.binwrite(file, "x")
      assert_equal :ok, Sound.status(file)
      assert_equal :missing_file, Sound.status(path("nope.wav"))
    end

    def test_status_bare_name_is_os_specific
      # macOS: unknown name -> missing_system_sound; elsewhere -> macos_only.
      expected = Sound.macos? ? :missing_system_sound : :macos_only
      assert_equal expected, Sound.status("Glasszzz")
    end

    # --- synthesis: WAV correctness ------------------------------------------

    def test_synth_train_is_a_well_formed_wav
      assert_valid_wav Sound.synth("train")
    end

    def test_synth_chime_is_a_well_formed_wav
      assert_valid_wav Sound.synth("chime")
    end

    def test_synth_unknown_name_is_nil
      assert_nil Sound.synth("nope")
    end

    def test_synth_amplitude_is_gentle
      # Normalized to PEAK (~0.5 full scale), so it can't clip or startle. Every
      # built-in (defaults + variants) shares the gentle ceiling.
      ceiling = (Sound::PEAK * 32_767).ceil + 1
      Sound::BUILTINS.each do |name|
        peak = parse_wav(Sound.synth(name))[:samples].map(&:abs).max
        assert peak <= ceiling, "#{name} peak #{peak} exceeds gentle ceiling #{ceiling}"
        assert peak.positive?, "#{name} is silent"
      end
    end

    def test_all_builtins_synthesize_to_valid_wavs
      Sound::BUILTINS.each { |name| assert_valid_wav Sound.synth(name) }
    end

    def test_builtins_are_acoustically_distinct
      # train, chime, and the six variants must each be a different sound — no
      # variant silently aliasing another (the whole point of having them).
      wavs = Sound::BUILTINS.map { |name| Sound.synth(name) }
      assert_equal wavs.size, wavs.uniq.size, "every built-in should be distinct"
    end

    # --- ensure_builtin: materialize once, cache -----------------------------

    def test_ensure_builtin_writes_once_and_reuses
      path = Sound.ensure_builtin("train")
      assert File.exist?(path)
      before = File.mtime(path)
      assert_equal path, Sound.ensure_builtin("train") # cached: same path
      assert_equal before, File.mtime(path)            # not rewritten
    end

    # --- play: guards + the spawn seam ---------------------------------------

    def test_play_noops_on_blank_spec
      calls = []
      stub_method(Sound, :run, ->(cmd, wait) { calls << [cmd, wait] }) do
        Sound.play(nil)
        Sound.play("")
      end
      assert_empty calls
    end

    def test_play_noops_when_no_player
      calls = []
      stub_method(Sound, :which, ->(_b) { false }) do
        stub_method(Sound, :run, ->(cmd, wait) { calls << [cmd, wait] }) do
          Sound.play("train")
        end
      end
      assert_empty calls
    end

    def test_play_invokes_resolved_player_with_file
      captured = nil
      stub_method(Sound, :which, ->(bin) { bin == "afplay" }) do
        stub_method(Sound, :run, ->(cmd, wait) { captured = [cmd, wait] }) do
          Sound.play("train")
        end
      end
      cmd, wait = captured
      assert_equal "afplay", cmd.first
      assert cmd.last.end_with?(".wav")
      refute wait
    end

    def test_play_threads_wait_flag
      captured = nil
      stub_method(Sound, :which, ->(bin) { bin == "afplay" }) do
        stub_method(Sound, :run, ->(cmd, wait) { captured = [cmd, wait] }) do
          Sound.play("train", wait: true)
        end
      end
      assert captured.last
    end

    # --- normalize: silence guard --------------------------------------------

    def test_normalize_leaves_silence_untouched
      # All-zero buffer must not divide by zero.
      assert_equal [0.0, 0.0, 0.0], Sound.normalize([0.0, 0.0, 0.0])
    end

    private

    def assert_valid_wav(bytes)
      refute_nil bytes
      w = parse_wav(bytes)
      assert_equal "RIFF", w[:riff]
      assert_equal "WAVE", w[:wave]
      assert_equal 1, w[:audio_format]      # PCM
      assert_equal 1, w[:channels]          # mono
      assert_equal Sound::RATE, w[:rate]
      assert_equal 16, w[:bits]
      assert_equal w[:data_size], w[:samples].size * 2 # 16-bit
      assert_equal bytes.bytesize - 44, w[:data_size]  # 44-byte header
      assert w[:samples].size.positive?
    end

    def parse_wav(bytes)
      audio_format, channels, rate, _byte_rate, _align, bits = bytes[20, 16].unpack("vvVVvv")
      data_size = bytes[40, 4].unpack1("V")
      {
        riff: bytes[0, 4], wave: bytes[8, 4],
        audio_format: audio_format, channels: channels, rate: rate, bits: bits,
        data_size: data_size, samples: bytes[44..].unpack("s<*")
      }
    end
  end
end
