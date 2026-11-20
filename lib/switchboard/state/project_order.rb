# frozen_string_literal: true

require_relative "../support/keyed_marker_store"
require_relative "../support/marker_block"
require_relative "../support/paths"

module Switchboard
  # The order of the projects in the sidebar, once you've moved one with J/K: a view
  # preference, so it lives in its own file and a keypress never rewrites config.yml
  # (whose comments YAML.dump would strip). One project name per line, written whole and
  # atomically. Projects it doesn't name (one just added) follow in config order; a
  # missing or unreadable file means plain config order.
  module ProjectOrder
    module_function

    def names
      File.read(path, encoding: Encoding::UTF_8).lines(chomp: true).map(&:strip).reject(&:empty?).uniq
    rescue StandardError
      []
    end

    # Config project rows in display order.
    def sort(rows)
      at = names.each_with_index.to_h
      rows.each_with_index.sort_by { |row, i| [at.key?(name_of(row)) ? 0 : 1, at.fetch(name_of(row), 0), i] }.map(&:first)
    end

    # nil on success, or why the write failed.
    def write(list)
      MarkerBlock.atomic_write(path, list.reject { |n| n.to_s.include?("\n") }.map { |n| "#{n}\n" }.join, follow: false)
      nil
    rescue StandardError => e
      KeyedMarkerStore.reason(e)
    end

    def name_of(row) = row.is_a?(Hash) ? row["name"] : nil

    def path
      Paths.state("SWITCHBOARD_PROJECT_ORDER_FILE", "project_order")
    end
  end
end
