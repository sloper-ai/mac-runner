import Foundation

/// The script that boots a GitHub Actions runner inside a Linux container.
///
/// Inputs arrive as `MR_*` environment variables rather than being spliced
/// into the script, so names, labels, and tokens need no shell quoting.
enum ContainerRunnerScript {
    /// Where the runner's work directory (the host's `_work`, or a Docker
    /// volume) and the host's `_diag` directory are mounted.
    static let workMount = "/mac-runner/_work"
    static let diagnosticsMount = "/mac-runner/_diag"

    static let script = #"""
    set -euo pipefail
    log() { echo "[mac-runner] $*"; }
    # GitHub's runner image copies its diagnostics to stdout; they're in _diag already.
    unset ACTIONS_RUNNER_PRINT_LOG_TO_STDOUT
    if [ -n "${MR_SUDO+set}" ]; then SUDO="$MR_SUDO"
    elif [ "$(id -u)" -ne 0 ]; then SUDO="sudo"
    else SUDO=""; fi
    # Make a directory owned by this user, using sudo only if needed.
    ensure_dir() {
      mkdir -p "$1" 2>/dev/null || $SUDO mkdir -p "$1"
      [ -w "$1" ] || $SUDO chown "$(id -u):$(id -g)" "$1"
    }
    # Don't register a runner that's missing tools its jobs were promised.
    fail_tools() {
      log "ERROR: tool installation failed ($1). Not starting the runner so jobs don't run without these tools."
      log "Fix the package list (Settings → Extra CI Tools) or use an image that has them, then start the runner again."
      exit 1
    }

    # Use the image's Actions runner if it has one, else download it.
    RUNNER_HOME=""
    for dir in ${MR_RUNNER_CANDIDATES:-/home/runner /actions-runner /runner}; do
      if [ -x "$dir/run.sh" ]; then RUNNER_HOME="$dir"; break; fi
    done
    if [ -z "$RUNNER_HOME" ]; then
      RUNNER_HOME=/runner
      log "No Actions runner in this image; downloading $MR_RUNNER_URL"
      ensure_dir "$RUNNER_HOME"
      cd "$RUNNER_HOME"
      curl -fsSL -o runner.tar.gz "$MR_RUNNER_URL"
      tar -xzf runner.tar.gz
      rm runner.tar.gz
      $SUDO ./bin/installdependencies.sh >/dev/null || log "installdependencies.sh failed; continuing"
    fi

    # Tools picked when the runner was created.
    if [ -n "${MR_APT_PACKAGES:-}" ] || [ "${MR_INSTALL_GH:-0}" = 1 ]; then
      if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        packages="${MR_APT_PACKAGES:-}"
        if [ "${MR_INSTALL_GH:-0}" = 1 ] && ! command -v gh >/dev/null 2>&1; then
          log "Adding the GitHub CLI apt repository"
          if ! { $SUDO apt-get update -qq \
                 && $SUDO apt-get install -y -qq --no-install-recommends curl ca-certificates >/dev/null \
                 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
                    | $SUDO tee /usr/share/keyrings/githubcli-archive-keyring.gpg >/dev/null \
                 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
                    | $SUDO tee /etc/apt/sources.list.d/github-cli.list >/dev/null; }; then
            fail_tools "could not add the GitHub CLI apt repository"
          fi
          packages="$packages gh"
        fi
        packages="$(echo $packages)"  # normalize spacing
        if [ -n "$packages" ]; then
          log "Installing tools: $packages"
          $SUDO apt-get update -qq || log "apt-get update failed; trying the install anyway"
          # shellcheck disable=SC2086
          $SUDO apt-get install -y -qq --no-install-recommends $packages >/dev/null \
            || fail_tools "could not install: $packages"
        fi
      else
        log "This image has no apt-get; skipping tool installation"
      fi
    fi

