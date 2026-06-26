# frozen_string_literal: true

module Switchboard
  # Rename a workspace: move its worktree directory (the display name) and rename
  # its tmux session in place. The shared core behind both front-ends — the
  # sidebar `r` key (Sidebar#rename) and the `switchboard rename` CLI verb
  # (issue #42) — so a running agent can (re)name its own live workspace.
  #
  # The branch is left as-is so its PR link and git identity stay intact. No UI
  # here: callers own the prompt / reload / messages. The result is a status the
  # caller maps to output:
  #
  #   :ok        moved + session renamed (or no session to rename — clientless)
  #   :unchanged the name didn't change (rename to the current leaf)
  #   :invalid   the name sanitizes to empty, or still carries a "/" (see below)
  #   :exists    a real dir already sits at the target
  #   :failed    the git worktree move failed (or the project is unknown)
  #   :partial   the dir moved but a *reachable* session's rename failed — the
  #              dir is the source of truth, so this is recoverable (prune reaps
  #              the orphan), but the caller should say so rather than claim :ok
  module Rename
    module_function

    Result = Struct.new(:status, :dest)

    def perform(config, project_name, old_path, newname)
      project = config.project(project_name)
      return Result.new(:failed) unless project

      name = Creator.sanitize(newname)
      # Reject a "/" the sanitizer preserves: a slashed name would nest the dir
      # while Tmux.session_name / Worktree#leaf only see the basename, so the
      # session and sidebar would silently disagree with the path. Agents type
      # branch-style names (feature/auth), so this is the likely CLI input.
      return Result.new(:invalid) if name.empty? || name.include?("/")

      dest = File.join(File.dirname(old_path), name)
      # Same target ⇒ nothing to do. File.identical? also catches a case-only
      # rename (Old -> old) on a case-insensitive FS (macOS APFS), where the two
      # names ARE the same dir and git worktree move can't separate them — so it's
      # "unchanged", not a collision or a failure.
      return Result.new(:unchanged, dest) if dest == old_path || File.identical?(dest, old_path)
      # A real dir blocks the move; a stale rename-bridge symlink does not
      # (move_worktree clears it first), so only a non-symlink counts as taken.
      return Result.new(:exists, dest) if File.exist?(dest) && !File.symlink?(dest)

      # bridge: leave a symlink at the old path so a running agent's frozen
      # project dir keeps resolving and its hooks keep reporting (see move_worktree).
      return Result.new(:failed, dest) unless Git.move_worktree(project["path"], old_path, dest, bridge: true)

      # Carry the agent's conversation history to the new path so `/resume` still
      # finds it after a restart — the cwd just changed out from under it (#42).
      ClaudeHistory.migrate(old_path, dest)

      Result.new(rename_session(project_name, old_path, dest), dest)
    end

    # Rename the session in place (don't kill it) so a running agent and its
    # conversation survive. Returns :ok when there was nothing to rename (same
    # name, or no live session — a clientless rename from a plain shell) or the
    # rename succeeded; :partial only when a session genuinely existed and the
    # rename failed, so the caller can distinguish "fine" from "orphaned".
    def rename_session(project_name, old_path, dest)
      old_name = Tmux.session_name(Worktree.new(project: project_name, path: old_path))
      new_name = Tmux.session_name(Worktree.new(project: project_name, path: dest))
      return :ok if old_name == new_name
      return :ok unless Tmux.has_session?(old_name) # no session yet / no server — not a failure

      Tmux.rename_session(old_name, new_name) ? :ok : :partial
    end

    # --- name suggestion (issue #84) -----------------------------------------
    #
    # So the user never has to invent a workspace name: harvest the model-written
    # name Claude already puts on its pane title, falling back to the branch's
    # first commit subject. Only ever *prefills* the sidebar `r` prompt or is
    # *printed* by no-arg `switchboard rename` — never auto-renames (the title
    # drifts with the conversation, so it's snapshotted at the accept keypress).

    SLUG_CAP = 24 # keep a suggested leaf readable in the default 40-col sidebar pane
    # Bare generic subjects that make a useless leaf. Matched WHOLE, not as a prefix:
    # "fix the bug" -> "fix-the-bug" is a fine name and stays; only a lone "fix" drops.
    DENYLIST = %w[wip tmp temp initial checkpoint test fix update changes stuff].freeze

    # Ordered, deduped name candidates for `worktree` (best first), or [] when
    # suggestions are off or nothing usable is found. `session` is the tmux session
    # whose agent pane title to read (the node's session for the sidebar, the
    # current session for the CLI). The git fallback is computed only when the pane
    # title yields nothing — a fallback shouldn't shell `git log` on every keypress.
    # Rescued: a malformed pane title / commit subject must degrade to no suggestion,
    # never crash the caller (the sidebar TUI / the CLI).
    def suggest(config, worktree, session:)
      return [] unless config.suggest_names?

      current = File.basename(worktree.path)
      parent  = File.dirname(worktree.path)
      candidates = [slugify_title(Tmux.agent_pane_title(session))].compact # the model's name (preferred)
      candidates << slugify_title(Git.first_commit_subject(worktree.path, worktree.base)) if candidates.empty?
      candidates.compact.uniq.reject do |c|
        sibling = File.join(parent, c)
        c == current ||                                  # never suggest the current name
          DENYLIST.include?(c) || c.match?(/\A\d+\z/) ||  # bare generic / bare issue numbers
          (File.exist?(sibling) && !File.symlink?(sibling)) # a real sibling dir collides; a stale bridge symlink doesn't (perform clears it)
      end
    rescue StandardError
      []
    end

    # Prose title/subject -> a flat, lowercase leaf, or nil. Strips a leading
    # activity glyph (Claude's spinner/✳ + space) BEFORE sanitizing — else the
    # space would become a leading dash — then downcases, sanitizes, drops a
    # surviving "/", and caps at a word boundary so a long summary doesn't make an
    # unwieldy leaf. nil when nothing usable survives.
    def slugify_title(raw)
      return nil if raw.nil?

      # scrub first: a pane title (a non-UTF-8 locale's OSC title) or a commit
      # subject (i18n.commitEncoding) can carry invalid UTF-8, and the regex /
      # downcase / sanitize below would raise on bad bytes — degrade, don't crash.
      slug = Creator.sanitize(raw.scrub.sub(/\A[^[:alnum:]]+/, "").downcase)
      slug = slug[0, SLUG_CAP].sub(/-+[^-]*\z/, "") if slug.length > SLUG_CAP # trim the partial last word
      # Leading-dash strip is reachable: a non-ASCII alnum (é) survives the Unicode
      # [[:alnum:]] glyph-strip but ASCII \w in sanitize drops it, leaving a dash.
      slug = slug.sub(/\A-+/, "").sub(/-+\z/, "")
      slug if !slug.empty? && !slug.include?("/")
    end
  end
end
