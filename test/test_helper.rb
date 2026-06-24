# frozen_string_literal: true

# Zero-dependency test harness: Minitest ships with Ruby, so the suite honors
# switchboard's "stdlib only, no Gemfile" rule. Run a file directly
# (`ruby -Itest test/installer_test.rb`) or the whole suite via `bin/test`
# (which wraps `ruby -Itest -e 'Dir["test/*_test.rb"]...'`).
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "yaml"
require "shellwords"
require "stringio"

require_relative "../lib/switchboard"

class Minitest::Test
  # Temporarily swap one method on a module/object for the block, then restore —
  # a version-proof stand-in for minitest/mock's stub (not loadable in every
  # bundled minitest). Used to fake a single shell-out seam, e.g. Git.branch_history.
  def stub_method(receiver, name, impl)
    original = receiver.method(name)
    receiver.define_singleton_method(name, impl)
    yield
  ensure
    receiver.define_singleton_method(name, original)
  end

  # Swap $stdin for the block (restored after) so a test can drive the sidebar's
  # raw-mode read_key against a controllable IO — e.g. a closed pipe to hit EOF.
  def with_stdin(io)
    original = $stdin
    $stdin = io
    yield
  ensure
    $stdin = original
  end
end

module Switchboard
  # Isolates every test from real state. A fresh tmpdir plus a wall of env
  # overrides so NOTHING reads or writes outside the sandbox: the config, the
  # symlink dir, the agent-state + PR-cache dirs, the XDG roots Hook materializes
  # its reporter into, the git global/system config, HOME, and gh's config dir.
  # TMUX is unset AND tmux's socket dir is redirected into the sandbox, so no
  # test pokes a live tmux server. Everything is restored on teardown by
  # replacing ENV wholesale.
  class SandboxTest < Minitest::Test
    def setup
      @dir = Dir.mktmpdir("switchboard-test")
      @env = ENV.to_h

      # switchboard's own knobs
      ENV["SWITCHBOARD_CONFIG"]    = path("config.yml")
      ENV["SWITCHBOARD_BIN_DIR"]   = path("bin")
      ENV["SWITCHBOARD_STATE_DIR"]     = path("state")     # AgentState (T3 seam)
      ENV["SWITCHBOARD_ATTENTION_DIR"] = path("attention") # Attention markers (bold-until-viewed)
      ENV["SWITCHBOARD_COLLAPSE_DIR"]  = path("collapse")  # Collapse folds (shared project collapse state)
      ENV["SWITCHBOARD_CACHE_DIR"]     = path("cache")     # Pr cache (T3 seam)

      # Anything that reads $HOME / XDG / git-global must land in the sandbox —
      # Hook.ensure_script writes a reporter into XDG_DATA_HOME, Creator shells
      # git, etc. Without this, "no real state touched" would be a lie.
      ENV["HOME"]              = @dir
      ENV["XDG_DATA_HOME"]     = path("xdg-data")
      ENV["XDG_STATE_HOME"]    = path("xdg-state")
      ENV["XDG_CONFIG_HOME"]   = path("xdg-config")
      ENV["XDG_CACHE_HOME"]    = path("xdg-cache")
      ENV["GIT_CONFIG_GLOBAL"] = path("gitconfig") # need not exist; isolates host global
      ENV["GIT_CONFIG_SYSTEM"] = File::NULL        # ignore /etc/gitconfig
      ENV["GH_CONFIG_DIR"]     = path("gh")
      ENV.delete("GH_TOKEN")
      ENV.delete("TMUX")
      # Unsetting TMUX only stops a test from looking like it's INSIDE a server;
      # a fresh `tmux` shell-out still talks to the default socket. Point that
      # socket dir at the empty sandbox so even the deliberately-ungated server
      # ops (uninstall's teardown_live runs `tmux unbind-key`/`set-hook -gu`
      # without the TMUX gate, by design) can't reach — let alone clobber — the
      # developer's real tmux. No server lives here, so those calls just no-op.
      ENV["TMUX_TMPDIR"] = @dir
    end

    def teardown
      ENV.replace(@env) if @env # guard: setup may have raised before @env was set
      FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
    end

    def path(*parts)
      File.join(@dir, *parts)
    end

    # A throwaway git repo under the sandbox, deterministic and hermetic so tests
    # never depend on the host's git defaults: a fixed `main` initial branch (not
    # the runner's init.defaultBranch), a seeded commit, and local identity (the
    # global config is isolated to an empty file). With `origin:`, also wires an
    # origin remote backed by a bare clone AND sets refs/remotes/origin/HEAD, so
    # Git.remote_head / Registrar see a real default-branch symref. With
    # `object_format:` (e.g. "sha256"), passes it through to `git init` — the
    # `git` helper raises if the local build lacks the format, so callers can
    # rescue to `skip`. Returns the path.
    def temp_git_repo(name = "repo", origin: false, object_format: nil)
      repo = path(name)
      FileUtils.mkdir_p(repo)
      init = ["init", "-q", "-b", "main"]
      init << "--object-format=#{object_format}" if object_format
      git(repo, *init)
      git(repo, "config", "user.email", "test@example.com")
      git(repo, "config", "user.name", "Switchboard Test")
      File.write(File.join(repo, "README.md"), "seed\n")
      git(repo, "add", "-A")
      git(repo, "commit", "-q", "-m", "init")
      wire_origin(repo) if origin
      repo
    end

    # Run git (under `dir` when given), raising with output on failure so a
    # broken fixture fails loudly instead of producing a silently-empty repo.
    def git(dir, *args)
      full = (dir ? ["-C", dir] : []) + args
      out = `git #{full.map { |a| Shellwords.escape(a) }.join(' ')} 2>&1`
      raise "git #{args.join(' ')} failed: #{out}" unless $?.success?

      out
    end

    private

    def wire_origin(repo)
      bare = "#{repo}.git"
      git(nil, "clone", "-q", "--bare", repo, bare)
      git(repo, "remote", "add", "origin", bare)
      git(repo, "fetch", "-q", "origin")
      git(bare, "symbolic-ref", "HEAD", "refs/heads/main")
      git(repo, "remote", "set-head", "origin", "main") # creates refs/remotes/origin/HEAD
    end
  end
end
