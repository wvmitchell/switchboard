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

    # --- start_command: the setup script + the agent (#83) -------------------
    #
    # What `n` types into a NEW worktree's window. The setup script is handed to
    # `sh -ec` as ONE argument (so a multi-line script stays valid shell) and only
    # the wrapper joins the `&&` — so a failed setup means the agent never starts.

    # A sidebar whose @config is the given YAML data.
    def sidebar_with_config(data, nodes: [proj("app")])
      File.write(Config.path, YAML.dump(data))
      sb = sidebar(nodes: nodes)
      sb.instance_variable_set(:@config, Config.new)
      sb
    end

    def test_start_command_wraps_setup_and_chains_the_agent
      sb = sidebar_with_config({ "session_command" => "claude",
                                "projects" => [{ "name" => "app", "path" => "/p",
                                                 "worktree_creation_command" => "bundle install" }] })
      assert_equal "env SWITCHBOARD_PROJECT_PATH=/p sh -ec bundle\\ install && claude",
                   sb.send(:start_command, "app", nil)
    end

    # The escaping has to survive a real multi-line script — that's the whole reason
    # for the sh -ec wrapper instead of splicing the script into the && chain.
    def test_start_command_survives_a_multiline_script
      script = "if [ -f ../.env ]; then\n  cp ../.env .\nfi"
      sb = sidebar_with_config({ "session_command" => "claude",
                                "projects" => [{ "name" => "app", "path" => "/p",
                                                 "worktree_creation_command" => script }] })
      start = sb.send(:start_command, "app", "/wt/new")
      assert_equal ["env", "SWITCHBOARD_PROJECT_PATH=/p", "SWITCHBOARD_WORKTREE_PATH=/wt/new",
                    "sh", "-ec", script, "&&", "claude"], Shellwords.split(start),
                   "the script reaches sh -ec as ONE argument, verbatim"
    end

    # The composed line is typed into an interactive shell, so an apostrophe in the script
    # (`echo "it's done"`, a path like /Users/o'brien) is the classic escaping trap — the
    # same one CLAUDE.md calls out for the codex TOML block. Shellwords must neutralize it.
    def test_start_command_survives_an_apostrophe_in_the_script
      script = "echo it's done"
      sb = sidebar_with_config({ "session_command" => "claude",
                                 "projects" => [{ "name" => "app", "path" => "/p",
                                                  "worktree_creation_command" => script }] })
      assert_equal ["env", "SWITCHBOARD_PROJECT_PATH=/p", "sh", "-ec", script, "&&", "claude"],
                   Shellwords.split(sb.send(:start_command, "app", nil)),
                   "an apostrophe survives the round-trip as ONE argument"
    end

    def test_start_command_setup_alone_when_no_session_command
      sb = sidebar_with_config({ "projects" => [{ "name" => "app", "path" => "/p",
                                                 "worktree_creation_command" => "bundle install" }] })
      assert_equal "env SWITCHBOARD_PROJECT_PATH=/p sh -ec bundle\\ install", sb.send(:start_command, "app", nil)
    end

    def test_start_command_is_just_the_session_command_when_no_setup
      sb = sidebar_with_config({ "session_command" => "claude",
                                "projects" => [{ "name" => "app", "path" => "/p" }] })
      assert_equal "claude", sb.send(:start_command, "app", nil)
    end

    # REGRESSION: "" is truthy in Ruby, and Tmux gates the send-keys on `if start &&
    # created` — so an empty compose would type a bare Enter into every new worktree
    # shell on the DEFAULT config (no setup, no session_command). It must be nil.
    def test_start_command_is_nil_not_empty_string_when_nothing_is_configured
      sb = sidebar_with_config({ "projects" => [{ "name" => "app", "path" => "/p" }] })
      assert_nil sb.send(:start_command, "app", nil), "an empty compose must be nil, or tmux types a bare Enter"
    end

    # REGRESSION: `session_command: false` (the config's disable idiom — YAML hands us the
    # boolean, and `Config#session_command` passes it through) must stay OFF. `compact`
    # alone would keep it, join it into the literal word `false`, and type that into every
    # new worktree's shell — a regression on a config that has nothing to do with #83.
    # Tmux's `if start && created` gate used to swallow the raw false; once it's part of a
    # joined String it's just another truthy token.
    def test_start_command_ignores_a_false_session_command
      sb = sidebar_with_config({ "session_command" => false,
                                 "projects" => [{ "name" => "app", "path" => "/p" }] })
      assert_nil sb.send(:start_command, "app", nil), "a false session_command is OFF, not the word `false`"

      with_setup = sidebar_with_config({ "session_command" => false,
                                         "projects" => [{ "name" => "app", "path" => "/p",
                                                          "worktree_creation_command" => "bundle install" }] })
      refute_includes with_setup.send(:start_command, "app", nil).to_s, "false",
                      "and it must not tack `&& false` onto the setup script"
    end

    # The worktree lives under worktree_root; the project's checkout lives wherever it's
    # registered — two unrelated trees, so a setup script has NO relative way to reach the
    # checkout it wants to copy .env out of. Switchboard hands both paths over.
    def test_start_command_exports_the_project_and_worktree_paths_to_the_script
      sb = sidebar_with_config({ "projects" => [{ "name" => "app", "path" => "/repos/app",
                                                  "worktree_creation_command" =>
                                                    'cp "$SWITCHBOARD_PROJECT_PATH/.env" .' }] })
      parts = Shellwords.split(sb.send(:start_command, "app", "/wt/new"))
      assert_equal %w[env SWITCHBOARD_PROJECT_PATH=/repos/app SWITCHBOARD_WORKTREE_PATH=/wt/new sh -ec],
                   parts.first(5), "env (not a bare VAR=v prefix, which fish rejects) exports both paths"
      assert_equal 'cp "$SWITCHBOARD_PROJECT_PATH/.env" .', parts.last,
                   "the script is still ONE argument, and its $VAR is left for the sh child to expand"
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

    # The create path (`n`, and filter-mode ↵ on a project header) is the ONE place
    # the setup script is composed in.
    def test_create_passes_the_composed_start_command_to_tmux
      sb = sidebar_with_config({ "session_command" => "claude",
                                "projects" => [{ "name" => "app", "path" => "/p",
                                                 "worktree_creation_command" => "bundle install" }] })
      captured = :unset
      stub_method(Creator, :create, ->(*) { "/wt/new" }) do
        stub_method(Tmux, :go, ->(_wt, start:) { captured = start }) do
          capture_io { sb.send(:create, proj("app")) }
        end
      end
      assert_equal "env SWITCHBOARD_PROJECT_PATH=/p SWITCHBOARD_WORKTREE_PATH=/wt/new sh -ec bundle\\ install && claude",
                   captured
    end
  end
end
