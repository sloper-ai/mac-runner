# Mac Runner

Simple Mac menu bar app and CLI for managing GitHub Actions self-hosted runners.

## Features

- 🏃 Run multiple GitHub Actions runners on a single Mac
- 🖥️ **Dual CLI + GUI** — manage runners from terminal or menu bar
- 🔑 **`gh` CLI integration** — no manual PAT tokens, uses your existing `gh auth`
- 🔒 **Hybrid isolation** — choose user isolation (macOS runners) or container isolation (Linux workflows)
- 🎭 **Headless by default** — runners run without GUI access (enable when needed for visual testing)
- ⏸️ Pause/Resume all runners with one click
- 🎯 Perfect for when you need your Mac's resources for intensive work
- 📊 Monitor runner status from menu bar
- ⚡ Native Mac app, lightweight and fast
- 🤖 **Fully automated setup**: downloads and configures runners automatically, and provisions `gh` plus the repo's toolchains (Node, Python, Go, Ruby, Rust) on the host or in containers
- 🧹 **Disk pressure cleanup**: safely reclaim idle runner workspaces and CI caches
- 🔋 **Auto-pause**: pause runners on low battery or during quiet hours (per-runner schedules), finishing the current job first and resuming automatically
- 📈 **Resource monitoring**: per-runner CPU, memory, and workspace size, with optional alerts (`mac-runner status --resources`)
- 📜 **Log viewer**: live-tail, filter, and export runner output and diagnostics (`mac-runner logs <name> --follow`), with log rotation
- 🪟 **Dashboard window**: every runner's status, current job, recent jobs, resources, and logs in one window
- 🔔 **Job notifications**: native notifications when jobs start and finish (caught from each runner's own log, so even jobs of a few seconds show up), and an animated menu bar icon while any runner is executing
- 📦 **Custom container images**: run Linux runners on your own OCI images (linux/arm64 with `bash`; see [Container Isolation](#3-container-isolation-linux-runners) for requirements), each with its own virtual display when GUI access is on
- 🐳 **Docker engine**: run Linux container runners in Docker (Docker Desktop, OrbStack, Colima) instead of Apple's Containerization, with local images and the work directory in a Docker volume; set each container's CPUs and memory on either engine
- 🗂️ **Declarative config**: describe runners in `.mac-runner.yml` and `mac-runner apply` them (`mac-runner export` to start)
- ♻️ **Just-in-time runners**: a single-use registration and a fresh workspace for every job, deleted afterwards, with optional cache volumes that outlive them ([Just-in-time Runners](#just-in-time-runners))

## Why?

GitHub Actions self-hosted runners are great, but:
- Official runner only supports one instance per machine
- No easy way to pause runners when you need CPU/memory
- Managing multiple repos means multiple runner processes
- No visual indication of runner status

**Mac Runner solves this.**

## Installation

### Homebrew

```bash
brew install --cask omniaura/tap/mac-runner
```

### Direct Download

Download the latest DMG from [Releases](https://github.com/omniaura/mac-runner/releases)

### Prerequisites

- macOS 13+ (macOS 15+ for user isolation, macOS 26+ for container isolation with Apple's engine)
- [`gh` CLI](https://cli.github.com/) installed and authenticated (`gh auth login`)
- Apple Silicon Mac (for container isolation with Apple's engine), or Docker (for its [Docker engine](#docker-engine))

## Quick Start

### GUI

1. Launch Mac Runner from Applications or run `open /Applications/MacRunner.app` — it appears in the menu bar
2. Click "Add Runner"
3. Browse your repos (fetched via `gh`), pick one
4. Runner downloads, configures, registers, and starts automatically

### CLI

```bash
# Check GitHub auth
mac-runner auth

# Add a runner (downloads, configures, starts in background)
mac-runner add owner/repo --name my-runner --labels macos,mac-runner

# Add a runner with GUI access (for visual tests, Xcode UI tests, etc.)
mac-runner add owner/repo --enable-gui

# List runners
mac-runner list

# Start/stop
mac-runner start my-runner
mac-runner stop my-runner

# Remove (deregisters from GitHub and deletes the runner's workspace)
mac-runner remove my-runner

# Status summary
mac-runner status

# Preview or run cleanup (active runner data is always skipped)
mac-runner cleanup --dry-run
mac-runner cleanup

# Remove every runner and every file Mac Runner created
mac-runner uninstall --dry-run
mac-runner uninstall
```

Runners started via CLI persist in the background — they survive the terminal session. Stop and start them from any terminal or from the GUI.

### Disk Cleanup

GitHub Actions jobs can leave large workspaces and dependency caches behind. `mac-runner cleanup` removes the contents of stopped runners' `_work` directories plus known npm, SwiftPM, Homebrew, Go, Cargo, Gradle, and Xcode caches. If any runner is active, its workspace is skipped and shared caches are preserved.

In Settings, enable **Clean CI Data When Disk Space Is Low** and choose a minimum free-space target. Mac Runner checks at most once per hour and only cleans when available space falls below that target. Automatic cleanup is off by default.

Use `mac-runner cleanup --workspaces-only` to preserve all shared caches.

### Uninstalling

`mac-runner uninstall` tears down a Mac Runner installation completely. It stops running
runners, deregisters them from GitHub, and deletes every location Mac Runner writes to:

| Location | Contents |
| --- | --- |
| `~/.mac-runner` | Runner workspaces — the extracted runner release and its `_work` checkout, typically >1 GB each |
| `~/Library/Application Support/MacRunner` | `config.json`, PID files, container kernel |
| `~/Library/Preferences/{com.omniaura.mac-runner,mac-runner}.plist` | App and CLI preferences |
| `~/Library/HTTPStorages/*`, `~/Library/Caches/*` | Cached update checks |
| `~/Library/Application Support/CrashReporter`, `~/Library/Logs/DiagnosticReports` | Crash and diagnostic reports |

Deregistering first matters: deleting a runner's credentials without telling GitHub leaves
it listed as a permanently offline runner in the repository's Actions settings.

```bash
mac-runner uninstall --dry-run      # show exactly what would be deleted, and how much space
mac-runner uninstall                # prompts before deleting
mac-runner uninstall --yes          # skip the prompt
mac-runner uninstall --include-app  # also delete MacRunner.app and the mac-runner symlink
mac-runner uninstall --keep-runners # delete local files but leave GitHub registrations
```

Uninstall also removes **orphaned workspaces** — directories left on disk by earlier
versions that deleted a runner from `config.json` without deleting its files. If you have
been using Mac Runner for a while, `--dry-run` is worth running even if you have no runners
configured.

If you installed with Homebrew, remove the app itself with `brew uninstall --cask mac-runner`.
Use `brew uninstall --zap --cask mac-runner` to remove the app and all of its data in one step.

**Run `mac-runner uninstall` first if you have runners configured.** Homebrew only deletes
local files: it cannot deregister your runners from GitHub, and it cannot reach workspaces
owned by a dedicated service user, which live outside your home directory. Runners removed
without deregistering stay listed in the repository's Actions settings as permanently
offline.

## Declarative Configuration

Describe your runners in a file and let `mac-runner apply` create, update, and remove them to match. This makes a setup easy to reproduce on another Mac or to keep in version control.

```bash
# Start from what you have now
mac-runner export -o .mac-runner.yml

# Preview, then apply
mac-runner apply --dry-run
mac-runner apply
```

`apply` reads `-f <path>`, or `./.mac-runner.yml`, or `~/.mac-runner/config.yml`, in that order. It prints its plan first and asks before removing or re-registering runners (`--yes` skips the prompt). `--no-prune` keeps runners that aren't in the file. Running it again when nothing has changed does nothing.

```yaml
version: 1

# Optional global settings
settings:
  isolation: user                  # none | user | container
  quiet-hours: { start: "22:00", end: "06:00" }   # or: never
  pause-on-battery: true
  battery-threshold: 20            # percent, 5-95

runners:
  - name: mac-runner-ci            # letters, digits, . _ -
    repo: omniaura/mac-runner      # or `org: omniaura` for an organization runner
    labels: [macos, swift]         # default: [macos, mac-runner]
    count: 2                       # creates mac-runner-ci-1 and mac-runner-ci-2

  - name: linux-builder
    org: omniaura
    isolation: container           # none | user | container | global (default: global)
    engine: docker                 # container isolation: apple | docker (default: apple)
    image: my-ci-image:latest      # container isolation (default: ghcr.io/actions/actions-runner:latest)
    cpus: 4                        # container isolation (default: 2)
    memory: 8g                     # container isolation: 8g, 8192m, or MB (default: 4g)
    jit: true                      # a single-use registration per job (default: false)
    tools: []                      # container isolation: tools to install at start; [] = none (default: detected)
    cache: [/home/runner/.cargo/registry]   # Docker engine: container paths kept in volumes across jobs
    enable-gui: false              # default: false (headless)
    open-files: 65536              # default: the global limit
    quiet-hours: never             # never | { start, end } (default: global schedule)
```

Runners are matched by name. What happens to an existing runner depends on what changed:

| Change | What `apply` does |
|---|---|
| New name | Registers and starts the runner |
| `repo`/`org`, `labels`, or `isolation` | Unregisters and registers the runner again |
| `enable-gui`, `open-files`, `image`, `engine`, `cpus`, `memory`, `jit`, `tools`, or `cache` | Updates it, restarting it if it's running |
| `quiet-hours` | Updates it in place |
| Name no longer in the file | Unregisters it and deletes its workspace (unless `--no-prune`) |

A restart never interrupts a job: the change applies when the runner next starts (for a JIT runner, from its next job). An `engine` or `jit` change is the exception, since a runner must stop the way it started (stopping a JIT runner deletes its registration; stopping a long-lived one doesn't): while a job runs it's left for later, so run `apply` again once the runner is idle.

## Just-in-time Runners

A just-in-time (JIT) runner registers a new, single-use runner with GitHub each time it starts, runs one job on it, and deletes it. Every job gets a fresh registration and a fresh workspace, and Mac Runner cleans up after each one, so nothing a job leaves behind reaches the next, and no stale runners pile up in the repository's settings. GitHub-hosted runners and Actions Runner Controller work the same way.

Use it when:
- jobs shouldn't see what earlier jobs left: checkouts, build output, files under `_work/_temp`, anything a step wrote into the workspace;
- you run workflows you don't fully trust (pull requests from forks, say), together with [user or container isolation](#isolation-modes);
- jobs should all start from the same state, so none passes only because an earlier one left something behind.

The cost is a few seconds per job (a registration, plus a container start on the container engines), and whatever a job needs from the workspace is fetched again, `actions/setup-*` tool caches included, unless you keep it in a [cache volume](#cache-volumes-docker).

```bash
# Every isolation mode can use it
mac-runner add owner/repo --isolation user --jit --labels self-hosted,macOS,ARM64
mac-runner add owner/repo --isolation container --engine docker --image my-ci-image:latest --jit \
  --labels self-hosted,Linux,ARM64 --no-tools \
  --cache /home/runner/.cargo/registry --cache /home/runner/.cache/uv
```

In a [config file](#declarative-configuration), set `jit: true` on the runner (and `tools`, `cache` as below); `apply` switches an existing runner over in place, restarting it. In the GUI: Add Runner → Single-Use Runners (JIT).

**Labels.** GitHub gives a JIT runner exactly the labels it's registered with: unlike `config.sh`, it adds no `self-hosted`, OS, or architecture labels. List every label your workflows' `runs-on` asks for, e.g. `--labels self-hosted,Linux,ARM64`.

**How it runs.**
- At each start, Mac Runner asks GitHub for a JIT config (`POST /repos/{owner}/{repo}/actions/runners/generate-jitconfig`, or the organization's) for a runner named `<name>-<6 hex digits>` in the default runner group, with the runner's labels, and records its ID (`githubRunnerId`).
- The JIT config is the runner's credentials. It reaches the runner in `ACTIONS_RUNNER_INPUT_JITCONFIG`, which the runner reads like `--jitconfig` (and then removes from its own environment), so it's never in a command line or `ps`, and Mac Runner never logs it. Docker and Apple's engine put it in the container's environment (Docker by name only: `-e ACTIONS_RUNNER_INPUT_JITCONFIG`); without isolation it's in the runner's environment. A dedicated user's runner is started by `sudo`, which clears the environment, so its config goes to a file only that user can read (mode 0600, written from stdin), which the launch reads into the variable and deletes before starting `run.sh`.
- Once its job is done the runner exits, and Mac Runner deletes the registration and starts the next one right away. That's not a crash. A crash is, and so is an exit within 30 seconds that ran no job (a rejected config, say): the usual auto-restart backoff and retry limit apply.
- The menu bar app keeps JIT runners going whatever started them: when a runner started by `mac-runner add`, `start`, or `apply` exits after its job, the app registers and starts the next one. Keep the app running; the CLI says so when it starts a JIT runner while the app isn't. (A container runner on Apple's engine lives in the process that started it, which handles its exits itself.)
- `mac-runner list` and `status` mark JIT runners, and `status` shows each one's current registration. Between jobs, while its next registration is made, a JIT runner still shows as running.

**Cleanup.**
- After every exit, and on `mac-runner stop`, `remove`, and `uninstall`, Mac Runner deletes that start's registration (a 404 is fine: GitHub deletes a single-use runner itself once it has run a job). So a stopped JIT runner never leaves an idle registration behind. `remove` and `uninstall` also delete offline `<name>-<hex>` registrations left by earlier starts (if Mac Runner was killed mid-job, say).
- Each start begins with an empty workspace. On Docker, the work volume (`mac-runner-<runner id>-work`) is deleted and created again before the container runs, and the runner doesn't start if it can't be. Apple's engine and the process modes delete `_work` (as the dedicated user, through Mac Runner's sudo rules). The previous registration's credential files (`.runner`, `.credentials`, `.credentials_rsaparams`) go too, and containers are removed when they exit (`docker run --rm`). The last job's workspace stays until the runner starts again or is removed.
- `runner.log` and `_diag` stay as they are, with the usual rotation and pruning.

### Cache Volumes (Docker)

A fresh workspace means fresh downloads, but package caches are worth keeping. On the Docker engine, `--cache <container path>` (repeatable) or `cache: [...]` in a config file backs each path with a named volume, `mac-runner-<runner id>-cache-<8 hex digits of the path's hash>`, that outlives the container. Docker fills a new volume with whatever the image has at that path, and Mac Runner makes the path writable by the image's user (with `sudo` where needed), along with any parent directory Docker had to create in that user's home. Removing the runner (or uninstalling) deletes its cache volumes; to empty one, stop the runner and `docker volume rm` it. Paths are absolute paths in the container, outside `/mac-runner`. Apple's engine doesn't support them.

Good candidates, for an image whose user is `runner`:

| Tool | Paths |
| --- | --- |
| Cargo | `/home/runner/.cargo/registry`, `/home/runner/.cargo/git` |
| Go | `/home/runner/go/pkg/mod` (modules), `/home/runner/.cache/go-build` (build cache) |
| uv | `/home/runner/.cache/uv` (uv copies from it instead of hard-linking across volumes; `UV_LINK_MODE=copy` quiets its warning) |
| pnpm | `/home/runner/.local/share/pnpm/store`, with the store set to that absolute path in the workflow (`pnpm config set store-dir /home/runner/.local/share/pnpm/store`): by default pnpm keeps its store on the project's filesystem, which here is the work volume, emptied for every job |

Cache what a tool downloads, not the tool: a volume keeps the first contents it got, so caching all of `~/.cargo` would freeze the toolchain the image ships.

### Skipping Tool Installation

Container runners install the GitHub CLI, the toolchains detected in the repository, and Settings → **Extra CI Tools** with `apt-get` each time their container starts; for a JIT runner, that's before every job. If the image already has its tools, `--no-tools` on `mac-runner add` (`tools: []` in a config file) installs nothing. `tools: [gh, jq]` installs just those (tool names as above, or apt packages); leaving `tools` out keeps detecting them, as before.

## CI/CD: Self-Hosted Runner with Automatic Cloud Fallback

Mac Runner uses a pattern that automatically routes CI jobs to your self-hosted Mac when it's online, and falls back to GitHub-hosted cloud runners when it's not. This means pushes to main always build, regardless of whether your Mac is on.

### How It Works

The release workflow uses [`mikehardy/runner-fallback-action`](https://github.com/mikehardy/runner-fallback-action) to query the GitHub API for available self-hosted runners before the build job starts:

```yaml
jobs:
  preflight:
    runs-on: ubuntu-latest
    outputs:
      runner: ${{ steps.runner.outputs.use-runner }}
    steps:
      - name: Select runner
        id: runner
        uses: mikehardy/runner-fallback-action@v1
        with:
          primary-runner: mac-runner
          fallback-runner: macos-latest
          fallback-on-error: true
          github-token: ${{ secrets.RUNNER_TOKEN }}

  build:
    needs: preflight
    runs-on: ${{ fromJson(needs.preflight.outputs.runner) }}
    steps:
      - run: echo "Running on the best available runner"
```

| Mac online | Runner used | Cost |
|---|---|---|
| Yes | `mac-runner` (self-hosted) | Free |
| No | `macos-latest` (cloud) | GitHub Actions minutes |

This pattern is useful for any project that wants fast, free self-hosted builds when available, with reliable cloud fallback. See the [community discussion](https://github.com/orgs/community/discussions/20019) for background on why this isn't built into GitHub Actions natively.

### Token Setup

The runner-fallback-action queries the GitHub REST API to check runner availability. This requires a token with admin read access — the default `GITHUB_TOKEN` does not have this permission.

1. Create a [fine-grained Personal Access Token](https://github.com/settings/personal-access-tokens/new):
   - **Repository access:** select "Only select repositories" and pick your repo
   - **Permissions → Repository → Administration:** Read-only
2. Add it as a repository secret named `RUNNER_TOKEN`:
   ```bash
   gh secret set RUNNER_TOKEN
   ```

> **Note:** If the token is missing or invalid, `fallback-on-error: true` ensures the workflow still runs — it just falls back to cloud runners.

### References

- [`mikehardy/runner-fallback-action`](https://github.com/mikehardy/runner-fallback-action) — runner availability checker
- [`jimmygchen/runner-fallback-action`](https://github.com/jimmygchen/runner-fallback-action) — original (archived)
- [GitHub Community: Auto-switch to GitHub runner if self-hosted unavailable](https://github.com/orgs/community/discussions/20019)

## Isolation Modes

Mac Runner supports three isolation modes to protect your development environment:

### 1. No Isolation (Default)
- Runners execute directly as your current user
- Simple setup, works on any macOS version
- ⚠️ **Not recommended for untrusted workflows** — CI jobs have full access to your files

### 2. User Isolation (macOS 15+)
- Each runner runs as a dedicated system user (e.g., `_macrunner`)
- Prevents CI jobs from accessing your files, credentials, and desktop
- Best for macOS-based workflows
- **How to enable:**
  ```bash
  # CLI
  mac-runner add owner/repo --isolation user

  # GUI
  Settings → Isolation Mode → Dedicated User
  ```

### 3. Container Isolation (Linux runners)
- Runs each runner as a **Linux** (arm64) runner inside its own lightweight VM, using Apple's [Containerization framework](https://github.com/apple/containerization), or in a Docker container with the [Docker engine](#docker-engine)
- Best for Linux-based workflows and cross-platform testing
- **Requirements:** macOS 26+, Apple Silicon, and a Linux kernel (see below) for Apple's engine; a running Docker for the Docker engine
- **How to enable:**
  ```bash
  # CLI (default image: GitHub's ghcr.io/actions/actions-runner:latest)
  mac-runner add owner/repo --isolation container

  # With your own image
  mac-runner add owner/repo --isolation container --image ghcr.io/myorg/ci-image:latest

  # In Docker, with more CPUs and memory
  mac-runner add owner/repo --isolation container --engine docker --cpus 4 --memory 8g

  # GUI
  Add Runner → Isolation Mode → Container (optionally pick the Engine and set Container Image)
  ```

**Kernel.** Mac Runner looks for a Linux kernel at `MacRunner.app/Contents/Resources/vmlinux` or `~/Library/Application Support/MacRunner/vmlinux`. The [Kata Containers](https://github.com/kata-containers/kata-containers/releases) kernel works:
```bash
curl -fLO https://github.com/kata-containers/kata-containers/releases/download/3.17.0/kata-static-3.17.0-arm64.tar.xz
tar -xJf kata-static-3.17.0-arm64.tar.xz ./opt/kata/share/kata-containers/vmlinux.container
cp -L opt/kata/share/kata-containers/vmlinux.container ~/Library/Application\ Support/MacRunner/vmlinux
```

**Images.** Images are pulled from any public OCI registry (GHCR, Docker Hub, …) the first time a runner uses them and are cached locally after that. An image needs:
- linux/arm64 and `bash`
- Either the GitHub Actions runner already installed at `/home/runner`, `/actions-runner`, or `/runner` (as in `ghcr.io/actions/actions-runner`), or `curl` and `tar` so Mac Runner can download it at start
- `apt-get` (Debian/Ubuntu) if you want automatic tool installation. Other images still work; tools just aren't installed for you.
- For GUI access: `Xvfb` preinstalled, or `apt-get` with a default user that is root or has passwordless `sudo` so Mac Runner can install it. Otherwise the runner doesn't start, rather than running GUI jobs without a display.

**Tools.** When a container runner is created, Mac Runner picks the tools its jobs are likely to need: the GitHub CLI, toolchains detected from the repository (Node, Python, Go, Ruby, Rust), and any **Extra CI Tools** from Settings (installed as apt packages). They're installed with `apt-get` each time the runner's container starts, never per job (for a [JIT runner](#just-in-time-runners), every start is a job). An image that has its tools can [skip this](#skipping-tool-installation) with `--no-tools`.

**CPUs and memory.** Each container gets 2 CPUs and 4 GB unless its runner sets its own: `--cpus 4 --memory 8g` on `mac-runner add` (memory as `8g`, `8192m`, or a number of MB), or `cpus` and `memory` in a [config file](#declarative-configuration). CPUs can't exceed the Mac's cores, and memory must be at least `1g`. `mac-runner list` and `status` show them when they aren't the defaults.

**Lifetime.** With Apple's engine, a container runner's VM lives inside the process that started it. Start container runners from the menu bar app to keep them running in the background. `mac-runner add`/`start` for a container runner stays in the foreground and streams its output until you press Ctrl-C. (Docker runners run in the background on their own; see below.)

Container runners register with the name and labels you give them (default labels: `linux, mac-runner`). Their `runner.log` and `_diag` logs sit in the runner's directory like other modes (`mac-runner logs <name>`).

#### Docker engine

Container runners can run in Docker instead of Apple's Containerization, with Docker Desktop, OrbStack, Colima, or anything else that gives you a working `docker` CLI. Use it on Macs without macOS 26, to run images you've built locally, or when jobs need a real Linux filesystem for their work directory: Apple's engine shares `_work` from the Mac over virtio-fs, which refuses some files Linux tools create (GNU tar's mode-0 placeholder files, for one, so `actions/setup-node` can't extract Node there).

```bash
mac-runner add owner/repo --isolation container --engine docker
mac-runner add owner/repo --isolation container --engine docker --image my-ci-image:latest
```

In a config file, set `engine: docker` on the runner (`apple` is the default). In the GUI: Add Runner → Isolation Mode → Container → Engine: Docker.

- **Images** come from Docker: an image you've built (`docker build -t my-ci-image .`) works without a registry, and others are pulled the first time a runner uses them. The image requirements above apply. If the image's user isn't root, it needs passwordless `sudo` (as GitHub's runner image has) to take over the work volume, which Docker creates owned by root.
- **Work directory.** `_work` is the Docker volume `mac-runner-<runner id>-work` (shown in the dashboard), so checkouts and the tool cache survive restarts (a [JIT runner](#just-in-time-runners) empties it for every job, and can keep caches in [cache volumes](#cache-volumes-docker)). It's deleted with the runner by `mac-runner remove` and `mac-runner uninstall`; `mac-runner cleanup` leaves it alone (to empty it, stop the runner and `docker volume rm` it). `runner.log` and `_diag` stay in the runner's directory on the Mac, which Docker must be able to mount writable (Docker Desktop and OrbStack can by default).
- **Lifetime.** A Docker runner is an ordinary background process, like a runner without isolation: `docker-run.sh` in its directory runs `docker run` in the foreground. It keeps running after `mac-runner add`/`start` returns and when the menu bar app quits. Stopping it stops and removes its container.
- **Docker must be running** when the runner starts. At login, Mac Runner gives Docker up to two minutes to start before restarting Docker runners.
- **CPUs and memory** are `docker run --cpus` and `--memory` limits, so Docker needs at least that many CPUs itself (Docker Desktop → Settings → Resources). A runner that asks for more than Docker has doesn't start; one on the defaults gets at most what Docker has.

### Per-Runner Isolation Override

You can set a global default isolation mode and override it per-runner:

```bash
# Set global default to user isolation
mac-runner settings --isolation user

# Add a Linux runner with container isolation
mac-runner add owner/linux-project --isolation container

# Add a macOS runner with no isolation (for trusted workflows)
mac-runner add owner/trusted-project --isolation none
```

In the GUI, each runner displays its isolation mode with an icon:
- 🔓 No isolation
- 👤 User isolation
- 📦 Container isolation ("Container (Docker)" on the Docker engine)

## GUI Access

By default, runners operate in **headless mode** — they run without access to the GUI (display, windows, etc.). This is optimal for most CI jobs and prevents interference with your desktop.

**When to enable GUI access:**
- Visual testing (screenshot comparisons, E2E tests with browsers)
- Xcode UI tests
- iOS Simulator tests
- macOS app GUI automation

**How to enable:**
```bash
# CLI
mac-runner add owner/repo --enable-gui

# GUI
Add Runner → Enable GUI Access (toggle)
```

### Separate displays per runner

- **Container runners** with GUI access each get their **own virtual display**: Xvfb runs inside the runner's VM (1920×1080×24) and `DISPLAY` is set for its jobs, so windows, focus, and screenshots from one runner never touch another's. Linux GUI tests (headed browsers, Electron, X11 apps) run side by side without interfering. Headless container runners get `CI=true HEADLESS=true` like other modes.
- **macOS runners** (no isolation or a dedicated user) with GUI access share the logged-in user's desktop. macOS only gives a user a separate GUI session when that user actually logs in at the login window, and the dedicated `_macrunner` user has no password by design, so Mac Runner can't create one. For parallel macOS UI tests, either keep one GUI-enabled runner per Mac (target it with a label) or run Mac Runner inside separate macOS VMs, each with its own GUI-enabled runner.

## Roadmap

Planned work and ideas are tracked as [open enhancement issues](https://github.com/omniaura/mac-runner/issues?q=is%3Aopen+label%3Aenhancement). Their `priority:high`, `priority:medium`, and `priority:low` labels show priority (for example, [high-priority items](https://github.com/omniaura/mac-runner/issues?q=is%3Aopen+label%3Aenhancement+label%3Apriority%3Ahigh)). Open issues with a linked pull request are in progress. Suggestions are welcome: [open an issue](https://github.com/omniaura/mac-runner/issues/new).

## Architecture

- **Swift 6 / SwiftUI** — Native Mac app
- **Menu Bar Interface** — Always accessible, minimal UI
- **`gh` CLI** — All GitHub API calls go through `gh` (auth, repos, runner tokens, CRUD)
- **PID-based process management** — Runners persist across CLI sessions
- **Dual entry point** — `main.swift` dispatches to CLI handler or SwiftUI app

## Development

```bash
# Build
swift build

# Run CLI
.build/debug/mac-runner --help

# Run GUI (no args)
.build/debug/mac-runner

# Test
swift test
```

## Contributing

We use [Conventional Commits](https://www.conventionalcommits.org/) for automatic versioning:

- `feat:` — New feature (minor bump)
- `fix:` — Bug fix (patch bump)
- `chore:` — No release

See [CONTRIBUTING.md](CONTRIBUTING.md) for full guidelines.

## License

MIT
