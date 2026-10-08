# Releasing Mac Runner

Releases of this fork are automatic. Every push to `main` runs the [Release workflow](.github/workflows/release.yml), and [semantic-release](https://github.com/semantic-release/semantic-release) works out from the commit messages whether a release is due.

## Conventional Commits decide the version

| Commits on `main` since the last release | Release |
| --- | --- |
| a `feat:` | minor: 1.25.1 → 1.26.0 |
| a `fix:` or `perf:`, and no `feat:` | patch: 1.25.1 → 1.25.2 |
| a breaking change: `feat!:`, `fix!:` or a `BREAKING CHANGE:` footer | major: 1.25.1 → 2.0.0 |
| only `docs:`, `ci:`, `build:`, `chore:`, `refactor:`, `test:` or `style:` | none |

`main` takes squash merges only, so semantic-release sees one commit per pull request, and GitHub gives it the pull request's title (the commit's, for a one-commit pull request). Give pull requests a Conventional Commits title.

Versions continue from the tags the fork inherited from upstream; `v1.25.1` is the latest. The rules are in [`.releaserc.json`](.releaserc.json).

## What a release does

When a release is due, the workflow, on a GitHub-hosted `macos-26` runner:

1. Has semantic-release work out the version and the release notes, and add the notes to `CHANGELOG.md` in the checkout.
2. Runs `scripts/build-release.sh <version>` (semantic-release's `prepareCmd`), which builds a universal (arm64 + x86_64) release binary, assembles `build/MacRunner.app` with an `Info.plist` for that version, signs it, zips it to `build/MacRunner-<version>.zip`, and writes the version and the zip's SHA-256 into `Casks/mac-runner.rb` in the checkout.
3. Tags the `main` commit that triggered the run `v<version>` and publishes the GitHub release with the zip attached.
4. Brings the updated `CHANGELOG.md` and `Casks/mac-runner.rb` to `main` through a [release pull request](#the-release-pull-request) that it merges itself.

When no release is due, nothing is built and no pull request is opened. semantic-release doesn't comment on issues or pull requests: issues are disabled in this fork.

## The Homebrew tap

This repository is the tap: `Casks/mac-runner.rb` on `main` is what `brew` installs, and every release moves it to the new version (step 4). The repository isn't named `homebrew-…`, so people tap it by URL:

```bash
brew tap sloper-ai/mac-runner https://github.com/sloper-ai/mac-runner
brew install --cask sloper-ai/mac-runner/mac-runner
```

The app checks this repository's latest release for updates and, when the cask installed it, upgrades with `brew upgrade --cask sloper-ai/mac-runner/mac-runner`.

## The release pull request

The organization's ruleset only accepts pull requests on `main` (squash merges, no approvals required), so the workflow never pushes to `main`. Once the release is published, semantic-release's `successCmd` writes its version to `build/released-version`, and the next step of the workflow:

1. commits `Casks/mac-runner.rb` and `CHANGELOG.md` as `github-actions[bot]` on a new branch `release/v<version>`, with the message `chore(release): <version> [skip ci]`, and pushes it;
2. opens a pull request titled `chore(release): <version>` against `main`;
3. squash-merges it with `GITHUB_TOKEN` and deletes the branch.

Merges made with `GITHUB_TOKEN` don't trigger workflows, so this doesn't start another release run, and `[skip ci]` keeps a merge by hand from starting one either. Opening the pull request relies on the repository setting that lets GitHub Actions create pull requests (**Settings → Actions → General → Workflow permissions**), which is on.

If GitHub refuses the merge, for example because the ruleset wants an approval for a change a bot made, the step fails with an error that links the pull request. The release is published by then; only the tap lags, offering the previous version until someone merges the pull request by hand. Merge it before the next release, whose pull request would otherwise be based on a `main` without it.

## Signing and notarization

By default releases are signed **ad hoc** with `scripts/MacRunner.entitlements`: no Apple Developer ID, no notarization. macOS won't open a quarantined app signed that way, so the cask removes the `com.apple.quarantine` flag after installing (its caveats say so), and people who download the zip themselves clear the flag by hand (see the README).

Releases switch to Developer ID signing with the hardened runtime, and to notarization, once these repository secrets exist:

| Secret | Description |
|--------|-------------|
| `APPLE_CERTIFICATE_BASE64` | Base64-encoded `.p12` Developer ID Application certificate |
| `APPLE_CERTIFICATE_PASSWORD` | Password for the `.p12` file |
| `APPLE_TEAM_ID` | 10-character Apple Developer Team ID |
| `APPLE_API_KEY_BASE64` | Preferred: base64-encoded App Store Connect API key (`.p8`) for notarization |
| `APPLE_API_KEY_ID` | Preferred: App Store Connect API key ID |
| `APPLE_API_ISSUER_ID` | Preferred: App Store Connect issuer ID |
| `APPLE_ID` | Optional fallback: Apple ID email used for notarization |
| `APPLE_ID_PASSWORD` | Optional fallback: app-specific password for notarization |

With the certificate secrets set, the workflow imports the certificate into a temporary keychain and exports `SIGNING_IDENTITY`. `scripts/build-release.sh` then signs the app with it, notarizes the zip through `scripts/notarize.sh` when the notarization secrets are set as well, staples the ticket and zips the stapled app again. The keychain and the API key are deleted at the end of the job. Once releases are notarized, the cask's `postflight_steps` and its quarantine caveat can go.

## Building a release locally

```bash
./scripts/build-release.sh 0.0.0-test   # build/MacRunner.app and build/MacRunner-0.0.0-test.zip
git checkout Casks/mac-runner.rb        # the script pointed the cask at the local zip
```

`make app` builds the same universal app bundle without zipping it or touching the cask.

## Releasing by hand

To retry a release that failed before it was tagged, rerun the Release workflow, or run it from the **Actions** tab (**Run workflow** on `main`). It still releases only if there are unreleased `feat:`, `fix:` or `perf:` commits. To release a change that was merged without one, merge a commit such as `fix: release <change>` (see [AGENTS.md](AGENTS.md)).

Once the tag exists, a rerun finds nothing to release and opens no pull request. If a release was published but its release pull request never got opened, make it by hand: put the version and the SHA-256 of the release's zip (`gh release download v<version> --pattern 'MacRunner-*.zip'`, then `shasum -a 256`) into `Casks/mac-runner.rb`, add the release notes to the top of `CHANGELOG.md`, and merge that as `chore(release): <version>`.

## Troubleshooting

- **No workflow runs at all.** GitHub disables workflows in a new fork until someone enables them on the repository's **Actions** tab.
- **`startup_failure`.** The organization allows only GitHub-owned actions (`actions/*`), pinned to a full commit SHA with the version in a comment, such as `actions/checkout@<sha> # v7.0.1`. `gh api repos/actions/checkout/git/ref/tags/v7.0.1` gives the SHA; if its object is a `tag`, `gh api repos/actions/checkout/git/tags/<sha>` gives the commit it points to.
- **"Release pull request not merged".** The release is out; merge the linked `release/v<version>` pull request by hand. See [The release pull request](#the-release-pull-request).
- **"GitHub Actions is not permitted to create or approve pull requests".** Turn that setting back on under **Settings → Actions → General → Workflow permissions**, then open a pull request from the `release/v<version>` branch the workflow already pushed, and merge it.
- **The build fails.** The package needs Swift 6, and Apple's Containerization needs Xcode 26 or newer; the default Xcode of `macos-26` has both. The workflow's *Show toolchain* step prints the versions in use.
