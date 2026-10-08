#!/usr/bin/env bash
# Build the release app and point the Homebrew cask at it.
#
#   scripts/build-release.sh <version>
#
# Produces build/MacRunner.app and build/MacRunner-<version>.zip, a universal
# (arm64 + x86_64) release build, and writes <version> and the zip's SHA-256 into
# Casks/mac-runner.rb. The release workflow runs it through semantic-release
# (@semantic-release/exec prepareCmd), so it only runs when a release is due.
#
# Signing is ad hoc, unless SIGNING_IDENTITY names a Developer ID Application
# identity in the keychain (the release workflow imports one when the
# APPLE_CERTIFICATE_* secrets exist). With Developer ID, the app is also notarized
# and stapled when scripts/notarize.sh has credentials: NOTARY_API_KEY_PATH,
# APPLE_API_KEY_ID and APPLE_API_ISSUER_ID, or APPLE_ID, APPLE_ID_PASSWORD and
# APPLE_TEAM_ID.
#
# Run locally, it rewrites the cask too: `git checkout Casks/mac-runner.rb` after.
set -euo pipefail

version="${1:-}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  echo "usage: $0 <version>   (a semantic version, e.g. 1.26.0 or 0.0.0-test)" >&2
  exit 64
fi

cd "$(dirname "$0")/.."

# Nothing here needs GitHub credentials, and semantic-release passes its whole
# environment on: keep its token away from the third-party code the build runs.
unset GITHUB_TOKEN GH_TOKEN

app="build/MacRunner.app"
zip="build/MacRunner-${version}.zip"
cask="Casks/mac-runner.rb"
entitlements="scripts/MacRunner.entitlements"

# Building Containerization opens more files than the default limit allows.
ulimit -n 65536 2>/dev/null || ulimit -n "$(ulimit -Hn)" 2>/dev/null || true

# --disable-sandbox, as CI uses too: the SwiftPM sandbox can block writes that
# building Apple's Containerization package needs. It only affects build-time
# isolation.
build_args=(-c release --arch arm64 --arch x86_64 --disable-sandbox)

echo "==> Building mac-runner ${version} for arm64 and x86_64"
swift build "${build_args[@]}"

# Multi-arch products land in a toolchain-specific place (.build/apple/Products/Release
# before Swift 6.4, .build/out/Products/Release since), so ask SwiftPM where.
bin_dir="$(swift build "${build_args[@]}" --show-bin-path)"
binary="${bin_dir}/mac-runner"
# One arch per call: newer lipo reads any further arch as an input file.
for arch in arm64 x86_64; do
  if ! lipo "$binary" -verify_arch "$arch"; then
    echo "error: ${binary} has no ${arch} slice" >&2
    exit 1
  fi
done

echo "==> Assembling ${app}"
rm -rf "$app" build/MacRunner-*.zip
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/MacRunner"
VERSION="$version" ./scripts/generate-info-plist.sh > "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist"

# codesign rejects bundles carrying Finder info or resource forks.
xattr -cr "$app"
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
  echo "==> Signing with ${SIGNING_IDENTITY}"

  # Nested code first, then the executable, then the bundle.
  while IFS= read -r nested; do
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$nested"
  done < <(find "$app" \( \
    -path '*/Contents/Frameworks/*.framework' -o \
    -path '*/Contents/Frameworks/*.dylib' -o \
    -path '*/Contents/PlugIns/*.appex' -o \
    -path '*/Contents/XPCServices/*.xpc' -o \
    -path '*/Contents/Helpers/*' -o \
    -path '*/Contents/Library/LoginItems/*.app' \
  \) -depth)

  codesign --force --options runtime --timestamp \
    --entitlements "$entitlements" --sign "$SIGNING_IDENTITY" \
    "$app/Contents/MacOS/MacRunner"
  codesign --force --options runtime --timestamp --deep \
    --entitlements "$entitlements" --sign "$SIGNING_IDENTITY" \
    "$app"
else
  echo "==> Signing ad hoc (SIGNING_IDENTITY is not set)"
  codesign --force --sign - --entitlements "$entitlements" "$app"
fi
codesign --verify --deep --strict --verbose=2 "$app"

echo "==> Zipping ${zip}"
# --keepParent puts MacRunner.app at the top of the archive, where the cask expects
# it. --norsrc leaves out extended attributes (such as the build machine's
# com.apple.provenance): stored as ._ files, they break the bundle's seal when the
# zip is extracted with plain unzip. The app keeps nothing it needs in them.
ditto -c -k --norsrc --keepParent "$app" "$zip"

if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
  if [[ -n "${NOTARY_API_KEY_PATH:-}" && -n "${APPLE_API_KEY_ID:-}" && -n "${APPLE_API_ISSUER_ID:-}" ]] ||
     [[ -n "${APPLE_ID:-}" && -n "${APPLE_ID_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
    echo "==> Notarizing ${zip}"
    ./scripts/notarize.sh "$zip"
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"

    echo "==> Zipping the stapled app"
    rm -f "$zip"
    ditto -c -k --norsrc --keepParent "$app" "$zip"
  else
    echo "warning: no notarization credentials; ${app} is signed but not notarized" >&2
  fi
fi

sha256="$(shasum -a 256 "$zip" | awk '{print $1}')"

echo "==> Pointing ${cask} at ${version} (${sha256})"
sed -E -i '' \
  -e "s/^  version \"[^\"]*\"\$/  version \"${version}\"/" \
  -e "s/^  sha256 (\"[0-9a-f]*\"|:no_check)\$/  sha256 \"${sha256}\"/" \
  "$cask"
if ! grep -qxF "  version \"${version}\"" "$cask" || ! grep -qxF "  sha256 \"${sha256}\"" "$cask"; then
  echo "error: could not update the version and sha256 stanzas in ${cask}" >&2
  exit 1
fi

echo "==> Built ${zip} ($(lipo -archs "$app/Contents/MacOS/MacRunner"))"
