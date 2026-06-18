# frozen_string_literal: true

module Switchboard
  # Renders the fzf list lines and the preview pane. All ANSI, no mouse.
  module View
    module_function

    DOT_DIRTY = "\e[33m●\e[0m" # yellow filled — uncommitted changes
    DOT_CLEAN = "\e[32m○\e[0m" # green hollow — clean

    PR_COLORS = { "OPEN" => 32, "DRAFT" => 33, "MERGED" => 35, "CLOSED" => 31 }.freeze

    # Rows are "<visible>\t<path>\t<branch>\t<kind>\t<project>". fzf displays
    # field 1 and searches fields 1+5 (so cross-project fuzzy search still
    # works under nesting). kind = "proj" | "ws" | "br".

    # Level 1: project header.
    def project_row(project)
      row("\e[1m▾ #{project.name}\e[0m", project.path, "", "proj", project.name)
    end

    # Level 2: a workspace nested under its project.
    def workspace_row(worktree)
      dot = worktree.dirty ? DOT_DIRTY : DOT_CLEAN
      visible = format("  %s %-40s %s", dot, truncate(worktree.display_name, 40), pr_badge(worktree.pr))
      row(visible, worktree.path, worktree.branch, "ws", worktree.project)
    end

    # Level 3: a branch nested under its workspace; the active branch (current
    # HEAD) gets a cyan dot.
    def branch_row(path, branch, pr, project:, active:, last:)
      glyph = last ? "└" : "├"
      marker = active ? "\e[36m●\e[0m" : " "
      visible = format("      %s %s %-34s %s", glyph, marker, truncate(branch, 34), pr_badge(pr))
      row(visible, path, branch, "br", project)
    end

    # A tab/newline in a display name (emdash names are free-form) would shift
    # the hidden \t-delimited fields and switch to the wrong worktree, so scrub
    # control chars from the visible column.
    def row(visible, path, branch, kind, project)
      "#{visible.tr("\t\n\r", ' ')}\t#{path}\t#{branch}\t#{kind}\t#{project}"
    end

    def preview(worktree, model)
      ahead, behind = Git.ahead_behind(worktree.path, worktree.base)
      short = Git.shortstat(worktree.path, worktree.base)

      out = +""
      out << "#{bold(worktree.project)}  ›  #{bold(worktree.display_name)}\n\n"
      out << field("branch", worktree.branch)
      out << field("base", blank(worktree.base) ? "(none)" : worktree.base)
      out << field("status", format("↑%d ↓%d   %s", ahead, behind, short.empty? ? "no diff vs base" : short))
      out << field("PR", pr_badge(worktree.pr))

      out << "\n#{bold('branches in this workspace')}\n"
      branches_in(worktree).each do |branch|
        marker = branch == worktree.branch ? "\e[36m●\e[0m" : " "
        out << format("  %s %-40s %s\n", marker, truncate(branch, 40), pr_badge(model.pr_for(branch)))
      end

      out << "\n#{bold('diff --stat')}\n"
      out << Git.diffstat(worktree.path, worktree.base)
      out
    end

    def project_preview(project)
      workspaces = project.worktrees.reject(&:primary)
      out = +""
      out << "#{bold(project.name)}\n\n"
      out << field("path", project.path)
      out << field("base", blank(project.base_ref) ? "(none)" : project.base_ref)
      out << "\n#{bold('workspaces')} (#{workspaces.size})\n"
      workspaces.each do |w|
        out << format("  %s %-36s %s\n", w.dirty ? DOT_DIRTY : DOT_CLEAN,
                      truncate(w.display_name, 36), pr_badge(w.pr))
      end
      out
    end

    def branch_preview(worktree, branch, model)
      out = +""
      out << "#{bold(branch)}\n\n"
      out << field("PR", pr_badge(model.pr_for(branch)))
      out << field("base", blank(worktree.base) ? "(none)" : worktree.base)
      out << "\n#{bold('diff --stat vs base')}\n"
      out << Git.diffstat_ref(worktree.path, worktree.base, branch)
      out
    end

    def pr_badge(pr)
      return "\e[90m—\e[0m" unless pr

      state = pr["is_draft"].to_i == 1 ? "DRAFT" : pr["status"].to_s.upcase
      color = PR_COLORS.fetch(state, 37)
      "\e[#{color}m#{pr['identifier'] || '#?'} #{state}\e[0m"
    end

    # Same capped, deduped lineage the tree rows use, so the preview's branch
    # list never disagrees with what you can actually navigate.
    def branches_in(worktree)
      Tree.lineage(worktree)
    end

    def field(label, value)
      format("%-8s %s\n", label, value)
    end

    def bold(str)
      "\e[1m#{str}\e[0m"
    end

    def blank(str)
      str.nil? || str.empty?
    end

    def truncate(str, width)
      str = str.to_s
      str.length > width ? "#{str[0, width - 1]}…" : str
    end
  end
end
