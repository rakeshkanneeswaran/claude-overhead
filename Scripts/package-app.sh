#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
ICON_SOURCE_PATH="$PROJECT_DIR/.github/overhead-icon.png"
source "$SCRIPT_DIR/signing-common.sh"

PACKAGE_VARIANT="${CHIMLO_PACKAGE_VARIANT:-development}"
case "$PACKAGE_VARIANT" in
  development)
    APP_BUNDLE_NAME="Claude Overhead Dev"
    APP_BUNDLE_IDENTIFIER="com.rakesh.overhead.development"
    ;;
  release)
    APP_BUNDLE_NAME="Claude Overhead"
    APP_BUNDLE_IDENTIFIER="com.rakesh.overhead"
    CHIMLO_CODE_SIGN_IDENTITY="${CHIMLO_CODE_SIGN_IDENTITY:-$CHIMLO_RELEASE_SIGNING_IDENTITY_DEFAULT}"
    CHIMLO_CODE_SIGN_KEYCHAIN="${CHIMLO_CODE_SIGN_KEYCHAIN:-$CHIMLO_RELEASE_SIGNING_KEYCHAIN_DEFAULT}"
    CHIMLO_CODE_SIGN_PASSWORD_FILE="${CHIMLO_CODE_SIGN_PASSWORD_FILE:-$CHIMLO_RELEASE_SIGNING_PASSWORD_FILE_DEFAULT}"
    CHIMLO_REQUIRE_STABLE_SIGNING=1
    ;;
  update-test)
    APP_BUNDLE_NAME="Claude Overhead Update Test"
    APP_BUNDLE_IDENTIFIER="com.rakesh.overhead.update-test"
    CHIMLO_CODE_SIGN_IDENTITY="${CHIMLO_CODE_SIGN_IDENTITY:-$CHIMLO_RELEASE_SIGNING_IDENTITY_DEFAULT}"
    CHIMLO_CODE_SIGN_KEYCHAIN="${CHIMLO_CODE_SIGN_KEYCHAIN:-$CHIMLO_RELEASE_SIGNING_KEYCHAIN_DEFAULT}"
    CHIMLO_CODE_SIGN_PASSWORD_FILE="${CHIMLO_CODE_SIGN_PASSWORD_FILE:-$CHIMLO_RELEASE_SIGNING_PASSWORD_FILE_DEFAULT}"
    CHIMLO_REQUIRE_STABLE_SIGNING=1
    ;;
  *)
    print -u2 "Unknown Claude Overhead package variant: $PACKAGE_VARIANT"
    print -u2 "Expected 'development', 'release', or 'update-test'."
    exit 1
    ;;
esac

