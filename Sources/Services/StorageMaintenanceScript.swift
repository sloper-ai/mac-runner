import Foundation

/// Runs inside a short-lived container made from the configured runner image,
/// before obtaining JIT credentials. Only that runner's named volumes are mounted.
enum StorageMaintenanceScript {
    static let script = #"""
    set -eu
    # Physical traversal only. A cache root with a symlink component is skipped.
    safe_dir() {
      [ -d "$1" ] || return 1
      p="$1"
      while [ "$p" != / ]; do
        [ ! -L "$p" ] || return 1
        p=$(dirname "$p")
      done
    }
    free_bytes() { df -Pk /storage-work | awk 'NR==2 {printf "%.0f\n", $4 * 1024}'; }
    before=$(free_bytes)
    total=0
    for root in "$@"; do
      safe_dir "$root" || continue
      # -P and -xdev keep traversal in this volume and out of symlink targets.
      # Whole-cache expiry avoids leaving partial npx installs or package indexes.
      recent=$(find -P "$root" -xdev -type f -mtime -"$MR_CACHE_AGE" -print -quit)
      if [ -z "$recent" ]; then
        find -P "$root" -xdev -mindepth 1 -depth -delete
      fi
      size=$(du -skx "$root" | awk '{print $1}')
      total=$((total + size * 1024))
    done
    if [ "$total" -gt "$MR_CACHE_BYTES" ] || [ "$before" -lt "$MR_GUEST_BYTES" ] || [ "$MR_PRESSURE" = 1 ]; then
      for root in "$@"; do
        safe_dir "$root" || continue
        # Unlink links themselves, never traverse them. No glob misses dotfiles.
        find -P "$root" -xdev -mindepth 1 -depth -delete
      done
      echo '[mac-runner] Reset disposable package caches (budget or disk reserve).'
      total=0
    fi
    echo "MR_CACHE_REMAINING=$total"
    echo "MR_GUEST_AVAILABLE=$(free_bytes)"
    if [ -d /storage-docker ]; then
      du -skx /storage-docker | awk '{printf "MR_DOCKER_BYTES=%.0f\n", $1 * 1024}'
    fi
    """#

    static func value(_ name: String, in output: String) -> Int64? {
        output.split(separator: "\n").last(where: { $0.hasPrefix(name + "=") })
            .flatMap { Int64($0.dropFirst(name.count + 1)) }
    }
}
