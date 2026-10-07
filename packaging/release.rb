# frozen_string_literal: true

# The pure half of .github/workflows/release.yml, kept here so it's unit-tested
# offline (test/release_test.rb) instead of living as untestable YAML shell.
#
#   ruby packaging/release.rb version                 # → 0.50.0
#   ruby packaging/release.rb notes 0.50.0 TITLE_FILE NOTES_FILE
#   ruby packaging/release.rb tarball-url 0.50.0
#   ruby packaging/release.rb formula 0.50.0 SHA256   # rendered formula → stdout
module Release
  module_function

  ROOT = File.expand_path("..", __dir__)
  REPO = "wvmitchell/switchboard"
  FORMULA_URL = %r{^(\s*url ")#{Regexp.escape("https://github.com/#{REPO}/archive/refs/tags/v")}[^"]+\.tar\.gz(")$}
  FORMULA_SHA = /^(\s*sha256 ")[^"]*(")$/

  def version(path = File.join(ROOT, "lib/switchboard/version.rb"))
    File.read(path)[/VERSION = "(\d+\.\d+\.\d+)"/, 1] or raise "no VERSION in #{path}"
  end

  # [title, body] for the `## [x.y.z] — title (date)` CHANGELOG section. A version
  # with no entry is an error — releasing without notes means the bump skipped the
  # CHANGELOG half of the convention.
  def notes(changelog, version)
    lines = changelog.lines
    start = lines.index { |l| l.start_with?("## [#{version}]") } or raise "no CHANGELOG entry for #{version}"
    stop = lines[(start + 1)..].index { |l| l.start_with?("## [") }
    body = lines[(start + 1)...(stop ? start + 1 + stop : lines.size)].join.strip
    heading = lines[start].sub(/\A## \[#{Regexp.escape(version)}\]\s*(—|-)?\s*/, "").sub(/\s*\(\d{4}-\d{2}-\d{2}\)\s*\z/, "").strip
    ["v#{version}#{" — #{heading}" unless heading.empty?}", body]
  end

  # The in-repo formula with url + sha256 pointed at this release. Exactly one of
  # each must be replaced — a template that drifted would otherwise ship stale.
  def render_formula(template, version, sha)
    raise "bad sha256: #{sha.inspect}" unless sha.match?(/\A\h{64}\z/)

    url = tarball_url(version)
    [FORMULA_URL, FORMULA_SHA].each do |re|
      n = template.scan(re).size
      raise "formula template: expected one #{re.source} line, found #{n}" unless n == 1
    end
    template.sub(FORMULA_URL) { "#{$1}#{url}#{$2}" }.sub(FORMULA_SHA) { "#{$1}#{sha}#{$2}" }
  end

  def tarball_url(version)
    "https://github.com/#{REPO}/archive/refs/tags/v#{version}.tar.gz"
  end
end

if $PROGRAM_NAME == __FILE__
  case ARGV[0]
  when "version" then puts Release.version
  when "notes"
    title, body = Release.notes(File.read(File.join(Release::ROOT, "CHANGELOG.md")), ARGV[1])
    File.write(ARGV[2], title)
    File.write(ARGV[3], "#{body}\n")
  when "tarball-url" then puts Release.tarball_url(ARGV[1])
  when "formula"
    print Release.render_formula(File.read(File.join(Release::ROOT, "packaging/homebrew/switchboard.rb")), ARGV[1], ARGV[2])
  else
    abort "usage: release.rb version | notes VERSION TITLE_FILE NOTES_FILE | tarball-url VERSION | formula VERSION SHA256"
  end
end
