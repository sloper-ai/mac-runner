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

When a release is due, semantic-release, on a GitHub-hosted `macos-26` runner:

1. Works out the version and the release notes, and adds the notes to `CHANGELOG.md`.
2. Runs `scripts/build-release.sh <version>`, which builds a universal (arm64 + x86_64) release binary, assembles `build/MacRunner.app` with an `Info.plist` for that version, signs it, zips it to `build/MacRunner-<version>.zip`, and writes the version and the zip's SHA-256 into `Casks/mac-runner.rb`.
3. Commits `CHANGELOG.md` and `Casks/mac-runner.rb` to `main` as `chore(release): <version> [skip ci]` and tags that commit `v<version>`.
4. Publishes the GitHub release with the zip attached.

When no release is due, nothing is built. semantic-release doesn't comment on issues or pull requests: issues are disabled in this fork.

## The Homebrew tap

This repository is the tap: `Casks/mac-runner.rb` on `main` is what `brew` installs, and every release moves it to the new version (step 3). The repository isn't named `homebrew-…`, so people tap it by URL:

```bash
brew tap sloper-ai/mac-runner https://github.com/sloper-ai/mac-runner
brew install --cask sloper-ai/mac-runner/mac-runner
```

The app checks this repository's latest release for updates and, when the cask installed it, upgrades with `brew upgrade --cask sloper-ai/mac-runner/mac-runner`.

## The token for the release commit

Step 3 pushes to `main` directly. The organization's ruleset for default branches requires pull requests, and the workflow's `GITHUB_TOKEN` may not bypass it, so with `GITHUB_TOKEN` alone a release fails at that push, after the build: no commit, tag or release is created.

Give the workflow a token that may push to `main` as a repository secret named `RELEASE_TOKEN`, for example a fine-grained personal access token of an organization admin with **Contents: Read and write** on this repository. The workflow uses it in place of `GITHUB_TOKEN` whenever it is set. Exempting this repository from the ruleset works too.

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

To retry a failed release, rerun the Release workflow, or run it from the **Actions** tab (**Run workflow** on `main`). It still releases only if there are unreleased `feat:`, `fix:` or `perf:` commits. To release a change that was merged without one, merge a commit such as `fix: release <change>` (see [AGENTS.md](AGENTS.md)).

## Troubleshooting

- **No workflow runs at all.** GitHub disables workflows in a new fork until someone enables them on the repository's **Actions** tab.
- **`startup_failure`.** The organization allows only GitHub-owned actions (`actions/*`), pinned to a full commit SHA with the version in a comment, such as `actions/checkout@<sha> # v7.0.1`. `gh api repos/actions/checkout/git/ref/tags/v7.0.1` gives the SHA; if its object is a `tag`, `gh api repos/actions/checkout/git/tags/<sha>` gives the commit it points to.
- **The release commit's push is rejected.** See [The token for the release commit](#the-token-for-the-release-commit).
- **The build fails.** The package needs Swift 6, and Apple's Containerization needs Xcode 26 or newer; the default Xcode of `macos-26` has both. The workflow's *Show toolchain* step prints the versions in use.
