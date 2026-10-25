# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # `switchboard upgrade`. brew and the exec hand-off are stubbed (the real ones would
  # change the machine / replace the test process); the clone path runs real git against
  # a local upstream.
  class UpgradeTest < SandboxTest
    def quietly
      orig = $stdout
      $stdout = StringIO.new
      result = yield
      [result, $stdout.string]
    ensure
      $stdout = orig
    end

    # Runs a brew-flavored upgrade with every outside effect stubbed, recording them.
    def brew_upgrade(method: :brew, latest: "9.9.9", stamps: %w[old new], ok: ->(_argv) { true }, leftovers: false)
      ran = []
      handed = false
      stamps = stamps.dup
      looked_up = false
      result, out = stub_method(Upgrade, :install_method, -> { method }) do
        stub_method(LatestRelease, :latest, ->(**) { looked_up = true; latest }) do
          stub_method(Upgrade, :stamp, ->(_m) { stamps.shift }) do
            stub_method(Upgrade, :system, ->(*argv) { ran << argv; ok.call(argv) }) do
              stub_method(Upgrade, :leftovers?, -> { leftovers }) do
                # Only the leftovers call reads as :finished, so every test that expects it also
                # pins the call shape (a hand-off finish would pass the old version instead).
                stub_method(Upgrade, :finish, ->(*a, **k) { a == [nil] && k == { leftovers: true } ? :finished : [:finish, a, k] }) do
                  stub_method(Upgrade, :handoff, -> { handed = true }) { quietly { Upgrade.run } }
                end
              end
            end
          end
        end
      end
      { ran: ran, handed: handed, result: result, out: out, looked_up: looked_up }
    end

    def test_a_newer_release_runs_brew_then_hands_off_to_the_new_binary
      r = brew_upgrade
      assert_equal [%w[brew update], %w[brew upgrade switchboard]], r[:ran]
      assert r[:handed]
    end

    # Value: protects=a failed `brew upgrade` stopping before anything is re-wired, while a
    # failed `brew update` (any unrelated tap that can't fetch) never blocks it; fails_when=
    # the update is a hard step again, or the upgrade's failure is ignored; why_new=Red Team
    # run 4 (D4); seam=none; no_claim=real brew output
    def test_a_failed_brew_step_stops_before_anything_is_rewired
      r = brew_upgrade(ok: ->(argv) { argv != %w[brew upgrade switchboard] })
      assert_equal [%w[brew update], %w[brew upgrade switchboard]], r[:ran]
      refute r[:handed]
      refute r[:result]

      r = brew_upgrade(ok: ->(argv) { argv != %w[brew update] })
      assert_equal [%w[brew update], %w[brew upgrade switchboard]], r[:ran], "a failed update still tries the upgrade"
      assert r[:handed], "the keg moved, so the new binary finishes"
      assert_includes r[:out], "`brew update` failed"
    end

    # Value: protects=a failed `brew upgrade` stopping the run even when `brew update` failed
    # too; fails_when=a failed update makes fetch ignore the upgrade's exit; why_new=coverage
    # audit (proposed test 1); seam=stamp; no_claim=real brew output
    def test_a_failed_update_and_upgrade_stop_without_a_hand_off
      r = brew_upgrade(ok: ->(_argv) { false })
      assert_equal [%w[brew update], %w[brew upgrade switchboard]], r[:ran]
      refute r[:handed], "a failed upgrade never hands off, whatever the stamp says"
      refute r[:result]
    end

    # Value: protects=no false "upgraded" when the tag is out but the tap formula isn't
    # yet; fails_when=the moved-check is dropped; why_new=new (D4); seam=stamp
    def test_a_tag_brew_doesnt_have_yet_says_so_without_finishing
      r = brew_upgrade(stamps: %w[same same])
      refute r[:handed]
      assert r[:result]
      assert_includes r[:out], "9.9.9 is tagged, but Homebrew doesn't have it yet"
    end

    def test_already_current_says_so_and_runs_nothing
      r = brew_upgrade(latest: VERSION)
      assert_empty r[:ran]
      refute r[:handed]
      assert r[:result]
      assert_includes r[:out], "#{VERSION} is up to date — run `switchboard doctor` if something seems off."
    end

    # Value: protects=re-running upgrade repairing one interrupted after brew; fails_when=
    # the up-to-date path exits without the leftovers check; why_new=new (D15); seam=leftovers?
    def test_already_current_with_unfinished_setup_finishes_it
      r = brew_upgrade(latest: VERSION, leftovers: true)
      assert_equal :finished, r[:result]
      assert_empty r[:ran]
    end

    # Value: protects=upgrade never calling itself current over a config it couldn't read;
    # fails_when=either nothing-to-fetch exit skips config_readable?; why_new=a broken config
    # listed no worktrees, so leftovers? said false and upgrade printed "up to date"; seam=none
    def test_a_config_that_wont_parse_fails_instead_of_reading_as_up_to_date
      File.write(Config.path, "--\nprojects:\n  - name: app\n")
      [brew_upgrade(latest: VERSION), brew_upgrade(stamps: %w[same same])].each do |r|
        refute r[:result]
        assert_includes r[:out], "config failed to parse ("
        refute_includes r[:out], "is up to date"
        refute r[:handed]
      end
    end

    # Value: protects=a broken config never blocks repairs that don't need it (tmux, codex,
    # reporter); fails_when=the config check returns before finish(leftovers:); why_new=ship 2
    # red team (D5); seam=leftovers?/finish (finish's own failure on the config is pinned in
    # installer_refresh_test)
    def test_a_broken_config_still_finishes_leftover_setup
      File.write(Config.path, "--\nprojects:\n")
      [brew_upgrade(latest: VERSION, leftovers: true), brew_upgrade(stamps: %w[same same], leftovers: true)].each do |r|
        assert_equal :finished, r[:result], "leftover setup still finished"
        refute_includes r[:out], "is up to date"
      end
    end

    def test_an_unreachable_release_list_lets_brew_decide
      r = brew_upgrade(latest: nil)
      assert_includes r[:out], "couldn't check for a newer release"
      assert_equal [%w[brew update], %w[brew upgrade switchboard]], r[:ran]
    end

    def test_a_head_install_fetches_head_and_skips_the_tag_lookup
      r = brew_upgrade(method: :brew_head)
      assert_equal [%w[brew upgrade --fetch-HEAD switchboard]], r[:ran]
      refute r[:looked_up]
      assert r[:handed]
    end

    # Value: protects=a release keg whose path merely contains "HEAD" staying on the release
    # channel; fails_when=the keg regex loosens past `switchboard/HEAD-`; why_new=only clean
    # paths were checked; seam=none; no_claim=non-Homebrew prefixes
    def test_a_head_keg_is_detected_from_the_install_path
      stub_method(Installer, :homebrew?, -> { true }) do
        stub_method(Installer, :real_root, -> { "/opt/homebrew/Cellar/switchboard/HEAD-0759e86/libexec" }) do
          assert_equal :brew_head, Upgrade.install_method
        end
        stub_method(Installer, :real_root, -> { "/opt/homebrew/Cellar/switchboard/0.51.1/libexec" }) do
          assert_equal :brew, Upgrade.install_method
        end
        %w[/opt/homebrew/Cellar/switchboard/0.52.0/libexec/HEADER/bin
           /opt/homebrew/Cellar/switchboard/0.52.0/HEAD-notes].each do |keg|
          stub_method(Installer, :real_root, -> { keg }) do
            assert_equal :brew, Upgrade.install_method, keg
          end
        end
      end
    end

    # --- clone (real git) ----------------------------------------------------

    # A clone tracking origin/main, with origin one commit ahead unless `behind: false`.
    def clone_install(behind: true)
      repo = temp_git_repo("switchboard", origin: true)
      git(repo, "branch", "-q", "--set-upstream-to=origin/main")
      if behind
        other = path("other")
        git(nil, "clone", "-q", "#{repo}.git", other)
        git(other, "config", "user.email", "t@example.com")
        git(other, "config", "user.name", "T")
        File.write(File.join(other, "new.rb"), "x\n")
        git(other, "add", "-A")
        git(other, "commit", "-q", "-m", "next")
        git(other, "push", "-q", "origin", "main")
      end
      repo
    end

    def clone_upgrade(repo)
      handed = false
      result, out = stub_method(Upgrade, :install_method, -> { :clone }) do
        stub_method(Installer, :repo_root, -> { repo }) do
          stub_method(Upgrade, :leftovers?, -> { false }) do
            stub_method(Upgrade, :handoff, -> { handed = true }) { quietly { Upgrade.run } }
          end
        end
      end
      { handed: handed, result: result, out: out }
    end

    def test_a_clone_behind_its_upstream_fast_forwards_then_hands_off
      repo = clone_install
      r = clone_upgrade(repo)
      assert r[:handed]
      assert File.exist?(File.join(repo, "new.rb")), "pulled"
    end

    def test_a_clone_level_with_its_upstream_is_up_to_date
      r = clone_upgrade(clone_install(behind: false))
      refute r[:handed]
      assert_includes r[:out], "is up to date"
    end

    def test_a_clone_with_tracked_changes_is_left_alone
      repo = clone_install
      File.write(File.join(repo, "README.md"), "local edit\n")
      r = clone_upgrade(repo)
      refute r[:handed]
      refute r[:result]
      assert_includes r[:out], "uncommitted changes"
      refute File.exist?(File.join(repo, "new.rb"))
    end

    def test_untracked_files_dont_block_a_clone_pull
      repo = clone_install
      File.write(File.join(repo, "scratch.txt"), "notes\n")
      assert clone_upgrade(repo)[:handed]
    end

    # Value: protects=a clone with its own commits AND new upstream commits never being merged
    # or rebased by upgrade; fails_when=clone_pull drops --ff-only (every other clone test
    # still passes); why_new=run-5 cycle-2 testing specialist; seam=none
    # Value: protects=an ignored local file (never committed, so unrecoverable) that the update
    # adds as a tracked path; git's fast-forward would overwrite it silently; fails_when=the
    # clone path goes back to an unchecked pull/merge; why_new=run-5 Codex adversarial
    # (reproduced); seam=none
    def test_an_update_that_would_overwrite_an_ignored_file_is_refused
      repo = clone_install # upstream adds new.rb
      File.write(File.join(repo, ".git", "info", "exclude"), "new.rb\n")
      File.write(File.join(repo, "new.rb"), "my notes\n")
      head = git(repo, "rev-parse", "HEAD")
      r = clone_upgrade(repo)
      refute r[:handed]
      refute r[:result]
      assert_includes r[:out], "merge --no-overwrite-ignore --ff-only @{upstream}` failed"
      assert_equal "my notes\n", File.read(File.join(repo, "new.rb")), "left untouched"
      assert_equal head, git(repo, "rev-parse", "HEAD")
    end

    # A clone whose upstream gets one more commit, built by `change` in a second clone.
    def push_upstream(repo, msg = "next")
      other = path("pusher-#{msg}")
      git(nil, "clone", "-q", "-b", "main", "#{repo}.git", other)
      git(other, "config", "user.email", "t@example.com")
      git(other, "config", "user.name", "T")
      yield other
      git(other, "add", "-A")
      git(other, "commit", "-q", "-m", msg)
      git(other, "push", "-q", "origin", "main")
    end

    # Value: protects=an ignored FILE at a parent of a path the update adds (git would delete
    # it to make the directory); fails_when=the merge loses --no-overwrite-ignore; why_new=run-6
    # security + state-machines (reproduced); seam=none
    def test_an_ignored_file_at_a_parent_of_an_incoming_path_is_kept
      repo = clone_install(behind: false)
      push_upstream(repo) { |o| FileUtils.mkdir_p(File.join(o, "cfg")); File.write(File.join(o, "cfg", "file"), "new\n") }
      File.write(File.join(repo, ".git", "info", "exclude"), "cfg\n")
      File.write(File.join(repo, "cfg"), "mine\n")
      head = git(repo, "rev-parse", "HEAD")
      r = clone_upgrade(repo)
      refute r[:handed]
      refute r[:result]
      assert_equal "mine\n", File.read(File.join(repo, "cfg"))
      assert_equal head, git(repo, "rev-parse", "HEAD")
    end

    # Value: protects=a plain untracked file the update adds (git refuses it on its own);
    # fails_when=the clone path starts forcing the merge; why_new=run-6 state-machines (no
    # untracked-incoming row); seam=none
    def test_an_untracked_file_the_update_adds_is_kept
      repo = clone_install # upstream adds new.rb
      File.write(File.join(repo, "new.rb"), "mine\n")
      r = clone_upgrade(repo)
      refute r[:handed]
      assert_equal "mine\n", File.read(File.join(repo, "new.rb"))
    end

    # Value: protects=an upstream rename by case only still upgrading on a case-insensitive
    # disk (macOS default); fails_when=a pre-merge existence check flags the tracked file as
    # a collision (the run-6 red-team bug in the removed check); why_new=red team; seam=none;
    # no_claim=case-sensitive filesystems (passes trivially there)
    def test_a_case_only_rename_upstream_still_upgrades
      repo = temp_git_repo("switchboard", origin: true)
      git(repo, "branch", "-q", "--set-upstream-to=origin/main")
      push_upstream(repo, "rename") { |o| git(o, "mv", "-f", "README.md", "Readme.md") } # the seed file
      r = clone_upgrade(repo)
      assert r[:handed], r[:out]
    end

    # Value: protects=clone_pull's own fetch failing (offline remote) stopping before any merge
    # or hand-off; fails_when=the merge runs after a failed fetch; why_new=run-6
    # state-machines (only the bounded pre-check's failure was tested); seam=none
    def test_a_clone_whose_fetch_fails_stops_before_merging
      repo = clone_install
      git(repo, "remote", "set-url", "origin", path("gone.git"))
      head = git(repo, "rev-parse", "HEAD")
      r = stub_method(Upgrade, :clone_behind?, -> { nil }) { clone_upgrade(repo) }
      refute r[:handed]
      refute r[:result]
      assert_includes r[:out], "fetch` failed"
      refute_includes r[:out], "merge --no-overwrite-ignore"
      assert_equal head, git(repo, "rev-parse", "HEAD")
    end

    # Value: protects=a clone on a detached HEAD (a pinned tag) never being moved by upgrade;
    # fails_when=the clone path checks out or resets to the upstream; why_new=run-6
    # state-machines (untested cell); seam=none
    def test_a_detached_clone_is_left_where_it_is
      repo = clone_install
      git(repo, "checkout", "-q", "--detach")
      head = git(repo, "rev-parse", "HEAD")
      r = clone_upgrade(repo)
      refute r[:handed]
      refute r[:result]
      assert_equal head, git(repo, "rev-parse", "HEAD")
    end

    # Value: protects=a clone with only local commits (nothing new upstream) reading up to
    # date and keeping them; fails_when=the behind check counts the wrong direction (would
    # merge or report behind); why_new=run-6 state-machines (untested cell); seam=none
    def test_a_clone_ahead_of_its_upstream_is_up_to_date
      repo = clone_install(behind: false)
      File.write(File.join(repo, "local.rb"), "y\n")
      git(repo, "add", "-A")
      git(repo, "commit", "-q", "-m", "local")
      head = git(repo, "rev-parse", "HEAD")
      r = clone_upgrade(repo)
      refute r[:handed]
      assert_includes r[:out], "is up to date"
      assert_equal head, git(repo, "rev-parse", "HEAD")
    end

    def test_a_diverged_clone_is_never_merged
      repo = clone_install
      File.write(File.join(repo, "local.rb"), "y\n")
      git(repo, "add", "-A")
      git(repo, "commit", "-q", "-m", "local")
      head = git(repo, "rev-parse", "HEAD")
      r = clone_upgrade(repo)
      refute r[:handed]
      refute r[:result]
      assert_equal head, git(repo, "rev-parse", "HEAD"), "no merge or rebase happened"
      refute File.exist?(File.join(repo, "new.rb"))
    end

    # --- hand-off and finish -----------------------------------------------------

    def test_a_new_binary_that_wont_start_says_how_to_finish
      result, out = stub_method(Upgrade, :exec, ->(*) { raise Errno::ENOENT, "switchboard" }) { quietly { Upgrade.handoff } }
      refute result
      assert_includes out, "re-run `switchboard upgrade` to finish"
    end

    def finish(from, hooks: true, codex: true, tmux: true)
      stub_method(Installer, :refresh_wiring, -> { hooks }) do
        stub_method(Upgrade, :refresh_codex, -> { codex }) do
          stub_method(Upgrade, :reload_tmux, -> { tmux }) { quietly { Upgrade.finish(from) } }
        end
      end
    end

    def test_finishing_an_upgrade_names_both_versions_and_the_sidebar_restart
      ok, out = finish("0.1.0")
      assert ok
      assert_includes out, "0.1.0 → #{VERSION}"
      assert_includes out, "press prefix-s twice in each switchboard session"
    end

    # Value: protects=the restart hint after a clone pull that didn't bump version.rb (a
    # real hand-off always means new code); fails_when=the hint keys off a version change
    # again; why_new=D1 item 8; seam=none
    def test_any_hand_off_gets_the_sidebar_hint_even_without_a_version_bump
      _, out = finish(VERSION)
      assert_includes out, "press prefix-s twice"
    end

    # Value: protects=the sidebar-restart hint naming the toggle key the user actually has bound;
    # fails_when=the hint hardcodes prefix-s (or reads only the configured key); why_new=every
    # finish test runs with the default key, so a hardcoded `s` passed them; seam=none
    def test_the_sidebar_hint_names_the_bound_toggle_key
      _, out = stub_method(Installer, :bound_toggle_key, -> { "F13" }) { finish("0.1.0") }
      assert_includes out, "press prefix-F13 twice"
    end

    # Value: protects=an up-to-date re-run saying it is finishing stale setup, not that it is
    # up to date; fails_when=finish ignores leftovers: or the old "is up to date, but its setup
    # isn't" wording returns; why_new=coverage gap; seam=none; no_claim=what the steps do
    def test_finishing_leftover_setup_says_setup_isnt_current
      _, out = stub_method(Installer, :refresh_wiring, -> { true }) do
        stub_method(Upgrade, :refresh_codex, -> { true }) do
          stub_method(Upgrade, :reload_tmux, -> { true }) { quietly { Upgrade.finish(nil, leftovers: true) } }
        end
      end
      assert_includes out, "setup isn't current"
      refute_includes out, "is up to date"
    end

    def test_finishing_leftover_setup_skips_the_sidebar_hint
      _, out = stub_method(Installer, :refresh_wiring, -> { true }) do
        stub_method(Upgrade, :refresh_codex, -> { true }) do
          stub_method(Upgrade, :reload_tmux, -> { true }) { quietly { Upgrade.finish(nil, leftovers: true) } }
        end
      end
      refute_includes out, "Running sidebars still have", "no new code was loaded"
    end

    def test_any_failed_finish_step_fails_the_upgrade
      refute finish("0.1.0", hooks: false).first
      refute finish("0.1.0", codex: false).first
      refute finish("0.1.0", tmux: false).first
    end

    def test_the_finish_flag_routes_to_finish
      got = nil
      stub_method(Upgrade, :finish, ->(from, **) { got = from }) { Upgrade.run(["--finish", "0.1.0"]) }
      assert_equal "0.1.0", got
    end

    def test_codex_is_left_alone_when_the_user_never_opted_in
      stub_method(CodexHook, :install_global, -> { flunk "must not write codex config" }) do
        assert Upgrade.refresh_codex
      end
    end

    # Value: protects=a dogfood checkout never counting (or rewriting) the shared reporter
    # as its own; fails_when=the installed-binary gate on the reporter is dropped;
    # why_new=D1 item 4; seam=installed_bin? (PATH lookup)
    def test_leftovers_include_a_stale_reporter_script_only_for_the_installed_binary
      File.write(HookFile.ensure_script, "#!/bin/sh\n# old\n")
      stub_method(Installer, :wired_fragment, ->(*) { nil }) do
        stub_method(Installer, :installed_bin?, -> { true }) { assert Upgrade.leftovers? }
        stub_method(Installer, :installed_bin?, -> { false }) { refute Upgrade.leftovers? }
      end
    end

    # Generated by /ship coverage audit.
    # Value: protects=re-running upgrade noticing a re-trust codex needs after its block
    # changed; fails_when=staleness is read after the rewrite (always current) or the note
    # dropped; why_new=refresh_codex was only tested opted-out; seam=none; no_claim=codex's
    # own trust check (a real config.toml in the sandboxed CODEX_HOME)
    def test_a_changed_codex_block_is_rewritten_and_asks_for_trust_once
      ENV["SWITCHBOARD_BIN"] = "/old/bin/switchboard"
      CodexHook.install_global
      ENV["SWITCHBOARD_BIN"] = "/new/bin/switchboard"
      stub_method(Installer, :installed_bin?, -> { false }) do
        assert Upgrade.refresh_codex
        assert_equal :stale, CodexHook.block_state, "another binary never repoints the global block"
      end
      ok, out = stub_method(Installer, :installed_bin?, -> { true }) { quietly { Upgrade.refresh_codex } }
      assert ok
      assert_equal :current, CodexHook.block_state
      assert_includes out, "run `/hooks` in codex once to trust them again"

      _, again = stub_method(Installer, :installed_bin?, -> { true }) { quietly { Upgrade.refresh_codex } }
      refute_includes again, "/hooks", "an unchanged block doesn't re-ask for trust"
    end

    # Generated by /ship coverage audit.
    # Value: protects=reload_tmux's outcome→exit mapping (a skip is fine, a failed reload
    # fails the upgrade); fails_when=a skip reads as failure or a false reload as success;
    # why_new=finish tests stub reload_tmux whole; seam=none; no_claim=the live reload (smoke)
    def test_reload_tmux_fails_only_when_a_reload_was_attempted_and_failed
      { unwired: true, no_server: true, true => true, false => false }.each do |outcome, want|
        ok, = stub_method(Installer, :reload_fragment, -> { outcome }) { quietly { Upgrade.reload_tmux } }
        assert_equal want, ok, outcome.inspect
      end
    end

    # Generated by /ship coverage audit.
    # Value: protects=an up-to-date re-run finishing stale worktree hooks or a server still
    # on old tmux wiring; fails_when=either leftovers? clause is dropped; why_new=only the
    # script and unwired-tmux clauses were tested; seam=installed_bin? (PATH lookup);
    # no_claim=the live tmux probes (live_hooks stubbed)
    def test_leftovers_include_stale_worktree_hooks_and_stale_live_tmux
      HookFile.ensure_script
      repo = temp_git_repo("app")
      File.write(Config.path, YAML.dump("projects" => [{ "name" => "app", "path" => repo }]))
      ENV["SWITCHBOARD_BIN"] = "/old/bin/switchboard"
      ClaudeHook.enable(repo)
      ENV["SWITCHBOARD_BIN"] = "/new/bin/switchboard"
      stub_method(Installer, :wired_fragment, ->(*) { nil }) do
        stub_method(Installer, :installed_bin?, -> { true }) { assert Upgrade.leftovers?, "stale worktree hooks" }
        stub_method(Installer, :installed_bin?, -> { false }) { refute Upgrade.leftovers?, "not ours to rewrite" }
      end

      stub_method(Installer, :installed_bin?, -> { false }) do
        stub_method(Installer, :wired_fragment, ->(*) { Installer.fragment_path }) do
          stub_method(Installer, :toggle_key_live?, ->(*) { true }) do
            stub_method(Installer, :tmux_version, -> { 3.4 }) do # not the host's tmux: CI's offline job has none
              stub_method(Installer, :live_hooks, -> { Installer::HOOK_SLOTS.to_h { |s| [s, s != Installer::HOOK_SLOTS.last] } }) do
                assert Upgrade.leftovers?, "a hook slot missing from the server"
              end
            end
            stub_method(Installer, :tmux_version, -> { 3.4 }) do # not the host's tmux
              stub_method(Installer, :live_hooks, -> { nil }) { refute Upgrade.leftovers?, "no server: nothing stale" }
            end
          end
        end
      end
    end

    def test_leftovers_ignore_tmux_when_tmux_isnt_wired_to_this_install
      HookFile.ensure_script
      stub_method(Installer, :installed_bin?, -> { false }) do
        stub_method(Installer, :wired_fragment, ->(*) { nil }) do
          stub_method(Installer, :live_hooks, -> { flunk "no server probe for an unwired install" }) do
            refute Upgrade.leftovers?
          end
        end
      end
    end

    # --- review fixes (D1) and the cells the reviewers found untested (D2) ----

    # Value: protects=a clone hand-off launched under system Ruby 2.6 still reaching a
    # modern Ruby; fails_when=SB_REEXEC (set by bin/switchboard's one-shot re-exec) leaks
    # into the new binary, which then loads lib/ under 2.6 and dies; why_new=D1 item 1;
    # seam=none (exec stubbed: a real one would replace the test process)
    def test_the_hand_off_lets_the_new_binary_re_exec_under_a_modern_ruby
      ENV["SB_REEXEC"] = "1"
      seen = :unset
      stub_method(Upgrade, :exec, ->(*) { seen = ENV["SB_REEXEC"] }) { quietly { Upgrade.handoff } }
      assert_nil seen
    end

    # Generated by /ship coverage audit.
    # Value: protects=the hand-off running the NEW binary's finish step; fails_when=exec drops
    # `--finish <old>` or execs something other than bin_path; why_new=exec was stubbed with
    # its args ignored; seam=none; no_claim=a real exec (would replace the test process)
    def test_the_hand_off_execs_the_installed_binary_into_finish_with_the_old_version
      argv = nil
      stub_method(Installer, :bin_path, -> { "/opt/homebrew/opt/switchboard/bin/switchboard" }) do
        stub_method(Upgrade, :exec, ->(*a) { argv = a }) { quietly { Upgrade.handoff } }
      end
      assert_equal ["/opt/homebrew/opt/switchboard/bin/switchboard", "upgrade", "--finish", VERSION], argv
    end

    # Generated by /ship coverage audit.
    # Value: protects=an upgrade whose install path vanished degrading to "unknown stamp"
    # (hand off) instead of a backtrace; fails_when=stamp's SystemCallError rescue is dropped;
    # why_new=every run test stubs stamp; seam=none; no_claim=how the path went missing
    def test_a_missing_install_path_stamps_unknown_instead_of_raising
      gone = path("gone", "switchboard")
      stub_method(Installer, :bin_path, -> { gone }) do
        assert_nil Upgrade.stamp(:brew)
      end
    end

    # Value: protects=`switchboard upgrade --dry-run` (or --help) never fetching, rewiring or
    # exec'ing; fails_when=the usage guard is dropped and the argument falls through to a run;
    # why_new=hardened: every machine-touching step is now stubbed and recorded, so a regressed
    # guard fails here instead of reaching brew/git or exec; seam=none; no_claim=usage wording
    def test_an_unknown_argument_never_runs_an_upgrade
      ran = []
      rec = ->(name, ret) { ->(*) { ran << name; ret } }
      stub_method(Upgrade, :install_method, rec.call(:install_method, :brew)) do
        stub_method(LatestRelease, :latest, ->(**) { ran << :latest; "999.0.0" }) do
          stub_method(Upgrade, :behind?, rec.call(:behind?, false)) do
            stub_method(Upgrade, :leftovers?, rec.call(:leftovers?, false)) do
              stub_method(Upgrade, :stamp, rec.call(:stamp, nil)) do
                stub_method(Upgrade, :fetch, rec.call(:fetch, false)) do
                  stub_method(Upgrade, :finish, rec.call(:finish, false)) do
                    stub_method(Upgrade, :handoff, rec.call(:handoff, false)) do
                      stub_method(Upgrade, :system, rec.call(:system, false)) do
                        _, err = capture_io { refute Upgrade.run(["--dry-run"]) }
                        assert_includes err, "usage: switchboard upgrade"
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
      assert_empty ran
    end

    def test_a_failed_head_fetch_stops
      r = brew_upgrade(method: :brew_head, ok: ->(_) { false })
      refute r[:handed]
      refute r[:result]
    end

    def test_a_head_install_with_no_new_commit_says_so_without_claiming_a_failed_check
      r = brew_upgrade(method: :brew_head, stamps: %w[same same])
      refute r[:handed]
      assert r[:result]
      assert_includes r[:out], "newest build of main"
      refute_includes r[:out], "couldn't check"
    end

    def test_a_clone_without_an_upstream_says_it_couldnt_check_and_fails_the_pull
      r = clone_upgrade(temp_git_repo("switchboard")) # no origin, no upstream
      assert_includes r[:out], "couldn't compare with your branch's upstream"
      refute r[:handed]
      refute r[:result]
    end

    def test_a_clone_with_nothing_to_pull_says_so
      repo = clone_install(behind: false)
      r = stub_method(Upgrade, :clone_behind?, -> { nil }) { clone_upgrade(repo) }
      refute r[:handed]
      assert r[:result]
      assert_includes r[:out], "newest commit on your branch"
    end

    def test_a_level_clone_with_unfinished_setup_finishes_it_without_pulling
      repo = clone_install(behind: false)
      head = git(repo, "rev-parse", "HEAD")
      got, = stub_method(Upgrade, :install_method, -> { :clone }) do
        stub_method(Installer, :repo_root, -> { repo }) do
          stub_method(Upgrade, :leftovers?, -> { true }) do
            stub_method(Upgrade, :finish, ->(*, **) { :finished }) { quietly { Upgrade.run } }
          end
        end
      end
      assert_equal :finished, got
      assert_equal head, git(repo, "rev-parse", "HEAD")
    end

    # Value: protects=an up-to-date run repairing an unbound toggle key or a stale codex
    # block; fails_when=either leftovers? clause is dropped; why_new=both were never tested
    # alone; seam=installed_bin? (PATH lookup)
    def test_leftovers_include_an_unbound_toggle_key_and_a_stale_codex_block
      HookFile.ensure_script
      stub_method(Installer, :installed_bin?, -> { false }) do
        stub_method(Installer, :wired_fragment, ->(*) { Installer.fragment_path }) do
          stub_method(Installer, :live_hooks, -> { Installer::HOOK_SLOTS.to_h { |s| [s, true] } }) do
            stub_method(Installer, :toggle_key_live?, ->(*) { false }) { assert Upgrade.leftovers?, "toggle key unbound" }
            stub_method(Installer, :toggle_key_live?, ->(*) { true }) { refute Upgrade.leftovers?, "all live" }
          end
        end
        ENV["SWITCHBOARD_BIN"] = "/old/bin/switchboard"
        CodexHook.install_global
        ENV["SWITCHBOARD_BIN"] = "/new/bin/switchboard"
        stub_method(Installer, :wired_fragment, ->(*) { nil }) { refute Upgrade.leftovers?, "not ours to rewrite" }
      end
      stub_method(Installer, :installed_bin?, -> { true }) do
        stub_method(Installer, :wired_fragment, ->(*) { nil }) { assert Upgrade.leftovers?, "stale codex block" }
      end
    end

    # Value: protects=an up-to-date run not looping forever when tmux rejected the configured
    # toggle key and switchboard bound its fallback; fails_when=leftovers? checks the
    # configured key instead of the one actually bound; why_new=D1 item 7; seam=tmux_option
    def test_leftovers_check_the_toggle_key_switchboard_actually_bound
      HookFile.ensure_script
      File.write(Config.path, YAML.dump("tmux_keys" => { "toggle" => "F13" }))
      asked = []
      stub_method(Installer, :installed_bin?, -> { false }) do
        stub_method(Installer, :wired_fragment, ->(*) { Installer.fragment_path }) do
          stub_method(Installer, :live_hooks, -> { Installer::HOOK_SLOTS.to_h { |s| [s, true] } }) do
            opts = { "@switchboard-toggle-key" => "s", "@switchboard-toggle-rejected" => "F13" }
            stub_method(Installer, :tmux_option, ->(name) { opts[name] }) do
              stub_method(Installer, :tmux_server?, -> { true }) do # so key_drift? really runs
                stub_method(Installer, :toggle_key_live?, ->(key = nil) { asked << key; key == "s" }) do
                  refute Upgrade.leftovers?
                end
              end
            end
          end
        end
      end
      assert_equal ["s"], asked
    end

    # Value: protects=an up-to-date upgrade applying a tmux_keys edited by hand (toggle or
    # home); fails_when=tmux_stale? checks only the bound toggle key; why_new=new (R4: the
    # bound key still worked, so upgrade said current); seam=tmux_option/tmux_server?
    def test_leftovers_include_a_hand_edited_tmux_key
      HookFile.ensure_script
      File.write(Config.path, YAML.dump("tmux_keys" => { "toggle" => "s", "home" => "H" }))
      opts = { "@switchboard-toggle-key" => "s", "@switchboard-home-key" => "S" }
      stub_method(Installer, :installed_bin?, -> { false }) do
        stub_method(Installer, :wired_fragment, ->(*) { Installer.fragment_path }) do
          stub_method(Installer, :live_hooks, -> { Installer::HOOK_SLOTS.to_h { |s| [s, true] } }) do
            stub_method(Installer, :toggle_key_live?, ->(*) { true }) do
              stub_method(Installer, :tmux_server?, -> { true }) do
                stub_method(Installer, :tmux_option, ->(name) { opts[name] }) do
                  assert Upgrade.leftovers?, "home edited from S to H by hand"
                  opts["@switchboard-home-key"] = "H"
                  refute Upgrade.leftovers?, "applied"
                end
              end
            end
          end
        end
      end
    end

    # --- cycle-2 findings (D5) ------------------------------------------------

    # Value: protects=a branch whose version.rb is ahead of the newest tag (any unreleased
    # bump) reading as up to date; fails_when=the compare turns into `!=`; why_new=only
    # equal and newer tags were tested; seam=none
    def test_an_older_tag_than_the_running_version_is_up_to_date
      r = brew_upgrade(latest: "0.0.1")
      assert_empty r[:ran]
      refute r[:handed]
      assert_includes r[:out], "is up to date"
    end

    def test_a_brew_stamp_follows_the_keg_the_opt_link_points_at
      keg1 = path("Cellar", "0.1.0", "switchboard")
      keg2 = path("Cellar", "0.2.0", "switchboard")
      [keg1, keg2].each { |k| FileUtils.mkdir_p(File.dirname(k)); File.write(k, "") }
      link = path("opt", "switchboard")
      FileUtils.mkdir_p(File.dirname(link))
      File.symlink(keg1, link)
      stub_method(Installer, :bin_path, -> { link }) do
        before = Upgrade.stamp(:brew)
        File.unlink(link)
        File.symlink(keg2, link)
        refute_equal before, Upgrade.stamp(:brew)
      end
    end

    # Value: protects=`switchboard upgrade` in a clone never hanging on a stalled fetch;
    # fails_when=the fetch goes back to an unbounded system call; why_new=cycle-2 Red Team;
    # seam=Git.fetch_base (the bounded fetch it delegates to; its deadline is pinned in git_test)
    def test_a_clone_check_uses_the_bounded_fetch_and_degrades_to_couldnt_check
      repo = clone_install
      args = nil
      got = stub_method(Installer, :repo_root, -> { repo }) do
        stub_method(Git, :fetch_base, ->(*a, **kw) { args = [a, kw]; false }) { Upgrade.clone_behind? }
      end
      assert_nil got
      assert_equal Upgrade::FETCH_DEADLINE, args.last[:timeout]
    end

    def test_a_checkout_git_cant_read_isnt_told_to_commit_or_stash
      dir = path("tarball")
      FileUtils.mkdir_p(dir)
      _, out = stub_method(Installer, :repo_root, -> { dir }) { quietly { Upgrade.clone_pull } }
      assert_includes out, "couldn't read git status"
      refute_includes out, "commit or stash"
    end

    def test_a_failed_step_doesnt_claim_nothing_changed
      _, out = stub_method(Upgrade, :system, ->(*) { false }) { quietly { Upgrade.step("brew", "upgrade", "switchboard") } }
      refute_includes out, "nothing was changed"
      assert_includes out, "re-run `switchboard upgrade`"
    end

    def test_leftovers_ignore_current_and_unhooked_worktrees_and_a_current_codex_block
      HookFile.ensure_script
      repo = temp_git_repo("app")
      plain = path("wts", "app", "plain")
      git(repo, "worktree", "add", "-q", plain, "-b", "plain")
      File.write(Config.path, YAML.dump("projects" => [{ "name" => "app", "path" => repo }]))
      ClaudeHook.enable(repo)
      CodexHook.install_global
      stub_method(Installer, :wired_fragment, ->(*) { nil }) do
        stub_method(Installer, :installed_bin?, -> { true }) { refute Upgrade.leftovers? }
      end
    end

    def test_another_binary_never_rewrites_a_current_codex_block
      CodexHook.install_global
      stub_method(Installer, :installed_bin?, -> { false }) do
        stub_method(CodexHook, :install_global, -> { flunk "must not write codex config" }) { assert Upgrade.refresh_codex }
      end
    end

    # --- /ship run 2 (D1) -----------------------------------------------------

    # Value: protects=a fetch that succeeded but couldn't be stamped still finishing the
    # upgrade; fails_when=nil == nil reads as "nothing newer"; why_new=stamps always stubbed
    # non-nil; seam=stamp
    def test_an_unknown_stamp_still_hands_off_after_a_successful_fetch
      assert brew_upgrade(stamps: [nil, nil])[:handed]
    end

    def test_nothing_newer_wording_follows_the_install_method
      _, brew = quietly { Upgrade.nothing_newer(:brew, nil) }
      assert_includes brew, "Homebrew has nothing newer than #{VERSION}"
      refute_includes brew, "build of main"
      _, head = quietly { Upgrade.nothing_newer(:brew_head, nil) }
      assert_includes head, "newest build of main"
      _, clone = quietly { Upgrade.nothing_newer(:clone, nil) }
      assert_includes clone, "newest commit on your branch"
    end

    # Value: protects=a clone upgrade never stalling on an ssh passphrase prompt it can't
    # show; fails_when=the bounded fetch runs without ssh BatchMode; why_new=run-2 Red Team;
    # seam=Git.fetch_base
    def test_the_clone_fetch_runs_ssh_in_batch_mode
      repo = clone_install
      kw = nil
      stub_method(Installer, :repo_root, -> { repo }) do
        stub_method(Git, :fetch_base, ->(*, **k) { kw = k; true }) { Upgrade.clone_behind? }
      end
      assert_includes kw[:env]["GIT_SSH_COMMAND"], "BatchMode=yes"
    end

    # Value: protects=an up-to-date upgrade on tmux < 3.0 (no indexed hook slots) not
    # "finishing setup" forever; fails_when=the slot check runs where slots can't exist;
    # why_new=run-2 Red Team; seam=tmux_version
    def test_old_tmux_without_hook_slots_isnt_a_leftover
      HookFile.ensure_script
      stub_method(Installer, :installed_bin?, -> { false }) do
        stub_method(Installer, :fragment_wired_here?, -> { true }) do
          stub_method(Installer, :live_hooks, -> { Installer::HOOK_SLOTS.to_h { |s| [s, false] } }) do
            stub_method(Installer, :toggle_key_live?, ->(*) { true }) do
              stub_method(Installer, :tmux_version, -> { 2.9 }) { refute Upgrade.leftovers? }
              stub_method(Installer, :tmux_version, -> { 3.4 }) { assert Upgrade.leftovers? }
            end
          end
        end
      end
    end

    # Value: protects=a clone that authenticates through core.sshCommand (a specific key,
    # an agent wrapper) keeping it for the up-to-date fetch; fails_when=the BatchMode
    # default overrides it (GIT_SSH_COMMAND outranks core.sshCommand); why_new=run-2 Red
    # Team; seam=Git.fetch_base
    def test_the_clone_fetch_keeps_a_configured_core_ssh_command
      repo = clone_install
      git(repo, "config", "core.sshCommand", "ssh -i ~/.ssh/work")
      kw = nil
      stub_method(Installer, :repo_root, -> { repo }) do
        stub_method(Git, :fetch_base, ->(*, **k) { kw = k; true }) { Upgrade.clone_behind? }
      end
      refute kw[:env].key?("GIT_SSH_COMMAND")
    end

    def test_the_clone_fetch_keeps_an_exported_ssh_choice
      repo = clone_install
      { "GIT_SSH_COMMAND" => "ssh -i ~/.ssh/work", "GIT_SSH" => "/usr/local/bin/my-ssh" }.each do |var, value|
        ENV[var] = value
        kw = nil
        stub_method(Installer, :repo_root, -> { repo }) do
          stub_method(Git, :fetch_base, ->(*, **k) { kw = k; true }) { Upgrade.clone_behind? }
        end
        refute kw[:env].key?("GIT_SSH_COMMAND"), "#{var} is the user's ssh choice"
      ensure
        ENV.delete(var)
      end
    end

    # Value: protects=a codex block the upgrade couldn't rewrite failing the finish (exit 1)
    # without telling the user to re-trust commands that never changed; fails_when=
    # refresh_codex drops install_global's refusal or prints the /hooks note after one;
    # why_new=finish tests stub refresh_codex whole; seam=none; no_claim=real codex trust
    def test_a_refused_codex_rewrite_fails_the_finish_without_asking_for_trust
      ENV["SWITCHBOARD_BIN"] = "/old/bin/switchboard"
      CodexHook.install_global
      ENV["SWITCHBOARD_BIN"] = "/new/bin/switchboard" # stale block: a success would ask for trust
      [:unsafe, :conflict, nil].each do |refusal|
        ok, out = stub_method(Installer, :installed_bin?, -> { true }) do
          stub_method(CodexHook, :install_global, -> { refusal }) { quietly { Upgrade.refresh_codex } }
        end
        refute ok, refusal.inspect
        refute_includes out, "/hooks` in codex once", refusal.inspect
      end
    end

    # Value: protects=a --HEAD (or couldn't-tell) run that fetched nothing new still
    # finishing stale setup, like an up-to-date run; fails_when=the unmoved path returns
    # before leftovers?; why_new=state-machines cycle 1 (behind? is always nil for --HEAD);
    # seam=none
    def test_an_unmoved_fetch_still_finishes_leftover_setup
      r = brew_upgrade(method: :brew_head, stamps: %w[same same], leftovers: true)
      assert_equal :finished, r[:result]
      assert_includes r[:out], "newest build of main"
      refute r[:handed]
      assert brew_upgrade(method: :brew_head, stamps: %w[same same], leftovers: false)[:result]
    end

    # Value: protects=a ✓ "reloaded" only when the bindings took (the fragment's exit is its
    # last line's, so a failed tmux-bind still exits 0); fails_when=reload_tmux trusts
    # run-shell's status alone; why_new=Red Team cycle 1; seam=none; no_claim=real tmux (smoke)
    def test_a_reload_whose_bindings_still_arent_live_fails
      ok, out = stub_method(Installer, :reload_fragment, -> { true }) do
        stub_method(Upgrade, :tmux_stale?, -> { true }) { quietly { Upgrade.reload_tmux } }
      end
      refute ok
      assert_includes out, "still aren't live"
    end

    # Value: protects=a wiped reporter with hooked worktrees (every agent dot dead) reading
    # as setup to finish, while a fresh install with nothing hooked stays quiet; fails_when=
    # leftovers? treats a missing reporter as "nothing hooked yet" again; why_new=
    # state-machines cycle 2; seam=installed_bin? (PATH lookup)
    def test_a_missing_reporter_is_a_leftover_only_while_worktrees_are_hooked
      repo = temp_git_repo("app")
      File.write(Config.path, YAML.dump("projects" => [{ "name" => "app", "path" => repo }]))
      stub_method(Installer, :wired_fragment, ->(*) { nil }) do
        stub_method(Installer, :installed_bin?, -> { true }) do
          refute Upgrade.leftovers?, "nothing hooked, no reporter: nothing to finish"
          ClaudeHook.enable(repo)
          File.delete(HookFile.script_path)
          assert Upgrade.leftovers?, "hooked worktrees, no reporter"
        end
      end
    end

    # Value: protects=Homebrew and clone runs whose fetch moved nothing still finishing stale
    # setup (the --HEAD case is pinned above); fails_when=the unmoved branch is narrowed to one
    # install method; why_new=state-machines cycle 2 untested cells; seam=none
    def test_brew_and_clone_fetches_that_moved_nothing_still_finish_leftovers
      r = brew_upgrade(stamps: %w[same same], leftovers: true)
      assert_equal :finished, r[:result]
      assert_includes r[:out], "9.9.9 is tagged"
      refute r[:handed]

      repo = clone_install(behind: false)
      got, out = stub_method(Upgrade, :install_method, -> { :clone }) do
        stub_method(Installer, :repo_root, -> { repo }) do
          stub_method(Upgrade, :clone_behind?, -> { nil }) do
            stub_method(Upgrade, :leftovers?, -> { true }) do
              stub_method(Upgrade, :finish, ->(*a, **k) { a == [nil] && k == { leftovers: true } ? :finished : [:finish, a, k] }) { quietly { Upgrade.run } }
            end
          end
        end
      end
      assert_equal :finished, got
      assert_includes out, "newest commit on your branch"
    end

    # Value: protects=a codex-only setup (no Claude-hooked worktree) whose reporter vanished
    # reading as unfinished setup: the global codex block runs the same script;
    # fails_when=reporter_needed? stops counting the codex block; why_new=state-machines run 4
    # (D2); seam=installed_bin? (PATH lookup)
    def test_a_missing_reporter_counts_when_only_the_codex_block_runs_it
      ENV["SWITCHBOARD_BIN"] = "/bin/switchboard"
      CodexHook.install_global
      File.delete(HookFile.script_path) if File.exist?(HookFile.script_path)
      stub_method(Installer, :wired_fragment, ->(*) { nil }) do
        stub_method(Installer, :installed_bin?, -> { true }) { assert Upgrade.leftovers?, "codex runs the missing reporter" }
      end
    end

    # Value: protects=a failed `brew update` where nothing moved (maybe switchboard's own tap)
    # failing with that cause, not "Homebrew doesn't have it yet" and exit 0; fails_when=the
    # update failure is forgotten once the upgrade step runs; why_new=Red Team run 4 (D7, a
    # regression from D4); seam=none
    def test_a_failed_update_that_moved_nothing_names_the_update
      r = brew_upgrade(stamps: %w[same same], ok: ->(argv) { argv != %w[brew update] })
      refute r[:result]
      assert_includes r[:out], "`brew update` failed, so Homebrew may not have the newest switchboard"
      refute_includes r[:out], "doesn't have it yet"
      refute r[:handed]
    end

    # Generated by /ship coverage audit.
    # Value: protects=a failed `brew update` whose upgrade succeeded but couldn't be stamped
    # still handing off to the new binary; fails_when=the update_blocked check moves ahead of
    # the stamp comparison; why_new=unknown stamp only tested with a clean update; seam=stamp;
    # no_claim=a real brew run
    def test_a_failed_update_with_an_unknown_stamp_still_hands_off
      r = brew_upgrade(stamps: [nil, nil], ok: ->(argv) { argv != %w[brew update] })
      assert r[:handed]
      refute_includes r[:out], "`brew update` failed, so Homebrew may not have"
    end

    # Generated by /ship coverage audit.
    # Value: protects=a clone whose bounded up-front check couldn't fetch still getting the new
    # commits; fails_when=clone_pull drops its own `git fetch` and merges a stale @{upstream};
    # why_new=every pull test fetched up front first; seam=Git.fetch_base; no_claim=network
    def test_a_clone_pull_fetches_itself_when_the_up_front_check_couldnt
      repo = clone_install
      r = stub_method(Git, :fetch_base, ->(*, **) { false }) { clone_upgrade(repo) }
      assert_includes r[:out], "couldn't compare with your branch's upstream"
      assert r[:handed]
      assert File.exist?(File.join(repo, "new.rb")), "pulled"
    end

    # Generated by /ship coverage audit.
    # Value: protects=an ignored local file whose name has a leading space still blocking the
    # update that adds it; fails_when=ignored_collisions reads git's -z output through a strip
    # (git_out); why_new=collision test uses a plain name; seam=none; no_claim=renames
    def test_an_ignored_file_with_an_edge_space_in_its_name_still_blocks_the_update
      repo = temp_git_repo("switchboard", origin: true)
      git(repo, "branch", "-q", "--set-upstream-to=origin/main")
      other = path("other")
      git(nil, "clone", "-q", "#{repo}.git", other)
      git(other, "config", "user.email", "t@example.com")
      git(other, "config", "user.name", "T")
      File.write(File.join(other, " notes.txt"), "upstream\n")
      git(other, "add", "-A")
      git(other, "commit", "-q", "-m", "next")
      git(other, "push", "-q", "origin", "main")
      File.write(File.join(repo, ".git", "info", "exclude"), " notes.txt\n")
      File.write(File.join(repo, " notes.txt"), "mine\n")
      r = clone_upgrade(repo)
      refute r[:handed]
      assert_includes r[:out], "merge --no-overwrite-ignore --ff-only @{upstream}` failed"
      assert_equal "mine\n", File.read(File.join(repo, " notes.txt"))
    end
  end
end
