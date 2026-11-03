#!/usr/bin/env bash
# Builds and packages Dabble release artifacts.
#
#   scripts/package-release.sh <version> [output-dir]
#
#   scripts/package-release.sh 1.0.0 build/release
#
# Produces in <output-dir>:
#   Dabble-macOS.zip           Dabble.app (ad-hoc signed), zipped with ditto
#   Dabble-macOS.dmg           Disk image with Dabble.app and an /Applications link
#   Dabble-iOS-unsigned.ipa    Unsigned iOS/iPadOS app (re-sign with AltStore, Sideloadly, …)
#   SHA256SUMS.txt             Checksums for the files above
#
# Environment:
#   DERIVED_DATA    derived data path (default: build/dd-release)
#   BUILD_NUMBER    CFBundleVersion (default: $GITHUB_RUN_NUMBER, else the git commit count)
#   SKIP_IOS=1      only build the Mac app
#   SKIP_MAC=1      only build the iOS app
set -euo pipefail

if [[ $# -lt 1 ]]; then
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit 64
fi

VERSION="${1#v}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

OUT="${2:-build/release}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
DERIVED_DATA="${DERIVED_DATA:-build/dd-release}"
BUILD_NUMBER="${BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}}"
PROJECT="Dabble.xcodeproj"
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/dabble-release.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT

log() { printf '\n\033[1;31m==>\033[0m \033[1m%s\033[0m\n' "$*"; }

log "Dabble $VERSION (build $BUILD_NUMBER) → $OUT"
xcodebuild -version

COMMON=(
  -project "$PROJECT"
  -configuration Release
  -derivedDataPath "$DERIVED_DATA"
  MARKETING_VERSION="$VERSION"
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
)

artifacts=()

# ---------------------------------------------------------------- macOS
if [[ "${SKIP_MAC:-0}" != 1 ]]; then
  log "Building DabbleMac (Release, ad-hoc signed)"
  xcodebuild "${COMMON[@]}" \
    -scheme DabbleMac \
    -destination 'generic/platform=macOS' \
    -quiet \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    build

  MAC_APP="$DERIVED_DATA/Build/Products/Release/Dabble.app"
  [[ -d "$MAC_APP" ]] || { echo "error: $MAC_APP not found" >&2; exit 1; }
  codesign --verify --deep --strict "$MAC_APP"
  echo "Signature: $(codesign -dv "$MAC_APP" 2>&1 | grep -E '^Signature=' || true)"
  echo "Version:   $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$MAC_APP/Contents/Info.plist") ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$MAC_APP/Contents/Info.plist"))"

  log "Packaging Dabble-macOS.zip"
  rm -f "$OUT/Dabble-macOS.zip"
  ditto -c -k --sequesterRsrc --keepParent "$MAC_APP" "$OUT/Dabble-macOS.zip"
  artifacts+=("Dabble-macOS.zip")

  log "Packaging Dabble-macOS.dmg"
  DMG_ROOT="$STAGING/dmg"
  mkdir -p "$DMG_ROOT"
  ditto "$MAC_APP" "$DMG_ROOT/Dabble.app"
  ln -s /Applications "$DMG_ROOT/Applications"
  rm -f "$OUT/Dabble-macOS.dmg"
  hdiutil create \
    -volname "Dabble $VERSION" \
    -srcfolder "$DMG_ROOT" \
    -fs HFS+ \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    "$OUT/Dabble-macOS.dmg" 2> >(grep -v 'deprecated' >&2) >/dev/null
  artifacts+=("Dabble-macOS.dmg")
fi

# ---------------------------------------------------------------- iOS
if [[ "${SKIP_IOS:-0}" != 1 ]]; then
  log "Building DabbleiOS (Release, unsigned)"
  xcodebuild "${COMMON[@]}" \
    -scheme DabbleiOS \
    -destination 'generic/platform=iOS' \
    -quiet \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    build

  IOS_APP="$DERIVED_DATA/Build/Products/Release-iphoneos/Dabble.app"
  [[ -d "$IOS_APP" ]] || { echo "error: $IOS_APP not found" >&2; exit 1; }

  log "Packaging Dabble-iOS-unsigned.ipa"
  IPA_ROOT="$STAGING/ipa"
  mkdir -p "$IPA_ROOT/Payload"
  ditto "$IOS_APP" "$IPA_ROOT/Payload/Dabble.app"
  rm -f "$OUT/Dabble-iOS-unsigned.ipa"
  (cd "$IPA_ROOT" && zip -qry -X "$OUT/Dabble-iOS-unsigned.ipa" Payload)
  artifacts+=("Dabble-iOS-unsigned.ipa")
fi

# ---------------------------------------------------------------- checksums
if [[ ${#artifacts[@]} -gt 0 ]]; then
  (cd "$OUT" && shasum -a 256 "${artifacts[@]}" > SHA256SUMS.txt)
  artifacts+=("SHA256SUMS.txt")
fi

log "Done"
for file in ${artifacts[@]+"${artifacts[@]}"}; do
  printf '  %-28s %s\n' "$file" "$(du -h "$OUT/$file" | cut -f1)"
done