    # GUI runners get their own virtual display; headless ones are marked as such.
    if [ "${MR_ENABLE_GUI:-0}" = 1 ]; then
      if ! command -v Xvfb >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
        log "Installing Xvfb for this runner's virtual display"
        $SUDO apt-get update -qq || log "apt-get update failed; trying the install anyway"
        DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -qq --no-install-recommends xvfb xauth x11-utils >/dev/null \
          || log "Could not install Xvfb"
      fi
      if ! command -v Xvfb >/dev/null 2>&1; then
        log "ERROR: GUI access needs Xvfb, and this image has neither Xvfb nor apt-get. Use an image with Xvfb, or turn off GUI access."
        exit 1
      fi
      display_number="${MR_DISPLAY#:}"
      x11_socket="${MR_X11_DIR:-/tmp/.X11-unix}/X$display_number"
      # A leftover socket or lock would look like a running display.
      rm -f "$x11_socket" "/tmp/.X$display_number-lock" 2>/dev/null \
        || $SUDO rm -f "$x11_socket" "/tmp/.X$display_number-lock" 2>/dev/null || true
      # -displayfd: Xvfb writes the display number to fd 3 only once it's
      # initialized and accepting connections (the signal xvfb-run relies on).
      ready_file="$(mktemp)"
      Xvfb "$MR_DISPLAY" -displayfd 3 -screen 0 "${MR_DISPLAY_SIZE:-1920x1080x24}" -nolisten tcp \
        3>"$ready_file" >/dev/null 2>&1 &
      xvfb_pid=$!
      # Connect a real client when xdpyinfo is available, giving up after 2s.
      probe_display() {
        command -v xdpyinfo >/dev/null 2>&1 || return 0
        DISPLAY="$MR_DISPLAY" xdpyinfo >/dev/null 2>&1 &
        local probe=$!
        for _ in $(seq 1 20); do
          if ! kill -0 "$probe" 2>/dev/null; then
            wait "$probe"
            return $?
          fi
          sleep 0.1
        done
        kill "$probe" 2>/dev/null
        return 1
      }
      display_ready=""
      display_deadline=$((SECONDS + 10))
      while [ "$SECONDS" -lt "$display_deadline" ]; do
        kill -0 "$xvfb_pid" 2>/dev/null || break
        if [ -s "$ready_file" ] && [ -S "$x11_socket" ] && probe_display; then
          display_ready=1
          break
        fi
        sleep 0.1
      done
      rm -f "$ready_file"
      sleep 0.3
      kill -0 "$xvfb_pid" 2>/dev/null || display_ready=""
      if [ -z "$display_ready" ]; then
        log "ERROR: the virtual display $MR_DISPLAY did not start. Not starting the runner so GUI jobs don't run without a display."
        exit 1
      fi
      export DISPLAY="$MR_DISPLAY"
      log "Virtual display $DISPLAY (${MR_DISPLAY_SIZE:-1920x1080x24})"
    else
      export CI=true HEADLESS=true
    fi

    # Keep job workspaces and diagnostics on the host, writable by this user.
    ensure_dir "$MR_WORK_DIR"
    ensure_dir "$MR_DIAG_DIR"
    if [ ! -L "$RUNNER_HOME/_diag" ]; then
      rm -rf "$RUNNER_HOME/_diag"
      ln -s "$MR_DIAG_DIR" "$RUNNER_HOME/_diag"
    fi

    # Cache volumes outlive the container. Docker creates a mount point (and any
    # missing parent) owned by root: make them this user's, parents within $HOME too.
    if [ -n "${MR_CACHE_DIRS:-}" ]; then
      IFS=: read -r -a cache_dirs <<< "$MR_CACHE_DIRS"
      for dir in "${cache_dirs[@]}"; do
        [ -n "$dir" ] || continue
        if ! ensure_dir "$dir" || [ ! -w "$dir" ]; then
          log "ERROR: the cache $dir isn't writable by $(id -un), and sudo couldn't fix that."
          exit 1
        fi
        parent="$(dirname "$dir")"
        while [ -n "${HOME:-}" ] && [ "$parent" != "$HOME" ] && [ "${parent#"$HOME"/}" != "$parent" ]; do
          [ -w "$parent" ] || $SUDO chown "$(id -u):$(id -g)" "$parent" 2>/dev/null \
            || log "Warning: $parent isn't writable by $(id -un)"
          parent="$(dirname "$parent")"
        done
      done
    fi

