# frozen_string_literal: true

require_relative "hook_file"
require_relative "marker_block"
require "strscan"

module Switchboard
  # The Codex adapter — GLOBAL delivery.
  #
  # Codex (verified 0.142 through 0.163) deliberately does NOT load a linked git
  # worktree's own `<worktree>/.codex/hooks.json`: it redirects a linked worktree's project
  # hooks to the MAIN checkout's `.codex/`. Switchboard is nothing but linked worktrees, so
  # the per-worktree file is dead on arrival. A CONFIG-level hook is not project-discovered,
  # so it fires everywhere — including linked worktrees. So Codex hooks ship as ONE
  # marker-delimited `[hooks]` block in the user's `~/.codex/config.toml` (via the shared
  # `MarkerBlock`), installed once with the user's consent (`Installer`), keyed off cwd by
  # the same agent-neutral reporter Claude uses. `AgentState` only renders tracked
  # worktrees, so the block firing for non-switchboard codex sessions is inert there.
  #
  # Trust: Codex won't run any hook until it's `/hooks`-approved (or bypassed). Codex
  # records each approval as a `[hooks.state."<file>:<event>:<i>:<j>"]` table holding the
  # command's `trusted_hash`, appended right after our `[hooks]` table — i.e. INSIDE this
  # block. So a re-`install_global` carries those tables into the new block, and the
  # approval survives AS LONG AS the emitted commands stay byte-stable (deterministic
  # paths + fixed event order; see HookFile.command_entries). Changing a command
  # re-triggers a one-time `/hooks` review. `remove_global` drops OUR approvals with the
  # block; approvals for other hook files (and codex's own tables) stay.
  #
  # Nesting: a global hook fires for EVERY codex, including a nested `codex exec` (a
  # `/codex` under Claude). The GUARD suppresses it when a Claude-Code parent is detected
  # (CLAUDECODE / CLAUDE_CODE_SESSION_ID propagate into the hook env). A top-level codex
  # launched by switchboard into a tmux shell has neither, so it fires. (Codex-under-codex
  # carries no Claude marker and is not caught — documented residual.)
  #
  # No Notification event: PermissionRequest is Codex's only user-blocked signal, so
  # `waiting` is best-effort (a session command that bypasses ALL approvals suppresses it).
  module CodexHook
    module_function

    BEGIN_MARK = "# >>> switchboard codex hooks >>>"
    # Codex keeps its own tables inside the block too, so this must never say "delete the
    # block": `uninstall` removes only switchboard's part. A comment, so changing it re-hashes
    # nothing.
    NOTE_MARK  = "# managed by switchboard — regenerated on install; `switchboard uninstall` removes it"
    END_MARK   = "# <<< switchboard codex hooks <<<"
    TRUST_TABLE = /\A\s*\[hooks\.state[\].]/
    TRUST_KEY = /\A\s*\[hooks\.state\."(.+):([a-z_]+):(\d+):(\d+)"\]/
    HOOKS_KEY = /(?:hooks|"hooks"|'hooks')/ # the `hooks` key, bare or either-quoted
    TOML_KEY = /(?:[A-Za-z0-9_-]+|"(?:[^"\\]|\\.)*"|'[^']*')/
    # A real TOML table-header LINE — `[a.b."c d"]` / `[[x]]`, optional trailing comment —
    # not just a line starting with `[` (a multi-line array's `  [1, 2],` continuation isn't one).
    HEADER = /\A\s*\[\[?\s*#{TOML_KEY}(?:\s*\.\s*#{TOML_KEY})*\s*\]\]?\s*(?:#.*)?\z/
    # The only lines our own `[hooks]` chunk may hold (besides blanks and comments): one-line
    # `<Event> = [...]` arrays, as `toml_hooks` and older releases wrote them.
    OUR_LINE = /\A[A-Z][A-Za-z]* = \[.*\]\s*\z/
    # The fix-it advice for every :unsafe report (install, uninstall, enable-hooks, doctor), so
    # it can't drift from movable_parts' rules. Keys AFTER the end marker belong to a table
    # inside the block, so "move them above the block" would silently re-home them — say where.
    # A lone `# >>>` is usually OUR block missing its end line: deleting it would orphan our [hooks]
    # (uninstall then sees nothing to remove, and install reads it as the user's), so say restore.
    UNSAFE_ADVICE = "its switchboard block holds lines switchboard didn't write, is followed by keys that belong " \
                    "to a table inside it, is duplicated, or has a # >>> / # <<< marker line without its partner. " \
                    "Move any setting you added inside (or right after) the markers into its own table outside " \
                    "them; if the block's `#{END_MARK}` line is gone, put it back after the block's last line " \
                    "(don't delete the `# >>>` line: the [hooks] under it is switchboard's); delete only a marker " \
                    "line with no block of its own. Codex itself may have written a `[[…]]` table there, or a " \
                    "table with a multi-line string (it appends new tables at the end of the file): move those " \
                    "tables, in their order, to just above the `# >>>` line. Then re-run"

    # Skip the codex reporter/nudge when running under another agent. Equal-precedence,
    # left-associative sh: `(A || B) && exit 0` — exit 0 (suppress) if EITHER marker is
    # set, else fall through to the command.
    GUARD = '[ -n "$CLAUDECODE" ] || [ -n "$CLAUDE_CODE_SESSION_ID" ] && exit 0'

    EVENTS = [
      ["UserPromptSubmit",  "thinking", nil],
      ["PreToolUse",        "thinking", "*"],
      ["PostToolUse",       "thinking", "*"],
      ["PermissionRequest", "waiting",  "*"],
      ["SessionStart",      "done",     nil]
    ].freeze

    def label = "codex"

    # ~/.codex/config.toml, honoring $CODEX_HOME (and sandboxed in tests).
    def config_path
      File.expand_path(File.join(ENV["CODEX_HOME"] || "~/.codex", "config.toml"))
    end

    # Idempotently write the global [hooks] block. Returns the path, or :collision if the
    # user has their own hooks config, :unsafe if the block holds something a line-based
    # move could break (see `movable_parts`), or :conflict if the file changed under us
    # (codex wrote it mid-install). Best-effort: any other error degrades to nil (never
    # crashes install).
    #
    # Codex appends every NEW table it writes after the file's last table and before its
    # trailing comments (toml_edit), and our block sits at EOF with a comment for an end
    # marker — so codex's own [desktop] / [plugins."…"] tables land INSIDE our markers.
    # Install keeps them: they move, verbatim and in order, to just above the block (which
    # stays last, where `MarkerBlock.build` appends it). Codex's `[hooks.state…]` trust
    # tables always follow `[hooks]`, so they're carried inside the block.
    def install_global
      script = HookFile.ensure_script
      existed = File.exist?(config_path)
      body = existed ? read_config : ""
      new_body = planned_install(body, script)
      return new_body if new_body.is_a?(Symbol) # :collision / :unsafe — the caller reports it
      return config_path if new_body == body # nothing to change: no write, no race window

      write_unless_changed(body, new_body, existed) || config_path
    rescue StandardError
      nil
    end

    # true only when the block was actually removed, so uninstall can't report a removal
    # that didn't happen; :unsafe / :conflict as for install. Codex's own tables found
    # inside the block stay (moved above where it was); only ours + our trust go.
    def remove_global
      return false unless File.exist?(config_path)

      body = read_config
      return false unless MarkerBlock.present?(body, BEGIN_MARK)

      parts = movable_parts(body) or return :unsafe
      # Our approvals codex filed below a table hand-added after the block are dead too.
      outside = drop_chunks(MarkerBlock.strip(body, BEGIN_MARK, END_MARK)) { |chunk| our_approval(chunk) }
      # Codex files EVERY approval under `[hooks.state]`, so the block also holds trust for
      # other hook files (a project `.codex/hooks.json`, plugins). Only ours goes with it.
      kept = parts[:foreign] + parts[:trust].reject { |chunk| our_trust?(chunk) }
      stripped = with_foreign(outside, kept)
      return false if stripped == body
      return :unsafe unless conserved?(stripped, [outside, *kept], "")

      write_unless_changed(body, stripped, true) || true
    rescue StandardError
      false
    end

    # Read-only twin of install_global for doctor: :current when the on-disk block's event lines
    # are exactly what install would write, :stale when they differ (an older release, or another
    # checkout's bin path), :unsafe when install would refuse to rewrite it, :collision when the
    # user's own hooks config sits outside it (install refuses that too, with its own advice).
    # Trust advice only makes sense for :current — approving a stale block blesses wrong commands.
    def block_state
      body = read_config
      ours = our_hooks(body) or return :unsafe
      plan = planned_install(body, HookFile.script_path) # the same checks install runs
      return plan if plan.is_a?(Symbol)

      event_groups(ours) == event_groups(toml_hooks(HookFile.script_path, bin)) ? :current : :stale
    rescue StandardError
      :unsafe
    end

    # [trusted, total]: how many of the hooks our block declares carry a codex
    # `[hooks.state."<file>:<event>:<group>:<handler>"]` approval (a `trusted_hash`, not
    # `enabled = false`). Untrusted hooks never run, so trusted < total means dead dots. A
    # hash's PRESENCE is all this can check — codex alone knows whether it still matches the
    # command (a changed command re-asks in `/hooks`); byte-stable commands keep it valid.
    # The key's file is compared by realpath: codex may spell the path differently from
    # CODEX_HOME (a symlinked ~/.codex).
    # gstack-shortcut(dec-455f3bf8): presence only, so an approval carried across a command change
    # still counts; upgrade when a user reports a green doctor with dead codex dots, or the next
    # change to codex trust handling.
    def trust_status
      body = File.exist?(config_path) ? read_config : ""
      expected = expected_trust_keys
      trusted = chunks(body).filter_map do |chunk|
        m = our_approval(chunk)
        next unless m && chunk.match?(/^\s*trusted_hash\s*=/)
        next if chunk.match?(/^\s*enabled\s*=\s*false\b/)

        key = "#{m[2]}:#{m[3]}:#{m[4]}"
        key if expected.include?(key)
      end
      [trusted.uniq.size, expected.size]
    rescue StandardError
      [0, expected_trust_keys.size]
    end

    # gstack-shortcut(dec-429d62c8): an invalid-UTF-8 config reads as no block (uninstall then skips it);
    # upgrade when a user reports it — codex rejects such a file too.
    def installed?
      File.exist?(config_path) && MarkerBlock.present?(read_config, BEGIN_MARK)
    rescue StandardError
      false
    end

    # The switchboard command the block's commands call (doctor names it in its :stale advice).
    def bin = ENV["SWITCHBOARD_BIN"] || "switchboard"

    # --- internals -----------------------------------------------------------

    # config.toml is UTF-8 (TOML requires it, and our note line has an em dash), whatever the
    # locale: under LC_ALL=C a default read is US-ASCII, every regex on it raises, and install
    # misreads its own write as a conflict while uninstall thinks nothing is installed.
    # A leading BOM is dropped too: every guard anchors on `\A\s*`, which a U+FEFF defeats, so a
    # user's `[hooks]` on line 1 would slip past the collision check (toml_edit skips the BOM).
    def read_config = File.read(config_path, encoding: Encoding::UTF_8).delete_prefix("\uFEFF")

    # What install would write over `body`: the new file, or :unsafe / :collision. block_state
    # runs the same plan, so doctor can't call a block current that install refuses.
    def planned_install(body, script)
      outside = MarkerBlock.strip(body, BEGIN_MARK, END_MARK)
      # Our own block first: with its end line gone, strip removes nothing and our `[hooks]`
      # would read as foreign — the advice the user needs is "restore the marker".
      parts = movable_parts(body) or return :unsafe
      # Collision guard: refuse if a hooks representation lives OUTSIDE our markers.
      return :collision if foreign_hooks?(outside)

      hooks = toml_hooks(script, bin)
      generated = "#{NOTE_MARK}\n[hooks]\n#{hooks}"
      # Every approval is carried, a changed command's too: codex re-asks for it in /hooks, and it
      # comes back valid when the command does (a checkout round trip); its `enabled` setting stays.
      trust = parts[:trust].join.strip
      inner = trust.empty? ? generated : "#{generated}\n\n#{trust}"
      new_body = MarkerBlock.build(with_foreign(outside, parts[:foreign]), BEGIN_MARK, END_MARK, inner)
      conserved?(new_body, [outside, *parts[:foreign], trust], generated) ? new_body : :unsafe
    end

    # The text between our markers split into `trust` (codex's `[hooks.state…]` approvals,
    # carried) and `foreign` (every other table codex appended there, moved out); our own
    # note + `[hooks]` are checked, then dropped (install regenerates them). nil when a line-based
    # move could change what the TOML means — there's no parser here (zero gems), so
    # refuse instead:
    #   - a multi-line string: a `[` line inside it would read as a header;
    #   - an array-of-tables `[[…]]`: its grouping and order carry meaning;
    #   - key lines before the first header (they belong to the table ABOVE the block) or
    #     right after the end marker (they belong to the last table INSIDE it): a comment
    #     doesn't end a table, so moving either re-homes them;
    #   - anything in OUR chunk we didn't write (a key codex or the user put in `[hooks]`, or
    #     a `[hooks.<x>]` table): regenerating ours would silently drop it;
    #   - any marker line beyond our block's own two: a second region (strip removes every
    #     region, but only one is split here), or a stray `# >>>` / `# <<<` beside ours,
    #     or a begin marker with no end marker (nothing would match, and install would
    #     append a second block).
    def movable_parts(body)
      match = MarkerBlock.region(BEGIN_MARK, END_MARK).match(body)
      parts = { trust: [], foreign: [] }
      return nil if !match && (MarkerBlock.present?(body, BEGIN_MARK) || body.match?(/^#{Regexp.escape(END_MARK)}/))
      return parts unless match
      return nil if body.scan(/^(?:#{Regexp.escape(BEGIN_MARK)}|#{Regexp.escape(END_MARK)})/).size != 2
      return nil if keys?(scan_lines(match.post_match.lines).first.take_while { |_l, _nested, opens| !opens }.map(&:first))

      chunks(match[1]).each do |chunk|
        kind = chunk_kind(chunk)
        return nil if kind == :unsafe || (kind == :preamble && keys?(chunk.lines))
        return nil if kind == :ours && !ours_only?(chunk)
        return nil if kind != :ours && kind != :preamble && chunk.match?(/"""|'''/)

        # gstack-shortcut(dec-3417a712): a comment trailing ours (or a dropped trust chunk) inside the
        # block goes with it, even one above a codex table that moves out; upgrade when a user reports one.
        parts[kind] << chunk unless kind == :ours || kind == :preamble # ours is regenerated
      end
      parts
    end

    # `text` without the chunks the block picks, except each dropped chunk's trailing comments:
    # a comment just above the next table is that table's (toml_edit reads it as its prefix).
    def drop_chunks(text)
      chunks(text).map do |chunk|
        next chunk unless yield(chunk)

        tail = chunk.lines.reverse.take_while { |l| l.strip.empty? || l.lstrip.start_with?("#") }.reverse
        tail.any? { |l| l.lstrip.start_with?("#") } ? tail.join : ""
      end.join
    end

    # Header-delimited chunks (a table header line plus everything up to the next).
    def chunks(text)
      scan_lines(text.to_s.lines).first.slice_before { |_l, _nested, opens| opens }.map { |rows| rows.map(&:first).join }
    end

    def header?(line) = line.chomp.match?(HEADER)

    # Each line as [line, nested?, opens-a-table?], plus whether anything is still open at EOF.
    # Only a header-shaped line at the top level opens a table: inside an open multi-line array
    # (`m = [\n  [1, 2]\n]`) or a multi-line `"""`/`'''` string, a `[…]` line is a value or
    # prose, however it looks. Brackets inside strings and comments don't count.
    def scan_lines(lines)
      depth = 0
      ml = nil
      rows = lines.map do |l|
        nested = depth.positive? || !ml.nil?
        opens = !nested && header?(l)
        unless opens
          bare, ml = bare_code(l, ml)
          depth = [depth + bare.count("[") - bare.count("]"), 0].max
        end
        [l, nested, opens]
      end
      [rows, depth.positive? || !ml.nil?]
    end

    # The line with its strings and comment removed, plus the multi-line string delimiter
    # still open after it (nil when none).
    def bare_code(line, ml)
      out = +""
      s = StringScanner.new(line)
      until s.eos?
        if ml == '"""'
          # A backslash escapes the next char, so `\"""` never closes; a closer may carry
          # up to two extra quotes (`""""` = a quote + the closer).
          if s.scan(/\\./m) then next
          elsif s.scan(/"""(?:""?)?/) then ml = nil
          else s.getch
          end
        elsif ml
          s.scan_until(/'''(?:''?)?/) ? ml = nil : s.terminate
        elsif s.scan(/"""|'''/) then ml = s.matched
        elsif s.scan(/"(?:[^"\\\n]|\\.)*"|'[^'\n]*'/) then next
        elsif s.scan(/#/) then s.terminate
        else out << s.getch
        end
      end
      [out, ml]
    end

    # :preamble (before any header), :trust, :ours (`[hooks]` itself), :foreign, or :unsafe
    # (an array-of-tables, or a `[hooks.<x>]` table that regenerating ours would drop).
    def chunk_kind(chunk)
      head = chunk.lines.first.to_s.chomp
      return :preamble unless head.match?(HEADER)
      # gstack-shortcut(dec-aae03c57): every [[…]] refuses, even a run codex appended that could move
      # like [desktop]; upgrade when codex is seen writing one into the block (e.g. [[skills.config]]).
      return :unsafe if head.match?(/\A\s*\[\[/)
      return :trust if head.match?(TRUST_TABLE)
      return :ours if head.match?(/\A\s*\[\s*#{HOOKS_KEY}\s*\]/)

      head.match?(/\A\s*\[\s*#{HOOKS_KEY}\s*\./) ? :unsafe : :foreign
    end

    def ours_only?(chunk)
      chunk.lines.drop(1).all? { |l| l.strip.empty? || l.lstrip.start_with?("#") || l.chomp.match?(OUR_LINE) }
    end

    def keys?(lines)
      lines.any? { |l| !l.strip.empty? && !l.lstrip.start_with?("#") }
    end

    # `outside` with codex's moved tables appended (so they land just above the block that
    # `MarkerBlock.build` appends next). No foreign tables ⇒ `outside` unchanged, so a
    # config codex never touched rewrites byte-for-byte as before (trust hashes stay put).
    def with_foreign(outside, foreign)
      return outside if foreign.empty?

      sep = outside.empty? || outside.end_with?("\n") ? "" : "\n"
      tables = foreign.join
      "#{outside}#{sep}#{tables}#{tables.end_with?("\n") ? "" : "\n"}"
    end

    # Line conservation: every non-blank line we meant to keep is in the new body, and the
    # only other lines are the ones we generate. A belt over the splitter — a bug there
    # aborts the write instead of losing a codex setting.
    def conserved?(new_body, kept, generated)
      ours = (generated.lines + ["#{BEGIN_MARK}\n", "#{END_MARK}\n"]).map(&:chomp)
      have = new_body.lines.map(&:chomp).reject { |l| l.strip.empty? }
      # Each kept piece split on its own: joining them first would fuse a piece that ends
      # without a newline (a trailing comment) with the next table header.
      want = kept.flat_map { |piece| piece.lines.map(&:chomp) }.reject { |l| l.strip.empty? }
      # Discount one copy per generated line, not every copy (Array#-): a kept line outside the
      # block can equal one of ours (a pasted note line), and must still count as kept.
      ours.each { |l| (i = have.index(l)) && have.delete_at(i) }
      have.sort == want.sort
    end

    # Write `new_body` only if the file still holds `body`, and never restore over a write
    # that lands while we're working: codex (often the desktop app) can save config.toml at
    # any moment, and rolling back to our snapshot would erase it. Returns :conflict for the
    # caller to report, nil on success. Not a lock (codex takes none) — a write in the last
    # instant before our rename can't be seen.
    def write_unless_changed(body, new_body, existed)
      return :conflict unless (File.exist?(config_path) ? read_config : nil) == (existed ? body : nil)

      MarkerBlock.backup(config_path) # first-write-only .bak (a pristine on-disk copy)
      MarkerBlock.atomic_write(config_path, new_body)
      return :conflict unless read_config == new_body

      nil
    end

    # "<event_snake>:<group>:<handler>" for every hook our block declares — codex indexes
    # groups per event in file order, one handler per group here.
    def expected_trust_keys
      event_groups(toml_hooks("sb", "sb")).flat_map do |event, groups|
        groups.each_index.map { |i| "#{trust_event(event)}:#{i}:0" }
      end
    end

    # Codex's trust-key spelling of an event: `PreToolUse` → `pre_tool_use`.
    def trust_event(event) = event.gsub(/([a-z])([A-Z])/, '\1_\2').downcase

    # Our `[hooks]` chunk(s) from the block on disk, or nil with no block.
    def our_hooks(body)
      match = MarkerBlock.region(BEGIN_MARK, END_MARK).match(body) or return nil
      chunks(match[1]).select { |c| chunk_kind(c) == :ours }.join
    end

    # Event → its group strings, split where `toml_hooks` joins them (`<Event> = [{ … }, { … }]`).
    def event_groups(text)
      text.lines.grep(OUR_LINE).to_h do |l|
        event, list = l.strip.split(" = ", 2)
        [event, list.delete_prefix("[").delete_suffix("]").split(/(?<=\}), (?=\{)/)]
      end
    end

    # The TRUST_KEY match of an approval for OUR file, else nil (other hook files, bare parents).
    def our_approval(chunk)
      m = chunk.match(TRUST_KEY)
      m if m && same_file?(m[1])
    end

    # A trust chunk for OUR file — or the bare `[hooks.state]` header, which only exists to
    # parent the approvals and goes with them. A bare header holding keys of its own is kept
    # (dropping it would silently lose them; conserved? never sees a chunk it was told to drop).
    def our_trust?(chunk)
      return true if our_approval(chunk)
      return false if chunk.match?(TRUST_KEY)

      chunk.match?(/\A\s*\[hooks\.state\]/) && !keys?(chunk.lines.drop(1))
    end

    def same_file?(path)
      File.realpath(path) == File.realpath(config_path)
    rescue StandardError
      File.expand_path(path) == File.expand_path(config_path)
    end

    # Any TOML `hooks` representation Codex accepts, outside our markers — in ANY spelling:
    # a table header `[hooks]` / `[ hooks ]` / `["hooks"]` / `[[hooks]]` / `[hooks.PreToolUse]`,
    # or a top-level `hooks =` / `hooks.managed_dir =` / `"hooks" =` dotted key (a `hooks` key
    # under some OTHER table is just that table's key), with the name bare, "double" or
    # 'single' quoted. Writing our own `[hooks]` alongside any of these makes two hooks
    # tables — invalid TOML that breaks the user's whole codex config — so we must detect
    # every form codex would parse as `hooks`. Codex's own `[hooks.state."…"]` approvals are
    # NOT a competing hooks config: a sub-table may precede an explicit `[hooks]` in valid
    # TOML, and they sit outside our block when they're for another hook file (left there by
    # uninstall, or written before we installed). `[[hooks.state]]` (an array) still collides.
    #
    # scan_lines keeps a `["hooks"]` array element (or a line of multi-line prose) from reading
    # as a table, and keeps the root-key scan going until the first REAL header. Both directions
    # fail closed: an unindented `[hooks…]` header line collides even when nested, and a bracket or
    # string left open at EOF (something the scanner misread) counts as a collision.
    def foreign_hooks?(stripped_body)
      rows, open_at_eof = scan_lines(stripped_body.lines)
      return true if open_at_eof

      rows.any? { |l, nested, _| foreign_hooks_header?(l) && (!nested || (header?(l) && !l.match?(/\A\s/))) } ||
        rows.take_while { |_l, _nested, opens| !opens }.any? { |l, nested, _| !nested && l.match?(/\A\s*#{HOOKS_KEY}\s*[.=]/) }
    end

    def foreign_hooks_header?(line)
      line.match?(/\A\s*\[\[\s*#{HOOKS_KEY}\s*[.\]]/) ||
        line.match?(/\A\s*\[\s*#{HOOKS_KEY}\s*(?:\]|\.(?!\s*(?:state|"state"|'state')\s*[.\]]))/)
    end

    # Serialize the shared command list into TOML `<Event> = [<groups>]` lines. Reuses
    # HookFile.command_entries (the same reporter/nudge/Stop strings as Claude) with the
    # codex guard. TOML BASIC strings (not literal) so a path with a single quote can't
    # break the string and the guard's double quotes escape cleanly.
    def toml_hooks(script, bin)
      by_event = Hash.new { |h, k| h[k] = [] }
      HookFile.command_entries(EVENTS, script, bin, guard: GUARD).each do |e|
        hook = %({ type = "command", command = #{toml_str(e[:command])} })
        group = e[:matcher] ? %({ matcher = #{toml_str(e[:matcher])}, hooks = [#{hook}] }) : "{ hooks = [#{hook}] }"
        by_event[e[:event]] << group
      end
      by_event.map { |event, groups| "#{event} = [#{groups.join(", ")}]" }.join("\n")
    end

    # A TOML basic string: wrap in double quotes and escape backslash, double quote, AND
    # the control chars TOML basic strings forbid raw (U+0000–U+001F) — a path with a
    # literal newline/tab would otherwise emit an unterminated/multi-line string and break
    # the whole config. Predefined escapes where TOML has them, `\uXXXX` for the rest.
    # Block form avoids Ruby's gsub backslash-replacement footgun.
    TOML_ESCAPES = { "\\" => "\\\\", '"' => '\\"', "\b" => "\\b", "\t" => "\\t",
                     "\n" => "\\n", "\f" => "\\f", "\r" => "\\r" }.freeze
    def toml_str(str)
      escaped = str.gsub(/[\\"\x00-\x1f]/) { |c| TOML_ESCAPES[c] || format("\\u%04X", c.ord) }
      %("#{escaped}")
    end
  end
end
