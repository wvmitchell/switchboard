# frozen_string_literal: true

require "json"
require "fileutils"
require "shellwords"

module Switchboard
  # PR badges sourced from `gh` and cached on disk, so the sidebar never blocks
  # on the network. The sidebar reads the cache (instant); `switchboard refresh`
  # re-fetches. Replaces reading emdash's pull_requests table.
  module Pr
    CACHE_DIR = File.expand_path("~/.cache/switchboard/prs")

    module_function

    # Cached PRs keyed by head branch — never hits the network.
    def for_project(name)
      cache = cache_file(name)
      return {} unless File.exist?(cache)

      JSON.parse(File.read(cache))
    rescue JSON::ParserError
      {}
    end

    # Fetch from gh and rewrite the cache. Returns the fresh map.
    def refresh(name, repo_path)
      data = fetch(repo_path)
      FileUtils.mkdir_p(CACHE_DIR)
      File.write(cache_file(name), JSON.dump(data))
      data
    end

    def fetch(repo_path)
      repo = repo_slug(repo_path)
      return {} unless repo

      out = `gh pr list -R #{Shellwords.escape(repo)} --state all --limit 200 \
             --json number,state,isDraft,headRefName 2>/dev/null`
      return {} if out.strip.empty?

      JSON.parse(out).each_with_object({}) do |pr, acc|
        acc[pr["headRefName"]] = {
          "identifier" => "##{pr['number']}",
          "status" => pr["state"],
          "is_draft" => pr["isDraft"] ? 1 : 0
        }
      end
    rescue JSON::ParserError
      {}
    end

    # owner/repo from the origin remote (git@github.com:o/r.git or https://…).
    def repo_slug(repo_path)
      url = `git -C #{Shellwords.escape(repo_path)} remote get-url origin 2>/dev/null`.strip
      return nil if url.empty?

      m = url.match(%r{[:/]([^/]+/[^/]+?)(?:\.git)?\z})
      m && m[1]
    end

    def cache_file(name)
      File.join(CACHE_DIR, "#{name.gsub(/[^\w.-]/, '_')}.json")
    end
  end
end
