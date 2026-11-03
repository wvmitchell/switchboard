# frozen_string_literal: true

module Switchboard
  # The install this process loaded: the checkout, or under Homebrew the keg's realpath
  # (require resolves symlinks, so __dir__ is the real lib dir). Captured once, at require
  # time, before an upgrade can move opt/.
  #
  # The one place a file locates paths from its own position. Pinned: it must never move
  # out of lib/switchboard/, because ROOT is computed from where this file sits. Files that
  # need the root require this one directly, so they still load on their own.
  ROOT = File.expand_path("../..", __dir__)
end
