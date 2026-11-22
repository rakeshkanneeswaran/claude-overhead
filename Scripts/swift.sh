#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
MODULE_CACHE="${TMPDIR:-/tmp}/overhead-clang-module-cache"
SWIFTPM_CACHE="${TMPDIR:-/tmp}/overhead-swiftpm-cache"

mkdir -p "$MODULE_CACHE" "$SWIFTPM_CACHE"
cd "$PROJECT_DIR"

COMMAND="${1:-}"
if [[ -z "$COMMAND" ]]; then
  echo "usage: swift.sh <build|test|run> [arguments...]" >&2
  exit 64
fi
shift

SWIFT_ARGS=("$@")
ACTIVE_DEVELOPER_DIR="$(/usr/bin/xcode-select -p)"

# ponytail: Command Line Tools ship no SwiftUIMacros plugin, and the macOS 27
# SDK turns SwiftUI's @State into a macro that needs it. Build against the
# macOS 26 SDK instead; drop this once Command Line Tools ship the plugin, or
# build with full Xcode. An explicit CHIMLO_SDK_PATH always wins.
if [[ -z "${CHIMLO_SDK_PATH:-}" && "$ACTIVE_DEVELOPER_DIR" == *CommandLineTools* \
      && -d "$ACTIVE_DEVELOPER_DIR/SDKs/MacOSX26.sdk" ]]; then
  CHIMLO_SDK_PATH="$ACTIVE_DEVELOPER_DIR/SDKs/MacOSX26.sdk"
fi

# Some Command Line Tools installations ship Swift Testing beside the
# toolchain without adding that directory to SwiftPM's test search paths.
# Supplying the installed framework explicitly keeps `make test` working with
# both Command Line Tools and full Xcode, without vendoring another test copy.
if [[ "$COMMAND" == "test" ]]; then
  TESTING_PLUGINS_DIR="$ACTIVE_DEVELOPER_DIR/usr/lib/swift/host/plugins/testing"
  if [[ -d "$TESTING_PLUGINS_DIR" ]]; then
    SWIFT_ARGS+=(-Xswiftc -plugin-path -Xswiftc "$TESTING_PLUGINS_DIR")
  fi
  TESTING_FRAMEWORKS_DIR="$ACTIVE_DEVELOPER_DIR/Library/Developer/Frameworks"
  if [[ -d "$TESTING_FRAMEWORKS_DIR/Testing.framework" ]]; then
    SWIFT_ARGS+=(
      -Xswiftc -F
      -Xswiftc "$TESTING_FRAMEWORKS_DIR"
      -Xlinker -F
      -Xlinker "$TESTING_FRAMEWORKS_DIR"
      -Xlinker -rpath
      -Xlinker "$TESTING_FRAMEWORKS_DIR"
    )
  fi
fi

if [[ -n "${CHIMLO_SDK_PATH:-}" ]]; then
  SDKROOT="$CHIMLO_SDK_PATH" \
    CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
    SWIFTPM_MODULECACHE_OVERRIDE="$SWIFTPM_CACHE" \
    swift "$COMMAND" --disable-sandbox "${SWIFT_ARGS[@]}" --sdk "$CHIMLO_SDK_PATH"
else
  CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
    SWIFTPM_MODULECACHE_OVERRIDE="$SWIFTPM_CACHE" \
    swift "$COMMAND" --disable-sandbox "${SWIFT_ARGS[@]}"
fi
