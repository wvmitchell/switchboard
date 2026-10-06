# Homebrew formula for switchboard. The source of truth lives here; a release
# copies it into the wvmitchell/homebrew-switchboard tap with url + sha256 filled in.
class Switchboard < Formula
  desc "Keyboard-only tmux switcher/creator for git-worktree workspaces"
  homepage "https://github.com/wvmitchell/switchboard"
  url "https://github.com/wvmitchell/switchboard/archive/refs/tags/v0.49.1.tar.gz"
  sha256 "REPLACE_WITH_RELEASE_TARBALL_SHA256"
  license "MIT"
  head "https://github.com/wvmitchell/switchboard.git", branch: "main"

  depends_on "gh"
  depends_on "git"
  depends_on "ruby" # macOS system Ruby is 2.6; switchboard needs >= 3.0
  depends_on "tmux"

  def install
    # Pin the interpreter: tmux panes run a non-interactive shell where
    # `env ruby` can resolve to system Ruby.
    inreplace "bin/switchboard", %r{\A#!/usr/bin/env ruby}, "#!#{formula_opt_bin("ruby")}/ruby"
    libexec.install "bin", "lib", "switchboard.tmux"
    bin.install_symlink libexec/"bin/switchboard"
    bin.install_symlink libexec/"bin/switchboard" => "sb"
  end

  def caveats
    <<~EOS
      Wire switchboard into tmux (adds one line to your tmux.conf and writes
      an empty config at ~/.config/switchboard/config.yml):
        switchboard install

      Then run `switchboard` (or `sb`) from any shell. `switchboard doctor`
      checks the setup.
    EOS
  end

  test do
    assert_match "switchboard #{version}", shell_output("#{bin}/switchboard --version")

    # Wiring must bake the upgrade-proof opt/ path, never the versioned keg.
    ENV["SWITCHBOARD_CONFIG"] = testpath/"config.yml"
    out = shell_output("#{bin}/switchboard install --print-tmux --no-codex-hooks")
    assert_match "#{opt_libexec}/switchboard.tmux", out
    refute_match "Cellar", out
  end
end