    # Docker-in-Docker: this runner's own Docker daemon, for its jobs. Without it,
    # or if it won't come up, the runner isn't started: its jobs expect Docker.
    if [ "${MR_DOCKER:-0}" = 1 ]; then
      as_root() { if [ -n "$SUDO" ]; then $SUDO -n "$@"; else "$@"; fi; }
      fail_docker() {
        log "ERROR: $1 Not starting the runner so jobs don't run without Docker."
        exit 1
      }
      command -v dockerd >/dev/null 2>&1 && command -v docker >/dev/null 2>&1 \
        || fail_docker "Docker-in-Docker needs dockerd and the docker CLI in the image (docker-ce, or docker.io on Debian and Ubuntu)."
      docker_socket="${MR_DOCKER_SOCKET:-/var/run/docker.sock}"
      docker_log="${MR_DOCKER_LOG:-/tmp/dockerd.log}"
      # cgroup v2: move this container's processes into a child cgroup, so the
      # daemon can hand controllers to its own containers (as Docker's dind does).
      if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
        as_root sh -c 'mkdir -p /sys/fs/cgroup/init && xargs -rn1 < /sys/fs/cgroup/cgroup.procs > /sys/fs/cgroup/init/cgroup.procs 2>/dev/null; sed -e "s/ / +/g" -e "s/^/+/" < /sys/fs/cgroup/cgroup.controllers > /sys/fs/cgroup/cgroup.subtree_control' 2>/dev/null \
          || log "Warning: couldn't delegate cgroup controllers; Docker's containers may not start"
      fi
      log "Starting Docker for this runner's jobs (log: $docker_log)"
      as_root dockerd >"$docker_log" 2>&1 &
      dockerd_pid=$!
      docker_up=""
      for _ in $(seq 1 "${MR_DOCKER_WAIT:-30}"); do
        if as_root docker info >/dev/null 2>&1; then docker_up=1; break; fi
        kill -0 "$dockerd_pid" 2>/dev/null || break
        sleep 1
      done
      if [ -z "$docker_up" ]; then
        tail -n 20 "$docker_log" 2>/dev/null | sed 's/^/[dockerd] /' || true
        if kill -0 "$dockerd_pid" 2>/dev/null; then
          fail_docker "the Docker daemon didn't answer within ${MR_DOCKER_WAIT:-30}s (its log is above)."
        fi
        fail_docker "the Docker daemon exited (its log is above). It needs a privileged container, and an image user that's root or has passwordless sudo."
      fi
      # Usable by this user and its jobs. Joining the socket's group now wouldn't
      # reach processes already running, so open the socket (in this container only).
      if [ ! -w "$docker_socket" ]; then
        as_root chmod 666 "$docker_socket" || fail_docker "couldn't make $docker_socket usable by $(id -un)."
      fi
      # The previous job's containers go, running ones too (a restart policy brings
      # them back), with their anonymous volumes. Images stay cached.
      leftovers="$(docker ps -aq 2>/dev/null || true)"
      if [ -n "$leftovers" ]; then
        # shellcheck disable=SC2086
        docker rm -f -v $leftovers >/dev/null || log "Warning: couldn't remove the previous job's containers"
      fi
      docker container prune -f >/dev/null 2>&1 || true
      log "Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '(unknown version)') is up for this runner's jobs"
    fi

