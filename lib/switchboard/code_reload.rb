# frozen_string_literal: true

require "json"
require "tempfile"
require_relative "latest_release"
require_relative "stable_path"

module Switchboard
  # A running sidebar swapping in new code without a restart (#48). The sidebar execs
  # its own SWITCHBOARD_BIN in place — same pid, pty and pane — and hands the few
  # per-process things worth keeping (cursor, the agent-edge baseline) to the new image
  # in one env var. Everything else is already on disk by design.
  #
  # Cross-version contract: newer code must accept every older payload. An absent one is a
  # cold start (a launch); one that won't decode is a blank resume, still a reload.
  module CodeReload
    module_function

    RESUME_ENV = "SWITCHBOARD_SIDEBAR_RESUME"
    SPREAD_ENV = "SWITCHBOARD_RELOAD_SPREAD" # tests and smoke runs set 0
    TAG = "@sb_reload"   # pane option: this pane's sidebar pid, so a sender knows it can take the signal
    FAILED_TAG = "@sb_reload_failed" # pane option: the root a reload couldn't switch to, or the bin when it wouldn't resolve (doctor, the next reload)
    SIGNAL = "USR1"
    SPREAD = 30          # seconds an off-screen sidebar may wait, so a fleet doesn't boot + rescan at once
    PREFLIGHT_SECS = 3
    CURSOR_FIELDS = %w[kind project path branch].freeze # a row's identity across the exec
    PAYLOAD_MAX = 64 * 1024
    VERSION = 1
    STATES = %w[thinking done waiting].freeze
    CHECK_SINCE = "0.59.0" # the first release with `sidebar --check`
    VERSION_LINE = /\Aswitchboard (\d+\.\d+\.\d+)\s*\z/

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
      real = real_bin(bin) or return nil
      root_of(real)
    end

    def root_of(real) = File.expand_path("../..", real)

    # The file SWITCHBOARD_BIN resolves to right now (a keg's bin under Homebrew), or nil. A
    # keg path goes through its opt/ twin first: an image that booted while opt/ was missing
    # kept the keg path, and would otherwise never follow another upgrade.
    def real_bin(bin = ENV["SWITCHBOARD_BIN"])
      return nil if bin.nil? || bin.empty?

      File.realpath(StablePath.resolve(bin))
    rescue SystemCallError
      nil
    end

    # :ok, :failed or :timeout: does `<bin> <args>` (default `version`) exit 0 within the
    # bound? exec only fails safe when the exec call itself fails; new code that raises while
    # loading would kill the pane. A sidebar's own reload checks `sidebar --check` with its
    # payload, which proves the new code can construct a sidebar and apply that payload. Run
    # in the env the exec will
    # use (SB_REEXEC cleared, else a system-Ruby re-exec is skipped and a working binary reads
    # as broken), with stdio off the pane (stdout only to `out`): it keeps the pane as its
    # controlling tty, so nothing it does may read keys or paint.
    def preflight(bin, *args, env: {}, secs: PREFLIGHT_SECS, out: File::NULL)
      args = ["version"] if args.empty?
      pid = Process.spawn({ "SB_REEXEC" => nil }.merge(env), bin, *args,
                          in: File::NULL, out: out, err: File::NULL, pgroup: true)
      status = ProcessIdentity.wait_within(pid, secs)
      return status.success? ? :ok : :failed if status

      ProcessIdentity.terminate_group(pid)
      :timeout
    rescue SystemCallError
      :failed
    end

    # Reload every sidebar on this tmux server (`upgrade` / `reload-sidebars`). A tagged
    # one gets the signal and swaps code itself, keeping its state — tagged meaning the pane
    # tag is the pane's pid, or a child of it (a shell like fish that doesn't exec its
    # command). An untagged one (older than 0.59, or tmux < 3.0) is respawned by its own
    # start command — but only when that binary passes `restartable` (once per distinct
    # binary): a respawn kills the old process first, so a broken or deleted checkout would
    # leave the window without a sidebar. Those stay running and are counted, and so are
    # sidebars a previous reload couldn't switch. nil off a server.
    def reload_all
      targets = Tmux.sidebar_reload_targets or return nil
      counts = { signaled: 0, respawned: 0, left: 0, failed: targets.count(&:failed) }
      marker = encode
      checked = Hash.new { |memo, bin| memo[bin] = restartable(bin, marker) }
      parents = Tmux.parent_pids(targets.filter_map(&:tag_pid))
      targets.each do |t|
        signal_pid = t.tagged ? t.pid : (t.tag_pid if t.tag_pid && parents[t.tag_pid] == t.pid)
        if t.between
          counts[:signaled] += 1 # mid-exec from another reload: already on its way
        elsif signal_pid
          counts[:signaled] += 1 if Tmux.signal_sidebar(signal_pid)
        elsif t.bin && (real = checked[t.bin]) && Tmux.same_reload_target?(t) &&
              start_file(t.bin) == real && # a link that moved since the check: leave it
              Tmux.respawn_sidebar(t, marker)
          counts[:respawned] += 1
        else
          counts[:left] += 1
        end
      end
      counts
    end

    # The file a restart of `bin` would run, if it's safe to: nil unless it resolves, prints
    # its version, and — 0.59+, the releases with `sidebar --check` — builds a sidebar from
    # `marker`. Older ones get `version` only: they'd run `sidebar --check` as a full hidden
    # sidebar (a home one prunes). Both runs use the one resolved file, so a brew relink
    # between them can't hand the check to an older keg. The check runs in this process's
    # env, which can resolve a different config, or (a clone's `env ruby`) a different Ruby,
    # than the tmux server the pane restarts in.
    def restartable(bin, marker)
      real = start_file(bin) or return nil
      return nil unless File.file?(real) && File.executable?(real)

      version = version_of(real) or return nil # an exit 0 that isn't ours: don't kill-first on it
      return real if LatestRelease.compare(version, CHECK_SINCE).negative?

      preflight(real, "sidebar", "--check", env: { RESUME_ENV => marker }) == :ok ? real : nil
    end

    # The file a respawn of `bin` execs, or nil. Unlike real_bin, no opt/ rewrite: tmux reruns
    # the pane's own command, so a keg path runs that keg even after an upgrade. Absolute only:
    # a relative one resolves against the pane's cwd and PATH, not ours.
    def start_file(bin)
      return nil unless bin.to_s.start_with?("/")

      File.realpath(bin)
    rescue SystemCallError
      nil
    end

    # "0.60.5" from `<bin> version`, or nil when it fails or prints anything else.
    def version_of(bin)
      Tempfile.create("sb-version") do |out|
        next nil unless preflight(bin, out: out) == :ok

        out.rewind
        out.read.to_s.scrub[VERSION_LINE, 1]
      end
    rescue SystemCallError
      nil
    end

    # [[:ok | :note, line], ...] for reload_all's counts; empty with no sidebars. A signaled
    # sidebar is only asked: it tests the new code itself, and records a failure for next time.
    def describe(counts)
      done = []
      done << "#{counts[:signaled]} asked to reload in place" if counts[:signaled].positive?
      done << "#{counts[:respawned]} restarted" if counts[:respawned].positive?
      lines = done.empty? ? [] : [[:ok, "sidebars: #{done.join(', ')}"]]
      if (left = counts[:left]).positive?
        lines << [:note, "#{left} sidebar#{'s' unless left == 1} left running old code: couldn't restart " \
                         "#{left == 1 ? 'it' : 'them'} safely (switchboard missing, won't start or just moved, or not a plain `switchboard sidebar`)"]
      end
      if (failed = counts.fetch(:failed, 0)).positive?
        lines << [:note, "#{failed} sidebar#{'s' unless failed == 1} failed to reload last time (asked again now) — " \
                         "`switchboard doctor` lists any still on old code"]
      end
      lines
    end

    # 0..SPREAD seconds (SWITCHBOARD_RELOAD_SPREAD overrides the bound).
    def spread_delay(rng = Random)
      bound = Float(ENV.fetch(SPREAD_ENV, SPREAD), exception: false) || SPREAD
      bound.positive? ? rng.rand * bound : 0.0
    end

    # Never raises and never exceeds what decode accepts: a name that isn't valid UTF-8 (git
    # branch names can be any bytes) is scrubbed, since JSON.generate would raise on it and the
    # whole fleet reloads at once; past PAYLOAD_MAX the baseline is dropped, keeping the cursor,
    # and so is announce: an empty notify cursor on an announcing first scan would re-ring
    # every alert.
    def encode(cursor: nil, offset: 0, hook_states: {}, notify: {}, announce: false)
      data = { "v" => VERSION, "cursor" => cursor&.transform_values { |v| v && utf8(v) }, "offset" => offset,
               "hook_states" => hook_states.to_h { |k, v| [utf8(k), v.to_s] },
               "notify" => notify.to_h { |k, t| [utf8(k), [t.to_i, t.nsec]] }, "announce" => announce }
      raw = JSON.generate(data)
      return raw if raw.bytesize <= PAYLOAD_MAX

      JSON.generate(data.merge("hook_states" => {}, "notify" => {}, "announce" => false))
    end

    def utf8(value)
      value.to_s.dup.force_encoding(Encoding::UTF_8).scrub
    end

    # A payload that was handed over but couldn't be read is still a reload, not a launch.
    BLANK = { cursor: nil, offset: 0, hook_states: {}, notify: {}, announce: false }.freeze

    # The payload as a symbol-keyed hash, or nil for anything not worth trusting (absent,
    # oversized, unparseable, an unknown version). Fields are filtered one by one, so a
    # bad entry drops only itself.
    def decode(raw)
      return nil if raw.nil? || raw.empty? || raw.bytesize > PAYLOAD_MAX

      data = JSON.parse(raw)
      return nil unless data.is_a?(Hash) && data["v"] == VERSION

      { cursor: cursor_from(data["cursor"]),
        offset: data["offset"].is_a?(Integer) && data["offset"] >= 0 ? data["offset"] : 0,
        hook_states: (data["hook_states"].is_a?(Hash) ? data["hook_states"] : {})
          .select { |k, v| k.is_a?(String) && STATES.include?(v) }.transform_values(&:to_sym),
        notify: (data["notify"].is_a?(Hash) ? data["notify"] : {})
          .filter_map { |k, v| [k, mtime_from(v)] if k.is_a?(String) && mtime_from(v) }.to_h,
        announce: data["announce"] == true }
    rescue JSON::ParserError, EncodingError
      nil
    end

    # Read and REMOVE the payload, so nothing this process spawns inherits it. nil only when
    # none was handed over (a launch); an unreadable one is BLANK, so a reload still skips the
    # clear and the launch-time prune.
    def take_resume(env = ENV)
      return nil unless env.key?(RESUME_ENV)

      decode(env.delete(RESUME_ENV)) || BLANK
    end

    def cursor_from(value)
      return nil unless value.is_a?(Hash)

      cursor = value.slice(*CURSOR_FIELDS)
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
  end
end
