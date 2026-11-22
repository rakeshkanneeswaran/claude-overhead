#!/bin/bash
# Installs Claude Overhead, the macOS notch companion for Claude Code.
#
#   curl -fsSL https://github.com/rakeshkanneeswaran/claude-overhead/releases/latest/download/install.sh | bash
#
# It downloads the latest release's disk image, checks it against the
# release's SHA-256 checksum, copies Claude Overhead into /Applications
# (or ~/Applications when /Applications is not writable), and opens it.
# Nothing else on the Mac is changed. Read it first if you like:
# https://github.com/rakeshkanneeswaran/claude-overhead/blob/main/Scripts/install.sh
#
# Options, as environment variables:
#   CLAUDE_OVERHEAD_VERSION=v1.0.0   install that release instead of the latest
#   CLAUDE_OVERHEAD_INSTALL_DIR=DIR  install into DIR
#   CLAUDE_OVERHEAD_NO_OPEN=1        do not open the app afterwards

# Scratch space, removed on exit whatever happens.
WORK=""
MOUNT=""
cleanup() {
  if [[ -n "$MOUNT" ]]; then /usr/bin/hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true; fi
  if [[ -n "$WORK" ]]; then rm -rf "$WORK"; fi
}

# Everything runs inside main, so a download cut off halfway runs nothing.
main() {
  set -euo pipefail

  local repo="rakeshkanneeswaran/claude-overhead"
  local version="${CLAUDE_OVERHEAD_VERSION:-latest}"
  local base
  if [[ "$version" == "latest" ]]; then
    base="https://github.com/$repo/releases/latest/download"
  else
    [[ "$version" == v* ]] || version="v$version"
    base="https://github.com/$repo/releases/download/$version"
  fi
  local app_name="Claude Overhead.app"
  local bundle_id="com.rakesh.overhead"

  bold() { printf '\033[1m%s\033[0m\n' "$1"; }
  step() { printf '\033[38;2;217;119;87m==>\033[0m %s\n' "$1"; }
  fail() { printf '\033[31mError:\033[0m %s\n' "$1" >&2; exit 1; }

  # Requirements: macOS 14 or newer on Apple silicon.
  [[ "$(uname -s)" == "Darwin" ]] || fail "Claude Overhead runs on macOS only."
  [[ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" == "1" ]] \
    || fail "Claude Overhead needs a Mac with Apple silicon."
  local macos major
  macos="$(/usr/bin/sw_vers -productVersion)"
  major="${macos%%.*}"
  (( major >= 14 )) || fail "Claude Overhead needs macOS 14 or newer (this Mac has $macos)."

  local install_dir="${CLAUDE_OVERHEAD_INSTALL_DIR:-}"
  if [[ -z "$install_dir" ]]; then
    if [[ -w /Applications ]]; then install_dir="/Applications"; else install_dir="$HOME/Applications"; fi
  fi
  mkdir -p "$install_dir"
  local destination="$install_dir/$app_name"

  WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-overhead-install.XXXXXX")"
  trap cleanup EXIT
  local work="$WORK"
  local mount="$work/mount"

  bold "Installing Claude Overhead"
  step "Downloading the ${version} release"
  /usr/bin/curl -fL --retry 3 --progress-bar -o "$work/Claude-Overhead.dmg" "$base/Claude-Overhead.dmg" \
    || fail "Could not download Claude Overhead. Check your connection and try again."
  /usr/bin/curl -fsSL --retry 3 -o "$work/SHA256SUMS.txt" "$base/SHA256SUMS.txt" \
    || fail "Could not download the release checksums."

  step "Checking the download"
  local expected actual
  expected="$(awk '$2 == "Claude-Overhead.dmg" { print $1 }' "$work/SHA256SUMS.txt")"
  actual="$(/usr/bin/shasum -a 256 "$work/Claude-Overhead.dmg" | awk '{ print $1 }')"
  [[ -n "$expected" && "$expected" == "$actual" ]] \
    || fail "The download does not match the release checksum. Nothing was installed."

  mkdir -p "$mount"
  /usr/bin/hdiutil attach -readonly -nobrowse -mountpoint "$mount" -quiet "$work/Claude-Overhead.dmg" \
    || fail "Could not open the disk image."
  MOUNT="$mount"
  local source="$mount/$app_name"
  [[ -d "$source" ]] || fail "The disk image does not contain $app_name."
  [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$source/Contents/Info.plist")" == "$bundle_id" ]] \
    || fail "The app in the disk image is not Claude Overhead."
  /usr/bin/codesign --verify --deep --strict "$source" 2>/dev/null \
    || fail "The app's code signature is not intact. Nothing was installed."
  local app_version
  app_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$source/Contents/Info.plist")"

  # The copy being replaced is closed first, so the new one starts cleanly.
  # Only a process running from exactly that path; any other copy is left alone.
  local pid running=""
  for pid in $(/usr/bin/pgrep -x Overhead || true); do
    if [[ "$(/bin/ps -o command= -p "$pid" 2>/dev/null)" == "$destination/Contents/MacOS/Overhead"* ]]; then
      running="$running $pid"
    fi
  done
  if [[ -n "$running" ]]; then
    step "Closing the running Claude Overhead"
    kill $running 2>/dev/null || true
    sleep 1
  fi

  step "Installing Claude Overhead $app_version into $install_dir"
  if [[ -d "$destination" ]]; then
    # Only ever the exact app bundle this script installs.
    [[ "$destination" == */"$app_name" ]] || fail "Refusing to replace $destination."
    rm -rf "$destination"
  fi
  /usr/bin/ditto "$source" "$destination"
  # A copy made by curl is not quarantined; clear the flag anyway in case an
  # earlier browser download left one on this path.
  /usr/bin/xattr -dr com.apple.quarantine "$destination" 2>/dev/null || true

  /usr/bin/hdiutil detach "$mount" -quiet >/dev/null 2>&1 || true
  MOUNT=""

  if [[ "${CLAUDE_OVERHEAD_NO_OPEN:-0}" != "1" ]]; then
    step "Opening Claude Overhead"
    /usr/bin/open "$destination"
  fi

  bold "Claude Overhead $app_version is installed."
  echo "The setup window walks you through connecting Claude Code. To remove it later,"
  echo "click Disconnect in Settings > Agents, then move \"$destination\" to the Trash."
}

main "$@"
