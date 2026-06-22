# frozen_string_literal: true

require "fileutils"

module Switchboard
  # Plays a short sound when a hooked agent finishes a turn (:done) or asks for
  # input (:waiting) — the audible twin of the sidebar's state dots, riding the
  # same completion edges that trigger the PR refresh (Sidebar#on_agent_edges).
  #
  # No audio is shipped or depended on. The two defaults are SYNTHESIZED in pure
  # Ruby (16-bit PCM WAV via Array#pack) and materialized into the XDG data dir
  # on first use — the same self-healing, install-independent trick Hook uses for
  # its reporter script. Config overrides either state with a file path or a bare
  # macOS system-sound name (e.g. "Glass"). Every failure is swallowed: no player
  # on PATH, no audio device, a bad path — the sidebar never blocks or crashes
  # for a sound.
  module Sound
    module_function

    # Built-in (synthesized) sound names config may reference. Bump ASSET_VERSION
    # when the synthesis changes so an upgrade regenerates the cached WAV — the
    # version rides in the filename, so a stale file is simply never referenced.
    BUILTINS = %w[train chime].freeze
    ASSET_VERSION = 1
    RATE = 22_050 # Hz, mono — ample for these blips, keeps the cached files tiny
    PEAK = 0.5    # baked-in amplitude: clearly audible, gentle enough for on-by-default

    # Players we know how to drive, in preference order, each with the flags that
    # make it quiet + non-interactive (ffplay would otherwise open a window and
    # hang). First one found on PATH wins. afplay is macOS; the rest cover the
    # common Linux audio stacks.
    PLAYERS = {
      "afplay" => [],
      "paplay" => [],
      "aplay"  => ["-q"],
      "ffplay" => ["-nodisp", "-autoexit", "-loglevel", "quiet"]
    }.freeze

    # Fire-and-forget by default: resolve the spec to a real file and play it
    # detached, off the caller's thread. With wait: true (the CLI one-shot) block
    # until it finishes. A nil/empty spec, no known player, or a missing file all
    # no-op silently — the "shell out, swallow, degrade to nothing" house rule.
    def play(spec, wait: false)
      return if spec.nil? || spec.to_s.strip.empty?

      argv = player_argv or return # no player on PATH -> stay silent, don't even synth
      file = resolve(spec.to_s.strip)
      return unless file && File.exist?(file)

      run(argv + [file], wait)
    rescue StandardError
      nil
    end

    # spec -> a playable file path (or nil):
    #   "train"/"chime"  -> the synthesized built-in (materialized on demand)
    #   contains / or ~  -> a literal file path, expanded
    #   bare name        -> a macOS system sound (/System/Library/Sounds/<n>.aiff)
    def resolve(spec)
      return ensure_builtin(spec) if BUILTINS.include?(spec)
      return File.expand_path(spec) if spec.include?("/") || spec.start_with?("~")

      sys = system_sound(spec)
      File.exist?(sys) ? sys : nil
    end

    # Diagnostic for `doctor` / the CLI demo: why a spec won't play (or :ok),
    # without side effects. Distinguishes a missing file from a macOS-only system
    # sound name on a non-macOS host (codex #6) so the message can be specific.
    def status(spec)
      return :muted if spec.nil? || spec.to_s.strip.empty?

      s = spec.to_s.strip
      return :ok if BUILTINS.include?(s)
      return File.exist?(File.expand_path(s)) ? :ok : :missing_file if s.include?("/") || s.start_with?("~")
      return :macos_only unless macos?

      File.exist?(system_sound(s)) ? :ok : :missing_system_sound
    end

    # argv prefix for the first installed player, or nil if none is on PATH.
    def player_argv
      name, flags = PLAYERS.find { |bin, _| which(bin) }
      name && [name, *flags]
    end

    def which(bin)
      ENV["PATH"].to_s.split(File::PATH_SEPARATOR).any? do |dir|
        path = File.join(dir, bin)
        File.file?(path) && File.executable?(path)
      end
    end

    def macos?
      RUBY_PLATFORM.include?("darwin")
    end

    def system_sound(name)
      "/System/Library/Sounds/#{name}.aiff"
    end

    # The actual launch, isolated so tests can stub it (no noise, no real spawn).
    # in: NULL too, so a detached player can never reach into the sidebar's
    # raw-mode stdin (codex #8).
    def run(cmd, wait)
      if wait
        system(*cmd, in: File::NULL, out: File::NULL, err: File::NULL)
      else
        Process.detach(Process.spawn(*cmd, in: File::NULL, out: File::NULL, err: File::NULL))
      end
    end

    # Stable, install-independent home for the synthesized WAVs (XDG data dir,
    # like Hook's reporter) — survives reinstalls and `brew upgrade`.
    def asset_dir
      File.expand_path(File.join(ENV["XDG_DATA_HOME"] || "~/.local/share", "switchboard", "sounds"))
    end

    # Write the synthesized WAV if it isn't cached yet, return its path. Written
    # to a pid-scoped temp then atomically renamed (codex #9), so a second
    # sidebar process racing on the same first-use never reads a half-written WAV.
    # The version is baked into the filename, so a synthesis change lands as a new
    # file and the stale one is just never referenced again.
    def ensure_builtin(name)
      path = File.join(asset_dir, "#{name}.v#{ASSET_VERSION}.wav")
      return path if File.exist?(path)

      FileUtils.mkdir_p(asset_dir)
      tmp = "#{path}.#{Process.pid}.tmp"
      File.binwrite(tmp, synth(name))
      File.rename(tmp, path) # atomic on one fs — readers see whole file or nothing
      path
    rescue StandardError
      nil
    end

    # --- synthesis -----------------------------------------------------------

    # WAV bytes for a built-in. train = two horn blasts over a tense minor-ish
    # cluster (the Conductor nod); chime = a soft ascending two-note bell.
    def synth(name)
      case name
      when "train" then wav(train)
      when "chime" then wav(chime)
      end
    end

    # Two short horn blasts. A diminished-7th-ish cluster with a few harmonics
    # per note gives the brassy air-horn timbre; short-then-long reads as a train.
    def train
      chord = [311.13, 369.99, 440.0, 523.25] # D#4 F#4 A4 C5
      normalize(blast(chord, 0.22) + silence(0.06) + blast(chord, 0.5))
    end

    # Ascending two-note bell (G5 -> C6): a calm "your turn" that won't be
    # mistaken for the horn.
    def chime
      normalize(bell(783.99, 0.22) + bell(1046.5, 0.5))
    end

    # A sustained horn blast: each chord note plus its first harmonics, under a
    # fast attack / short release so neither end clicks.
    def blast(freqs, dur)
      samples(dur) do |t, i, n|
        freqs.sum(0.0) { |f| harmonic(f, t, [1.0, 0.6, 0.35, 0.2]) } * ar_env(i, n, 0.012, 0.03)
      end
    end

    # A struck bell: one tone with a couple harmonics under an exponential decay.
    def bell(freq, dur)
      samples(dur) { |t, i, n| harmonic(freq, t, [1.0, 0.5, 0.25]) * decay_env(i, n, 0.006) }
    end

    # Sum of the first `amps.size` harmonics of `freq` at time `t` (sine partials).
    def harmonic(freq, t, amps)
      total = 0.0
      amps.each_with_index { |a, h| total += a * Math.sin(2 * Math::PI * freq * (h + 1) * t) }
      total
    end

    # `dur` seconds of samples, yielding (t, i, n) per sample.
    def samples(dur)
      n = (dur * RATE).round
      Array.new(n) { |i| yield(i.to_f / RATE, i, n) }
    end

    def silence(dur)
      Array.new((dur * RATE).round, 0.0)
    end

    # Attack/release envelope: linear up over `atk` s, full sustain, linear down
    # over the final `rel` s — kills the click at both ends of a blast.
    def ar_env(i, n, atk, rel)
      a = (atk * RATE).round
      r = (rel * RATE).round
      if i < a then i.to_f / a
      elsif i > n - r then [n - i, 0].max.to_f / r
      else 1.0
      end
    end

    # Tiny attack, then exponential decay to ~0 over the rest — a bell's tail.
    def decay_env(i, n, atk)
      a = (atk * RATE).round
      return i.to_f / a if i < a

      Math.exp(-4.0 * (i - a) / (n - a))
    end

    # Scale the whole buffer to `peak` so summed partials never clip and the
    # on-by-default volume stays gentle.
    def normalize(buf, peak = PEAK)
      max = buf.map(&:abs).max
      return buf if max.nil? || max.zero?

      scale = peak / max
      buf.map { |s| s * scale }
    end

    # Float samples (-1..1) -> a mono 16-bit PCM WAV (RIFF) byte string.
    def wav(buf)
      pcm = buf.map { |s| (s.clamp(-1.0, 1.0) * 32_767).round }.pack("s<*")
      header = [
        "RIFF", 36 + pcm.bytesize, "WAVE",
        "fmt ", 16, 1, 1, RATE, RATE * 2, 2, 16,
        "data", pcm.bytesize
      ].pack("a4 V a4  a4 V v v V V v v  a4 V")
      header + pcm
    end
  end
end
