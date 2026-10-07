# How to cut a release and enable the Homebrew tap

Cut a switchboard release (tag, GitHub Release, Homebrew formula), and do the
one-time setup that lets the pipeline publish to the tap. For maintainers. What
each step does is in [Reference: the release pipeline](reference-release.md).

## Prerequisites

- Push access to `wvmitchell/switchboard`.
- For the one-time tap setup: admin on the repo, and the ability to create a repo
  under `wvmitchell` and a fine-grained personal access token.

## Cut a release

Releases are driven by `lib/switchboard/version.rb`. You bump it in a PR; the
pipeline does the rest after merge.

1. In your PR, bump `Switchboard::VERSION` in `lib/switchboard/version.rb`
   (`feat` → minor, `fix` → patch).
2. Add the matching `## [X.Y.Z] — <title> (<YYYY-MM-DD>)` entry at the top of
   `CHANGELOG.md`. The release notes come from this entry, and
   `test/release_test.rb` fails if the current version has none.
3. Title the PR `vX.Y.Z <type>(<scope>): <summary>` and merge it (squash).
4. Wait for `test` and `formula` to pass on main. Whichever finishes second
   triggers `release`, which creates the `vX.Y.Z` tag and the GitHub Release, then
   updates the tap (once it's enabled, below).

You never create tags by hand.

## Enable the Homebrew tap (one time)

Until these are done, releases still get a tag and a GitHub Release, and the tap
step logs why it skipped.

1. **Make the repo public.** Brew downloads the release tarball anonymously, so
   it must be public. Settings → General → Danger Zone → Change visibility, or:

   ```sh
   gh repo edit wvmitchell/switchboard --visibility public --accept-visibility-change-consequences
   ```

2. **Create the tap repo.** Brew finds `wvmitchell/switchboard/switchboard` in a
   repo named `homebrew-switchboard`:

   ```sh
   gh repo create wvmitchell/homebrew-switchboard --public \
     --description "Homebrew tap for switchboard"
   ```

   It can start empty; the pipeline writes `Formula/switchboard.rb`.

3. **Create a fine-grained personal access token** (GitHub → Settings →
   Developer settings → Fine-grained tokens):
   - Repository access: **only** `wvmitchell/homebrew-switchboard`.
   - Permissions: **Contents: Read and write**. Nothing else.
   - An expiry you'll remember to renew (fine-grained tokens last a year at most).

4. **Save it as a repo secret** on `wvmitchell/switchboard`, named
   `HOMEBREW_TAP_TOKEN`:

   ```sh
   gh secret set HOMEBREW_TAP_TOKEN --repo wvmitchell/switchboard
   ```

   (Paste the token when prompted, so it doesn't end up in your shell history.)

5. **Publish the current release to the tap.** Either push anything to main, or
   run the workflow by hand:

   ```sh
   gh workflow run release --repo wvmitchell/switchboard --ref main
   ```

   The tap step runs on every green main tip, so it fills in the formula for the
   latest tagged version even if that version was released before you set up the tap.

## Verification

```sh
gh release list --repo wvmitchell/switchboard -L 1          # the new vX.Y.Z
gh run list --repo wvmitchell/switchboard -w release -L 1   # the run that made it
brew update && brew info wvmitchell/switchboard/switchboard # shows vX.Y.Z
```

Each release run prints its decision as a notice, for example
`v0.50.0: new version` or `v0.50.0: already released; refreshing the tap`.

## Troubleshooting

- **The run says `waiting on every CI gate to pass for main's tip`.** `test` or
  `formula` hasn't passed on main for the tip yet. The run triggered by the second
  gate to finish will act. If a gate failed, fix main and push.
- **The run says `not main's tip`.** Main moved during the run; the newer
  commit's run handles it.
- **The run says `version.rb (…) is behind the newest tag`.** `version.rb` went
  backwards, from a reverted bump or a collision settled on a lower number. Bump
  it past the newest tag.
- **The tap step says `HOMEBREW_TAP_TOKEN not set` or `repo is private`.** Finish
  the one-time setup above.
- **The tap push fails with 403.** The token expired, or it lacks Contents
  write on the tap repo. Create a new one and `gh secret set` it again, then run
  the workflow by hand.
- **The Plan step fails with an error instead of a notice.** A lookup failed
  (GitHub API outage, permissions). The step fails on purpose, so it can't be
  mistaken for "nothing to do". Re-run the workflow once GitHub is healthy.
- **A tag exists but has no GitHub Release.** The next run creates the Release for
  the existing tag automatically, so just re-run the workflow.
- **`formula` fails on main.** Releases wait until it's green. Reproduce locally
  with the steps in `.github/workflows/formula.yml`: archive the commit, render
  the formula against it, `brew tap-new`, then `brew audit --strict`,
  `brew install`, `brew test`.

## Related

- [Reference: the release pipeline](reference-release.md)
- [Explanation: distribution](explanation-distribution.md)
- [CONTRIBUTING](../CONTRIBUTING.md)
