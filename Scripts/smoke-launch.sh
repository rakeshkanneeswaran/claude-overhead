#!/bin/zsh
# Starts a packaged Claude Overhead and checks that it comes up: the app
# stays running and its bundled helper reaches its listener.
#
#   Scripts/smoke-launch.sh <path to the .app>
#
# The checks before this one read the bundle (signature, version, bundle id)
# and test the code as SwiftPM builds it. None of them starts the packaged
# app, and an app that cannot start cannot update itself either: every
# customer who took that release would have to reinstall by hand. So a
# release is not published until the bundle has been launched once.
#
# The connection file goes to a scratch folder, so a copy of the app already
# running on this Mac is not disturbed and nothing is left behind.
set -euo pipefail

APP="${1:?usage: smoke-launch.sh <path to the .app>}"
BINARY="$APP/Contents/MacOS/Overhead"
HELPER="$APP/Contents/Helpers/overhead"
[[ -x "$BINARY" ]] || { print -u2 "No app binary at $BINARY"; exit 1; }
[[ -x "$HELPER" ]] || { print -u2 "No helper at $HELPER"; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/overhead-smoke.XXXXXX")"
export CHIMLO_RUNTIME_DESCRIPTOR="$WORK/runtime.json"

"$BINARY" > "$WORK/app.log" 2>&1 &
APP_PID=$!
cleanup() {
  kill "$APP_PID" 2>/dev/null || true
  wait "$APP_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

for attempt in {1..80}; do
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    print -u2 "The packaged app exited during launch. Its output:"
    cat "$WORK/app.log" >&2
    exit 1
  fi
  if "$HELPER" ping >/dev/null 2>&1; then
    print "The packaged app launched and its helper reached it."
    exit 0
  fi
  sleep 0.5
done

print -u2 "The packaged app did not answer its helper within 40 seconds. Its output:"
cat "$WORK/app.log" >&2
exit 1
