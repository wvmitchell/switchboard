# frozen_string_literal: true

require_relative "../support/paths"

module Switchboard
  # Rename a workspace. The folder never moves: every agent keys its history by the cwd,
  # so moving it would orphan that history. A rename changes only what switchboard CALLS
  # the workspace: its stored name (Names), its branch when that's safe, its tmux session
  # in place, and (inside tmux) Claude's session title via the session-name worker. The
  # shared core behind the sidebar's `r` and `switchboard rename`, so a running agent can
  # name its own live workspace, mid-work, without stranding anything.
  #
  # No UI here: callers own the prompt / reload / messages. The result's status:
  #
  #   :ok             named (session renamed, or no live session to rename)
  #   :unchanged      it already has that name
  #   :invalid        the name sanitizes to empty, carries a "/", or isn't a valid branch
  #   :exists         another workspace, folder, build or session holds the name (`detail`)
  #   :branch_exists  a branch by the new name already exists
  #   :building       still being created; nothing changed
  #   :stale_peers    a sidebar runs code that can't read stored names (`detail`: panes)
  #   :names_unreadable / :listing_failed  a uniqueness source couldn't be read (`detail`)
  #   :failed         the name couldn't be saved; the branch was put back (`detail`)
  #   :rollback_failed  ...and the branch couldn't be put back (`detail`: [err, new, old])
  #   :partial        named, but the tmux session rename failed; the next switch heals it
  #
  # `dest` is the workspace's unchanged path, `name` the name it has now, `spawned` true
  # when the session-name worker was started.
  module Rename
    module_function

    Result = Struct.new(:status, :dest, :spawned, :name, :detail)

    def perform(config, project_name, path, newname)
      sync_session_name(config, project_name, name_it(config, project_name, path, newname))
    end

    # The rename itself, all under the project's lock so it serializes with another rename,
    # with placeholder reservation, and with prune. `perform` adds the title sync on top.
    def name_it(config, project_name, path, newname)
      project = config.project(project_name)
      return Result.new(:failed, path, nil, nil, "unknown project #{project_name}") unless project

      Creation.with_project_lock(project_name) { locked(config, project, project_name, path, newname) }
    end

    def locked(config, project, project_name, path, newname)
      wt = Worktree.new(project: project_name, path: path)
      real = Paths.real_or_self(path)
      current = wt.display_name
      res = ->(status, detail = nil, name = current) { Result.new(status, path, nil, name, detail) }
      # The worker computes its session name before opening it, so a rename mid-build would
      # split the session from the build.
      return res[:building] unless Creation.renamable?(Creation.for_path(path))

      stale = stale_peers
      return res[:stale_peers, stale] unless stale.empty?

      name = Placeholder.sanitize(newname)
      # A "/" the sanitizer keeps would read as a path segment in the session name.
      return res[:invalid] if name.empty? || name.include?("/")
      return res[:unchanged] if name == current

      live = Tmux.sessions || []
      old_session = Tmux.session_for(wt, live)
      status, map, err = Names.read_all
      return res[:names_unreadable, "#{map}: #{err}"] unless status == :ok

      listing = Git.worktrees(project["path"], strict: true)
      return res[:listing_failed, project["path"]] unless listing

      clash = clash_for(project_name, project, real, name, map, listing, live, old_session)
      return res[:exists, clash, name] if clash

      branch = sync_branch?(project["path"], path, current)
      if branch
        new_branch = branch_for(config, name)
        return res[:invalid, nil, name] unless Git.valid_branch_name?(new_branch)
        return res[:branch_exists, new_branch, name] if Git.branch_exists?(project["path"], new_branch)
        return res[:failed, "couldn't rename branch #{branch}", name] unless Git.rename_branch(project["path"], branch, new_branch)
      end

      saved = if name == wt.folder_name
                Names.delete(real) # back to the folder name: no entry needed
              else
                Names.write(real, name, project: project_name, branch: branch ? new_branch : Git.current_branch(path))
              end
      unless saved == :ok
        return res[:failed, saved.last] unless branch
        return res[:failed, saved.last] if Git.rename_branch(project["path"], new_branch, branch)

        return res[:rollback_failed, [saved.last, new_branch, branch]]
      end

      SessionName::Outcome.forget(real) # about the old name; this rename's worker judges afresh
      Result.new(rename_session(old_session, Tmux.session_name(wt), live), path, nil, name)
    end

    # What already holds `name` in this project, or nil. Compared as tmux session names
    # (foo.bar and foo-bar are one session): every other workspace's name, every other
    # folder in the project's worktree parents (folder names win the display rule, so a
    # name equal to one would be silently overridden), every unfinished build, and every
    # live sb/ session that isn't this workspace's.
    def clash_for(project_name, project, real, name, map, listing, live, own_session)
      want = Names.session_leaf(name)
      same = ->(other) { Names.session_leaf(other) == want }
      others = listing.reject { |w| w[:bare] || Paths.real_or_self(w[:path]) == real }
      others.each do |w|
        r = Paths.real_or_self(w[:path])
        shown = map[r] && !Names.clash?(map[r], map) ? map[r].name : File.basename(w[:path])
        return "workspace #{shown} (#{w[:path]})" if same[shown]
        return "the folder #{w[:path]}" if same[File.basename(w[:path])]
      end
      # Every worktree parent but the primary checkout's, plus this workspace's own: the
      # display rule compares against its siblings even beside the primary.
      primary_parent = File.dirname(Paths.real_or_self(project["path"]))
      parents = (listing.map { |w| File.dirname(Paths.real_or_self(w[:path])) } - [primary_parent] + [File.dirname(real)]).uniq
      parents.each do |dir|
        Names.siblings(dir).each do |f|
          next if File.join(dir, f) == real

          return "the folder #{File.join(dir, f)}" if same[f]
        end
      end
      Creation.all.each do |r|
        next unless r["project"] == project_name && Creation::PRE_READY.include?(r["state"]) && Paths.real_or_self(r["path"].to_s) != real

        return "a build in progress (#{r['path']})" if same[r["name"].to_s]
      end
      prefix = Tmux.session_prefix(project_name)
      live.each do |s|
        next if s[:name] == own_session || !s[:name].start_with?(prefix)

        return "the tmux session #{s[:name]}" if same[s[:name].delete_prefix(prefix)]
      end
      nil
    end

    # Live sidebar panes whose code can't read stored names (an older binary, a reload
    # mid-exec, a respawn not yet booted). A rename refuses while any is running: such a
    # sidebar would show folder names and an old prune would kill renamed sessions.
    def stale_peers
      targets = CodeReload.sidebar_reload_targets
      # A server that can't list its panes may still run an old sidebar: unknown isn't none.
      return Tmux.sessions.nil? ? [] : ["(tmux couldn't list panes)"] if targets.nil?

      targets.reject(&:names?).map(&:pane)
    end

    # Start the detached worker that types `/rename <name>` into the workspace's live
    # agent session once that's safe. Only inside tmux — the worker drives tmux, and the
    # offline suite (no TMUX) can never launch a real switchboard from a rename test. A
    # same-name rename spawns too: it's the retry doctor points at.
    def sync_session_name(config, project_name, result)
      return result unless %i[ok partial unchanged].include?(result.status)
      return result unless ENV["TMUX"] && config.sync_session_name_for(project_name)
      return result unless result.name.to_s.match?(SessionName::NAME) # the worker would refuse it

      bin = ENV["SWITCHBOARD_BIN"] or return result
      # Its own process group: an agent's tool runner that kills the rename command's group
      # on return can't take the worker down before it daemonizes.
      Process.detach(Process.spawn(bin, "sync-session-name", Paths.real_or_self(result.dest), result.name,
                                   pgroup: true, in: File::NULL, out: File::NULL, err: File::NULL))
      result.spawned = true
      result
    rescue SystemCallError
      result
    end

    # The branch to rename, or false when the branch should be left alone: only while it's
    # still the auto-named one (its leaf is the workspace's current name) AND unpushed —
    # renaming a pushed branch would orphan its remote ref / PR. `pushed?` checks a
    # remote-tracking ref, NOT @{upstream} (worktree add auto-tracks the base).
    def sync_branch?(repo, path, current_name)
      branch = Git.current_branch(path)
      return false if branch.empty?
      return false unless File.basename(branch) == current_name
      return false if Git.pushed?(repo, branch)

      branch
    end

    # The convention-correct branch for a name: <branch_prefix>/<name>, or bare <name>
    # when no prefix is configured.
    def branch_for(config, name)
      [config.branch_prefix, name].compact.join("/")
    end

    # Rename the live session in place (never kill it) so a running agent and its
    # conversation survive. :ok when there was nothing to rename (no live session — a
    # clientless rename from a plain shell — or the name didn't change) or it worked;
    # :partial when a session exists and the rename failed. Nothing dies either way:
    # sessions are matched by the folder they were created in, not their name.
    def rename_session(old_name, new_name, live)
      return :ok if old_name.nil? || old_name == new_name
      return :ok unless live.any? { |s| s[:name] == old_name }

      Tmux.rename_session(old_name, new_name) ? :ok : :partial
    end
  end
end
