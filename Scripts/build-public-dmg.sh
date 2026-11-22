#!/bin/zsh
# Builds the public Claude Overhead DMG and checks it before anything is
# uploaded: a valid image, a valid signature, the right version inside.
#
#   Scripts/build-public-dmg.sh <version> [build-number]
#
# Writes dist/public/Claude-Overhead-<version>.dmg, the same bytes as
# dist/public/Claude-Overhead.dmg (the stable name the website links to), and
# dist/public/SHA256SUMS.txt.
#
# Signing: CHIMLO_CODE_SIGN_IDENTITY names a Developer ID identity when one
# exists. Without it the app is ad-hoc signed, which this script states
# plainly; it never claims a signature or notarization it did not make.
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
VERSION="${1:-}"
BUILD_NUMBER="${2:-1}"

if [[ ! "$VERSION" =~ '^v?[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$' ]]; then
  print -u2 "usage: build-public-dmg.sh <version, e.g. 1.0.0> [build-number]"
  exit 64
fi
VERSION="${VERSION#v}"
if [[ ! "$BUILD_NUMBER" =~ '^[0-9]+$' ]]; then
  print -u2 "The build number must be a positive integer: $BUILD_NUMBER"
  exit 64
fi

cd "$PROJECT_DIR"
OUTPUT_DIR="$PROJECT_DIR/dist/public"
VERSIONED_DMG="$OUTPUT_DIR/Claude-Overhead-$VERSION.dmg"
STABLE_DMG="$OUTPUT_DIR/Claude-Overhead.dmg"
APP_PATH="$PROJECT_DIR/dist/Claude Overhead.app"
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

if [[ -z "${CHIMLO_CODE_SIGN_IDENTITY:-}" ]]; then
  export CHIMLO_CODE_SIGN_IDENTITY="-"
  export CHIMLO_ALLOW_ADHOC_RELEASE=1
fi

CHIMLO_PACKAGE_VARIANT=release \
  CHIMLO_VERSION="$VERSION" \
  CHIMLO_BUILD_NUMBER="$BUILD_NUMBER" \
  ./Scripts/package-app.sh
./Scripts/package-dmg.sh "$VERSIONED_DMG"

# Check the image the way a downloader would get it.
/usr/bin/hdiutil verify "$VERSIONED_DMG" >/dev/null
MOUNT_POINT="$(mktemp -d "${TMPDIR:-/tmp}/overhead-verify.XXXXXX")"
cleanup() { /usr/bin/hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true; rmdir "$MOUNT_POINT" 2>/dev/null || true; }
trap cleanup EXIT
/usr/bin/hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT_POINT" "$VERSIONED_DMG" >/dev/null
MOUNTED_APP="$MOUNT_POINT/Claude Overhead.app"
[[ -d "$MOUNTED_APP" ]] || { print -u2 "The DMG has no Claude Overhead.app"; exit 1; }
[[ -L "$MOUNT_POINT/Applications" ]] || { print -u2 "The DMG has no Applications shortcut"; exit 1; }
/usr/bin/codesign --verify --deep --strict "$MOUNTED_APP"
INSIDE_VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$MOUNTED_APP/Contents/Info.plist")"
INSIDE_ID="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$MOUNTED_APP/Contents/Info.plist")"
[[ "$INSIDE_VERSION" == "$VERSION" ]] || { print -u2 "The app inside says $INSIDE_VERSION, expected $VERSION"; exit 1; }
[[ "$INSIDE_ID" == "com.rakesh.overhead" ]] || { print -u2 "Unexpected bundle identifier: $INSIDE_ID"; exit 1; }
SIGNATURE="$(/usr/bin/codesign -dv "$MOUNTED_APP" 2>&1 | grep -E '^Signature=' || true)"
cleanup
trap - EXIT

cp "$VERSIONED_DMG" "$STABLE_DMG"
(cd "$OUTPUT_DIR" && /usr/bin/shasum -a 256 "${VERSIONED_DMG:t}" "${STABLE_DMG:t}" > SHA256SUMS.txt)

print "Built Claude Overhead $VERSION ($BUILD_NUMBER), $(/usr/bin/uname -m)"
print "Signature: ${SIGNATURE:-unknown}"
[[ "$SIGNATURE" == "Signature=adhoc" ]] && print "Ad-hoc signed: not Developer ID signed and not notarized."
print "$VERSIONED_DMG"
print "$STABLE_DMG"
cat "$OUTPUT_DIR/SHA256SUMS.txt"
