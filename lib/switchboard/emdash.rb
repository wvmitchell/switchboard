# frozen_string_literal: true

require "json"
require "shellwords"

module Switchboard
  # Read-only reader over emdash's SQLite store. Enrichment only — never writes.
  # Shells out to the sqlite3 CLI so we carry no gem dependencies.
  class Emdash
    DB_GLOB = File.expand_path("~/Library/Application Support/emdash/emdash*.db")

    # Newest emdashN.db, skipping the -wal/-shm sidecars.
    def self.db_path
      Dir.glob(DB_GLOB).reject { |p| p.end_with?("-wal", "-shm") }.max
    end

    def initialize(db = self.class.db_path)
      @db = db
    end

    def available?
      !@db.nil? && File.exist?(@db)
    end

    def projects
      query("SELECT id, name, path, base_ref FROM projects ORDER BY name")
    end

    # Friendly workspace name keyed by full branch (tasks.task_branch).
    def task_names
      @task_names ||= tasks.each_with_object({}) { |r, h| h[r["task_branch"]] = r["name"] }
    end

    # Friendly name keyed by the branch's last segment — recovers the name even
    # when a worktree's HEAD has drifted off the branch emdash recorded.
    def task_by_leaf
      @task_by_leaf ||= tasks.each_with_object({}) { |r, h| h[r["task_branch"].split("/").last] = r["name"] }
    end

    # Open PRs etc. keyed by head branch.
    def prs
      @prs ||= query("SELECT identifier, status, is_draft, head_ref_name FROM pull_requests")
               .each_with_object({}) { |r, h| h[r["head_ref_name"]] = r }
    end

    private

    def tasks
      @tasks ||= query("SELECT name, task_branch FROM tasks WHERE task_branch IS NOT NULL")
    end

    def query(sql)
      return [] unless available?

      out = `sqlite3 -readonly -json #{Shellwords.escape(@db)} #{Shellwords.escape(sql)} 2>/dev/null`
      out.strip.empty? ? [] : JSON.parse(out)
    rescue JSON::ParserError
      []
    end
  end
end
