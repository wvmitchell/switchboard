# frozen_string_literal: true

require "fileutils"
require "shellwords"

module Switchboard
  # Stands switchboard up from a fresh clone: a `switchboard` symlink on PATH, a
  # tmux.conf line that sources the self-locating `switchboard.tmux` fragment, and
  # an empty config — all idempotent and reversible by `uninstall`. Every step is
  # best-effort and prints its own status; one failing step never aborts the rest
  # (same degrade-gracefully posture as the rest of the codebase).
  #
  #   install ──┬─ symlink  ~/.local/bin/switchboard → <repo>/bin/switchboard
  #             ├─ tmux     marker block ⇒ run-shell '<repo>/switchboard.tmux'
  #             └─ init     Config.scaffold (empty config if none)
  #
  # The marker block carries the repo path, so a moved clone is healed by simply
  # re-running install (symlink repoints even when dangling; the block is rewritten
  # in place). Paths are escaped for the shell layer (Shellwords) and wrapped in
  # tmux single quotes so the eventual /bin/sh sees a correctly-quoted command —
  # verified against tmux for clone paths containing spaces.
  module Installer
    module_function

    BEGIN_MARK = "# >>> switchboard install >>>"
    NOTE_MARK  = "# managed by `switchboard install` — edits between the markers are overwritten"
    END_MARK   = "# <<< switchboard install <<<"

    # --- paths ---------------------------------------------------------------

    # Repo root from this file (lib/switchboard/installer.rb → ../..). Works
    # through a PATH symlink: require resolves to the real file, so __dir__ is
    # the real lib dir.
    def repo_root
      File.expand_path("../..", __dir__)
    end

    def bin_path
      File.join(repo_root, "bin", "switchboard")
    end

    def fragment_path
      File.join(repo_root, "switchboard.tmux")
    end

    def bin_dir
      File.expand_path(ENV["SWITCHBOARD_BIN_DIR"] || "~/.local/bin")
    end

    def symlink_path
      File.join(bin_dir, "switchboard")
    end

    # The single tmux.conf line that sources the fragment. Single tmux quotes
    # around the shell-escaped path: tmux passes it through verbatim and /bin/sh
    # then de-escapes, so spaces in the repo path survive both layers.
    def marker_line
      "run-shell '#{Shellwords.escape(fragment_path)}'"
    end

    # A quote in the repo path can't be nested safely in the two quoting contexts
    # we emit: a single quote closes the marker line's tmux '...' early, a double
    # quote closes the fragment's run-shell "'$BIN' ..." early, and a newline or
    # control char turns the marker line into multi-line garbage. All are
    # pathological in a real clone path; refuse rather than write a broken line.
    def tmux_safe_path?
      !fragment_path.match?(/['"\x00-\x1f]/)
    end

    # --- install -------------------------------------------------------------

    def install(no_tmux: false, print_tmux: false, conf: nil)
      puts "switchboard install"
      step_symlink
      wire_tmux(no_tmux: no_tmux, print_tmux: print_tmux, conf: conf)
      step_init
      warn_path
      warn_tmux_version
      puts "\nDone — press prefix-s to toggle the sidebar."
      puts "(If the key doesn't respond yet, reload tmux: `tmux source-file <your conf>`.)"
    end

    def step_symlink
      FileUtils.mkdir_p(bin_dir)
      if File.symlink?(symlink_path)
        return ok("symlink already points here: #{symlink_path}") if File.identical?(symlink_path, bin_path)
        return bad("left a foreign symlink at #{symlink_path} (points elsewhere) — remove it and re-run") unless ours_symlink?(symlink_path)

        File.delete(symlink_path) # ours but stale (e.g. repo moved) → repoint
      elsif File.exist?(symlink_path)
        return bad("#{symlink_path} already exists and isn't ours — leaving it untouched")
      end
      File.symlink(bin_path, symlink_path)
      ok "symlink: #{symlink_path} → #{bin_path}"
    rescue StandardError => e
      bad "symlink: #{e.message}"
    end

    # All three tmux paths (write / print / skip) sit behind the path-safety
    # guard, so a quote/control char in the repo path never produces a broken
    # marker line anywhere — not just on the automatic write.
    def wire_tmux(no_tmux:, print_tmux:, conf:)
      return bad("tmux: not wired — the repo path contains a quote or control character that can't be safely quoted in a tmux.conf line. Move the clone to a path without it.") unless tmux_safe_path?

      if print_tmux
        note "tmux: add this to your tmux.conf (then reload):"
        puts "      #{marker_line}"
      elsif no_tmux
        note "tmux: skipped (--no-tmux) — add `#{marker_line}` yourself to wire the keys"
      else
        step_tmux(conf)
      end
    end

    def step_tmux(conf_override)
      conf = tmux_conf(conf_override)
      prev = prefix_binding("s")
      body = File.exist?(conf) ? File.read(conf) : ""
      backup(conf) if File.exist?(conf)
      atomic_write(conf, with_block(strip_block(body)))
      reload(conf)
      ok "tmux: wired in #{conf}"
      note "prefix-s now toggles the sidebar (was: #{prev})" if prev && !prev.include?("switchboard")
    rescue StandardError => e
      bad "tmux: #{e.message}"
    end

    def step_init
      if Config.exist?
        note "config: #{Config.path} (exists — left as-is)"
      else
        Config.scaffold
        ok "config: wrote #{Config.path}"
      end
    end

    # --- uninstall -----------------------------------------------------------

    def uninstall(conf: nil)
      puts "switchboard uninstall"
      unlink_symlink
      unwire_tmux(conf)
      teardown_live
      puts "\nDone. Your config (#{Config.path}) and agent state were left untouched."
    end

    def unlink_symlink
      if File.symlink?(symlink_path) && ours_symlink?(symlink_path)
        File.delete(symlink_path)
        ok "removed symlink: #{symlink_path}"
      elsif File.symlink?(symlink_path)
        note "left foreign symlink at #{symlink_path} (not ours)"
      else
        note "no symlink at #{symlink_path}"
      end
    rescue StandardError => e
      bad "symlink: #{e.message}"
    end

    def unwire_tmux(conf_override)
      conf = tmux_conf(conf_override)
      if File.exist?(conf) && File.read(conf).include?(BEGIN_MARK)
        backup(conf)
        atomic_write(conf, strip_block(File.read(conf)))
        reload(conf)
        ok "removed tmux block from #{conf}"
      else
        note "no switchboard block in #{conf}"
      end
    rescue StandardError => e
      bad "tmux: #{e.message}"
    end

    # source-file re-runs the (now clean) config but doesn't drop a binding/hook
    # already live in the server — undo those explicitly when we're inside tmux.
    def teardown_live
      return unless ENV["TMUX"]

      system("tmux", "unbind-key", "s", out: File::NULL, err: File::NULL)
      system("tmux", "set-hook", "-gu", "client-session-changed[99]", out: File::NULL, err: File::NULL)
    end

    # --- doctor support (read-only predicates; cli renders the rows) ----------

    def linked?
      File.symlink?(symlink_path) && File.exist?(symlink_path) && File.identical?(symlink_path, bin_path)
    rescue StandardError
      false
    end

    def tmux_wired?(conf = nil)
      c = tmux_conf(conf)
      File.exist?(c) && File.read(c).include?(BEGIN_MARK)
    rescue StandardError
      false
    end

    # Major.minor as a Float (e.g. "3.6a" → 3.6); nil if tmux is absent.
    def tmux_version
      parse_version(`tmux -V 2>/dev/null`)
    end

    # Pull major.minor out of a `tmux -V` string as a Float, or nil. Split out
    # from the shell-out so it's unit-testable without tmux.
    def parse_version(str)
      v = str.to_s[/(\d+\.\d+)/, 1]
      v&.to_f
    end

    # --- internals -----------------------------------------------------------

    # A symlink at our PATH spot is "ours" if it resolves into this repo, or if
    # it dangles (the repo moved out from under it) — both are safe to repoint.
    # A real file, or a symlink into another live tree, is foreign.
    def ours_symlink?(link)
      return false unless File.symlink?(link)

      target = File.absolute_path(File.readlink(link), File.dirname(link))
      !File.exist?(target) || File.identical?(target, bin_path)
    rescue StandardError
      false
    end

    def with_block(body)
      body += "\n" unless body.empty? || body.end_with?("\n")
      "#{body}#{BEGIN_MARK}\n#{NOTE_MARK}\n#{marker_line}\n#{END_MARK}\n"
    end

    def strip_block(body)
      body.gsub(/^#{Regexp.escape(BEGIN_MARK)}\n.*?^#{Regexp.escape(END_MARK)}\n?/m, "")
    end

    # First-write-only backup: never overwrite a known-good .bak on a re-run.
    def backup(conf)
      bak = "#{conf}.bak"
      FileUtils.cp(conf, bak) unless File.exist?(bak)
    end

    # Write via temp-file + rename so the user's tmux.conf update is atomic: a
    # crash or ENOSPC mid-write leaves the old file intact, never a truncated
    # one (and never a half-written marker block). Rename is atomic within a dir.
    def atomic_write(path, content)
      tmp = "#{path}.#{Process.pid}.sb-tmp"
      File.write(tmp, content)
      File.rename(tmp, path)
    end

    def reload(conf)
      system("tmux", "source-file", conf, out: File::NULL, err: File::NULL) if ENV["TMUX"]
    end

    # The tmux.conf to edit: an explicit override, else the first $HOME-rooted
    # file tmux actually loaded (asked of the running server — skips system
    # files like /opt/homebrew/etc/tmux.conf), else the conventional fallback.
    def tmux_conf(override = nil)
      return File.expand_path(override) if override && !override.to_s.empty?

      loaded_user_conf ||
        [File.expand_path("~/.tmux.conf"), File.expand_path("~/.config/tmux/tmux.conf")].find { |p| File.exist?(p) } ||
        File.expand_path("~/.tmux.conf")
    end

    def loaded_user_conf
      return nil unless ENV["TMUX"]

      home = File.expand_path("~")
      `tmux display-message -p '#\{config_files}' 2>/dev/null`.strip
        .split(",").map(&:strip)
        .find { |f| f.start_with?(home) && File.exist?(f) }
    end

    # What prefix-<key> is currently bound to (for the "we're taking it" note), or
    # nil. Best-effort: only meaningful inside a running server.
    def prefix_binding(key)
      return nil unless ENV["TMUX"]

      `tmux list-keys -T prefix 2>/dev/null`.lines.each do |line|
        m = line.match(/-T\s+prefix\s+(\S+)\s+(.*)\z/)
        return m[2].strip if m && m[1] == key
      end
      nil
    end

    def warn_path
      return if ENV["PATH"].to_s.split(File::PATH_SEPARATOR).map { |p| File.expand_path(p) }.include?(bin_dir)

      note "#{bin_dir} isn't on your PATH — add this to your shell profile:"
      puts "      export PATH=\"#{bin_dir}:$PATH\""
    end

    # Popup is gone, so there's no hard floor; indexed session hooks want >= 3.0.
    def warn_tmux_version
      v = tmux_version
      return if v.nil? || v >= 3.0

      note "tmux #{v} is old — the session-switch sidebar refresh needs tmux >= 3.0 (toggle still works)"
    end

    def ok(msg)
      puts "  \e[32m✓\e[0m #{msg}"
    end

    def bad(msg)
      puts "  \e[31m✗\e[0m #{msg}"
    end

    def note(msg)
      puts "  \e[33m–\e[0m #{msg}"
    end
  end
end
