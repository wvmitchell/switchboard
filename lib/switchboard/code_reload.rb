# frozen_string_literal: true

require "json"

module Switchboard
  # A running sidebar swapping in new code without a restart (#48). The sidebar execs
  # its own SWITCHBOARD_BIN in place — same pid, pty and pane — and hands the few
  # per-process things worth keeping (cursor, the agent-edge baseline) to the new image
  # in one env var. Everything else is already on disk by design.
  #
  # Cross-version contract: newer code must accept every older payload, and a missing
  # or unreadable one is just a cold start.
  module CodeReload
    module_function

    RESUME_ENV = "SWITCHBOARD_SIDEBAR_RESUME"
    SPREAD_ENV = "SWITCHBOARD_RELOAD_SPREAD" # tests and smoke runs set 0
    TAG = "@sb_reload"   # pane option: this pane's sidebar pid, so a sender knows it can take the signal
    SIGNAL = "USR1"
    SPREAD = 30          # seconds an off-screen sidebar may wait, so a fleet doesn't boot + rescan at once
    PREFLIGHT_SECS = 3
    PAYLOAD_MAX = 64 * 1024
    VERSION = 1
    STATES = %w[thinking done waiting].freeze

    # The install this process loaded: <root>/lib/switchboard/.. — a keg's realpath under
    # Homebrew, the checkout otherwise. Captured at require time, before any upgrade moves opt/.
    LOADED_ROOT = File.expand_path("../..", __dir__)

    # Does SWITCHBOARD_BIN now resolve to different code than we loaded? Only a Homebrew
    # upgrade moves it (opt/ points at a new keg); a clone's root never changes, so this
    # is inert there. A stat or two, no subprocess. Unknown ⇒ false.
    def stale?(bin = ENV["SWITCHBOARD_BIN"])
      root = current_root(bin) or return false
      root != LOADED_ROOT
    end

    def current_root(bin = ENV["SWITCHBOARD_BIN"])
      return nil if bin.nil? || bin.empty?

      File.expand_path("../..", File.realpath(bin))
    rescue SystemCallError
      nil
    end

    # Does `<bin> version` load and exit 0 within the bound? exec only fails safe when the
    # exec call itself fails; new code that raises while loading would kill the pane. Run
    # in the env the exec will use (SB_REEXEC cleared, else a system-Ruby re-exec is
    # skipped and a working binary reads as broken), with no stdio: it keeps the pane as
    # its controlling tty, so nothing it does may read keys or paint.
    def preflight(bin, secs: PREFLIGHT_SECS)
      pid = Process.spawn({ "SB_REEXEC" => nil }, bin, "version",
                          in: File::NULL, out: File::NULL, err: File::NULL, pgroup: true)
      status = ProcessIdentity.wait_within(pid, secs)
      return status.success? if status

      ProcessIdentity.terminate_group(pid)
      false
    rescue SystemCallError
      false
    end

    # Reload every sidebar on this tmux server (`upgrade` / `reload-sidebars`). A tagged
    # one gets the signal and swaps code itself, keeping its state. An untagged one (older
    # than 0.59, or tmux < 3.0) is respawned by its own start command — but only when that
    # binary exists and loads (`version`, once per distinct binary): a respawn kills the old
    # process first, so a broken or deleted checkout would leave the window without a
    # sidebar. Those stay running and are counted. nil off a server.
    def reload_all
      targets = Tmux.sidebar_reload_targets or return nil
      counts = { signaled: 0, respawned: 0, left: 0 }
      loads = Hash.new { |memo, bin| memo[bin] = File.file?(bin) && File.executable?(bin) && preflight(bin) }
      marker = encode
      targets.each do |t|
        if t.tagged
          counts[:signaled] += 1 if Tmux.signal_sidebar(t)
        elsif t.bin && loads[t.bin] && Tmux.respawn_sidebar(t, marker)
          counts[:respawned] += 1
        else
          counts[:left] += 1
        end
      end
      counts
    end

    # [summary, warning-or-nil] for reload_all's counts; summary nil with nothing reached.
    def describe(counts)
      done = []
      done << "#{counts[:signaled]} reloading in place" if counts[:signaled].positive?
      done << "#{counts[:respawned]} restarted" if counts[:respawned].positive?
      left = counts[:left]
      warning = if left.positive?
                  "#{left} sidebar#{'s' unless left == 1} left running old code: " \
                    "#{left == 1 ? 'its' : 'their'} switchboard was removed or doesn't start"
                end
      [done.empty? ? nil : "sidebars: #{done.join(', ')}", warning]
    end

    # 0..SPREAD seconds (SWITCHBOARD_RELOAD_SPREAD overrides the bound).
    def spread_delay(rng = Random)
      bound = Float(ENV.fetch(SPREAD_ENV, SPREAD), exception: false) || SPREAD
      bound.positive? ? rng.rand * bound : 0.0
    end

    def encode(cursor: nil, offset: 0, hook_states: {}, notify: {}, announce: false)
      JSON.generate("v" => VERSION, "cursor" => cursor, "offset" => offset,
                    "hook_states" => hook_states.transform_keys(&:to_s).transform_values(&:to_s),
                    "notify" => notify.transform_values { |t| [t.to_i, t.nsec] }, "announce" => announce)
    end

    # The payload as a symbol-keyed hash, or nil for anything not worth trusting (absent,
    # oversized, unparseable, an unknown version). Fields are filtered one by one, so a
    # bad entry drops only itself.
    def decode(raw)
      return nil if raw.nil? || raw.empty? || raw.bytesize > PAYLOAD_MAX

      data = JSON.parse(raw)
      return nil unless data.is_a?(Hash) && data["v"] == VERSION

      { cursor: cursor_from(data["cursor"]),
        offset: data["offset"].is_a?(Integer) && data["offset"] >= 0 ? data["offset"] : 0,
        hook_states: hash_of(data["hook_states"]).select { |k, v| k.is_a?(String) && STATES.include?(v) }
                                                 .transform_values(&:to_sym),
        notify: hash_of(data["notify"]).filter_map { |k, v| [k, mtime_from(v)] if k.is_a?(String) && mtime_from(v) }.to_h,
        announce: data["announce"] == true }
    rescue JSON::ParserError, EncodingError
      nil
    end

    # Read and REMOVE the payload, so nothing this process spawns inherits it.
    def take_resume(env = ENV)
      decode(env.delete(RESUME_ENV))
    end

    def cursor_from(value)
      return nil unless value.is_a?(Hash)

      cursor = value.slice("kind", "project", "path", "branch")
      cursor.values.all? { |v| v.nil? || v.is_a?(String) } && cursor["kind"].is_a?(String) ? cursor : nil
    end

    # A notify cursor is a marker mtime, carried as exact [seconds, nanoseconds]: a float
    # can come back a hair early, and then the alert it already rang would ring again.
    def mtime_from(value)
      sec, nsec = value
      return nil unless value.is_a?(Array) && value.size == 2 && sec.is_a?(Integer) && nsec.is_a?(Integer)

      Time.at(sec, nsec, :nsec)
    rescue ArgumentError, RangeError
      nil
    end

    def hash_of(value)
      value.is_a?(Hash) ? value : {}
    end
  end
end
