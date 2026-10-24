# frozen_string_literal: true

require "tempfile"
require "tmpdir"
require_relative "process_identity"

module Switchboard
  # The newest released version, read from the release tags on GitHub — what `upgrade`
  # and `doctor` compare the running VERSION against. A plain `git ls-remote` (the repo is
  # public, so no auth and no gh), bounded like Git.fetch_base: offline or stalled, it's
  # killed at the deadline and reads as "couldn't check" (nil), never a hang.
  module LatestRelease
    module_function

    URL = "https://github.com/wvmitchell/switchboard"
    DEADLINE = 5 # seconds; ~6x a measured lookup, short enough that doctor never feels hung
    TAG = %r{\trefs/tags/v(\d+\.\d+\.\d+)\z}

    # "0.51.1", or nil when the tags couldn't be read in time.
    def latest(url: source, timeout: DEADLINE)
      raw = ls_remote_tags(url, timeout) or return nil
      highest(raw)
    end

    # SWITCHBOARD_RELEASES_URL points the lookup elsewhere (the test suite: nowhere).
    def source
      ENV["SWITCHBOARD_RELEASES_URL"] || URL
    end

    # Pure: the highest vX.Y.Z tag in `git ls-remote --tags --refs` output. Anything else
    # (a pre-release, a stray tag name) is ignored, so no tag text reaches the caller.
    def highest(raw)
      raw.to_s.scrub.each_line.filter_map { |line| line.chomp[TAG, 1] }.max_by { |v| parts(v) } # a ref may hold any bytes
    end

    # <0, 0 or >0, like <=>.
    def compare(a, b)
      parts(a) <=> parts(b)
    end

    def parts(version)
      version.to_s.split(".").map(&:to_i)
    end

    # The lookup is anonymous HTTPS to a public repo, so the user's git config stays out of
    # it: an `insteadOf` rewriting github.com to ssh would otherwise stall every lookup on a
    # key prompt until the deadline. BatchMode only matters for an ssh SWITCHBOARD_RELEASES_URL.
    def lookup_env
      { "GIT_TERMINAL_PROMPT" => "0", "GIT_CONFIG_GLOBAL" => File::NULL, "GIT_CONFIG_NOSYSTEM" => "1",
        "GIT_SSH_COMMAND" => ENV["GIT_SSH_COMMAND"] || "ssh -o BatchMode=yes" }
    end

    # Output goes to a temp file, not a pipe: a pipe could fill and stall git before we
    # read it, which the deadline would then misreport as "offline".
    def ls_remote_tags(url, timeout)
      Tempfile.create("sb-tags") do |out|
        pid = Process.spawn(lookup_env, "git", "ls-remote", "--tags", "--refs", url,
                            in: File::NULL, out: out, err: File::NULL, pgroup: true,
                            chdir: Dir.tmpdir) # no repo's own config either
        status = ProcessIdentity.wait_within(pid, timeout)
        unless status
          ProcessIdentity.terminate_group(pid) # git and its ssh/credential helpers
          return nil
        end
        status.success? ? File.read(out.path) : nil
      end
    rescue SystemCallError
      nil
    end
  end
end