if [[ -n "${CHIMLO_PACKAGE_OUTPUT_PATH:-}" ]]; then
  if [[ "$PACKAGE_VARIANT" != "update-test" ]]; then
    print -u2 "CHIMLO_PACKAGE_OUTPUT_PATH is reserved for the isolated update test."
    exit 1
  fi
  TARGET_APP_DIR="$CHIMLO_PACKAGE_OUTPUT_PATH"
  if [[ "$TARGET_APP_DIR" != /* ]]; then
    TARGET_APP_DIR="$PROJECT_DIR/$TARGET_APP_DIR"
  fi
  if [[ "$TARGET_APP_DIR" == *"/../"* || "$TARGET_APP_DIR" == *"/.." ]]; then
    print -u2 "The update-test output path cannot contain '..': $TARGET_APP_DIR"
    exit 1
  fi
  case "$TARGET_APP_DIR" in
    "$PROJECT_DIR/dist/update-test/"*.app) ;;
    *)
      print -u2 "The update-test app must stay under dist/update-test: $TARGET_APP_DIR"
      exit 1
      ;;
  esac
else
  TARGET_APP_DIR="$PROJECT_DIR/dist/$APP_BUNDLE_NAME.app"
fi

cd "$PROJECT_DIR"
./Scripts/swift.sh build -c release --product ChimloApp
./Scripts/swift.sh build -c release --product overhead

if [[ -n "${CHIMLO_SDK_PATH:-}" ]]; then
  BIN_DIR="$(SDKROOT="$CHIMLO_SDK_PATH" CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/overhead-clang-module-cache" SWIFTPM_MODULECACHE_OVERRIDE="${TMPDIR:-/tmp}/overhead-swiftpm-cache" swift build --disable-sandbox -c release --show-bin-path --sdk "$CHIMLO_SDK_PATH")"
else
  BIN_DIR="$(swift build --disable-sandbox -c release --show-bin-path)"
fi

STAGING_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/overhead-package.XXXXXX")"
APP_DIR="$STAGING_ROOT/$APP_BUNDLE_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
HELPERS_DIR="$CONTENTS_DIR/Helpers"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

cleanup_staging() {
  rm -rf "$STAGING_ROOT"
}
trap cleanup_staging EXIT

mkdir -p "$MACOS_DIR" "$HELPERS_DIR" "$FRAMEWORKS_DIR" "$RESOURCES_DIR"
cp "$PROJECT_DIR/Packaging/Info.plist" "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -replace CFBundleDisplayName -string "$APP_BUNDLE_NAME" "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -replace CFBundleName -string "$APP_BUNDLE_NAME" "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -replace CFBundleIdentifier -string "$APP_BUNDLE_IDENTIFIER" "$CONTENTS_DIR/Info.plist"

if [[ "$PACKAGE_VARIANT" != "development" ]]; then
  if [[ -n "${CHIMLO_VERSION:-}" ]]; then
    /usr/bin/plutil -replace CFBundleShortVersionString \
      -string "${CHIMLO_VERSION#v}" \
      "$CONTENTS_DIR/Info.plist"
  fi
  if [[ -n "${CHIMLO_BUILD_NUMBER:-}" ]]; then
    /usr/bin/plutil -replace CFBundleVersion \
      -string "$CHIMLO_BUILD_NUMBER" \
      "$CONTENTS_DIR/Info.plist"
  fi
fi

if [[ "$PACKAGE_VARIANT" == "development" ]]; then
  for sparkle_key in \
    SUFeedURL \
    SUPublicEDKey \
    SUEnableAutomaticChecks \
    SUScheduledCheckInterval \
    SUAllowsAutomaticUpdates \
    SUAutomaticallyUpdate \
    SUVerifyUpdateBeforeExtraction \
    SURequireSignedFeed; do
    /usr/bin/plutil -remove "$sparkle_key" "$CONTENTS_DIR/Info.plist" 2>/dev/null || true
  done
fi

if [[ "$PACKAGE_VARIANT" == "update-test" ]]; then
  UPDATE_FEED_URL="${CHIMLO_UPDATE_FEED_URL:-}"
  if [[ ! "$UPDATE_FEED_URL" =~ '^http://localhost:[0-9]+/appcast\.xml$' ]]; then
    print -u2 "The update-test feed must be a loopback appcast URL."
    print -u2 "Expected: http://localhost:<port>/appcast.xml"
    exit 1
  fi

  /usr/bin/plutil -replace SUFeedURL -string "$UPDATE_FEED_URL" "$CONTENTS_DIR/Info.plist"
  /usr/bin/plutil -replace SUEnableAutomaticChecks -bool false "$CONTENTS_DIR/Info.plist"
  /usr/bin/plutil -insert ChimloUpdateTestMode -bool true "$CONTENTS_DIR/Info.plist"
  /usr/bin/plutil -insert NSAppTransportSecurity \
    -json '{"NSAllowsLocalNetworking":true}' \
    "$CONTENTS_DIR/Info.plist"
fi

if [[ ! -d "$BIN_DIR/Sparkle.framework" ]]; then
  print -u2 "Missing Sparkle.framework in SwiftPM build products: $BIN_DIR"
  exit 1
fi

cp "$BIN_DIR/ChimloApp" "$MACOS_DIR/Overhead"
cp "$BIN_DIR/overhead" "$HELPERS_DIR/overhead"
/usr/bin/ditto "$BIN_DIR/Sparkle.framework" "$FRAMEWORKS_DIR/Sparkle.framework"

ICONSET_DIR="$STAGING_ROOT/Overhead.iconset"
mkdir -p "$ICONSET_DIR"
for icon_size in 16 32 128 256 512; do
  /usr/bin/sips \
    --resampleHeightWidth "$icon_size" "$icon_size" \
    "$ICON_SOURCE_PATH" \
    --out "$ICONSET_DIR/icon_${icon_size}x${icon_size}.png" \
    >/dev/null

  retina_size="$((icon_size * 2))"
  /usr/bin/sips \
    --resampleHeightWidth "$retina_size" "$retina_size" \
    "$ICON_SOURCE_PATH" \
    --out "$ICONSET_DIR/icon_${icon_size}x${icon_size}@2x.png" \
    >/dev/null
done
CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/overhead-clang-module-cache" \
  swift "$SCRIPT_DIR/build-icns.swift" "$ICONSET_DIR" "$RESOURCES_DIR/Overhead.icns"
rm -rf "$ICONSET_DIR"

chmod 755 \
  "$MACOS_DIR/Overhead" \
  "$HELPERS_DIR/overhead"

if command -v codesign >/dev/null 2>&1; then
  # Finder and downloaded vendor artifacts can carry provenance or quarantine
  # metadata into the generated bundle. Strip it from the disposable package
  # copy so codesign can replace nested signatures deterministically.
  /usr/bin/xattr -cr "$APP_DIR"
  overhead_configure_signing
  if [[ "${CHIMLO_REQUIRE_STABLE_SIGNING:-0}" == "1" && "$CHIMLO_SIGNING_MODE" == "adhoc" ]]; then
    # Public builds are ad-hoc signed until there is a Developer ID; that
    # must be asked for explicitly, so nothing ships unsigned by accident.
    if [[ "${CHIMLO_ALLOW_ADHOC_RELEASE:-0}" != "1" ]]; then
      print -u2 "Refusing to create a public release with an ad-hoc signature."
      print -u2 "Run 'make release-signing-identity' first, or set CHIMLO_ALLOW_ADHOC_RELEASE=1."
      exit 1
    fi
    print -u2 "Warning: this release build is ad-hoc signed: not Developer ID signed, not notarized."
  fi
  overhead_sign_app_bundle "$APP_DIR"

  if [[ "$CHIMLO_SIGNING_MODE" == "adhoc" ]]; then
    print -u2 "Warning: Claude Overhead was signed ad hoc. macOS may treat each rebuild as a new app."
    print -u2 "Run 'make signing-identity' once to install a stable local identity."
  else
    print "Signed with: $CHIMLO_ACTIVE_SIGNING_IDENTITY"
  fi
fi

mkdir -p "${TARGET_APP_DIR:h}"
rm -rf "$TARGET_APP_DIR"
mv "$APP_DIR" "$TARGET_APP_DIR"
rmdir "$STAGING_ROOT"
trap - EXIT

echo "$TARGET_APP_DIR"
