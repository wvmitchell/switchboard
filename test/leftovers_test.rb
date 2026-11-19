# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # Leftovers: one registry of every per-workspace store, read by doctor (scan, read-only)
  # and prune (clear). Run over real temp repos and worktrees; only pids are faked.
  class LeftoversTest < SandboxTest
    LIB = File.expand_path("../lib/switchboard", __dir__)

    def setup
      super
      @repo = temp_git_repo("app")
      @root = path("worktrees")
      @live = File.join(@root, "app", "live")
      FileUtils.mkdir_p(File.dirname(@live))
      git(@repo, "worktree", "add", "-q", "-b", "live", @live)
      @live = File.realpath(@live)
      @gone = File.join(File.realpath(@root), "app", "gone") # never created: a deleted workspace
      File.write(Config.path, YAML.dump("worktree_root" => @root, "projects" => [{ "name" => "app", "path" => @repo }]))
    end

    def config = Config.new

    def found(row) = Leftovers.scan(config)[row].map { |i| i.path || i.pid }

    # A pid that was real a moment ago and isn't now.
    def dead_pid
      pid = Process.spawn("true")
      Process.wait(pid)
      pid
    end

    def seed_markers(real)
      Attention.mark(real)
      Monitoring.mark(real)
      Notify.mark(real)
      OffstageHold.hold(real, pid: Process.pid)
      SessionName::Outcome.record_real(real, "ceiling", "x")
    end

    # Writers refuse a missing folder, so a deleted workspace's markers are seeded the way
    # they got there: written while it existed, then the folder went.
    def seed_gone
      FileUtils.mkdir_p(@gone)
      seed_markers(@gone)
      write_agent(@gone)
      FileUtils.rm_rf(@gone)
    end

    def write_agent(cwd, state: "done")
      FileUtils.mkdir_p(AgentState.state_dir)
      File.write(File.join(AgentState.state_dir, cwd.sum.to_s), "#{state}\t#{cwd}\t#{Time.now.to_i}\n")
    end

    # Value: protects=a store added later can't escape doctor and prune; fails_when=a lib
    # file names a store leaf no row or GLOBAL lists; why_new=the registry is the no-orphans
    # guarantee; seam=none (reads lib's source); no_claim=what each row decides (below)
    def test_every_store_leaf_in_lib_is_a_row_or_global
      overrides = ENV.keys.grep(/\ASWITCHBOARD_.*_(DIR|FILE)\z/)
      overrides.each { |k| ENV.delete(k) } # each dir falls back to its own leaf name
      rows = Leftovers.dirs.values.map { |d| File.basename(d) }
      leaves = Dir.glob(File.join(LIB, "**", "*.rb")).flat_map do |f|
        src = File.read(f)
        src.scan(/(?:KeyedMarkerStore\.dir|Paths\.(?:state|cache))\(\s*"[A-Z_]+",\s*"([^"]+)"\)/).flatten +
          src.scan(/Paths\.data\("([^"]+)"\)/).flatten +
          src.scan(/STORE = \["[A-Z_]+", "([^"]+)"\]/).flatten +
          src.scan(/File\.join\(Outcome\.dir, "(\.[a-z]+)"\)/).flatten
      end
      leaves << HookFile::MARK # Paths.data(MARK)
      assert_includes leaves, "agents", "the scan found the stores"
      assert_includes leaves, ".workers"
      assert_empty leaves.uniq - rows - Leftovers::GLOBAL, "add a Leftovers row or a GLOBAL entry for these"
    end

    # Value: protects=markers of a deleted workspace are found, a live one's are not;
    # fails_when=a row reads the wrong field or ignores the folder test; why_new=new op;
    # seam=none; no_claim=pid rows, creation, half-removed (below)
    def test_marker_rows_find_a_deleted_workspaces_entries_only
      seed_markers(@live)
      write_agent(@live)
      seed_gone
      %i[attention monitoring notify offstage_hold session_outcome agents].each do |row|
        assert_equal [@gone], found(row), row.to_s
      end
    end

    def test_clear_removes_leftovers_and_keeps_live_entries
      seed_markers(@live)
      seed_gone
      counts = Leftovers.clear(config)
      assert_equal 1, counts[:attention]
      assert_equal [@live], Attention.scan.to_a
      assert_empty Leftovers.scan(config).values.flatten
      assert_equal 1, SessionName::Outcome.all.size, "the live workspace's outcome stays"
    end

    # Value: protects=prune --dry-run and doctor never delete; fails_when=scan or a dry clear
    # GCs; why_new=doctor must stay read-only; seam=none
    def test_scan_and_a_dry_clear_change_nothing
      seed_gone
      before = Dir.glob(path("**", "*"), File::FNM_DOTMATCH).sort
      Leftovers.scan(config)
      assert_equal 1, Leftovers.clear(config, dry_run: true)[:attention]
      assert_equal before, Dir.glob(path("**", "*"), File::FNM_DOTMATCH).sort
    end

    # Value: protects=a late writer re-seeding a half-removed folder is still caught;
    # fails_when=only "gone" counts; why_new=the half-removed rule; seam=none
    def test_a_folder_under_the_root_that_git_no_longer_lists_is_a_leftover
      half = File.join(File.dirname(@live), "half")
      FileUtils.mkdir_p(half)
      Attention.mark(half)
      outside = path("elsewhere")
      FileUtils.mkdir_p(outside)
      write_agent(File.realpath(outside)) # the global codex hook reports from anywhere
      assert_equal [File.realpath(half)], found(:attention)
      assert_empty found(:agents), "a folder outside the worktree root is never a leftover for being unlisted"
      assert_equal [File.realpath(half)], Leftovers.stray_folders(config)
    end

    # Value: protects=another repository's live checkout under the root is never called
    # stray or cleared, while one whose repository is gone still is; fails_when=only our own
    # listings decide; why_new=found live (an old clone's worktree under the root); seam=none
    def test_another_repositorys_live_worktree_under_the_root_is_not_a_leftover
      other = temp_git_repo("other")
      foreign = File.join(File.dirname(@live), "foreign")
      git(other, "worktree", "add", "-q", "-b", "f", foreign)
      Attention.mark(File.join(foreign))
      dead = File.join(File.dirname(@live), "dead")
      FileUtils.mkdir_p(dead)
      File.write(File.join(dead, ".git"), "gitdir: #{path('nowhere', '.git', 'worktrees', 'dead')}\n")
      assert_empty found(:attention)
      assert_equal [File.realpath(dead)], Leftovers.stray_folders(config)
    end

    # Value: protects=doctor never advises rm -rf on a folder with a checkout inside it;
    # fails_when=only the folder and its parents are checked; why_new=pre-landing review;
    # seam=none
    def test_a_folder_holding_a_checkout_further_down_is_not_stray
      nested = File.join(File.dirname(@live), "experiments", "fork")
      FileUtils.mkdir_p(File.dirname(nested))
      git(nil, "clone", "-q", @repo, nested)
      assert_empty Leftovers.stray_folders(config)
    end

    # Value: protects=a project whose name sanitizes to nothing can't make the whole worktree
    # root look stray; fails_when=the empty leaf joins to the root; why_new=pre-landing review
    def test_a_project_name_that_sanitizes_to_nothing_adds_no_root
      File.write(Config.path, YAML.dump("worktree_root" => @root, "projects" => [{ "name" => "app", "path" => @repo },
                                                                                  { "name" => "日本", "path" => @repo }]))
      FileUtils.mkdir_p(File.join(@root, "old"))
      assert_empty Leftovers.stray_folders(config)
    end

    # Value: protects=a corrupt store file is skipped and kept, never a crash of prune;
    # fails_when=a bad byte or an out-of-range pid escapes scan; why_new=pre-landing review
    def test_corrupt_entries_are_kept_without_crashing
      KeyedMarkerStore.write(Attention.state_dir, "ff", "/tmp/\xFF\xFE\tx".b)
      KeyedMarkerStore.write(SessionName::Owner.dir, "aa", "#{2**70}-1")
      counts = Leftovers.clear(config)
      assert_equal 0, counts[:session_owner]
      assert File.exist?(File.join(SessionName::Owner.dir, "aa"))
    end

    # Value: protects=a failed listing never makes a live workspace look deleted;
    # fails_when=the half-removed rule runs on a failed strict listing; seam=Git.worktrees
    def test_a_failed_strict_listing_counts_only_gone_folders
      half = File.join(File.dirname(@live), "half")
      FileUtils.mkdir_p(half)
      Attention.mark(half)
      seed_gone
      real = Git.method(:worktrees)
      failing = ->(repo, strict: false) { strict ? nil : real.call(repo) }
      stub_method(Git, :worktrees, failing) do
        assert_equal [@gone], found(:attention)
        assert_empty Leftovers.stray_folders(config)
      end
    end

    def test_an_agent_file_in_a_subdir_of_a_live_workspace_is_kept
      sub = File.join(@live, "pkg")
      FileUtils.mkdir_p(sub)
      write_agent(sub)
      assert_empty found(:agents)
    end

    # Value: protects=worker claims and typing locks of dead pids are cleared, live ones
    # kept; fails_when=a pid row ignores liveness; why_new=no path to test; seam=none
    def test_pid_rows_are_leftovers_once_their_pid_is_dead
      dead = dead_pid
      KeyedMarkerStore.write(SessionName::Owner.dir, "aa", "#{dead}-1")
      KeyedMarkerStore.write(SessionName::Owner.dir, "bb", "#{Process.pid}-1")
      locks = File.join(SessionName::Outcome.dir, ".locks")
      FileUtils.mkdir_p(locks)
      File.write(File.join(locks, dead.to_s), "")
      File.write(File.join(locks, Process.pid.to_s), "")
      assert_equal [dead], found(:session_owner)
      assert_equal [dead], found(:session_locks)
    end

    # Value: protects=prune never unlinks a typing lock a worker holds, even under a dead
    # pid; fails_when=Leftovers.remove plain-deletes session_locks instead of drop_lock;
    # why_new=session_name_test covers drop_lock and sweep, not prune's remove path;
    # seam=none; no_claim=a second process holding it (a same-process flock stands in)
    def test_prune_leaves_a_held_typing_lock_and_takes_it_once_released
      dead = dead_pid
      FileUtils.mkdir_p(SessionName::Claude.locks_dir)
      lock = SessionName::Claude.lock_path(dead)
      File.open(lock, File::RDWR | File::CREAT) do |held|
        held.flock(File::LOCK_EX)
        assert_equal 0, Leftovers.clear(config)[:session_locks]
        assert File.exist?(lock), "held, so prune leaves it"
      end
      assert_equal 1, Leftovers.clear(config)[:session_locks]
      refute File.exist?(lock), "released and dead: prune takes it"
    end

    def test_a_pending_delete_marker_is_a_leftover_only_past_its_ttl
      PendingDelete.mark("/some/path")
      assert_empty found(:pending_delete), "a live delete keeps its marker"
      File.utime(Time.now - PendingDelete::TTL - 5, Time.now - PendingDelete::TTL - 5,
                 File.join(PendingDelete.state_dir, PendingDelete.key("/some/path")))
      assert_equal 1, found(:pending_delete).size
    end

    # Value: protects=the creation row decides exactly as the sidebar's GC; fails_when=an
    # in-flight or still-on-disk record counts; why_new=new op; seam=none
    def test_creation_records_follow_the_sidebars_drop_rule
      FileUtils.mkdir_p(Creation.state_dir)
      gone = { "id" => "20261117000000-aaaaaa", "project" => "app", "state" => "turn_done", "path" => @gone,
               "worktree_added" => true, "acked" => true, "created_at" => Time.now.to_f }
      building = gone.merge("id" => "20261117000000-bbbbbb", "state" => "building", "owner_pid" => Process.pid)
      [gone, building].each { |r| File.write(Creation.file(r["id"]), JSON.dump(r)) }
      assert_equal [@gone], found(:creation)
      Leftovers.clear(config)
      assert_nil Creation.find(gone["id"])
      refute_nil Creation.find(building["id"]), "nothing in flight is ever dropped"
    end

    # Value: protects=a crashed writer's temp file is swept, a live writer's never;
    # fails_when=the sweep ignores the pid or age, or matches another store's naming;
    # why_new=temps are the other way a store grows; seam=none
    def test_temp_files_go_once_old_and_their_pid_is_dead
      dir = Attention.state_dir
      FileUtils.mkdir_p(dir)
      old = Time.now - Leftovers::TEMP_AGE - 5
      dead = File.join(dir, "abc.#{dead_pid}.tmp")
      live = File.join(dir, "abd.#{Process.pid}.tmp")
      fresh = File.join(dir, "abe.#{dead_pid}.tmp")
      [dead, live, fresh].each { |f| File.write(f, "x") }
      [dead, live].each { |f| File.utime(old, old, f) }
      Leftovers.clear(config)
      refute File.exist?(dead)
      assert File.exist?(live) && File.exist?(fresh)
    end

    def test_settled_counts_only_entries_older_than_the_grace
      seed_gone
      now = Time.now
      assert_empty Leftovers.settled(Leftovers.scan(config, now: now), now: now)
      assert_equal 1, Leftovers.settled(Leftovers.scan(config, now: now), now: now + Leftovers::GRACE + 1)[:attention]
    end
  end
end
