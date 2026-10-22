# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/sidebar_case"

module Switchboard
  # Sidebar::Actions — the verbs (#57): remove/delete, rename via prompts,
  # open PR/repo (browse_args), the R badge refresh, the shared-view-state
  # toggles and their warm broadcasts, and the config-edit round trip.
  class SidebarActionsTest < SidebarCase
    def test_toggle_collapse_broadcasts_warm
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a")])
      bcast = 0
      stub_method(Tmux, :broadcast_warm, ->(**) { bcast += 1 }) do
        sb.send(:toggle_collapse, "app")
      end
      assert_equal 1, bcast, "collapsing a project pings other sidebars to repaint the fold now"
    end

    def test_toggle_branch_fold_broadcasts_warm
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a")])
      bcast = 0
      stub_method(Tmux, :broadcast_warm, ->(**) { bcast += 1 }) do
        sb.send(:toggle_branch_fold)
      end
      assert_equal 1, bcast, "z (branch fold) pings other sidebars too"
    end

    def test_toggle_full_header_broadcasts_warm
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a")])
      bcast = 0
      stub_method(Tmux, :broadcast_warm, ->(**) { bcast += 1 }) do
        sb.send(:toggle_full_header)
      end
      assert_equal 1, bcast, "H (full header) pings other sidebars too"
    end

    # Adding/removing a project changes the shared registry, so — like the view-state
    # toggles above — it pings peer sidebars to re-read config now (their rebuild's
    # refresh_config picks it up) instead of waiting for a respawn.
    def test_add_local_broadcasts_warm_so_peers_pick_up_the_new_project
      sb = sidebar(nodes: [])
      sb.define_singleton_method(:prompt_line) { |*| "/repos/new" }
      sb.define_singleton_method(:reload) { |**| }
      bcast = 0
      stub_method(Tmux, :broadcast_warm, ->(**) { bcast += 1 }) do
        stub_method(Registrar, :register, ->(*, **) { [{ "name" => "new" }, nil] }) do
          sb.send(:add_local)
        end
      end
      assert_equal 1, bcast, "registering a project pings peer sidebars to re-read the grown config"
    end

    def test_add_create_broadcasts_warm_so_peers_pick_up_the_new_project
      sb = sidebar(nodes: [])
      sb.define_singleton_method(:prompt_line) { |*| "fresh" }
      sb.define_singleton_method(:reload) { |**| }
      bcast = 0
      stub_method(Tmux, :broadcast_warm, ->(**) { bcast += 1 }) do
        stub_method(Registrar, :create, ->(*, **) { [{ "name" => "fresh" }, nil] }) do
          sb.send(:add_create)
        end
      end
      assert_equal 1, bcast, "creating a repo pings peer sidebars to re-read the grown config"
    end

    # A blank name cancels: Registrar.create is never reached and nothing is
    # broadcast — just a repaint.
    def test_add_create_blank_name_cancels
      sb = sidebar(nodes: [])
      sb.define_singleton_method(:prompt_line) { |*| "" }
      reloaded = 0
      sb.define_singleton_method(:reload) { |**| reloaded += 1 }
      created = 0
      stub_method(Registrar, :create, ->(*, **) { created += 1; [nil, nil] }) do
        stub_method(Tmux, :broadcast_warm, ->(**) {}) do
          sb.send(:add_create)
        end
      end
      assert_equal 0, created, "blank name never reaches Registrar.create"
      assert_equal 1, reloaded, "blank cancels with a repaint"
    end

    def test_remove_project_broadcasts_warm_so_peers_drop_it
      File.write(Config.path, YAML.dump("projects" => [{ "name" => "app", "path" => "/repos/app" }]))
      sb = sidebar(nodes: [proj("app")], cursor: 0)
      sb.instance_variable_set(:@config, Config.new)
      sb.define_singleton_method(:reload) { |**| }
      bcast = 0
      stub_method(Tmux, :broadcast_warm, ->(**) { bcast += 1 }) do
        stub_method(Tmux, :session_of, ->(*) { "sb/home" }) do          # not in the project: no eject
          stub_method(Tmux, :kill_project_sessions, ->(*) { [] }) do
            stub_method(sb, :confirm, ->(*) { true }) do
              sb.send(:remove_project, proj("app"))
            end
          end
        end
      end
      assert_equal 1, bcast, "removing a project pings peer sidebars to re-read the smaller config"
    end

    # --- remove: d routes by row kind ----------------------------------------

    def test_remove_routes_project_to_remove_project_and_workspace_to_delete
      sb = sidebar(nodes: [proj("app"), ws("a")], cursor: 0)
      routed = nil
      sb.define_singleton_method(:remove_project) { |node| routed = [:project, node.project] }
      sb.define_singleton_method(:delete) { routed = [:delete] }

      sb.send(:remove)
      assert_equal [:project, "app"], routed, "a project row removes the project"

      sb.instance_variable_set(:@cursor, 1) # workspace row
      sb.send(:remove)
      assert_equal [:delete], routed, "a workspace row deletes the worktree"
    end

    # --- delete: off-loop removal + shared row-hide (the delete-hang fix) -------

    # A sidebar whose cursor sits on a real, configured workspace row.
    def deletable_sidebar(ws_path: "/wt/a", branch: "feature")
      File.write(Config.path, YAML.dump("projects" => [{ "name" => "app", "path" => "/repos/app" }]))
      node = ws("a", path: ws_path)
      node[:branch] = branch
      sb = sidebar(nodes: [proj("app"), node], cursor: 1)
      sb.instance_variable_set(:@config, Config.new)
      sb
    end

    def test_delete_clean_hides_the_row_spawns_the_reaper_and_reloads_hooks_only
      sb = deletable_sidebar
      ENV["SWITCHBOARD_BIN"] = "/bin/switchboard"
      spawned = nil
      detached = false
      reload_kwargs = :never
      sb.define_singleton_method(:reload) { |**kw| reload_kwargs = kw }
      stub_method(Git, :clean?, ->(*) { true }) do
        stub_method(Tmux, :session_of, ->(*) { "sb/home" }) do        # not the current session
          stub_method(Tmux, :session_name, ->(*) { "sb/app/a" }) do
            stub_method(Tmux, :kill, ->(*) {}) do
              stub_method(Process, :spawn, ->(*a, **) { spawned = a; 4242 }) do
                stub_method(Process, :detach, ->(pid) { detached = (pid == 4242) }) do
                  stub_method(sb, :confirm, ->(*) { true }) do
                    sb.send(:delete)
                  end
                end
              end
            end
          end
        end
      end
      assert_includes PendingDelete.pending(["/wt/a"]), "/wt/a", "the row is hidden via a shared marker"
      assert_includes sb.instance_variable_get(:@pending_delete), "/wt/a", "...and this pane same-frame"
      assert_equal ["/bin/switchboard", "reap-worktree", "/repos/app", "/wt/a", "feature"], spawned,
                   "hands the removal to the detached reaper (repo, path, branch)"
      assert detached, "and detaches it so it outlives us"
      assert_equal({ hooks_only: true }, reload_kwargs, "the non-current reload skips the lsof fallback (Option C)")
    ensure
      ENV.delete("SWITCHBOARD_BIN")
    end

    # d on a real row whose build is still in flight cancels the build BEFORE the session
    # is killed, so its launcher can't start an agent in (or GC ring ✘ for) a workspace
    # you just deleted on purpose.
    def test_delete_cancels_an_in_flight_build_before_the_kill
      sb = deletable_sidebar
      rec = Creation.create(project: "app", name: "a", path: "/wt/a", task: "")
      Creation.transition(rec["id"], from: :queued, to: :launching)
      sb.send(:index_creations, Creation.all)
      state_at_kill = nil
      sb.define_singleton_method(:reload) { |**_kw| }
      stub_method(Git, :clean?, ->(*) { true }) do
        stub_method(Tmux, :session_of, ->(*) { "sb/home" }) do
          stub_method(Tmux, :kill, ->(*) { state_at_kill = Creation.find(rec["id"])["state"] }) do
            stub_method(sb, :start_removal, ->(*) {}) do
              stub_method(sb, :confirm, ->(*) { true }) { sb.send(:delete) }
            end
          end
        end
      end
      assert_equal "canceled", state_at_kill
    end

    # Deleting a workspace whose build already failed (no cancel can land): its record is
    # acked, so the ✘ doesn't come back as a synthetic row once the tree is gone.
    def test_delete_acks_a_failed_build_so_its_row_does_not_return
      sb = deletable_sidebar
      rec = Creation.create(project: "app", name: "a", path: "/wt/a", task: "")
      Creation.transition(rec["id"], from: :queued, to: :building)
      Creation.mark_failed(rec["id"], "interrupted", from: "building")
      sb.send(:index_creations, Creation.all)
      sb.define_singleton_method(:reload) { |**_kw| }
      stub_method(Git, :clean?, ->(*) { true }) do
        stub_method(Tmux, :session_of, ->(*) { "sb/home" }) do
          stub_method(Tmux, :kill, ->(*) {}) do
            stub_method(sb, :start_removal, ->(*) {}) do
              stub_method(sb, :confirm, ->(*) { true }) { sb.send(:delete) }
            end
          end
        end
      end
      assert Creation.find(rec["id"])["acked"]
      Creation.gc
      assert_nil Creation.find(rec["id"]), "no tree on disk: nothing left to guard"
    end

    def test_delete_dirty_prompts_to_force_and_aborts_when_declined
      sb = deletable_sidebar
      ENV["SWITCHBOARD_BIN"] = "/bin/switchboard"
      confirms = []
      marked = false
      stub_method(Git, :clean?, ->(*) { false }) do            # not clean ⇒ force prompt
        stub_method(PendingDelete, :mark, ->(*) { marked = true }) do
          sb.define_singleton_method(:confirm) do |msg|
            confirms << msg
            !msg.include?("uncommitted")                       # yes to "delete?", NO to "force?"
          end
          sb.send(:delete)
        end
      end
      assert_equal 2, confirms.size, "asks to delete, then to force"
      assert_match(/uncommitted changes/, confirms.last)
      refute marked, "declining force deletes nothing (no hide, no reaper)"
    ensure
      ENV.delete("SWITCHBOARD_BIN")
    end

    # Deleting the session you're in: fall back to home first, then kill — and DON'T
    # reload in-process (this process dies with the session; home + the reaper drive).
    def test_delete_current_session_goes_home_and_kills_without_reloading
      sb = deletable_sidebar
      ENV["SWITCHBOARD_BIN"] = "/bin/switchboard"
      went_home = false
      killed = false
      reloaded = false
      sb.define_singleton_method(:reload) { |**| reloaded = true }
      stub_method(Git, :clean?, ->(*) { true }) do
        stub_method(Tmux, :session_name, ->(*) { "sb/app/a" }) do
          stub_method(Tmux, :session_of, ->(*) { "sb/app/a" }) do   # WE are that session
            stub_method(Tmux, :go_home, -> { went_home = true }) do
              stub_method(Tmux, :kill, ->(*) { killed = true }) do
                stub_method(Process, :spawn, ->(*, **) { 1 }) do
                  stub_method(Process, :detach, ->(*) {}) do
                    stub_method(sb, :confirm, ->(*) { true }) do
                      sb.send(:delete)
                    end
                  end
                end
              end
            end
          end
        end
      end
      assert went_home, "falls back to home before killing the session we live in"
      assert killed, "then kills it"
      refute reloaded, "home + the reaper's broadcast drive the repaint, not this dying process"
    ensure
      ENV.delete("SWITCHBOARD_BIN")
    end

    # No self-invoke available (no SWITCHBOARD_BIN): remove synchronously so delete
    # still works (the old inline hang, but correct) and leaves no dangling hide.
    def test_delete_falls_back_to_synchronous_removal_without_the_binary
      sb = deletable_sidebar
      ENV.delete("SWITCHBOARD_BIN")
      removed = nil
      branch_deleted = nil
      sb.define_singleton_method(:reload) { |**| }
      stub_method(Git, :clean?, ->(*) { true }) do
        stub_method(Git, :remove_worktree, ->(repo, p, **) { removed = [repo, p]; true }) do
          stub_method(Git, :delete_branch, ->(_repo, b, **) { branch_deleted = b; true }) do
            stub_method(Tmux, :session_of, ->(*) { "sb/home" }) do
              stub_method(Tmux, :session_name, ->(*) { "sb/app/a" }) do
                stub_method(Tmux, :kill, ->(*) {}) do
                  stub_method(sb, :confirm, ->(*) { true }) do
                    sb.send(:delete)
                  end
                end
              end
            end
          end
        end
      end
      assert_equal ["/repos/app", "/wt/a"], removed, "no binary ⇒ remove synchronously"
      assert_equal "feature", branch_deleted
      assert_empty PendingDelete.pending(["/wt/a"]), "the sync fallback leaves no hide marker"
    end

    # Value: protects=the sidebar's own removal forces past a lock only on our un-set-up build, like the reaper; fails_when=sync_remove drops or hardcodes `locked:`, so an interrupted add's ✘ can't be deleted without the binary, or a lock you set is overridden; why_new=the delete tests stub remove_worktree ignoring kwargs; seam=none; no_claim=git honoring the second --force (cli_test covers that against a real lock)
    def test_sync_remove_forces_past_a_lock_only_on_an_unfinished_build
      sb = deletable_sidebar
      rec = Creation.create(project: "app", name: "half", path: "/wt/half", task: "t")
      Creation.update(rec["id"], state: "failed", reason: "interrupted")
      locks = {}
      stub_method(Git, :remove_worktree, ->(_repo, p, **kw) { locks[p] = kw[:locked]; true }) do
        stub_method(Git, :delete_branch, ->(*, **) { true }) do
          %w[/wt/half /wt/a].each { |p| sb.send(:sync_remove, "/repos/app", p, "b") }
        end
      end
      assert_equal({ "/wt/half" => true, "/wt/a" => false }, locks)
    end

    # bin present but the reaper spawn raises (e.g. a stale/broken SWITCHBOARD_BIN):
    # un-hide the row and remove synchronously so the delete still lands — never a
    # workspace hidden forever behind a reaper that never started.
    def test_delete_falls_back_to_sync_when_the_reaper_spawn_raises
      sb = deletable_sidebar
      ENV["SWITCHBOARD_BIN"] = "/bin/switchboard"
      removed = nil
      sb.define_singleton_method(:reload) { |**| }
      stub_method(Git, :clean?, ->(*) { true }) do
        stub_method(Process, :spawn, ->(*_a, **_k) { raise Errno::ENOENT }) do
          stub_method(Git, :remove_worktree, ->(repo, p, **) { removed = [repo, p]; true }) do
            stub_method(Git, :delete_branch, ->(*, **) { true }) do
              stub_method(Tmux, :session_of, ->(*) { "sb/home" }) do
                stub_method(Tmux, :session_name, ->(*) { "sb/app/a" }) do
                  stub_method(Tmux, :kill, ->(*) {}) do
                    stub_method(sb, :confirm, ->(*) { true }) do
                      sb.send(:delete)
                    end
                  end
                end
              end
            end
          end
        end
      end
      assert_equal ["/repos/app", "/wt/a"], removed, "a failed spawn falls back to synchronous removal"
      assert_empty PendingDelete.pending(["/wt/a"]), "and clears the optimistic hide marker"
      refute_includes sb.instance_variable_get(:@pending_delete), "/wt/a", "...in-memory too"
    ensure
      ENV.delete("SWITCHBOARD_BIN")
    end

    # The optimistic hide is a plain row transform: a pending path vanishes at once.
    def test_a_pending_delete_path_is_hidden_from_the_rows
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a"), ws("b", path: "/wt/b")])
      sb.instance_variable_set(:@pending_delete, Set.new(["/wt/a"]))
      sb.send(:recompute_rows)
      assert_equal ["b"], ws_names(sb), "the workspace being deleted disappears immediately"
    end

    # --- remove_project: confirm -> unregister + close sessions ----------------

    def test_remove_project_unregisters_and_closes_sessions_when_confirmed
      File.write(Config.path, YAML.dump("projects" => [{ "name" => "app", "path" => "/repos/app" }]))
      sb = sidebar(nodes: [proj("app")], cursor: 0)
      sb.instance_variable_set(:@config, Config.new)
      killed = nil
      reloaded = false
      sb.define_singleton_method(:reload) { |**| reloaded = true }
      stub_method(Tmux, :session_of, ->(*) { "sb/home" }) do            # not in the project: no eject
        stub_method(Tmux, :kill_project_sessions, ->(name) { killed = name; [] }) do
          stub_method(sb, :confirm, ->(*) { true }) do
            sb.send(:remove_project, proj("app"))
          end
        end
      end
      assert_equal "app", killed, "closes the project's sessions"
      assert reloaded, "refreshes the tree in-process"
      refute Config.new.project("app"), "and unregisters it from the config"
    end

    def test_remove_project_is_a_noop_when_not_confirmed
      File.write(Config.path, YAML.dump("projects" => [{ "name" => "app", "path" => "/repos/app" }]))
      sb = sidebar(nodes: [proj("app")], cursor: 0)
      sb.instance_variable_set(:@config, Config.new)
      killed = false
      stub_method(Tmux, :kill_project_sessions, ->(*) { killed = true; [] }) do
        stub_method(sb, :confirm, ->(*) { false }) do
          sb.send(:remove_project, proj("app"))
        end
      end
      refute killed, "an unconfirmed remove closes nothing"
      assert Config.new.project("app"), "...and keeps the project registered"
    end

    # Removing the project whose session we're in would kill this sidebar's own
    # pane: fall back to home first, poke home to re-read the smaller config
    # (its git reload won't show it), and DON'T reload in-process — home drives.
    def test_remove_project_ejects_to_home_when_removing_the_session_were_in
      File.write(Config.path, YAML.dump("projects" => [{ "name" => "app", "path" => "/repos/app" }]))
      sb = sidebar(nodes: [proj("app")], cursor: 0)
      sb.instance_variable_set(:@config, Config.new)
      went_home = false
      poked = nil
      reloaded = false
      sb.define_singleton_method(:reload) { |**| reloaded = true }
      stub_method(Tmux, :session_of, ->(*) { "sb/app/feat" }) do        # we're inside the project
        stub_method(Tmux, :go_home, ->(*) { went_home = true }) do
          stub_method(Tmux, :poke_sidebar_of, ->(s, **kw) { poked = [s, kw] }) do
            stub_method(Tmux, :kill_project_sessions, ->(*) { [] }) do
              stub_method(sb, :confirm, ->(*) { true }) do
                sb.send(:remove_project, proj("app"))
              end
            end
          end
        end
      end
      assert went_home, "removing the session we're in falls back to home first"
      assert_equal [Tmux::HOME, { reload_config: true }], poked, "pokes home to re-read the smaller config"
      refute reloaded, "the dying sidebar doesn't reload in-process"
    end

    # --- R: force a PR refresh now (T4 manual trigger) -----------------------
    # A PR merged/closed on GitHub fires no local trigger, so R fans a refresh
    # across every registered project (bypassing the staleness gates) and notifies
    # so the keypress is felt even when nothing changed.
    def test_R_refreshes_every_registered_project_and_notifies
      ENV["SWITCHBOARD_BIN"] = "/opt/sb" # the wrapper is what lets a refresh spawn
      File.write(Config.path, YAML.dump("projects" => [{ "name" => "app", "path" => "/x" },
                                                        { "name" => "lib", "path" => "/y" }]))
      sb = sidebar(nodes: [proj("app")])
      sb.instance_variable_set(:@config, Config.new)
      refreshed = []
      sb.define_singleton_method(:maybe_refresh_prs) { |p| refreshed << p }
      notified = nil
      stub_method(Tmux, :notify, ->(msg) { notified = msg }) do
        sb.send(:dispatch, "R")
      end
      assert_equal %w[app lib], refreshed, "R refreshes every project, not just the highlighted one"
      assert_match(/refreshing PRs/, notified.to_s, "R confirms the keypress on the status line")
    end

    # Without the wrapper, maybe_refresh_prs can't spawn — so R must not claim a
    # refresh on the status line either.
    def test_R_is_silent_without_the_wrapper
      ENV.delete("SWITCHBOARD_BIN")
      File.write(Config.path, YAML.dump("projects" => [{ "name" => "app", "path" => "/x" }]))
      sb = sidebar(nodes: [proj("app")])
      sb.instance_variable_set(:@config, Config.new)
      refreshed = []
      sb.define_singleton_method(:maybe_refresh_prs) { |p| refreshed << p }
      notified = false
      stub_method(Tmux, :notify, ->(_msg) { notified = true }) do
        sb.send(:dispatch, "R")
      end
      assert_empty refreshed, "no wrapper ⇒ nothing spawns"
      refute notified, "...and no misleading 'refreshing' notify"
    end

    # --- O / open_repo: open the row's repo in the browser (issue #63) ---------
    # browse_args is the pure decision behind O: the `gh browse` sub-args, with
    # --branch only when the row has an OPEN PR. An open (or draft) PR guarantees
    # its head branch is still on the remote (GitHub closes a PR the instant its
    # branch is deleted), so /tree/<branch> resolves; a merged/closed PR keeps its
    # badge after the branch is gone, so it must NOT deep-link (it would 404).

    def tree_node(kind:, path: "/wt/x", branch: nil, pr: nil)
      Tree::Node.new(kind: kind, project: "app", path: path, branch: branch, pr: pr)
    end

    def test_browse_args_project_header_opens_repo_home
      assert_equal ["browse"], Sidebar::Actions.browse_args(tree_node(kind: "proj", path: "/repos/app"))
    end

    def test_browse_args_open_pr_deep_links_the_branch
      n = tree_node(kind: "ws", branch: "feat", pr: { "identifier" => "#7", "status" => "OPEN", "is_draft" => 0 })
      assert_equal ["browse", "--branch", "feat"], Sidebar::Actions.browse_args(n)
    end

    # A draft PR is OPEN (is_draft just flags the badge color), so its branch is on
    # the remote — deep-link it too.
    def test_browse_args_draft_pr_still_deep_links
      n = tree_node(kind: "ws", branch: "feat", pr: { "identifier" => "#8", "status" => "OPEN", "is_draft" => 1 })
      assert_equal ["browse", "--branch", "feat"], Sidebar::Actions.browse_args(n)
    end

    # The load-bearing correctness case: a merged PR's branch is often deleted, so
    # --branch would 404. Fall back to the repo home.
    def test_browse_args_merged_pr_falls_back_to_repo_home
      n = tree_node(kind: "br", branch: "feat", pr: { "identifier" => "#9", "status" => "MERGED", "is_draft" => 0 })
      assert_equal ["browse"], Sidebar::Actions.browse_args(n)
    end

    # A fresh, unpushed branch has no PR badge — repo home, never a 404.
    def test_browse_args_no_pr_falls_back_to_repo_home
      assert_equal ["browse"], Sidebar::Actions.browse_args(tree_node(kind: "ws", branch: "feat", pr: nil))
    end

    # Defensive: an OPEN PR with an empty branch (e.g. a detached-HEAD worktree)
    # must not emit `--branch ""` — fall back to repo home.
    def test_browse_args_open_pr_but_empty_branch_falls_back
      assert_equal ["browse"], Sidebar::Actions.browse_args(tree_node(kind: "ws", branch: "", pr: { "status" => "OPEN" }))
    end

    def test_browse_args_nil_or_pathless_returns_nil
      assert_nil Sidebar::Actions.browse_args(nil)
      assert_nil Sidebar::Actions.browse_args(tree_node(kind: "ws", path: nil, branch: "feat",
                                               pr: { "status" => "OPEN" }))
    end

    def test_dispatch_O_opens_the_repo
      sb = sidebar(nodes: [proj("app")])
      called = false
      sb.define_singleton_method(:open_repo) { called = true }
      sb.send(:dispatch, "O")
      assert called, "O routes to open_repo"
    end

    def test_dispatch_H_toggles_the_full_header
      sb = sidebar(nodes: [proj("app")])
      sb.send(:dispatch, "H")
      assert sb.instance_variable_get(:@full_header), "H routes to toggle_full_header"
      assert FullHeader.enabled?, "and writes through to the shared store"
    end

    # open_repo wires browse_args into the detached gh spawn, chdir'd to the row.
    def test_open_repo_spawns_gh_browse_in_the_rows_dir
      sb = sidebar(nodes: [proj("app")]) # proj path "/repos/app" → repo home
      captured = nil
      stub_method(Process, :spawn, ->(*a, **k) { captured = [a, k]; 4242 }) do
        stub_method(Process, :detach, ->(pid) { pid }) do
          sb.send(:open_repo)
        end
      end
      assert_equal ["gh", "browse"], captured[0]
      assert_equal "/repos/app", captured[1][:chdir]
    end

    # The UI-never-crashes guarantee: a missing dir / no `gh` raises SystemCallError
    # from spawn, which spawn_gh swallows — open_repo returns nil, never raises.
    def test_open_repo_survives_a_missing_dir_or_gh
      sb = sidebar(nodes: [proj("app")])
      stub_method(Process, :spawn, ->(*_a, **_k) { raise Errno::ENOENT }) do
        assert_nil sb.send(:open_repo)
      end
    end

    # O on the empty-tree home (no row → current nil → browse_args nil) must do
    # nothing — never spawn gh. Pins the open_repo early-return contract.
    def test_open_repo_on_empty_tree_does_not_spawn
      sb = sidebar(nodes: [])
      spawned = false
      stub_method(Process, :spawn, ->(*_a, **_k) { spawned = true; 0 }) do
        assert_nil sb.send(:open_repo)
      end
      refute spawned, "O on an empty tree must not spawn gh"
    end

    # Regression: open_pr now routes through the shared spawn_gh helper. It had no
    # test before; pin that the refactor preserves its exact gh invocation.
    def test_open_pr_still_spawns_gh_pr_view
      sb = sidebar(nodes: [proj("app"), tree_node(kind: "ws", path: "/wt/feat", branch: "feat")], cursor: 1)
      captured = nil
      stub_method(Process, :spawn, ->(*a, **k) { captured = [a, k]; 7 }) do
        stub_method(Process, :detach, ->(pid) { pid }) do
          sb.send(:open_pr)
        end
      end
      assert_equal ["gh", "pr", "view", "feat", "--web"], captured[0]
      assert_equal "/wt/feat", captured[1][:chdir]
    end

    # O (open the row's repo) needs no branch, so it works on every row kind. It no
    # longer rides the footer (one line now) — it lives in the ? overlay's action list.
    def test_overlay_advertises_O_repo
      sb = sidebar(nodes: [proj("app")])
      stub_method(Tmux, :pane_switch_keys, -> { [] }) do
        lines = sb.send(:help_lines, 40).map { |l| strip_ansi(l) }
        assert(lines.any? { |l| l.include?("O") && l.include?("open its repo") },
               "the overlay lists O (open repo)")
      end
    end

    # --- reload_config_and_rebuild: the post-edit (Ctrl-R) reload -------------
    # `e` lets you hand-edit raw YAML, so a syntax slip is expected. A bad save
    # must NOT tear the sidebar down: keep the last good @config and surface the
    # error on tmux's status line (Tmux.notify) instead.

    def test_reload_config_and_rebuild_keeps_last_good_config_on_bad_yaml
      File.write(Config.path, YAML.dump("worktree_root" => "~/wt", "projects" => []))
      sb = sidebar(nodes: [])
      good = Config.new
      sb.instance_variable_set(:@config, good)

      File.write(Config.path, "a: : :\n  - broken") # now invalid YAML
      captured = nil
      stub_method(Tmux, :notify, ->(msg) { captured = msg }) do
        sb.send(:reload_config_and_rebuild)
      end

      assert_same good, sb.instance_variable_get(:@config), "kept the last good config on a parse error"
      assert_match(/config not reloaded/, captured.to_s, "surfaced the error via tmux notify")
    end

    # --- edit_config: the `e` command handed to edit_in_home ------------------
    # The editor is left UNescaped so the spawned shell resolves $EDITOR at run
    # time (the nvim fix); the path is escaped; the trailer returns to origin and
    # pokes that sidebar to re-read config.
    def test_edit_config_builds_a_runtime_resolved_editor_command
      ENV["SWITCHBOARD_BIN"] = "/opt/sb"
      captured = nil
      stub_method(Tmux, :session_of, -> { "sb/app/feat" }) do
        stub_method(Tmux, :edit_in_home, ->(cmd) { captured = cmd }) do
          sidebar(nodes: []).send(:edit_config)
        end
      end
      assert captured.start_with?("${VISUAL:-${EDITOR:-vi}} "), "editor resolved by the spawned shell, not baked"
      assert_includes captured, Shellwords.escape(Config.path)
      assert_match(%r{/opt/sb reload-config sb/app/feat\z}, captured, "returns to origin + reloads on :q")
    end

    # Pressing `e` from outside tmux (or with no TMUX_PANE) makes Tmux.session_of
    # nil; .to_s collapses it to "", so the trailer still emits a reload-config
    # with an empty origin — which reload_config_poke special-cases back to HOME.
    # Must not raise and must still carry the trailer.
    def test_edit_config_tolerates_a_nil_origin_session
      captured = nil
      stub_method(Tmux, :session_of, -> { nil }) do
        stub_method(Tmux, :edit_in_home, ->(cmd) { captured = cmd }) do
          sidebar(nodes: []).send(:edit_config)
        end
      end
      assert_match(/reload-config\s*('')?\z/, captured.to_s, "empty origin still produces a reload trailer")
    end

    # --- n (background dispatch) and switch -----------------------------------

    # A sidebar whose @config is the given YAML data.
    def sidebar_with_config(data, nodes: [proj("app")])
      File.write(Config.path, YAML.dump(data))
      sb = sidebar(nodes: nodes)
      sb.instance_variable_set(:@config, Config.new)
      sb
    end

    # REGRESSION: setup runs once per WORKTREE, not once per session. Re-entering an
    # existing workspace must carry the agent command only.
    def test_switch_never_carries_the_setup_command
      sb = sidebar_with_config({ "session_command" => "claude",
                                 "projects" => [{ "name" => "app", "path" => "/p",
                                                  "worktree_creation_command" => "bundle install" }] },
                               nodes: [proj("app"), ws("a", path: "/wt/a")])
      captured = :unset
      stub_method(Tmux, :go, ->(_wt, start:) { captured = start }) do
        sb.send(:switch, ws("a", path: "/wt/a"))
      end
      assert_equal "claude", captured, "switching into an existing workspace must not re-run setup"
    end

    # Value: protects=re-entering a workspace whose session died starts a `{task}` session_command as the bare command; fails_when=entry_command passes session_command_for raw, typing a literal `{task}` that the agent reads as its prompt; why_new=switch tests use a plain `claude`; {task} substitution is tested only in the launcher; seam=none; no_claim=quote-context substitution
    def test_switch_resolves_a_task_template_to_the_bare_command
      sb = sidebar_with_config({ "session_command" => "claude --model opus {task}",
                                 "projects" => [{ "name" => "app", "path" => "/p" }] },
                               nodes: [proj("app"), ws("a", path: "/wt/a")])
      captured = :unset
      stub_method(Tmux, :go, ->(_wt, start:) { captured = start }) do
        sb.send(:switch, ws("a", path: "/wt/a"))
      end
      assert_equal "claude --model opus", captured.strip, "no literal {task} reaches the shell"
    end

    # n is a dispatch: it records the build, spawns the detached worker and returns —
    # no git, no tmux switch on the input loop. The setup + agent contract it used to
    # compose now lives in the launcher (creator_dispatch_test ports every assertion).
    def test_create_spawns_the_worker_and_never_switches
      sb = sidebar_with_config({ "worktree_root" => path("wts"), "session_command" => "claude",
                                 "projects" => [{ "name" => "app", "path" => temp_git_repo("app", origin: true) }] })
      spawned = nil
      switched = false
      ENV["SWITCHBOARD_BIN"] = "/bin/switchboard"
      stub_method(sb, :prompt_line, ->(*_a, **_k) { "fix the flaky test" }) do
        stub_method(Process, :spawn, ->(*args, **_o) { spawned = args; 4242 }) do
          stub_method(Process, :detach, ->(_pid) {}) do
            stub_method(Tmux, :go, ->(*_a, **_k) { switched = true }) do
              stub_method(Tmux, :broadcast_warm, ->(**_k) {}) do
                stub_method(sb, :reload, -> {}) { sb.send(:create, proj("app")) }
              end
            end
          end
        end
      end
      rec = Creation.all.first
      assert_equal "fix the flaky test", rec["task"]
      assert_equal "queued", rec["state"]
      assert_equal ["/bin/switchboard", "create-workspace", rec["id"]], spawned
      refute switched, "dispatch never switches you into the new workspace"
    end

    def test_create_esc_dispatches_nothing
      sb = sidebar_with_config({ "worktree_root" => path("wts"),
                                 "projects" => [{ "name" => "app", "path" => "/p" }] })
      stub_method(sb, :prompt_line, ->(*_a, **_k) {}) { sb.send(:create, proj("app")) }
      assert_empty Creation.all
    end

    def test_create_asks_for_a_task_naming_the_project
      sb = sidebar_with_config({ "projects" => [{ "name" => "app", "path" => "/p" }] })
      seen = nil
      stub_method(sb, :prompt_line, lambda { |label, hint:, task:|
        seen = [label, hint, task]
        nil
      }) { sb.send(:create, proj("app")) }
      assert_equal ["app task", " (↵ = no task · esc)", true], seen
    end

    def test_create_without_the_wrapper_fails_the_record_at_once
      sb = sidebar_with_config({ "worktree_root" => path("wts"),
                                 "projects" => [{ "name" => "app", "path" => temp_git_repo("app", origin: true) }] })
      ENV.delete("SWITCHBOARD_BIN")
      stub_method(sb, :prompt_line, ->(*_a, **_k) { "" }) do
        stub_method(Tmux, :broadcast_warm, ->(**_k) {}) do
          stub_method(sb, :reload, -> {}) { sb.send(:create, proj("app")) }
        end
      end
      rec = Creation.all.first
      assert_equal "failed", rec["state"]
      assert_equal "didnt_start", rec["reason"]
    end

    # D12: re-entering a dispatched workspace whose setup failed (its session gone after
    # a quit) opens a plain shell with the reason, never the agent.
    def test_switch_into_a_failed_dispatch_opens_a_plain_shell
      sb = sidebar_with_config({ "session_command" => "claude",
                                 "projects" => [{ "name" => "app", "path" => "/p" }] },
                               nodes: [proj("app"), ws("a", path: "/wt/a")])
      rec = Creation.create(project: "app", name: "a", path: "/wt/a", task: "")
      Creation.transition(rec["id"], from: :queued, to: :launching)
      Creation.mark_failed(rec["id"], "setup", 1, from: "launching")
      sb.send(:index_creations, Creation.all)
      captured = :unset
      stub_method(Tmux, :go, ->(_wt, start:) { captured = start }) { sb.send(:switch, ws("a", path: "/wt/a")) }
      refute_includes captured, "claude"
      assert_equal ["echo", "switchboard: setup did not succeed (setup exit 1), so switchboard won't start the agent here; finish setup and start it by hand, or press d on the row"],
                   Shellwords.split(captured)
    end

    # Setup DID succeed (the agent exited fast, or a quit landed in the grace): the tree
    # is set up, so re-entering it starts the agent like any other workspace.
    def test_switch_into_a_set_up_but_canceled_dispatch_starts_the_agent
      sb = sidebar_with_config({ "session_command" => "claude",
                                 "projects" => [{ "name" => "app", "path" => "/p" }] },
                               nodes: [proj("app"), ws("a", path: "/wt/a")])
      rec = Creation.create(project: "app", name: "a", path: "/wt/a", task: "")
      Creation.transition(rec["id"], from: :queued, to: :launching, worktree_added: true, setup_ok: true)
      Creation.cancel_all
      sb.send(:index_creations, Creation.all)
      captured = :unset
      stub_method(Tmux, :go, ->(_wt, start:) { captured = start }) { sb.send(:switch, ws("a", path: "/wt/a")) }
      assert_equal "claude", captured
    end

    # The same guard after a quit mid-setup: the build was canceled, not failed, but its
    # setup never finished either.
    def test_switch_into_a_canceled_dispatch_opens_a_plain_shell
      sb = sidebar_with_config({ "session_command" => "claude",
                                 "projects" => [{ "name" => "app", "path" => "/p" }] },
                               nodes: [proj("app"), ws("a", path: "/wt/a")])
      rec = Creation.create(project: "app", name: "a", path: "/wt/a", task: "")
      Creation.transition(rec["id"], from: :queued, to: :launching, worktree_added: true)
      Creation.cancel_all
      sb.send(:index_creations, Creation.all)
      captured = :unset
      stub_method(Tmux, :go, ->(_wt, start:) { captured = start }) { sb.send(:switch, ws("a", path: "/wt/a")) }
      refute_includes captured, "claude"
      assert_equal ["echo", Creation.notice(:reentry_canceled)], Shellwords.split(captured)
    end

    # Value: protects=re-entering a build still in flight (its session died mid-setup) never starts the agent; fails_when=entry_command guards only failed/canceled records; why_new=the switch guards were tested only for terminal states; seam=none; no_claim=GC later marking the build interrupted
    def test_switch_into_a_build_still_in_flight_opens_a_plain_shell
      %w[building launching].each do |state|
        Creation.all.each { |r| Creation.delete(r["id"]) }
        sb = sidebar_with_config({ "session_command" => "claude",
                                   "projects" => [{ "name" => "app", "path" => "/p" }] },
                                 nodes: [proj("app"), ws("a", path: "/wt/a")])
        rec = Creation.create(project: "app", name: "a", path: "/wt/a", task: "")
        Creation.transition(rec["id"], from: :queued, to: state, worktree_added: true)
        sb.send(:index_creations, Creation.all)
        captured = :unset
        stub_method(Tmux, :go, ->(_wt, start:) { captured = start }) { sb.send(:switch, ws("a", path: "/wt/a")) }
        assert_equal ["echo", Creation.notice(:reentry_building)], Shellwords.split(captured), state
      end
    end
  end
end
