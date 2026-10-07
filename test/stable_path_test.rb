# frozen_string_literal: true

require_relative "test_helper"
require "rbconfig"

module Switchboard
  # A Homebrew keg path is versioned and deleted on upgrade+cleanup; everything
  # we bake into tmux/claude/codex wiring must use the opt/ twin instead.
  class StablePathTest < SandboxTest
    def test_a_clone_path_passes_through
      assert_equal "/Users/me/src/switchboard/bin/switchboard",
                   StablePath.resolve("/Users/me/src/switchboard/bin/switchboard")
      refute StablePath.homebrew?("/Users/me/src/switchboard")
    end

    def test_a_keg_path_maps_to_its_opt_twin
      prefix = brew_prefix
      keg = "#{prefix}/Cellar/switchboard/0.50.0"
      assert_equal "#{prefix}/opt/switchboard/libexec/bin/switchboard",
                   StablePath.resolve("#{keg}/libexec/bin/switchboard")
      assert_equal "#{prefix}/opt/switchboard", StablePath.resolve(keg)
      assert StablePath.homebrew?("#{keg}/libexec")
    end

    # No opt link (a half-installed or hand-copied keg) ⇒ keep the realpath
    # rather than bake a path that doesn't exist.
    def test_a_keg_without_an_opt_link_keeps_the_realpath
      keg = "#{path('brew')}/Cellar/switchboard/0.50.0/libexec"
      assert_equal keg, StablePath.resolve(keg)
      refute StablePath.homebrew?(keg)
    end

    # Another formula's keg is none of our business.
    def test_another_formulas_keg_passes_through
      prefix = brew_prefix
      other = "#{prefix}/Cellar/tmux/3.5/bin/tmux"
      assert_equal other, StablePath.resolve(other)
    end

    # End to end through the real installer.rb loaded from a fake keg: __dir__ is
    # the versioned realpath, but repo_root (→ fragment_path, the tmux.conf line)
    # and bin_path come out on the opt/ twin, and install knows it's brew-managed.
    def test_installer_loaded_from_a_keg_bakes_the_opt_path
      prefix = brew_prefix
      keg = "#{prefix}/Cellar/switchboard/0.50.0/libexec"
      FileUtils.mkdir_p(keg)
      FileUtils.cp_r(File.expand_path("../lib", __dir__), keg)
      script = 'require "switchboard"; i = Switchboard::Installer; puts i.repo_root, i.bin_path, i.homebrew?'
      out = IO.popen([RbConfig.ruby, "-I", "#{keg}/lib", "-e", script], err: File::NULL, &:read)
      assert_equal ["#{prefix}/opt/switchboard/libexec",
                    "#{prefix}/opt/switchboard/libexec/bin/switchboard",
                    "true"], out.lines.map(&:chomp)
    end

    # Value: protects=bin/switchboard's SWITCHBOARD_BIN (the bin baked into codex/claude hook
    # commands) staying on the opt/ twin under brew; fails_when=bin/switchboard reverts to the bare
    # File.realpath (keg path ⇒ every upgrade changes the hook bytes, voiding codex /hooks trust);
    # why_new=the keg test above loads lib only and the formula test checks repo_root, neither runs
    # bin/switchboard's own resolution; seam=none (real `install --codex-hooks` from a fake keg)
    def test_bin_run_from_a_keg_bakes_the_opt_path_into_codex_hooks
      prefix = brew_prefix
      keg = "#{prefix}/Cellar/switchboard/0.50.0/libexec"
      FileUtils.mkdir_p(keg)
      %w[bin lib switchboard.tmux].each { |f| FileUtils.cp_r(File.expand_path("../#{f}", __dir__), keg) }
      env = { "CODEX_HOME" => path("codex"), "SWITCHBOARD_BIN" => nil }
      IO.popen(env, [RbConfig.ruby, "#{keg}/bin/switchboard", "install", "--no-tmux", "--codex-hooks"],
               err: File::NULL, &:read)
      toml = File.read(File.join(path("codex"), "config.toml"))
      assert_includes toml, "#{prefix}/opt/switchboard/libexec/bin/switchboard"
      refute_includes toml, "Cellar"
    end

    private

    # A prefix whose opt/switchboard exists, like a linked brew install.
    def brew_prefix
      prefix = File.realpath(path("brew").tap { |p| FileUtils.mkdir_p(p) })
      FileUtils.mkdir_p("#{prefix}/opt/switchboard")
      prefix
    end
  end
end
