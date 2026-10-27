# frozen_string_literal: true

module Switchboard
  # A fake Homebrew prefix for the code-reload smoke tests (#48): <prefix>/Cellar/switchboard/<name>
  # are copies of this checkout and <prefix>/opt/switchboard links to one, so StablePath (whose
  # regex is prefix-agnostic) hands a sidebar started from it the opt path, exactly as under
  # brew. "Upgrading" is repointing that link; patching a keg's wordmark makes a reload visible.
  module FakeKeg
    MARK_B = "◖═◗ SwitchboarB"

    def keg(name)
      root = File.join(@prefix, "Cellar", "switchboard", name)
      FileUtils.mkdir_p(root)
      FileUtils.cp_r(File.join(SmokeCase::REPO, "bin"), root)
      FileUtils.cp_r(File.join(SmokeCase::REPO, "lib"), root)
      yield root if block_given?
      root
    end

    def patch_wordmark(root)
      render = File.join(root, "lib", "switchboard", "sidebar", "render.rb")
      File.write(render, File.read(render).sub(Sidebar::WORDMARK, MARK_B))
    end

    def point_opt_at(name)
      opt = File.join(@prefix, "opt", "switchboard")
      FileUtils.mkdir_p(File.dirname(opt))
      FileUtils.rm_f(opt)
      File.symlink(File.join(@prefix, "Cellar", "switchboard", name), opt)
    end

    def opt_bin
      File.join(@prefix, "opt", "switchboard", "bin", "switchboard")
    end
  end
end
