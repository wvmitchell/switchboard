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
      return "" unless pr.is_a?(Hash)

      pr["is_draft"].to_i == 1 ? "DRAFT" : pr["status"].to_s.upcase
    end

    # Diff-count badge (issue #79). Additions green, deletions red — the universal
    # convention, and already switchboard's palette (green = done/open, red =
    # closed); the +/− signs keep it distinct from those meanings.
    DIFF_COLORS = { add: 32, del: 31 }.freeze

    # The plain "+22 −333" badge (for width math), or "" when there's nothing to
    # show — no counts, or a clean 0/0 branch. Counts ≥ 1000 abbreviate (1.5k /
    # 12k) so a huge diff can't swallow the name in the narrow pane.
    def diff_label(counts)
      diff_parts(counts).compact.join(" ")
    end

    # The same badge, colored. "" exactly when diff_label is "".
    def diff_tag(counts)
      adds, dels = diff_parts(counts)
      [colorize(adds, DIFF_COLORS[:add]), colorize(dels, DIFF_COLORS[:del])].compact.join(" ")
    end

    # ["+22", "−333"], each nil when that side is zero. Guards on Array so a
    # malformed cache entry can't raise in the paint loop.
    def diff_parts(counts)
      return [nil, nil] unless counts.is_a?(Array)

      adds, dels = counts
      [("+#{abbrev(adds)}" if adds.to_i.positive?), ("−#{abbrev(dels)}" if dels.to_i.positive?)]
    end

    # Compact a count for the narrow pane: exact below 1000, else "1.5k" (one
    # decimal under 10k) or "12k" (whole thereafter).
    def abbrev(num)
      num = num.to_i
      return num.to_s if num < 1000

      thousands = num / 1000.0
      thousands >= 10 ? "#{thousands.round}k" : "#{num / 100 / 10.0}k".sub(".0k", "k")
    end

    def colorize(part, color)
      part && "\e[#{color}m#{part}\e[0m"
    end
  end
end
