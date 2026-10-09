cask "mac-runner" do
  # scripts/build-release.sh sets both on every release.
  version "1.27.1"
  sha256 "a7cae18dd90555d9049b07c7ba4af7dc9bf2986af342c231ba8f61c4da6f5f54"

  url "https://github.com/sloper-ai/mac-runner/releases/download/v#{version}/MacRunner-#{version}.zip"
  name "Mac Runner"
  desc "Menu bar app for GitHub Actions self-hosted runners, with a Docker engine"
  homepage "https://github.com/sloper-ai/mac-runner"

  depends_on macos: :ventura

  app "MacRunner.app"
  binary "#{appdir}/MacRunner.app/Contents/MacOS/MacRunner", target: "mac-runner"

  # Releases are signed ad hoc and not notarized, so Gatekeeper would refuse to open
  # the app while it carries the quarantine flag of the download.
  postflight_steps do
    run "/usr/bin/xattr",
        args:         ["-d", "-r", "com.apple.quarantine", "{{appdir}}/MacRunner.app"],
        must_succeed: false
  end

  # `zap` is a blunt, whole-directory removal of the invoking user's files, which is
  # what `brew zap` is for. `mac-runner uninstall` is the surgical path: it deregisters
  # runners from GitHub, reaches service-user workspaces under /Users/<service-user>,
  # and preserves anything inside ~/.mac-runner it does not recognise as its own.
  zap trash: [
    # Runner workspaces live outside Application Support because the GitHub runner
    # scripts break on paths containing spaces. This is by far the largest artifact:
    # each configured runner holds an extracted runner release plus its _work checkout.
    "~/.mac-runner",
    "~/Library/Application Support/CrashReporter/mac-runner_*.plist",
    "~/Library/Application Support/CrashReporter/MacRunner_*.plist",
    "~/Library/Application Support/MacRunner",
    "~/Library/Caches/com.omniaura.mac-runner",
    "~/Library/HTTPStorages/com.omniaura.mac-runner",
    "~/Library/HTTPStorages/com.omniaura.mac-runner.binarycookies",
    "~/Library/HTTPStorages/mac-runner",
    "~/Library/HTTPStorages/MacRunner",
    "~/Library/Logs/DiagnosticReports/mac-runner-*.ips",
    "~/Library/Logs/DiagnosticReports/MacRunner-*.ips",
    "~/Library/Preferences/com.omniaura.mac-runner.plist",
    "~/Library/Preferences/mac-runner.plist",
    "~/Library/Saved Application State/com.omniaura.mac-runner.savedState",
  ]

  caveats <<~EOS
    Mac Runner from this tap is signed ad hoc, not with an Apple Developer ID,
    and is not notarized. So that macOS opens it, this cask removes the
    com.apple.quarantine flag from MacRunner.app after installing it.

    To get started:

    1. Install and authenticate the GitHub CLI: brew install gh && gh auth login
    2. Launch from Applications or run: open /Applications/MacRunner.app
    3. Click the runner icon in the menu bar and add a runner
    4. Or use the CLI: mac-runner add owner/repo --name my-runner

    For help: https://github.com/sloper-ai/mac-runner

    To uninstall, run this first:

        mac-runner uninstall

    It deregisters your runners from GitHub - otherwise they linger in the
    repository's Actions settings as permanently offline runners - and removes
    workspaces owned by a dedicated service user, which live outside your home
    directory and are not reachable by `brew zap`.
  EOS
end