    cd "$RUNNER_HOME"
    if [ -n "${ACTIONS_RUNNER_INPUT_JITCONFIG:-}" ]; then
      # Single-use runner: it registers itself from the JIT config in its
      # environment (the runner reads ACTIONS_RUNNER_INPUT_JITCONFIG like
      # --jitconfig), so there's no config.sh.
      log "Starting a single-use (JIT) runner"
    else
      ./config.sh --unattended --replace \
        --url "$MR_URL" --token "$MR_TOKEN" \
        --name "$MR_NAME" --labels "$MR_LABELS" --work "$MR_WORK_DIR"
      unset MR_TOKEN
    fi
    ulimit -n "$MR_OPEN_FILES" 2>/dev/null || ulimit -n "$(ulimit -Hn)" 2>/dev/null || true
    exec ./run.sh
    """#

    /// X display for GUI-enabled container runners. Each runner has its own VM
    /// or container, so every runner gets a separate display even though the
    /// name is shared.
    static let displayName = ":99"

    /// DNS-safe hostname for a runner's container.
    static func hostname(for runnerName: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        let mapped = String(runnerName.lowercased().map { allowed.contains($0) ? $0 : "-" })
        let trimmed = mapped.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "mac-runner" : String(trimmed.prefix(63)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// apt packages for tool names from `ToolProvisioningService.plan`, and
    /// whether the GitHub CLI (from its own apt repository) is wanted.
    static func aptPackages(for tools: [String]) -> (packages: [String], installGitHubCLI: Bool) {
        var packages: [String] = []
        var installGitHubCLI = false
        for tool in tools {
            switch tool {
            case "gh": installGitHubCLI = true
            case "node": packages += ["nodejs", "npm"]
            case "python": packages += ["python3", "python3-pip", "python3-venv"]
            case "go": packages += ["golang-go"]
            case "ruby": packages += ["ruby-full"]
            case "rust": packages += ["cargo", "rustc"]
            default: packages.append(tool)
            }
        }
        var seen = Set<String>()
        return (packages.filter { seen.insert($0).inserted }, installGitHubCLI)
    }

    /// How the runner in the container registers.
    enum Registration: Equatable {
        /// With `config.sh` and a registration token (`MR_TOKEN`), as a long-lived runner.
        case token(String)
        /// As a single-use runner, from a JIT config in `ACTIONS_RUNNER_INPUT_JITCONFIG`
        /// (the runner reads it like `--jitconfig`); `config.sh` is skipped.
        case jitConfig(String)

        var variable: (name: String, value: String) {
            switch self {
            case .token(let token): return ("MR_TOKEN", token)
            case .jitConfig(let config): return (JITRunner.configVariable, config)
            }
        }
    }

    /// The script's inputs, in a fixed order: the container environment both
    /// engines give it. Values are passed as they are, never through a shell.
    /// `cacheDirectories` (Docker cache volumes) and `MR_DOCKER` (Docker-in-Docker)
    /// are only listed when used, so other runners get the same inputs as before.
    static func variables(
        registrationURL: String,
        registration: Registration,
        runnerName: String,
        labels: [String],
        runnerDownloadURL: String,
        openFileLimit: Int,
        tools: [String],
        enableGUI: Bool,
        cacheDirectories: [String] = [],
        dockerInDocker: Bool = false
    ) -> [(name: String, value: String)] {
        let apt = aptPackages(for: tools)
        var variables = [
            ("RUNNER_ALLOW_RUNASROOT", "1"),
            ("MR_URL", registrationURL),
            registration.variable,
            ("MR_NAME", runnerName),
            ("MR_LABELS", labels.joined(separator: ",")),
            ("MR_RUNNER_URL", runnerDownloadURL),
            ("MR_OPEN_FILES", String(openFileLimit)),
            ("MR_WORK_DIR", workMount),
            ("MR_DIAG_DIR", diagnosticsMount),
            ("MR_APT_PACKAGES", apt.packages.joined(separator: " ")),
            ("MR_INSTALL_GH", apt.installGitHubCLI ? "1" : "0"),
            ("MR_ENABLE_GUI", enableGUI ? "1" : "0"),
            ("MR_DISPLAY", displayName),
        ]
        if !cacheDirectories.isEmpty {
            // Cache paths can't contain ':' (see DockerRunnerEngine.cachePaths).
            variables.append(("MR_CACHE_DIRS", cacheDirectories.joined(separator: ":")))
        }
        if dockerInDocker {
            variables.append(("MR_DOCKER", "1"))
        }
        return variables
    }

    static func environment(for config: ContainerRunnerConfiguration) -> [String] {
        variables(
            registrationURL: config.repositoryURL,
            registration: config.jitConfig.map(Registration.jitConfig) ?? .token(config.registrationToken),
            runnerName: config.runnerName,
            labels: config.labels,
            runnerDownloadURL: config.runnerDownloadURL,
            openFileLimit: config.openFileLimit,
            tools: config.tools,
            enableGUI: config.enableGUI
        ).map { "\($0.name)=\($0.value)" }
    }
}
