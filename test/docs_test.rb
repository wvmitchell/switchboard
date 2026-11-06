# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # Guards the docs' shape so a PR can't quietly rot it: links, anchors and § pointers
  # resolve, quoted section names (of CLAUDE.md or any doc) exist, AGENTS.md's claims hold, every doc fits the
  # Diataxis set docs/README.md states, the upstream "last verified" versions live only
  # in CLAUDE.md (the lines the security monitor updates), and no doc points at TODOs or
  # thoughts/. Reads files only, so it's a plain Minitest::Test, not a SandboxTest.
  class DocsTest < Minitest::Test
    ROOT = File.expand_path("..", __dir__)

    # Diataxis kind => filename prefix's H1, its docs/README.md section, its README bullet.
    KINDS = {
      "tutorial" => { h1: /\A# Tutorial: /, section: "Tutorial", bullet: "New here?" },
      "howto" => { h1: /\A# How to /, section: "How-to guides", bullet: "How-to guides" },
      "reference" => { h1: /\A# Reference: /, section: "Reference", bullet: "Reference" },
      "explanation" => { h1: /\A# Explanation: /, section: "Explanation", bullet: "Explanation" }
    }.freeze

    # What AGENTS.md says CLAUDE.md holds => the CLAUDE.md heading that holds it.
    AGENTS_CLAIMS = {
      "the invariants that bite" => "Invariants that bite",
      "the conventions" => "Conventions",
      "which doc in `docs/` holds the full detail" => "Where the detail lives"
    }.freeze

    # A tracked contract version outside CLAUDE.md is a second copy that drifts.
    VERIFIED_VERSION = /
      \b(?:last\s+(?:verified|checked)|(?:verified|checked)\s+through)\b[^.;]{0,80}?\d+\.\d+
      | \b(?:verified|checked)\s+\d+\.\d+\S*\s+through\b
      | \b(?:verified|checked)\s+live\s+(?:on|against)\b[^.;]{0,40}?\d+\.\d+
    /xi

    def test_relative_links_and_anchors_resolve
      broken = markdown_files.flat_map do |file|
        links(file).filter_map do |link|
          path, anchor = link.split("#", 2)
          target = path.empty? ? file : File.expand_path(path, File.dirname(file))
          next if File.directory?(target)
          next "#{rel(file)}: #{link} (no such file)" unless File.exist?(target)
          next unless anchor && target.end_with?(".md")
          "#{rel(file)}: #{link} (no such heading)" unless anchors(target).include?(anchor)
        end
      end
      assert_empty broken, "broken doc links — point them at the heading's current slug"
    end

    # A short quote names a section and must match a heading; a longer one quotes a
    # sentence and must still be in CLAUDE.md's text. (A short quote matched against
    # the text would pass on any table row that happens to share the words.)
    def test_quoted_claude_md_sections_exist
      sections = headings(claude_md).map(&:downcase)
      text = File.read(claude_md).gsub(/\s+/, " ").downcase
      present = lambda do |quote|
        quote.split.size <= 4 ? sections.include?(quote.downcase) : text.include?(quote.downcase)
      end
      sources = markdown_files - [claude_md] + Dir[File.join(ROOT, "{lib,test,bin}/**/*")]
      stale = sources.select { File.file?(_1) && _1 != __FILE__ }.flat_map do |file|
        prose(file).scan(/CLAUDE\.md(?:'s|,)?\s+["“]([^"”]+)["”]/).flatten
                   .reject(&present)
                   .map { "#{rel(file)}: CLAUDE.md \"#{_1}\"" }
      end
      assert_empty stale, "these quote a CLAUDE.md section or phrase that's no longer there — " \
                          "point them at the doc that now holds it"
    end

    # The same for a doc's own sections, named after a link to it
    # (`[agent presence](…), "Heading"`) or by its plain name (`(agent presence, "Heading")`).
    # A heading counts when the quote is all of it or its start, before a ":", "(" or "—".
    def test_quoted_doc_sections_exist
      stale = markdown_files.flat_map do |file|
        text = without_fences(File.read(file)).gsub(/\s+/, " ")
        quoted_doc_sections(file, text).filter_map do |target, quote|
          next "#{rel(file)}: \"#{quote}\" names #{rel(target)}, which doesn't exist" unless File.exist?(target)
          next if headings(target).any? { section_named?(_1, quote) }

          "#{rel(file)}: \"#{quote}\" isn't a section of #{rel(target)}"
        end
      end
      assert_empty stale, "point at the section with an anchor link instead: " \
                          "[doc § Heading](doc.md#heading)"
    end

    def test_agents_md_claims_about_claude_md_hold
      agents = File.read(File.join(ROOT, "AGENTS.md")).gsub(/\s+/, " ")
      sections = headings(claude_md)
      AGENTS_CLAIMS.each do |claim, heading|
        assert_includes agents, claim, "AGENTS.md no longer says CLAUDE.md holds #{claim}; " \
                                       "update AGENTS_CLAIMS with it"
        assert_includes sections, heading, "AGENTS.md says CLAUDE.md holds #{claim}, " \
                                           "but CLAUDE.md has no \"#{heading}\" section"
      end
    end

    # Value: protects=lib paths in workflows and docs still name files; fails_when=a file moves
    # and formula.yml's filter stops triggering the brew test (no failure, just no run), or
    # release.yml's version path 404s; why_new=link checks skip plain paths; seam=none;
    # no_claim=the filter list is complete
    def test_lib_paths_in_workflows_and_docs_exist
      sources = Dir[File.join(ROOT, ".github/workflows/*.yml")] + Dir[File.join(ROOT, "docs/*.md")] +
                %w[AGENTS.md CLAUDE.md CONTRIBUTING.md README.md].map { File.join(ROOT, _1) }
      stale = sources.flat_map do |file|
        File.read(file).scan(%r{lib/switchboard(?:\.rb|/[\w/]+(?:\.rb|/\*\*))}).uniq
            .reject { |path| Dir[File.join(ROOT, path)].any? }
            .map { |path| "#{file.delete_prefix("#{ROOT}/")}: #{path}" }
      end
      assert_empty stale, "these paths name no file; update them to where the file lives now"
    end

    def test_agents_and_claude_md_agree_with_ci_on_ruby
      rubies = File.read(File.join(ROOT, ".github/workflows/test.yml"))
                   .scan(/ruby: '([\d.]+)'/).flatten
      { "AGENTS.md" => File.join(ROOT, "AGENTS.md"), "CLAUDE.md" => claude_md }.each do |name, file|
        text = File.read(file).gsub(/\s+/, " ").delete("*")
        assert_equal rubies.min_by { Gem::Version.new(_1) }, text[/Ruby (?:≥|>=) ?(\d+(?:\.\d+)+)/, 1],
                     "#{name}'s Ruby floor must match the oldest Ruby in CI"
        assert_equal rubies.join(" and "), text[/CI runs (\d+(?:\.\d+)+ and \d+(?:\.\d+)+)/, 1],
                     "#{name}'s \"CI runs …\" must match test.yml's matrix"
      end
    end

    def test_every_doc_is_a_diataxis_kind
      docs.each do |file|
        kind = kind_of(file)
        assert kind, "#{rel(file)}: name it tutorial-/howto-/reference-/explanation-*.md (Diataxis)"
        assert_match KINDS[kind][:h1], File.foreach(file).first.to_s,
                     "#{rel(file)}: a #{kind} doc's title starts #{KINDS[kind][:h1].source}"
      end
    end

    def test_docs_index_files_every_doc_under_its_kind
      index = docs_index
      assert_equal KINDS.values.map { _1[:section] }.sort, index.keys.sort,
                   "docs/README.md's \"By reader need\" sections changed; update KINDS"
      docs.each do |file|
        next unless (kind = kind_of(file)) # test_every_doc_is_a_diataxis_kind reports it

        name = File.basename(file)
        filed = index.select { |_, names| names.include?(name) }.keys
        assert_equal [KINDS[kind][:section]], filed,
                     "docs/README.md must list #{name} once, under #{KINDS[kind][:section]}"
      end
    end

    def test_readme_files_each_doc_under_its_kind
      bullets = readme_doc_bullets
      assert_equal KINDS.values.map { _1[:bullet] }.sort, bullets.keys.sort,
                   "README.md's docs bullets changed; update KINDS"
      misfiled = bullets.flat_map do |label, names|
        names.reject { KINDS[kind_of(_1)]&.dig(:bullet) == label }.map { "#{_1} under #{label}" }
      end
      assert_empty misfiled, "README.md files these docs under the wrong Diataxis kind"
    end

    def test_verified_versions_live_only_in_claude_md
      copies = (docs + %w[AGENTS.md CONTRIBUTING.md README.md].map { File.join(ROOT, _1) })
               .flat_map do |file|
        File.read(file).gsub(/\s+/, " ").scan(VERIFIED_VERSION).map { "#{rel(file)}: #{_1}" }
      end
      assert_empty copies, "a contract's last-verified version is tracked only in CLAUDE.md " \
                           "(\"Upstream contracts, last verified\"); link " \
                           "../CLAUDE.md#upstream-contracts-last-verified instead"
    end

    # The docs describe how switchboard works now; deferred work lives in TODOS.md alone.
    # docs/README.md may still link the backlog from its "See also".
    def test_docs_dont_reference_todos
      mentions = docs.flat_map do |file|
        File.foreach(file).with_index(1).select { |line, _| line.match?(/\bTODO/i) }
            .map { |_, n| "#{rel(file)}:#{n}" }
      end
      assert_empty mentions, "the docs describe what is, not the backlog: state the gap or " \
                             "limitation plainly and keep the plan in TODOS.md"
    end

    # A "§ Section" pointer is a link with an anchor, so the link test above checks it;
    # bare prose pointers went stale silently when the docs' headings changed.
    def test_section_pointers_are_links
      bare = markdown_files.flat_map do |file|
        File.foreach(file).with_index(1).filter_map do |line, n|
          stripped = line.gsub(/\[[^\]]*\]\([^)]*#[^)]+\)/, "")
          "#{rel(file)}:#{n}" if stripped.include?("§")
        end
      end
      assert_empty bare, "write a section pointer as [doc § Heading](doc.md#heading)"
    end

    # An issue or PR number tells a reader nothing the sentence shouldn't say itself, and
    # those from before v0.50.0 point into a private archive. Code spans and fences are out:
    # sample PR badges (`#128`) are drawn output. A link target is out only as an anchor.
    def test_docs_dont_cite_issue_numbers
      cited = markdown_files.reject { File.basename(_1).match?(/\A(CHANGELOG|TODOS)\.md\z/) }.flat_map do |file|
        without_fences(File.read(file, encoding: "UTF-8")).lines.select { cites_issue_number?(_1) }
                                                           .map { "#{rel(file)}: #{_1.strip[0, 70]}" }
      end
      assert_empty cited, "say what the behaviour is instead of citing its issue or PR number"
    end

    # thoughts/ is gitignored, so a pointer into it leads nowhere for a reader.
    def test_docs_dont_point_into_thoughts
      mentions = (docs + [File.join(ROOT, "docs/README.md")]).flat_map do |file|
        File.foreach(file).with_index(1).select { |line, _| line.include?("thoughts/") }
            .map { |_, n| "#{rel(file)}:#{n}" }
      end
      assert_empty mentions, "thoughts/ is local and gitignored; put what the reader needs in the doc"
    end

    private

    def claude_md = File.join(ROOT, "CLAUDE.md")
    def docs = Dir[File.join(ROOT, "docs/*.md")].reject { File.basename(_1) == "README.md" }.sort
    def markdown_files = Dir[File.join(ROOT, "{*.md,docs/*.md}")].sort
    def rel(file) = file.delete_prefix("#{ROOT}/")
    def kind_of(file) = File.basename(file)[/\A(#{KINDS.keys.join("|")})-/o, 1]

    def without_fences(text) = text.gsub(/^(```|~~~).*?^\1[^\n]*$/m, "")

    # `(?<!&)` spares an HTML entity; a `repo#57` citation still counts.
    def cites_issue_number?(line)
      prose = line.gsub(/(`+).*?\1/, "")
      prose.match?(%r{/(?:issues|pull)/\d|\b(?:issue|PR)s? \d}i) ||
        prose.gsub(/\]\([^)]*\)/, "]").match?(/(?<!&)#\d/)
    end

    def headings(file)
      without_fences(File.read(file)).scan(/^#+\s+(.+?)\s*#*$/).flatten
    end

    # GitHub's slugs: lowercase, punctuation dropped, spaces to hyphens, -N on repeats.
    def anchors(file)
      @anchors ||= {}
      @anchors[file] ||= begin
        seen = Hash.new(0)
        headings(file).map do |heading|
          slug = heading.downcase.gsub(/[^\p{L}\p{N}\p{M}_\- ]/u, "").tr(" ", "-")
          (seen[slug] += 1) == 1 ? slug : "#{slug}-#{seen[slug] - 1}"
        end
      end
    end

    def links(file)
      without_fences(File.read(file)).gsub(/`[^`\n]*`/, "")
                                      .scan(/\]\(([^)\s]+)(?:\s+"[^"]*")?\)/).flatten
                                      .reject { _1.match?(/\A[a-z]+:/) }
    end

    # [[target doc, quoted section name]] for each quoted section pointer in a file's text.
    def quoted_doc_sections(file, text)
      linked = text.scan(/\]\(([^)\s#]+\.md)(?:#[^)]*)?\)\s*,\s*["“]([^"”]+)["”]/).map do |path, quote|
        [File.expand_path(path, File.dirname(file)), quote]
      end
      named = text.scan(/\(([^()\[\]]*?),\s*["“]([^"”]+)["”]\)/).filter_map do |lead, quote|
        name = doc_nicknames.keys.find { lead.downcase.end_with?(_1) }
        [doc_nicknames[name], quote] if name
      end
      linked + named
    end

    # The plain names docs go by: the text of every link to a doc, e.g. "agent presence".
    def doc_nicknames
      @doc_nicknames ||= markdown_files.each_with_object({}) do |file, names|
        File.read(file).scan(/\[([^\]`]{3,40})\]\(([^)\s#]*explanation-[\w-]+\.md|[^)\s#]*(?:howto|reference|tutorial)-[\w-]+\.md)/) do |label, path|
          names[label.downcase.strip] ||= File.expand_path(path, File.dirname(file))
        end
      end
    end

    def section_named?(heading, quote)
      plain = heading.delete("`").downcase
      wanted = quote.delete("`").downcase
      plain == wanted || plain.start_with?("#{wanted}:", "#{wanted} (", "#{wanted} —")
    end

    # Comment markers dropped and lines joined, so a reference wrapped across lines still reads as one.
    def prose(file)
      File.read(file).lines.map { _1.sub(/\A\s*#\s?/, "") }.join(" ").gsub(/\s+/, " ")
    rescue ArgumentError # a binary file
      ""
    end

    # docs/README.md's "By reader need" section title => the doc filenames linked under it.
    def docs_index
      text = File.read(File.join(ROOT, "docs/README.md"))[/^## By reader need.*?(?=^## )/m].to_s
      text.split(/^### /).drop(1).to_h do |section|
        title = KINDS.values.map { _1[:section] }.find { section.lines.first.include?(_1) }
        [title || section.lines.first.strip, section.scan(/\]\(([\w-]+\.md)\)/).flatten]
      end
    end

    # README.md's Diataxis bullets ("- **Reference** — …") => the docs/ filenames each links.
    def readme_doc_bullets
      labels = KINDS.values.map { _1[:bullet] }
      File.read(File.join(ROOT, "README.md")).split(/^- /).each_with_object({}) do |bullet, found|
        label = bullet[/\A\*\*(.+?)\*\*/, 1]
        next unless labels.include?(label)

        found[label] = bullet[/\A.*?(?=\n\n|\z)/m].scan(%r{\]\(docs/([\w-]+\.md)\)}).flatten
      end
    end
  end
end
