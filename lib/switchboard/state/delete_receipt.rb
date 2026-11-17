# frozen_string_literal: true

require "json"
require_relative "../support/keyed_marker_store"

module Switchboard
  # One file per workspace being deleted: the delete's lock and its recovery record. It
  # names the workspace (path, realpath, project, repo, record and generation token), the
  # tmux server, its owner (pid + start time), the branch plan pinned at preflight, the
  # phase reached and the branches already deleted. Rewritten before each destructive
  # step, and removed only once every item is verified gone. No TTL: a dead owner's
  # receipt is taken over by the next delete, or finished by prune once git no longer
  # lists the path. Keyed by the realpath, which the receipt keeps because the folder
  # stops resolving once it's gone.
  module DeleteReceipt
    VERSION = 1
    PHASES = %w[claimed session_closed removed].freeze

    module_function

    def dir = KeyedMarkerStore.dir("SWITCHBOARD_DELETE_RECEIPTS_DIR", "delete-receipts")

    def key(real) = KeyedMarkerStore.key(real)

    def file(real) = File.join(dir, key(real))

    # Truthy once it's on disk.
    def write(receipt)
      KeyedMarkerStore.write(dir, key(receipt["real"]), JSON.dump(receipt.merge("v" => VERSION)))
    end

    def read(real)
      parse(File.read(file(real)))
    rescue StandardError
      nil
    end

    def all
      KeyedMarkerStore.entries(dir).filter_map { |_, content, _| parse(content) }
    end

    def parse(content)
      r = JSON.parse(content)
      r.is_a?(Hash) && r["real"].is_a?(String) && r["path"].is_a?(String) ? r : nil
    rescue JSON::ParserError
      nil
    end

    # True once no receipt is left for `real`.
    def delete(real)
      File.delete(file(real))
      true
    rescue Errno::ENOENT
      true
    rescue StandardError
      false
    end

    # Is the delete that wrote it still running? An unreadable start time can't prove the
    # owner gone; only a dead pid can.
    def owner_alive?(receipt)
      pid = receipt["owner_pid"]
      return false unless pid.is_a?(Integer) && pid.positive?
      return true if ProcessIdentity.same?(pid, receipt["owner_start"])

      (receipt["owner_start"].to_s.empty? || ProcessIdentity.start_of(pid).empty?) && ProcessIdentity.alive?(pid)
    end

    def owner(pid = Process.pid) = { "owner_pid" => pid, "owner_start" => ProcessIdentity.start_of(pid) }

    # A receipt with a live owner for this realpath: rename refuses while one exists.
    def live_for?(real)
      r = read(real)
      !r.nil? && owner_alive?(r)
    end
  end
end
