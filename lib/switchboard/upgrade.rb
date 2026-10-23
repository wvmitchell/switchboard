# frozen_string_literal: true

module Switchboard
  # `switchboard upgrade`: fetch the newest switchboard the way it was installed, then let
  # the NEW code finish the job (`upgrade --finish`) — what used to be
  # `brew update && brew upgrade switchboard` (or `git pull`) followed by `install`.
  #
  #   upgrade ─ behind? ─ no ─ leftovers? ─ no ─► "up to date"
  #     │                        └ yes ─► finish (this version)
  #     └ yes / couldn't tell ─► brew | git pull ─ moved? ─ no ─► "nothing newer yet" ─ leftovers? ─ yes ─► finish
  #                                                   └ yes ─► exec <bin> upgrade --finish <old>
  #
  # The install method is the channel: a Homebrew install follows releases, a `--HEAD`
  # one follows main, a clone follows whatever branch it tracks. The hand-off is an exec,
  # not a call, because this process has the OLD code loaded and only the new binary
  # knows what the new version wires.
  module Upgrade
    module_function

    FETCH_DEADLINE = Creator::FETCH_DEADLINE # a clone's up-to-date fetch gets a workspace build's budget

    def run(argv = [])
      return finish(argv[1]) if argv.first == "--finish"
      # An unknown argument (`--help`, `--dry-run`) must never fall through to a real upgrade.
      unless argv.empty?
        warn "usage: switchboard upgrade"
        return false
      end

      method = install_method
      puts "switchboard upgrade — #{VERSION} (#{describe(method)})"
      latest = LatestRelease.latest if method == :brew
      case behind?(method, latest)
      when false
        return finish(nil, leftovers: true) if leftovers?

        puts "switchboard #{VERSION} is up to date — run `switchboard doctor` if something seems off."
        return true
      when nil
        # A --HEAD install has no release to compare against; that's not a failed check.
        if method == :clone
          Installer.note "couldn't compare with your branch's upstream — trying `git pull`"
        elsif method == :brew
          Installer.note "couldn't check for a newer release — asking Homebrew"
        end
      end

      before = stamp(method)
      fetched = fetch(method) or return false
      if before && stamp(method) == before # unknown ⇒ hand off
        return update_blocked if fetched == :update_failed
        nothing_newer(method, latest)
        return leftovers? ? finish(nil, leftovers: true) : true
      end

      handoff
    end

    # --- install method ------------------------------------------------------

    def install_method
      return :clone unless Installer.homebrew?

      head_keg? ? :brew_head : :brew
    end

    def head_keg?
      Installer.real_root.match?(%r{/Cellar/switchboard/HEAD-})
    end

    def describe(method)
      { brew: "Homebrew", brew_head: "Homebrew, --HEAD", clone: "clone at #{Installer.repo_root}" }[method]
    end

    # true / false, or nil when it can't be told up front (offline, a HEAD install, a
    # branch with no upstream) — the fetch then decides.
    def behind?(method, latest)
      case method
      when :brew  then latest && LatestRelease.compare(latest, VERSION).positive?
      when :clone then clone_behind?
      end
    end

    def clone_behind?
      root = Installer.repo_root
      # Stalled ⇒ "couldn't compare", never a hang; BatchMode so an ssh passphrase prompt it
      # can't show (its own process group) fails at once instead of eating the deadline.
      # Only when nothing else picks the ssh: GIT_SSH_COMMAND outranks core.sshCommand, so
      # setting it over a configured one would drop the key or wrapper that clone needs.
      ssh_chosen = ENV["GIT_SSH_COMMAND"] || ENV["GIT_SSH"] || git_out(root, "config", "core.sshCommand")
      env = ssh_chosen ? {} : { "GIT_SSH_COMMAND" => "ssh -o BatchMode=yes" }
      return nil unless Git.fetch_base(root, nil, timeout: FETCH_DEADLINE, env: env)

      count = git_out(root, "rev-list", "--count", "HEAD..@{upstream}") or return nil
      count.to_i.positive?
    end

    # What changes when an upgrade lands: a Homebrew keg's realpath carries its version
    # (or HEAD-<sha>), a clone's HEAD its commit.
    def stamp(method)
      if method == :clone
        git_out(Installer.repo_root, "rev-parse", "HEAD")
      else
        File.realpath(Installer.bin_path)
      end
    rescue SystemCallError
      nil
    end

    # --- fetch ---------------------------------------------------------------

    def fetch(method)
      case method
      when :brew
        updated = brew_update
        step("brew", "upgrade", "switchboard") && (updated || :update_failed)
      when :brew_head then step("brew", "upgrade", "--fetch-HEAD", "switchboard")
      when :clone     then clone_pull
      end
    end

    # Fast-forward only, and never over local changes: a merge or a stash is the user's
    # call. Untracked files don't block the check; if an incoming file would overwrite one,
    # git refuses on its own and says which. An IGNORED file git overwrites by default, and
    # its contents were never committed, so the merge runs with --no-overwrite-ignore: git
    # itself then refuses (parent paths, symlinks and case-folding filesystems included).
    def clone_pull
      root = Installer.repo_root
      dirty = git_out(root, "status", "--porcelain", "--untracked-files=no")
      if dirty.nil?
        Installer.bad "couldn't read git status in #{root} — is it a git clone?"
        return false
      elsif !dirty.empty?
        Installer.bad "#{root} has uncommitted changes — commit or stash them, then re-run `switchboard upgrade`"
        return false
      end
      step("git", "-C", root, "fetch") &&
        step("git", "-C", root, "merge", "--no-overwrite-ignore", "--ff-only", "@{upstream}")
    end

    # `brew update` exits non-zero when ANY tap can't be fetched, though `brew upgrade` still
    # works and the keg stamp decides whether anything moved, so a failure is only a note.
    def brew_update
      puts "  $ brew update"
      return true if system("brew", "update")

      Installer.note "`brew update` failed (another tap?) — trying the upgrade anyway"
      false
    end

    # The update failed AND nothing moved: maybe switchboard's own tap couldn't be fetched,
    # so "Homebrew doesn't have it yet" would be wrong advice; say what actually failed.
    def update_blocked
      Installer.bad "`brew update` failed, so Homebrew may not have the newest switchboard — see its output above " \
                    "(an untrusted tap? `brew trust wvmitchell/switchboard`), then re-run `switchboard upgrade`"
      false
    end

    # Streams the command's own output (brew/git progress is the point).
    def step(*argv)
      puts "  $ #{argv.join(' ')}"
      return true if system(*argv)

      Installer.bad "`#{argv.join(' ')}` failed — see its output above, then re-run `switchboard upgrade`"
      false
    end

    def nothing_newer(method, latest)
      if method == :brew && latest
        puts "switchboard #{latest} is tagged, but Homebrew doesn't have it yet — try again in a few minutes."
      elsif method == :brew
        puts "Homebrew has nothing newer than #{VERSION}."
      else
        puts "switchboard #{VERSION} is already the newest #{method == :clone ? 'commit on your branch' : 'build of main'}."
      end
      true
    end

    def handoff
      # bin/switchboard's one-shot re-exec guard: left set, a new binary launched under system
      # Ruby 2.6 (a clone's `env ruby` shebang) would skip its own re-exec and fail to load.
      ENV.delete("SB_REEXEC")
      exec(Installer.bin_path, "upgrade", "--finish", VERSION)
    rescue SystemCallError => e
      Installer.bad "upgraded, but the new switchboard didn't start (#{e.message}) — re-run `switchboard upgrade` to finish"
      false
    end

    # --- finish (runs as the new version) ------------------------------------

    # Also reached from an up-to-date run whose wiring is stale — an earlier upgrade that
    # was interrupted before this step, or one done by hand without `install`.
    def finish(from, leftovers: false)
      if leftovers
        puts "switchboard #{VERSION}'s setup isn't current — finishing it:"
      else
        puts "switchboard upgrade — finishing #{from && from != VERSION ? "#{from} → #{VERSION}" : VERSION}"
      end
      hooks_ok = Installer.refresh_wiring
      codex_ok = refresh_codex
      tmux_ok = reload_tmux
      summary(from)
      hooks_ok && codex_ok && tmux_ok
    end

    # Re-ensure the global codex block only if the user already opted in — never prompt —
    # and only from the installed binary: its commands call back into whichever binary
    # wrote them, the same reason worktree hooks are refreshed only from it. A changed block
    # means changed command bytes, which codex re-asks trust for.
    def refresh_codex
      return true unless CodexHook.installed? && Installer.installed_bin?

      stale = CodexHook.block_state == :stale
      ok = Installer.report_codex_install(CodexHook.install_global, reensure: true, verb: "upgrade")
      Installer.note "codex's hook commands changed — run `/hooks` in codex once to trust them again" if ok && stale
      ok
    end

    def reload_tmux
      case Installer.reload_fragment
      when :unwired   then Installer.note "tmux: not wired to this install — skipped (`switchboard install` wires it)"
      when :no_server then Installer.note "tmux: no server running — the new bindings load when tmux starts"
      when true
        # The fragment's exit status is its last line's, so check that the bindings took.
        if tmux_stale?
          Installer.bad "tmux: reloaded, but switchboard's bindings still aren't live — run `tmux source-file <your tmux.conf>`"
          return false
        end
        Installer.ok "tmux: reloaded switchboard's bindings and hooks"
      else
        Installer.bad "tmux: couldn't reload — run `tmux source-file <your tmux.conf>`"
        return false
      end
      true
    end

    # Any hand-off means new code (a clone pull need not bump the version); only the
    # leftovers path, which loaded nothing new, skips the hint.
    def summary(from)
      return unless from

      loaded = from == VERSION ? "the code they started with" : from
      puts "\nRunning sidebars still have #{loaded} loaded: press prefix-#{Installer.bound_toggle_key} twice in each switchboard session to restart them."
    end

    # Cheap local checks for setup an upgrade should have done.
    def leftovers?
      ours = Installer.installed_bin? # only the installed binary may rewrite hooks or the reporter
      (ours && (reporter_stale? || !Installer.stale_worktrees.empty?)) ||
        tmux_stale? ||
        (ours && CodexHook.installed? && CodexHook.block_state == :stale)
    end

    # Another release's reporter, or none at all while something still runs it.
    def reporter_stale?
      case HookFile.script_state
      when :stale   then true
      when :missing then Installer.reporter_needed?
      else false
      end
    end

    # Only an install tmux.conf actually sources can be stale in the server (no server
    # running reads as not stale: the live probes return nil).
    def tmux_stale?
      return false unless Installer.fragment_wired_here?

      # tmux < 3.0 can't hold the indexed hook slots at all, so only the key can be stale there.
      slots_stale = Installer.tmux_version.to_f >= 3.0 && Installer.live_hooks&.value?(false)
      slots_stale || Installer.toggle_key_live?(Installer.bound_toggle_key) == false
    end

    def git_out(root, *args)
      out = IO.popen(["git", "-C", root, *args], err: File::NULL, &:read)
      $?.success? ? out.strip : nil
    rescue SystemCallError
      nil
    end
  end
end
