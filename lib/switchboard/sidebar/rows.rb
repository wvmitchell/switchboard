# frozen_string_literal: true

module Switchboard
  class Sidebar
    # Rows (#57): the view-model half between the Tree and the paint — rebuild
    # (hydrating every shared on-disk view preference), the collapse/branch-fold
    # row transforms (#107), the / filter rows (#60), and the off-paint
    # diff-count cache with its mtime gate (#79). A concern module on Sidebar
    # (see CLAUDE.md conventions); what a row SHOWS stays here, what a row
    # LOOKS like lives in Render.
    module Rows
      private

      # Structure + PR badges, NOT per-worktree dirty (16 git-status calls would
      # stall the paint). Fast.
      def rebuild
        refresh_config # pick up a project added/removed in another session (mtime-gated; see actions.rb)
        @model = Model.new(@config, with_dirty: false)
        @nodes = Tree.nodes(@model, branch_cache: @branch_cache)
        resolve_keymap # re-read sidebar_keys so an `e` config edit re-binds the tree keys (#108)
        # Hydrate folds from the shared on-disk store so every window's sidebar
        # agrees and a respawned pane keeps them. GC against the configured project
        # names (the stable registry, not the git-built tree, so a project that
        # momentarily fails to build doesn't lose its fold).
        @collapsed = Collapse.collapsed(@config.projects.map { |p| p["name"] })
        # Workspaces mid-deletion: hidden in every window while a detached daemon runs
        # the slow `git worktree remove` (the marker is cleared when it finishes, or
        # aged out by TTL if the daemon dies). Git still lists the worktree until the
        # removal lands, so it's in @nodes — the filter below drops it from the rows.
        @pending_delete = PendingDelete.pending(@nodes.select { |n| n.kind == "ws" }.map(&:path))
        @full_header = FullHeader.enabled? # shared toggle: full header on every session
        @fold_branches = BranchFold.folded? # shared toggle: fold every workspace's branches (#107)
        # Shared pane width: a ←/→ resize in any window lands here. Skip the hydrate
        # while a local resize is pending uncommitted (@resized): a rebuild triggered
        # mid-burst (a C-l/C-r token following a ←/→ in the same read) would otherwise
        # rehydrate the OLD on-disk width over the value commit_resize is about to
        # persist, silently dropping the resize. When the width changed elsewhere, nil
        # @geom so the next pin_if_resized actually re-pins — else it short-circuits on
        # our unchanged pane geometry and a peer window stays stuck at the old width
        # until a cross-session re-pin.
        unless @resized
          new_width = Width.resolved
          @geom = nil if new_width != @width
          @width = new_width
        end
        recompute_rows
      end

      # Visible rows. Normally: all nodes, minus the children of collapsed projects.
      # In / filter mode: each project's matching workspaces, kept UNDER their
      # project header so the grouping stays visible. Collapse is ignored (the point
      # is reaching any workspace fast, even a folded one). Headers ARE selectable
      # here — ↵ on a header creates a new workspace in that project, ↵ on a workspace
      # switches to it (see switch_to_filtered).
      def recompute_rows
        @rows = @filter ? filtered_rows : visible_tree
        @cursor = @cursor.clamp(0, [@rows.size - 1, 0].max)
      end

      # The normal (non-filter) rows: the full tree, minus the children of collapsed
      # projects, and — when the global `z` branch-fold is on (issue #107) — minus
      # every workspace's branch-history rows, each multi-branch workspace folded down
      # to a single row. Folding is a cheap row transform (like project collapse), NOT
      # a rebuild, so `z` is instant and the careful Tree / #90 diff-suppression logic
      # is untouched: a folded ws row is a shallow clone marked NOT expanded (so its own
      # diff/PR badge shows again — #90's suppression only bites while the branches are
      # visible) carrying the active branch's PR and the hidden-branch count for the cue.
      def visible_tree
        active_pr, counts = fold_lookup
        rows = []
        @nodes.each do |n|
          next if n.kind != "proj" && @pending_delete.include?(n.path) # being deleted: hide the ws + its branch rows
          next if n.kind != "proj" && @collapsed.include?(n.project) # collapsed project hides its children
          next if n.kind == "br" && @fold_branches                   # folded: hide every branch row
          rows << (foldable_ws?(n) ? fold_ws(n, active_pr[n.path], counts[n.path]) : n)
        end
        rows
      end

      # Per-workspace [active-branch PR, branch-row count], precomputed once from the
      # branch nodes we're about to hide — what a folded ws row needs to stand in for
      # its active branch (the restored badge) and to show the `▸N` cue. Empty unless
      # folding, so the expanded tree pays nothing.
      def fold_lookup
        active_pr = {}
        counts = Hash.new(0)
        if @fold_branches
          @nodes.each do |n|
            next unless n.kind == "br"

            counts[n.path] += 1
            active_pr[n.path] = n.pr if n.active
          end
        end
        [active_pr, counts]
      end

      # A ws row whose branch rows are currently folded away (global `z` on AND it has
      # more than one branch). foldable_ws? gates the clone; fold_ws builds it.
      def foldable_ws?(node)
        @fold_branches && node.kind == "ws" && node.expanded
      end

      # A shallow clone of a folded multi-branch ws row: NOT expanded (so the render
      # gates show its own diff/PR badge again), carrying its active branch's PR and the
      # hidden-branch count (`folded`) for the dim `▸N` cue. A copy so @nodes is left
      # intact (rebuild reuses it; the @diffs cache keys on path/branch/kind, unchanged).
      def fold_ws(node, pr, count)
        node.class.new(**node.to_h.merge(expanded: false, pr: pr, folded: count))
      end

      # Filter rows: walk the tree and, per project, emit its header plus its matching
      # workspaces. A header shows when its OWN name matches — so a project with no
      # (matching) workspaces still appears, and you can ↵ to create its first one — OR
      # when it has matching workspaces (grouping context). Neither ⇒ dropped. Branch-
      # history rows are deliberately skipped: switching to one is identical to
      # switching to its workspace, so a lone branch match would just orphan under a
      # header with no workspace above it.
      def filtered_rows
        rows = []
        header = nil
        keep_header = false
        matches = []
        @nodes.each do |n|
          if n.kind == "proj"
            rows.push(header, *matches) if header && (keep_header || matches.any?)
            header = n
            keep_header = self.class.fuzzy_match?(n.project, @filter)
            matches = []
          elsif n.kind == "ws" && !@pending_delete.include?(n.path) && self.class.fuzzy_match?(filter_text(n), @filter)
            matches << n
          end
        end
        rows.push(header, *matches) if header && (keep_header || matches.any?)
        rows
      end

      # Where the cursor lands after a query keystroke: the first workspace match (so
      # type-then-↵ jumps), not the leading project header. Entry (start_filter) lands
      # on the first row instead; you can arrow up onto a header to create. 0 when
      # there's no match.
      def first_selectable
        @rows.index { |n| n.kind != "proj" } || 0
      end

      # The text a workspace is matched against in filter mode: project + its name +
      # its current branch, so typing a project name narrows to its workspaces and
      # typing a workspace (or current-branch) name jumps straight to it.
      def filter_text(node)
        [node.project, node.name, node.branch].compact.join(" ")
      end

      # Per-worktree diff counts (issue #79): "+adds −dels" of each row's branch vs
      # its base, cached off the paint loop like the agent dots and PR badges — a git
      # diff per worktree is the same cost as the git status the model skips with
      # with_dirty:false, so it can't ride the synchronous paint. Keyed [path, branch]
      # so a workspace's inline branch rows each carry their own count.
      #
      # The gate is the worktree's logs/HEAD mtime — read FRESH here, not from
      # @branch_cache[path][1], because that cached mtime only refreshes on rebuild;
      # the refresh_agents edge caller runs WITHOUT a rebuild, so a just-landed commit would
      # otherwise compare stale-to-stale and skip. Only the gitdir ([0], stable and
      # already absolute) is safe to reuse from @branch_cache. A MERGED/CLOSED PR row
      # bypasses the gate: origin fast-forwarding past the branch zeros the base...HEAD
      # diff without moving logs/HEAD (the same blind spot the PR badge has, healed by
      # R). Compute value-or-nil; nil DELETES the entry, so a row that loses its cache
      # slot, base, or diffability clears instead of painting a ghost count. Fully
      # rescued — a diff fault never disturbs the dots or the paint.
      def refresh_diffs
        # #88: counts off ⇒ no git diff shell-outs at all (not just a hidden label).
        # clear (not a bare return) so a live flip to diff_counts:false drops any
        # counts already cached, instead of leaving stale numbers until a respawn.
        return @diffs.clear unless @config.diff_counts?

        @nodes.each do |n|
          next unless %w[ws br].include?(n.kind)

          # Key on kind too: an expanded workspace emits a ws row AND a br row for the
          # SAME current branch — they'd share [path, branch] but carry different prs
          # (the ws drops its badge when expanded, so pr nil ⇒ resting false; the br
          # keeps it), and the disagreeing resting flag would ping-pong the one entry
          # and recompute forever. Separate keys, separate (identical) entries.
          key = [n.path, n.branch, n.kind]
          gitdir = @branch_cache.dig(n.path, 0)
          head_log = gitdir && File.join(gitdir, "logs", "HEAD")
          mtime = head_log && File.exist?(head_log) ? File.mtime(head_log) : nil
          # Recompute when the reflog moved (fresh mtime) OR the PR just entered/left a
          # resting state (MERGED/CLOSED) — that flip is when origin may have
          # fast-forwarded past the branch and zeroed base...HEAD without touching
          # logs/HEAD. The resting flag is stored, so a merged row recomputes ONCE on
          # the transition, not every reload (which would re-run a synchronous git diff
          # forever — the cost with_dirty:false exists to avoid). R clears @diffs for
          # the rare lag where the fetch trails the badge flip.
          # Gate on (mtime, resting) — and skip on entry presence alone, NOT `mtime &&`:
          # a worktree with a cached gitdir but a vanished logs/HEAD reads mtime nil, and
          # requiring a non-nil mtime to skip would recompute it every reload. With this,
          # a nil-mtime row computes ONCE (nil == nil holds next pass) and self-heals to
          # the normal gate the moment logs/HEAD returns (its real mtime != the stored nil).
          resting = %w[MERGED CLOSED].include?(View.pr_state(n.pr))
          entry = @diffs[key]
          next if entry && entry[0] == mtime && entry[1] == resting

          counts = (Git.diff_counts(n.path, n.base, n.branch) if gitdir && n.base)
          if counts
            @diffs[key] = [mtime, resting, *counts]
          else
            @diffs.delete(key)
          end
        end
      rescue StandardError
        nil
      end

      # The cached [adds, dels] for a row, or nil. Drops the leading [mtime, resting?]
      # the gate keys on. ws/br only — projects never have a diff.
      #
      # A folded multi-branch ws (the fold_ws clone, marked by `folded`) stands in for
      # its active branch, so it reads that branch's cached diff (keyed "br"), NOT its
      # own "ws" entry. The values are identical (base...HEAD == base...active-branch),
      # but only the "br" entry takes the #90 MERGED/CLOSED bypass: refresh_diffs derives
      # the "ws" entry's resting flag from the expanded ws node, whose pr is nil, so it
      # misses the bypass that zeros a merged branch when origin fast-forwards past it
      # without moving logs/HEAD. Reading "br" makes a folded ws self-heal on merge
      # exactly like the unfolded branch row does (R is still the manual catch-all).
      def diff_for(node)
        kind = node.folded ? "br" : node.kind
        entry = @diffs[[node.path, node.branch, kind]]
        entry && entry.drop(2)
      end

      # The single place that decides whether a row shows a diff count. Folds in both
      # the #88 global toggle and the #90 expanded-ws suppression: an expanded
      # workspace's name row diffs HEAD (== its active branch), so the count would
      # duplicate the active branch row right below it — show it on the branch rows
      # only. Re-checks @config here (not just at refresh_diffs) so render hides the
      # count the instant the toggle flips, before the next reload clears @diffs.
      def diff_visible?(node)
        return false unless @config.diff_counts?
        return false unless %w[ws br].include?(node.kind)

        !(node.kind == "ws" && node.expanded)
      end
    end
    include Rows
  end
end
