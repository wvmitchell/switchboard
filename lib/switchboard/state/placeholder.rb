# frozen_string_literal: true

require "securerandom"

module Switchboard
  # A throwaway "adjective-noun-hex" name for a brand-new workspace, so you don't have
  # to invent a name before you know what the work is — you rename it (and its
  # branch) once you do (see Rename). Zero deps: two word lists, NOT the `faker`
  # gem. Words are short, lowercase, and hyphen-free so the result is a clean
  # leaf (and a valid branch name).
  module Placeholder
    module_function

    # Only ever grows: `generated?` must keep recognizing every name handed out before.
    ADJECTIVES = %w[
      amber azure bold brave bright calm clever cozy crisp dapper
      eager fancy gentle jolly keen lively lucky mellow merry nimble
      placid plucky quiet rustic shady snug spry sunny tidy witty
      wandering quirky breezy frosty golden hidden humble silent
      ancient arctic autumn balmy bashful blithe bouncy brisk bubbly candid
      cheerful chilly cobalt copper coral cosmic crimson curious dainty dandy
      dewy dusky earnest elated fabled feisty fleet fluffy foggy gallant
      giddy glad gleaming glossy graceful grand hardy hazy hearty hushed
      jaunty jovial leafy lofty loyal lunar marble mighty misty modest
      mossy noble olive opal patient peppy polished proud rosy ruby
      sandy serene shiny silky silver sleepy snowy solar spicy stellar
      stormy sturdy tawny tender thrifty tranquil trusty velvet vivid warm
      wild windy wise woolly zesty dreamy rugged sunlit starry
    ].freeze

    NOUNS = %w[
      acorn badger birch cedar cricket dawn ember falcon fern finch
      fjord glade grove harbor heron lark lichen maple meadow moss
      otter pine quill raven ridge river sparrow spruce thicket
      willow wren brook canyon hollow lantern pebble thistle
      alder aspen beaver bison bluff boulder bramble breeze burrow cairn
      cardinal cascade chickadee clover comet cove coyote crane creek crocus
      cypress dune eagle elk estuary fawn fox garnet geyser glacier
      gully hawk hazel heather hedge hickory ivy juniper kestrel lagoon
      laurel ledge lilac lynx magpie marsh mesa mink nectar oak
      orchard osprey owl prairie puffin quail reed robin rowan sage
      sequoia shore sierra skylark starling summit swallow tern thrush tide
      timber tundra valley violet walnut warbler wheat wolf yarrow minnow
      tortoise walrus bobcat cobble basin poppy
    ].freeze

    # A fresh "<adjective>-<noun>-<4 hex>" leaf. Agents key a workspace's history by its
    # folder, so a name reused after its workspace is gone would hand the new one the old
    # one's conversations. The suffix makes that astronomically unlikely (~1 billion names)
    # with nothing to remember; callers still retry past a live dir or branch collision.
    def generate
      "#{ADJECTIVES.sample}-#{NOUNS.sample}-#{SecureRandom.hex(2)}"
    end

    # Whether `leaf` looks like a name WE generated: "<adjective>-<noun>-<4 hex>", or the
    # suffixless shape older versions handed out, both words on our lists. This is #92's
    # "still unnamed" signal (a placeholder workspace the agent should rename), so it needs
    # no on-disk marker: a real rename changes the leaf and this goes false. A user who happens to
    # type an on-list adjective-noun reads as a placeholder — rare, and harmless
    # (auto_rename is opt-in and the nudge self-gates).
    def generated?(leaf)
      adj, noun, suffix = leaf.to_s.split("-", 3)
      (suffix.nil? || suffix.match?(/\A[0-9a-f]{4}\z/)) && ADJECTIVES.include?(adj) && NOUNS.include?(noun)
    end

    # Filesystem- and branch-safe: spaces become dashes, the char class drops
    # anything exotic, and ".", ".." and empty path segments are stripped so a
    # name can never climb out of (or absolute-jump around) the worktree root via
    # File.join — "../../etc" sanitizes to "etc", "/tmp/x" to "tmp/x", "." to "".
    # The one rule for workspace and project folder names (Creator, Rename).
    def sanitize(name)
      cleaned = name.to_s.strip.gsub(/\s+/, "-").gsub(%r{[^\w./-]}, "")
      cleaned.split("/").reject { |seg| seg.empty? || seg == "." || seg == ".." }.join("/")
    end
  end
end
