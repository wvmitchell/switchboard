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

    private

    # A prefix whose opt/switchboard exists, like a linked brew install.
    def brew_prefix
      prefix = File.realpath(path("brew").tap { |p| FileUtils.mkdir_p(p) })
      FileUtils.mkdir_p("#{prefix}/opt/switchboard")
      prefix
    end
  end
end
