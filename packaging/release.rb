# frozen_string_literal: true

# The pure half of .github/workflows/release.yml, kept here so it's unit-tested
# offline (test/release_test.rb) instead of living as untestable YAML shell.
#
#   ruby packaging/release.rb version                 # → 0.50.0
#   ruby packaging/release.rb notes 0.50.0 TITLE_FILE NOTES_FILE
#   ruby packaging/release.rb tarball-url 0.50.0
#   ruby packaging/release.rb plan true false true   # → release=…/tap=…/reason=…
#   ruby packaging/release.rb formula 0.50.0 SHA256 [TEMPLATE]   # rendered formula → stdout
module Release
  module_function

  ROOT = File.expand_path("..", __dir__)
  REPO = "wvmitchell/switchboard"
  FORMULA_URL = %r{^(\s*url ")#{Regexp.escape("https://github.com/#{REPO}/archive/refs/tags/v")}[^"]+\.tar\.gz(")$}
  FORMULA_SHA = /^(\s*sha256 ")[^"]*(")$/
  # sha256 of zero bytes: what a failed/empty tarball download hashes to.
  EMPTY_SHA = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

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
    raise "sha256 of an empty file: the tarball download failed" if sha == EMPTY_SHA

    url = tarball_url(version)
    [FORMULA_URL, FORMULA_SHA].each do |re|
      n = template.scan(re).size
      raise "formula template: expected one #{re.source} line, found #{n}" unless n == 1
    end
    template.sub(FORMULA_URL) { "#{$1}#{url}#{$2}" }.sub(FORMULA_SHA) { "#{$1}#{sha}#{$2}" }
  end

  # What a release run should do. Only main's tip acts (a pending run can be
  # superseded and runs finish out of order, so anything else could tag a stale
  # commit or move the tap backwards), and only once every gating CI workflow
  # (test AND formula) is green for it, so whichever finishes second acts. The
  # tap update is idempotent, so it runs on every acting run (healing a failed or
  # late-enabled update), tagging only for a new version.
  def plan(tip:, tagged:, checks_green:)
    return { release: false, tap: false, reason: "not main's tip; the tip's run acts instead#{' (version still untagged)' unless tagged}" } unless tip
    return { release: false, tap: false, reason: "waiting on test + formula to both pass for main's tip" } unless checks_green

    { release: !tagged, tap: true, reason: tagged ? "already tagged; refreshing the tap" : "new version" }
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
  when "plan"
    tip, tagged, green = ARGV[1, 3].map { |a| a == "true" }
    Release.plan(tip: tip, tagged: tagged, checks_green: green).each { |k, v| puts "#{k}=#{v}" }
  when "formula"
    template = ARGV[3] || File.join(Release::ROOT, "packaging/homebrew/switchboard.rb")
    print Release.render_formula(File.read(template), ARGV[1], ARGV[2])
  else
    abort "usage: release.rb version | notes VERSION TITLE_FILE NOTES_FILE | tarball-url VERSION | " \
          "plan TIP TAGGED CHECKS_GREEN | formula VERSION SHA256 [TEMPLATE]"
  end
end
