# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # Registrar.register adds an on-disk repo to the config. Tested against real
  # repos so the git toplevel + remote_head base-resolution actually run.
  class RegistrarTest < SandboxTest
    def setup
      super
      Config.scaffold # start from an empty, valid config
      # Registrar.create makes an empty initial commit; seed an identity in the
      # walled-off global so it's deterministic (not reliant on git auto-derivation).
      git(nil, "config", "--global", "user.email", "test@example.com")
      git(nil, "config", "--global", "user.name", "Switchboard Test")
    end

    def test_register_adds_a_repo_and_derives_the_name_from_its_dir
      repo = temp_git_repo("myproj", origin: true)
      entry, err = Registrar.register(Config.new, repo)
      assert_nil err
      assert_equal "myproj", entry["name"]
      assert Config.new.project("myproj"), "the project is now in the config"
    end

    # base == the global default is dropped, so the project inherits it rather
    # than carrying redundant per-project noise.
    def test_register_drops_base_when_it_equals_the_global_default
      repo = temp_git_repo("app", origin: true) # remote_head == origin/main == global base
      entry, = Registrar.register(Config.new, repo)
      assert_nil entry["base"]
    end

    def test_register_keeps_base_when_it_differs_from_the_global_default
      File.write(Config.path, YAML.dump("base" => "origin/trunk", "projects" => []))
      repo = temp_git_repo("app", origin: true) # remote_head origin/main != origin/trunk
      entry, = Registrar.register(Config.new, repo)
      assert_equal "origin/main", entry["base"]
    end

    def test_register_rejects_a_non_repo
      FileUtils.mkdir_p(path("plain"))
      entry, err = Registrar.register(Config.new, path("plain"))
      assert_nil entry
      assert_match(/not a git repo/, err)
    end

    def test_register_rejects_a_taken_name
      repo = temp_git_repo("dup", origin: true)
      Registrar.register(Config.new, repo)
      entry, err = Registrar.register(Config.new, repo) # fresh Config re-reads the now-populated file
      assert_nil entry
      assert_match(/name taken/, err)
    end

    # --- unregister: the inverse of register ---------------------------------

    def test_unregister_drops_a_registered_project
      repo = temp_git_repo("gone", origin: true)
      Registrar.register(Config.new, repo)
      entry, err = Registrar.unregister(Config.new, "gone")
      assert_nil err
      assert_equal "gone", entry["name"]
      refute Config.new.project("gone"), "the project is gone from the config"
    end

    def test_unregister_rejects_an_unknown_project
      entry, err = Registrar.unregister(Config.new, "ghost")
      assert_nil entry
      assert_match(/no such project/, err)
    end

    def test_unregister_leaves_the_repo_on_disk
      repo = temp_git_repo("keepme", origin: true)
      Registrar.register(Config.new, repo)
      Registrar.unregister(Config.new, "keepme")
      assert Dir.exist?(repo), "unregister is pure registry surgery — the repo stays"
    end

    # --- create: make and register a brand-new empty repo --------------------

    def test_create_makes_and_registers_a_new_repo
      entry, err = Registrar.create(Config.new, "fresh")
      assert_nil err
      assert_equal "fresh", entry["name"]
      assert Config.new.project("fresh"), "the new repo is in the config"
      assert Git.toplevel(entry["path"]), "a real git repo was created on disk"
    end

    def test_create_rejects_a_blank_name
      entry, err = Registrar.create(Config.new, "  ")
      assert_nil entry
      assert_match(/name required/, err)
    end

    # Free-form input that isn't sanitize-stable (a space would make the source
    # dir and Creator's worktree segment diverge; a slash or leading dot invites
    # traversal/hidden dirs) is rejected, not silently mangled.
    def test_create_rejects_an_unclean_name
      ["my repo", "a/b", ".hidden", "we!rd"].each do |bad|
        entry, err = Registrar.create(Config.new, bad)
        assert_nil entry, "#{bad.inspect} is rejected"
        assert_match(/invalid name/, err)
      end
    end

    def test_create_rejects_a_taken_name
      Registrar.create(Config.new, "dup")
      entry, err = Registrar.create(Config.new, "dup") # fresh Config re-reads the populated file
      assert_nil entry
      assert_match(/name taken/, err)
    end

    def test_create_rejects_an_existing_dir
      FileUtils.mkdir_p(File.join(Config.new.projects_root, "occupied"))
      entry, err = Registrar.create(Config.new, "occupied")
      assert_nil entry
      assert_match(/already exists/, err)
    end

    def test_create_registers_nothing_when_init_fails
      stub_method(Git, :init, ->(*) { false }) do
        entry, err = Registrar.create(Config.new, "flop")
        assert_nil entry
        assert_match(/create failed/, err)
      end
      refute Config.new.project("flop"), "a failed init registers nothing"
    end

    # The load-bearing guard: a repo created here must be immediately usable by
    # the real worktree-creation path — the regression test for the unborn-HEAD
    # bug (a bare `git init` would make Creator's `worktree add ... <base>` fail).
    def test_created_repo_is_immediately_worktree_able
      Registrar.create(Config.new, "usable")
      dest = Creator.create(Config.new, "usable", "wip")
      assert dest, "Creator.create returns a worktree path"
      assert Dir.exist?(dest), "the worktree exists on disk"
    end
  end
end
