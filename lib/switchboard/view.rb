# frozen_string_literal: true

module Switchboard
  # PR rendering for the sidebar tree. The narrow pane has no room for a state
  # word, so state is carried by color and the row shows just the identifier
  # (e.g. a green "#12" for an open PR).
  module View
    module_function

    PR_COLORS = { "OPEN" => 32, "DRAFT" => 33, "MERGED" => 35, "CLOSED" => 31 }.freeze

    # The bare identifier ("#12"), or "" when there's no PR. Used for width math
    # before color is applied, so the sidebar can right-align it. Guards on Hash
    # (not just nil): a corrupt cache row must not raise in the paint loop.
    def pr_identifier(pr)
      return "" unless pr.is_a?(Hash)

      (pr["identifier"] || "#?").to_s
    end

    # The identifier colored by PR state, or "" when there's no PR.
    def pr_tag(pr)
      id = pr_identifier(pr)
      return "" if id.empty?

      color = PR_COLORS.fetch(pr_state(pr), 37)
      "\e[#{color}m#{id}\e[0m"
    end

    def pr_state(pr)
      pr["is_draft"].to_i == 1 ? "DRAFT" : pr["status"].to_s.upcase
    end
  end
end
