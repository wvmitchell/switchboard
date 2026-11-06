# frozen_string_literal: true

require_relative "test_helper"
require "ripper"

module Switchboard
  # Holds lib/switchboard's layering (docs/explanation-architecture.md#layers): every file
  # sits in exactly one layer, and a file may reference constants only in its own layer or
  # below. References come from Ripper's constant tokens, so a name in a comment, string or
  # heredoc (HookFile::SCRIPT is a shell script) is never a dependency. A violation we accept
  # goes in ALLOWED with what removes it (none today); the list only shrinks, so a fixed
  # violation left on it fails too. Reads files only, so it's a plain Minitest::Test.
  class LayersTest < Minitest::Test
    LIB = File.expand_path("../lib/switchboard", __dir__)

    # Lowest first. A file may depend on its own layer or any layer before it. A file's folder
    # is its layer; interfaces sit at the top of lib/switchboard, with no folder of their own.
    LAYERS = { support: "support", adapters: "adapters", state: "state", operations: "ops", interfaces: nil }.freeze
    # These stay at the top whatever they do: root.rb computes ROOT from where it sits, and
    # UpdateCheck, packaging/release.rb and the release workflow read version.rb by path.
    PINNED = { "root" => :support, "version" => :support }.freeze
    INTERFACES = %w[cli hook_commands sidebar].freeze

    # [file, referenced file] => what removes it. An entry covers the whole file pair, so a new
    # reference between the same two files goes unnoticed until the entry is deleted.
    ALLOWED = {}.freeze

    # Only root.rb may locate files from its own position: such a file changes meaning when
    # it moves (a CodeReload root that shifts makes stale? true on every tick, so every
    # sidebar re-execs forever). Everything else uses Switchboard::ROOT. root.rb is pinned,
    # and lib/switchboard.rb isn't scanned.
    PATH_MATH_HOME = "root"

    def test_every_lib_file_has_a_layer
      assert_empty lib_files.reject { |f| layer_of(f) }, "move these into a layer's folder; see docs/explanation-architecture.md#layers"
    end

    def test_pinned_files_and_interfaces_stay_at_the_top
      assert_empty (PINNED.keys + INTERFACES) - lib_files, "these must stay directly in lib/switchboard"
    end

    def test_a_file_outside_the_layer_folders_has_no_layer
      assert_nil layer_of("stray")
      assert_nil layer_of("elsewhere/stray")
      assert_equal :operations, layer_of("ops/installer/keybindings")
      assert_equal :interfaces, layer_of("sidebar/edges")
      assert_equal :support, layer_of("root")
    end

    def test_no_file_depends_on_a_higher_layer
      upward = violations.reject { |pair| ALLOWED.key?(pair) }
      assert_empty upward.map { |from, to| "#{from} (#{layer_of(from)}) → #{to} (#{layer_of(to)})" },
                   "a lower layer references a higher one; see docs/explanation-architecture.md#layers"
    end

    def test_every_top_level_constant_has_one_home
      homes = definitions_by_file.group_by(&:first).transform_values { |defs| defs.map(&:last).uniq }
      assert_empty homes.select { |_, files| files.size > 1 }, "a top-level constant is defined in two files, so its layer is ambiguous"
    end

    def test_allowed_violations_are_still_real
      stale = ALLOWED.keys - violations
      assert_empty stale, "fixed, so delete these from LayersTest::ALLOWED"
    end

    def test_only_root_files_locate_paths_from_their_own_position
      found = lib_files.select { |f| path_math?(source(f)) }
      assert_equal [PATH_MATH_HOME], found, "only root.rb locates files from __dir__/__FILE__; use Switchboard::ROOT (see docs/explanation-architecture.md#layers)"
    end

    def test_names_in_comments_strings_and_heredocs_are_not_references
      src = <<~'RUBY'
        # Tmux.go is mentioned here
        x = "Git.capture"
        y = <<~SH
          Creator.work
        SH
        Config.new
      RUBY
      assert_equal ["Config"], references(src, %w[Tmux Git Creator Config])
    end

    def test_qualified_and_defined_names_resolve_to_the_top_level_constant
      src = <<~RUBY
        module Switchboard
          class Sidebar
            def a = Switchboard::Tmux.go
            def b = SessionName::Claude
            def c = Sidebar::Edges
          end
        end
      RUBY
      # Switchboard::Tmux folds to Tmux; Claude and Edges are nested, not top-level;
      # the `class Sidebar` definition isn't a reference, but the Sidebar:: use is.
      assert_equal %w[Tmux SessionName Sidebar], references(src, %w[Tmux SessionName Claude Sidebar Edges])
    end

    def test_a_symbol_naming_a_constant_is_not_a_reference
      src = <<~'RUBY'
        x = :Config
        y = :"#{Tmux}"
      RUBY
      # :Config only names a symbol; the interpolated Tmux really is evaluated.
      assert_equal ["Tmux"], references(src, %w[Config Tmux])
    end

    def test_a_file_ripper_cannot_parse_fails_instead_of_passing
      assert_raises(SyntaxError) { tokens("def broken(") }
    end

    def test_only_real_nested_definitions_shadow_a_top_level_name
      src = <<~RUBY
        module Switchboard
          module CodeReload
            VERSION = 1
            NOTE = <<~TXT
                class Config
            TXT
          end
        end
      RUBY
      # VERSION and NOTE are defined inside CodeReload; the indented `class Config` is heredoc text.
      assert_equal %w[VERSION NOTE], nested_names(src)
    end

    private

    def lib_files
      Dir[File.join(LIB, "**", "*.rb")].map { |f| f.delete_prefix("#{LIB}/").delete_suffix(".rb") }.sort
    end

    def source(file) = File.read(File.join(LIB, "#{file}.rb"))

    def layer_of(file)
      return PINNED[file] if PINNED.key?(file)
      return :interfaces if INTERFACES.include?(file[%r{\A[^/]+}])

      LAYERS.key(file[%r{\A([^/]+)/}, 1]) if file.include?("/")
    end

    def rank(file) = LAYERS.keys.index(layer_of(file))

    # Every [file, referenced file] pair that points to a higher layer.
    def violations
      @violations ||= lib_files.flat_map do |file|
        references(source(file), top_level.keys - nested_names(source(file)))
          .map { |const| top_level[const] }
          .reject { |target| family(target) == family(file) }
          .select { |target| rank(target) && rank(file) && rank(target) > rank(file) } # unlayered: its own test fails
          .map { |target| [file, target] }
      end.uniq
    end

    # Switchboard's top-level constants => the file that defines them.
    def top_level = @top_level ||= definitions_by_file.to_h

    # [constant, file] for every top-level definition (column 2, inside `module Switchboard`).
    def definitions_by_file
      lib_files.select { |f| unit(f) == without_folder(f) }.flat_map do |file|
        definitions(source(file)).select { |_, col| col == 2 }.map { |const, _| [const, file] }
      end
    end

    # A constant a file defines for itself (CodeReload::VERSION) shadows the top-level one.
    def nested_names(src) = definitions(src).select { |_, col| col >= 4 }.map(&:first).uniq

    # [name, column] for each `module X` / `class X` / `X =` in code, never in heredoc text.
    def definitions(src)
      toks = tokens(src)
      toks.each_with_index.filter_map do |((_, col), type, text), i|
        nxt = toks[i + 1]
        if type == :on_kw && %w[module class].include?(text) && nxt && nxt[1] == :on_const then [nxt[2], col]
        elsif type == :on_const && nxt && nxt[1] == :on_op && nxt[2] == "=" && !(i.positive? && toks[i - 1][2] == "::") then [text, col]
        end
      end
    end

    # raise_errors: a file Ripper can't parse would lex partially and pass the check silently.
    def tokens(src) = Ripper.lex(src, raise_errors: true).reject { |_, type, _| %i[on_sp on_nl on_ignored_nl on_comment].include?(type) }

    def without_folder(file) = file.delete_prefix("#{LAYERS[layer_of(file)]}/")

    # A top-level file's name, or the top-level file a part belongs to: installer/keybindings
    # reopens Installer, so its definitions aren't top-level ones.
    def unit(file) = without_folder(file)[%r{\A[^/]+}]

    # sidebar/* are concern files of Sidebar and tmux/* of Tmux, so each is one unit.
    def family(file) = unit(file).then { |u| %w[sidebar tmux].include?(u) ? u : file }

    # Constant tokens naming one of `names`: not a definition (`module X`), and not nested
    # under something else (`Sidebar::Edges`), except under `Switchboard::`.
    def references(src, names)
      tokens = tokens(src)
      tokens.each_with_index.filter_map do |(_, type, text), i|
        next unless type == :on_const && names.include?(text)

        prev = i.positive? ? tokens[i - 1] : nil
        next if prev && prev[1] == :on_kw && %w[module class].include?(prev[2])
        next if prev && prev[1] == :on_symbeg # :Config is a symbol, not a reference
        next if prev && prev[2] == "::" && !(i > 1 && tokens[i - 2][2] == "Switchboard")

        text
      end.uniq
    end

    def path_math?(src)
      Ripper.lex(src, raise_errors: true).any? { |_, type, text| (type == :on_ident && text == "__dir__") || (type == :on_kw && text == "__FILE__") }
    end
  end
end
