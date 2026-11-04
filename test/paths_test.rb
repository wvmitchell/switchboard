# frozen_string_literal: true

require_relative "test_helper"
require "rbconfig"

module Switchboard
  # Pins where every store lives, byte for byte. The expected paths are written out here,
  # never built with Paths, so a resolver that drifted fails instead of agreeing with itself.
  class PathsTest < SandboxTest
    LIB = File.expand_path("../lib", __dir__)

    # Each store's reader, its env override, and its path under the default root.
    STATE = {
      "AgentState.state_dir" => ["SWITCHBOARD_STATE_DIR", "agents"],
      "Attention.state_dir" => ["SWITCHBOARD_ATTENTION_DIR", "attention"],
      "BranchFold.marker" => ["SWITCHBOARD_BRANCH_FOLD_FILE", "branch_fold"],
      "Collapse.state_dir" => ["SWITCHBOARD_COLLAPSE_DIR", "collapse"],
      "Creation.state_dir" => ["SWITCHBOARD_CREATION_DIR", "creation"],
      "FullHeader.marker" => ["SWITCHBOARD_FULL_HEADER_FILE", "full_header"],
      "Monitoring.state_dir" => ["SWITCHBOARD_MONITORING_DIR", "monitoring"],
      "Notify.state_dir" => ["SWITCHBOARD_NOTIFY_DIR", "notify"],
      "OffstageHold.state_dir" => ["SWITCHBOARD_OFFSTAGE_HOLD_DIR", "offstage_hold"],
      "PendingDelete.state_dir" => ["SWITCHBOARD_PENDING_DELETE_DIR", "pending-delete"],
      "SessionName::Outcome.dir" => ["SWITCHBOARD_SESSION_NAME_DIR", "session-name"],
      "Width.state_file" => ["SWITCHBOARD_WIDTH_FILE", "width"]
    }.freeze
    CACHE = {
      "Pr.cache_dir" => ["SWITCHBOARD_CACHE_DIR", "prs"],
      "UpdateCheck.cache_path" => ["SWITCHBOARD_UPDATE_CACHE", "latest.json"]
    }.freeze
    DATA = { "HookFile.script_path" => "sb-agent-hook", "Sound.asset_dir" => "sounds" }.freeze

    def read(store) = Switchboard.module_eval(store, __FILE__, __LINE__)

    def clear_overrides
      (STATE.values + CACHE.values).each { |env, _| ENV.delete(env) }
    end

    def test_stores_live_under_their_xdg_root
      clear_overrides
      STATE.each { |store, (_, leaf)| assert_equal path("xdg-state", "switchboard", leaf), read(store), store }
      CACHE.each { |store, (_, leaf)| assert_equal path("xdg-cache", "switchboard", leaf), read(store), store }
      DATA.each { |store, leaf| assert_equal path("xdg-data", "switchboard", leaf), read(store), store }
    end

    def test_stores_fall_back_to_home_without_xdg
      clear_overrides
      %w[XDG_STATE_HOME XDG_CACHE_HOME XDG_DATA_HOME].each { |k| ENV.delete(k) }
      STATE.each { |store, (_, leaf)| assert_equal path(".local/state/switchboard", leaf), read(store), store }
      CACHE.each { |store, (_, leaf)| assert_equal path(".cache/switchboard", leaf), read(store), store }
      DATA.each { |store, leaf| assert_equal path(".local/share/switchboard", leaf), read(store), store }
    end

    def test_an_override_wins_and_has_its_tilde_expanded
      STATE.merge(CACHE).each do |store, (env, _)|
        ENV[env] = "~/elsewhere/#{env}"
        assert_equal path("elsewhere", env), read(store), store
      end
    end

    # Taken literally, "" expands to the current directory, where a store's cleanup deletes
    # files. Every family and the sh reporter read it as unset.
    def test_an_empty_override_counts_as_unset
      STATE.each do |store, (env, leaf)|
        ENV[env] = ""
        assert_equal path("xdg-state", "switchboard", leaf), read(store), store
      end
      CACHE.each do |store, (env, leaf)|
        ENV[env] = ""
        assert_equal path("xdg-cache", "switchboard", leaf), read(store), store
      end
    end

    def test_an_empty_xdg_root_counts_as_unset
      clear_overrides
      %w[XDG_STATE_HOME XDG_CACHE_HOME XDG_DATA_HOME].each { |k| ENV[k] = "" }
      STATE.each { |store, (_, leaf)| assert_equal path(".local/state/switchboard", leaf), read(store), store }
      CACHE.each { |store, (_, leaf)| assert_equal path(".cache/switchboard", leaf), read(store), store }
      DATA.each { |store, leaf| assert_equal path(".local/share/switchboard", leaf), read(store), store }
    end

    # Value: protects=quit and a marker scan never delete files in the current directory when a store variable is exported empty; fails_when=Paths.state takes "" literally again; why_new=the path pins would pass if a store bypassed Paths; seam=none; no_claim=a variable set to a real directory, which is honored
    def test_cleanup_with_empty_overrides_leaves_the_current_directory_alone
      STATE.each_value { |env, _| ENV[env] = "" }
      cwd = path("a-worktree")
      FileUtils.mkdir_p(cwd)
      File.write(File.join(cwd, "notes.txt"), "mine\n")
      Dir.chdir(cwd) do
        [AgentState, Monitoring, Notify, OffstageHold, PendingDelete].each(&:clear_all)
        Attention.marked([cwd])
      end
      assert_equal ["notes.txt"], Dir.children(cwd)
    end


    def test_a_relative_xdg_cache_root_stays_relative
      clear_overrides
      ENV["XDG_CACHE_HOME"] = "rel"
      CACHE.each { |store, (_, leaf)| assert_equal "rel/switchboard/#{leaf}", read(store), store }
    end

    # Each copy keeps the failure it had before it moved here: a vanished path keeps its raw
    # spelling, except where it must match nothing.
    REAL_OR_SELF = %w[Attention.realpath ClaudeSessions.real Creation.real_path Monitoring.realpath
                      Notify.realpath Reconcile.real Rename.canonical SessionName::Outcome.realpath].freeze
    REAL_OR_NIL = %w[OffstageHold.realpath].freeze
    NIL_FOR_BLANK = %w[Attention.realpath Monitoring.realpath Notify.realpath].freeze

    def call(helper, arg)
      mod, meth = helper.split(/\.(?=\w+\z)/)
      Switchboard.const_get(mod).send(meth, arg)
    end

    def test_each_realpath_copy_keeps_its_failure_value
      gone = path("gone")
      link = path("link")
      File.symlink(@dir, link)
      (REAL_OR_SELF + REAL_OR_NIL).each { |h| assert_equal File.realpath(@dir), call(h, link), h }
      REAL_OR_SELF.each { |h| assert_equal gone, call(h, gone), h }
      REAL_OR_NIL.each { |h| assert_nil call(h, gone), h }
      assert_equal gone, AgentState.new.send(:real, gone), "AgentState reads an instance helper"
      NIL_FOR_BLANK.each do |h|
        assert_nil call(h, nil), h
        assert_nil call(h, ""), h
      end
    end

    def test_real_or_nil_and_real_or_self_on_a_vanished_path
      assert_nil Paths.real_or_nil(path("gone"))
      assert_equal path("gone"), Paths.real_or_self(path("gone"))
      assert_nil Paths.real_or_self(nil)
    end

    # A view flag resolves its path inside the rescue, so a bad override degrades.
    def test_view_flags_degrade_on_an_unresolvable_override
      ENV["SWITCHBOARD_FULL_HEADER_FILE"] = "~no_such_user_xyz_42/flag"
      refute FullHeader.enabled?
      assert_nil FullHeader.enable
      assert_nil FullHeader.disable
    end

    # Width and Sound replace a symlink; UpdateCheck writes through it. Each kept what it did.
    def test_width_replaces_a_symlink_rather_than_writing_through_it
      target = path("real-width")
      File.write(target, "50")
      File.symlink(target, Width.state_file)
      Width.set(60)
      refute File.symlink?(Width.state_file)
      assert_equal "60", File.read(Width.state_file)
      assert_equal "50", File.read(target)
    end

    def test_sound_replaces_a_dangling_symlink_rather_than_writing_through_it
      name = Sound::BUILTINS.first
      asset = File.join(Sound.asset_dir, "#{name}.v#{Sound::ASSET_VERSION}.wav")
      FileUtils.mkdir_p(Sound.asset_dir)
      File.symlink(path("elsewhere.wav"), asset)
      assert_equal asset, Sound.ensure_builtin(name)
      refute File.symlink?(asset)
      refute File.exist?(path("elsewhere.wav"))
    end

    def test_atomic_write_follows_a_symlink_by_default
      target = path("real")
      link = path("link-file")
      File.write(target, "old")
      File.symlink(target, link)
      MarkerBlock.atomic_write(link, "new")
      assert File.symlink?(link)
      assert_equal "new", File.read(target)
    end

    def test_a_built_in_sound_is_written_whole_and_leaves_no_temp
      wav = Sound.ensure_builtin(Sound::BUILTINS.first)
      assert_equal Sound.synth(Sound::BUILTINS.first).b, File.binread(wav)
      assert_equal [File.basename(wav)], Dir.children(File.dirname(wav))
    end

    # Each store resolves through Paths, so it has to load without lib/switchboard.rb.
    def test_stores_load_on_their_own
      { "agent_state" => "AgentState.state_dir", "width" => "Width.state_file", "sound" => "Sound.asset_dir",
        "hook_file" => "HookFile.script_path", "full_header" => "FullHeader.marker",
        "branch_fold" => "BranchFold.marker", "collapse" => "Collapse.state_dir",
        "codex_hook" => "CodexHook.bin" }.each do |lib, expr|
        out = IO.popen([RbConfig.ruby, "-I#{LIB}", "-e", "require #{"switchboard/#{lib}".inspect}; puts Switchboard::#{expr}"],
                       err: %i[child out], in: File::NULL, &:read)
        assert $?.success?, "#{lib} on its own: #{out}"
      end
    end

    # HookFile::SCRIPT has to keep its own shell copy of this logic: it runs without Ruby.
    def test_the_sh_reporter_agrees_with_agent_state
      line = HookFile::SCRIPT.lines.find { |l| l.start_with?("dir=") } or flunk("the reporter has no dir= line")
      resolve = lambda do
        IO.popen(["sh", "-c", "#{line}printf %s \"$dir\""], &:read)
      end

      assert_equal path("state"), AgentState.state_dir
      assert_equal AgentState.state_dir, resolve.call

      ENV.delete("SWITCHBOARD_STATE_DIR")
      assert_equal path("xdg-state", "switchboard", "agents"), AgentState.state_dir
      assert_equal AgentState.state_dir, resolve.call

      ENV.delete("XDG_STATE_HOME")
      assert_equal path(".local/state/switchboard/agents"), AgentState.state_dir
      assert_equal AgentState.state_dir, resolve.call

      ENV["SWITCHBOARD_STATE_DIR"] = ""
      ENV["XDG_STATE_HOME"] = ""
      assert_equal path(".local/state/switchboard/agents"), AgentState.state_dir
      assert_equal AgentState.state_dir, resolve.call
    end

    # Under a C locale Ruby hands ENV back as BINARY, which raises when joined with the UTF-8
    # strings built from these paths. Every store reads as UTF-8, whatever the locale.
    def test_every_store_is_utf8_under_a_c_locale_with_a_non_ascii_root
      root = path("zoë")
      assert_every_store_is_utf8("XDG_STATE_HOME" => root, "XDG_CACHE_HOME" => root, "XDG_DATA_HOME" => root)
    end

    # With no XDG root the path comes from `~`, which expands from a BINARY $HOME.
    def test_every_store_is_utf8_under_a_c_locale_with_a_non_ascii_home
      assert_every_store_is_utf8("HOME" => path("zoë"), "XDG_STATE_HOME" => nil, "XDG_CACHE_HOME" => nil, "XDG_DATA_HOME" => nil)
    end

    def assert_every_store_is_utf8(roots)
      env = { "LC_ALL" => "C", "LANG" => "C" }.merge(roots)
      (STATE.values + CACHE.values).each { |name, _| env[name] = nil }
      stores = STATE.keys + CACHE.keys + DATA.keys
      probe = <<~RUBY
        require "switchboard"
        #{stores.inspect}.each do |s|
          p = Switchboard.module_eval(s)
          puts [s, p.encoding, p.valid_encoding?, p.unpack1("H*"), ("\\u00e9" + p).encoding].join(" ")
        end
      RUBY
      out = IO.popen([env, RbConfig.ruby, "-I#{LIB}", "-e", probe], err: %i[child out], in: File::NULL, &:read)
      assert $?.success?, out

      lines = out.lines.map(&:split)
      assert_equal stores, lines.map(&:first)
      lines.each do |store, encoding, valid, hex, joined|
        assert_equal "UTF-8", encoding, store
        assert_equal "true", valid, store
        assert_equal "UTF-8", joined, store
        assert_includes [hex].pack("H*").force_encoding(Encoding::UTF_8), "zoë", store
      end
    end
  end
end
