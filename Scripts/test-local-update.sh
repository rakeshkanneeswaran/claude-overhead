#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
# Outside a macOS-protected folder (Documents, Desktop) the test apps never
# trigger a Files and Folders prompt; set CHIMLO_UPDATE_TEST_ROOT to a
# temporary folder named update-test for that.
TEST_ROOT="${CHIMLO_UPDATE_TEST_ROOT:-$PROJECT_DIR/dist/update-test}"
HOST_APP_PATH="$TEST_ROOT/host/Claude Overhead.app"
UPDATE_APP_PATH="$TEST_ROOT/update/Claude Overhead.app"
FEED_DIR="$TEST_ROOT/feed"
DMG_PATH="$FEED_DIR/Claude-Overhead-99.0.0.dmg"
APPCAST_PATH="$FEED_DIR/appcast.xml"
SERVER_LOG_PATH="$TEST_ROOT/server.log"
PACKAGE_APP="$SCRIPT_DIR/package-app.sh"
PACKAGE_DMG="$SCRIPT_DIR/package-dmg.sh"
GENERATE_APPCAST="$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
SIGN_UPDATE="$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/bin/sign_update"
SPARKLE_ACCOUNT="${SPARKLE_KEY_ACCOUNT:-com.rakesh.overhead}"
PORT="${CHIMLO_UPDATE_TEST_PORT:-55116}"
HOST_VERSION="98.0.0"
HOST_BUILD="9800"
UPDATE_VERSION="99.0.0"
UPDATE_BUILD="9900"
MODE="${1:-}"
TEST_BUNDLE_IDENTIFIER="com.rakesh.overhead.update-test"
STATES_LOG="$TEST_ROOT/states.log"
AUTO_TIMEOUT_SECONDS="${CHIMLO_UPDATE_TEST_TIMEOUT:-240}"

# Public releases are ad-hoc signed (no Developer ID), so the test signs the
# same way by default. Set CHIMLO_CODE_SIGN_IDENTITY to test identity signing.
export CHIMLO_CODE_SIGN_IDENTITY="${CHIMLO_CODE_SIGN_IDENTITY:--}"
if [[ "$CHIMLO_CODE_SIGN_IDENTITY" == "-" ]]; then
  export CHIMLO_ALLOW_ADHOC_RELEASE=1
fi

# The EdDSA key: a key file (SPARKLE_ED_KEY_FILE) or the Keychain account.
typeset -a SPARKLE_KEY_ARGS
if [[ -n "${SPARKLE_ED_KEY_FILE:-}" ]]; then
  SPARKLE_KEY_ARGS=(--ed-key-file "$SPARKLE_ED_KEY_FILE")
else
  SPARKLE_KEY_ARGS=(--account "$SPARKLE_ACCOUNT")
fi

case "$MODE" in
  ""|--prepare-only|--auto|--auto-whats-new|--auto-tampered|--auto-offline|--auto-wrong-notes) ;;
  *)
    print -u2 "Usage: $0 [--prepare-only | --auto | --auto-whats-new | --auto-tampered | --auto-offline | --auto-wrong-notes]"
    print -u2 "  --auto              update unattended; pass when 98 becomes 99 with 99's What's New, and relaunches"
    print -u2 "  --auto-whats-new    as a person would: check, the What's New window opens, then its Update Now"
    print -u2 "  --auto-tampered     the download is altered after signing; pass when it is refused"
    print -u2 "  --auto-offline      nothing serves the feed; pass when the failure is explained"
    print -u2 "  --auto-wrong-notes  the feed carries another version's notes; pass when they are not shown"
    exit 64
    ;;
esac

if [[ ! "$PORT" =~ '^[0-9]+$' ]] || (( PORT < 1024 || PORT > 65535 )); then
  print -u2 "CHIMLO_UPDATE_TEST_PORT must be between 1024 and 65535."
  exit 64
fi

if [[ "$TEST_ROOT" != "$PROJECT_DIR/dist/update-test" ]] \
   && [[ "${TEST_ROOT:t}" != "update-test" || ( "$TEST_ROOT" != /private/tmp/* && "$TEST_ROOT" != /private/var/folders/* && "$TEST_ROOT" != /tmp/* ) ]]; then
  print -u2 "Refusing to replace an unexpected test directory: $TEST_ROOT"
  print -u2 "Use $PROJECT_DIR/dist/update-test or a temporary folder named update-test."
  exit 1
fi

if [[ ! -x "$GENERATE_APPCAST" || ! -x "$SIGN_UPDATE" ]]; then
  print -u2 "Sparkle's update tools are unavailable."
  print -u2 "Run 'swift package resolve' first."
  exit 1
fi

PYTHON_BIN=""
if [[ "$MODE" != "--prepare-only" ]]; then
  PYTHON_BIN="${CHIMLO_PYTHON_BIN:-$(command -v python3 || true)}"
  if [[ -z "$PYTHON_BIN" ]]; then
    print -u2 "Python 3 is required to serve the local test feed."
    exit 1
  fi

  if /usr/bin/nc -z 127.0.0.1 "$PORT" >/dev/null 2>&1; then
    print -u2 "Port $PORT is already in use."
    print -u2 "Choose another port with CHIMLO_UPDATE_TEST_PORT=<port>."
    exit 1
  fi
fi

FEED_BASE_URL="http://localhost:$PORT"
FEED_URL="$FEED_BASE_URL/appcast.xml"
TEST_PROCESS_PATTERN='update-test/(host|update)/Claude Overhead\.app/Contents/MacOS/Overhead'

if /usr/bin/pgrep -f "$TEST_PROCESS_PATTERN" >/dev/null 2>&1; then
  print -u2 "Claude Overhead Update Test is still running."
  print -u2 "Quit it before starting a fresh local update test."
  exit 1
fi

rm -rf "$TEST_ROOT"
mkdir -p "${HOST_APP_PATH:h}" "${UPDATE_APP_PATH:h}" "$FEED_DIR"

# What's New for the test release: a card with a picture, one with a
# character and one with words only, plus notes for another version to
# prove that the wrong notes are never shown.
NOTES_ROOT="$TEST_ROOT/notes"
WRONG_NOTES_VERSION="97.0.0"
mkdir -p "$NOTES_ROOT/ReleaseNotes/$UPDATE_VERSION"
"${CHIMLO_PYTHON_BIN:-python3}" - "$NOTES_ROOT/ReleaseNotes/$UPDATE_VERSION/whats-new-test.png" <<'PNG_END'
import struct, sys, zlib
width, height = 320, 160
rows = b"".join(
    b"\x00" + b"".join(bytes((40 + 200 * x // width, 70 + 120 * y // height, 96)) for x in range(width))
    for y in range(height)
)
def chunk(kind, body):
    return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)) \
    + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")
open(sys.argv[1], "wb").write(png)
PNG_END
for notes_version in "$UPDATE_VERSION" "$WRONG_NOTES_VERSION"; do
  cat > "$NOTES_ROOT/ReleaseNotes/$notes_version.json" <<NOTES_END
{
  "schema": 1,
  "version": "$notes_version",
  "date": "2026-01-01",
  "introduction": "Test release $notes_version for the local update test. Nothing here is a real change.",
  "cards": [
    { "id": "test-feature", "category": "feature", "title": "A test feature with a character",
      "summary": "This card proves that a release can carry a character's pixels.",
      "visual": { "kind": "sprites", "sprites": [ { "character": "animals.cat" } ] } },
    { "id": "test-improvement", "category": "improvement", "title": "A test improvement with a picture",
      "summary": "This card proves that a picture is shown only when its SHA-256 matches.",
      "visual": { "kind": "image", "image": { "file": "whats-new-test.png", "alt": "A test gradient." } } },
    { "id": "test-fix", "category": "fix", "title": "A test fix with words only",
      "summary": "This card proves that a card needs no picture." }
  ]
}
NOTES_END
done
mkdir -p "$NOTES_ROOT/ReleaseNotes/$WRONG_NOTES_VERSION"
cp "$NOTES_ROOT/ReleaseNotes/$UPDATE_VERSION/whats-new-test.png" "$NOTES_ROOT/ReleaseNotes/$WRONG_NOTES_VERSION/"
EMBEDDED_NOTES_VERSION="$UPDATE_VERSION"
[[ "$MODE" == "--auto-wrong-notes" ]] && EMBEDDED_NOTES_VERSION="$WRONG_NOTES_VERSION"

print "Building the signed update candidate ($UPDATE_VERSION)..."
CHIMLO_VERSION="$UPDATE_VERSION" \
CHIMLO_BUILD_NUMBER="$UPDATE_BUILD" \
CHIMLO_WHATS_NEW_ROOT="$NOTES_ROOT" \
CHIMLO_PACKAGE_VARIANT=update-test \
CHIMLO_PACKAGE_OUTPUT_PATH="$UPDATE_APP_PATH" \
CHIMLO_UPDATE_FEED_URL="$FEED_URL" \
  "$PACKAGE_APP"

print "Packaging the local update disk image..."
CHIMLO_PACKAGE_APP_PATH="$UPDATE_APP_PATH" \
  "$PACKAGE_DMG" "$DMG_PATH"

print "Generating the signed local appcast, with What's New for $EMBEDDED_NOTES_VERSION..."
# As Scripts/generate-appcast.sh does for a release: the published notes go
# into the feed entry, and their pictures sit beside the download.
PUBLISHED_NOTES="$TEST_ROOT/published-notes.json"
"$SCRIPT_DIR/swift.sh" run overhead-release-notes emit "$EMBEDDED_NOTES_VERSION" \
  --root "$NOTES_ROOT" --output "$PUBLISHED_NOTES" --assets "$FEED_DIR" >/dev/null
cp "$PUBLISHED_NOTES" "${DMG_PATH:r}.txt"
"$GENERATE_APPCAST" \
  "${SPARKLE_KEY_ARGS[@]}" \
  --download-url-prefix "$FEED_BASE_URL/" \
  --link "https://github.com/rakeshkanneeswaran/claude-overhead" \
  --maximum-versions 1 \
  --maximum-deltas 0 \
  --embed-release-notes \
  -o "$APPCAST_PATH" \
  "$FEED_DIR"

if [[ ! -f "$APPCAST_PATH" ]]; then
  print -u2 "Sparkle did not generate the local appcast."
  exit 1
fi

/usr/bin/xmllint --noout "$APPCAST_PATH"
"$SIGN_UPDATE" "${SPARKLE_KEY_ARGS[@]}" --verify "$APPCAST_PATH"

ACTUAL_URL="$(/usr/bin/xmllint --xpath \
  'string(//*[local-name()="enclosure"]/@url)' "$APPCAST_PATH")"
ARCHIVE_SIGNATURE="$(/usr/bin/xmllint --xpath \
  'string(//*[local-name()="enclosure"]/@*[local-name()="edSignature"])' \
  "$APPCAST_PATH")"
APPCAST_LENGTH="$(/usr/bin/xmllint --xpath \
  'string(//*[local-name()="enclosure"]/@length)' "$APPCAST_PATH")"
ACTUAL_LENGTH="$(/usr/bin/stat -f '%z' "$DMG_PATH")"
APPCAST_BUILD="$(/usr/bin/xmllint --xpath \
  'string(//*[local-name()="item"]/*[local-name()="version"])' \
  "$APPCAST_PATH")"

EMBEDDED_NOTES="$(/usr/bin/xmllint --xpath \
  'string(//*[local-name()="item"]/*[local-name()="description"])' "$APPCAST_PATH")"
if [[ -z "$EMBEDDED_NOTES" || "$EMBEDDED_NOTES" != "$(<"$PUBLISHED_NOTES")" ]]; then
  print -u2 "The local appcast does not carry the published What's New."
  exit 1
fi

if [[ "$ACTUAL_URL" != "$FEED_BASE_URL/${DMG_PATH:t}" ]]; then
  print -u2 "The local appcast points at an unexpected download URL: $ACTUAL_URL"
  exit 1
fi

if [[ -z "$ARCHIVE_SIGNATURE" \
   || "$APPCAST_LENGTH" != "$ACTUAL_LENGTH" \
   || "$APPCAST_BUILD" != "$UPDATE_BUILD" ]]; then
  print -u2 "The local appcast metadata is incomplete or stale."
  exit 1
fi

"$SIGN_UPDATE" "${SPARKLE_KEY_ARGS[@]}" \
  --verify "$DMG_PATH" "$ARCHIVE_SIGNATURE"

print "Building the older signed host ($HOST_VERSION)..."
CHIMLO_VERSION="$HOST_VERSION" \
CHIMLO_BUILD_NUMBER="$HOST_BUILD" \
CHIMLO_PACKAGE_VARIANT=update-test \
CHIMLO_PACKAGE_OUTPUT_PATH="$HOST_APP_PATH" \
CHIMLO_UPDATE_FEED_URL="$FEED_URL" \
  "$PACKAGE_APP"

verify_test_app() {
  typeset app_path="$1"
  typeset expected_version="$2"
  typeset info_plist="$app_path/Contents/Info.plist"

  /usr/bin/codesign --verify --deep --strict "$app_path"

  typeset bundle_identifier
  typeset app_version
  typeset feed_url
  typeset update_test_mode
  typeset automatic_checks
  bundle_identifier="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$info_plist")"
  app_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$info_plist")"
  feed_url="$(/usr/bin/plutil -extract SUFeedURL raw "$info_plist")"
  update_test_mode="$(/usr/bin/plutil -extract ChimloUpdateTestMode raw "$info_plist")"
  automatic_checks="$(/usr/bin/plutil -extract SUEnableAutomaticChecks raw "$info_plist")"

  if [[ "$bundle_identifier" != "$TEST_BUNDLE_IDENTIFIER" \
     || "$app_version" != "$expected_version" \
     || "$feed_url" != "$FEED_URL" \
     || "$update_test_mode" != "true" \
     || "$automatic_checks" != "false" ]]; then
    print -u2 "The local update test app has unexpected bundle metadata: $app_path"
    exit 1
  fi
}

verify_test_app "$HOST_APP_PATH" "$HOST_VERSION"
verify_test_app "$UPDATE_APP_PATH" "$UPDATE_VERSION"

HOST_REQUIREMENT="$(/usr/bin/codesign -d -r- "$HOST_APP_PATH" 2>&1 \
  | /usr/bin/sed -n 's/^designated => //p')"
UPDATE_REQUIREMENT="$(/usr/bin/codesign -d -r- "$UPDATE_APP_PATH" 2>&1 \
  | /usr/bin/sed -n 's/^designated => //p')"

if [[ "$CHIMLO_CODE_SIGN_IDENTITY" == "-" ]]; then
  # Ad-hoc requirements are each build's own hash, so they never match.
  # Sparkle then relies on the EdDSA signature, which is what releases use.
  print "Ad-hoc signed: the update is trusted through its EdDSA signature."
elif [[ -z "$HOST_REQUIREMENT" || "$HOST_REQUIREMENT" != "$UPDATE_REQUIREMENT" ]]; then
  print -u2 "The two local test apps do not share a designated requirement."
  exit 1
fi

rm -rf "$UPDATE_APP_PATH"
rmdir "${UPDATE_APP_PATH:h}"

print "PASS: local update artifacts are signed, isolated, and internally consistent."
print "Host:    $HOST_APP_PATH"
print "Update:  $DMG_PATH"
print "Appcast: $APPCAST_PATH"
print "Bundle:  $TEST_BUNDLE_IDENTIFIER"

if [[ "$MODE" == "--prepare-only" ]]; then
  exit 0
fi

if [[ "$MODE" == "--auto-tampered" ]]; then
  # Altered after signing, as a compromised mirror would serve it.
  print -n "tampered" >> "$DMG_PATH"
fi

SERVER_PID=0
cleanup_server() {
  if (( SERVER_PID > 0 )) && /bin/kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    /bin/kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup_server EXIT INT TERM

SERVER_READY=1
if [[ "$MODE" != "--auto-offline" ]]; then
"$PYTHON_BIN" -m http.server "$PORT" \
  --bind 127.0.0.1 \
  --directory "$FEED_DIR" \
  >"$SERVER_LOG_PATH" 2>&1 &
SERVER_PID=$!

SERVER_READY=0
for _ in {1..50}; do
  if /usr/bin/curl --silent --fail "$FEED_URL" >/dev/null 2>&1; then
    SERVER_READY=1
    break
  fi
  /bin/sleep 0.1
done
fi

if (( ! SERVER_READY )); then
  print -u2 "The local update server did not start."
  print -u2 "See: $SERVER_LOG_PATH"
  exit 1
fi

/usr/bin/defaults delete "$TEST_BUNDLE_IDENTIFIER" >/dev/null 2>&1 || true

if [[ "$MODE" == --auto* ]]; then
  # Unattended: the host checks, downloads, verifies, installs and relaunches
  # on its own, logging every state. Pass when the bundle on disk is the
  # update and the relaunched app reports "Updated to".
  : > "$STATES_LOG"
  AUTO_ARGUMENT="--update-test-auto-install"
  [[ "$MODE" == "--auto-whats-new" ]] && AUTO_ARGUMENT="--update-test-auto-whats-new"
  /usr/bin/open -n "$HOST_APP_PATH" --args "$AUTO_ARGUMENT" --update-test-log "$STATES_LOG"
  HOST_PLIST="$HOST_APP_PATH/Contents/Info.plist"
  RESULT="timeout"
  for _ in $(seq 1 "$AUTO_TIMEOUT_SECONDS"); do
    /bin/sleep 1
    if /usr/bin/grep -q "failed(" "$STATES_LOG" 2>/dev/null; then RESULT="failed"; break; fi
    installed="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$HOST_PLIST" 2>/dev/null || true)"
    if [[ "$installed" == "$UPDATE_VERSION" ]] \
       && /usr/bin/grep -q "^$UPDATE_VERSION	updated(version: \"$UPDATE_VERSION\")" "$STATES_LOG" 2>/dev/null; then
      RESULT="passed"; break
    fi
  done
  # What the host read from the feed before installing: the notes must be
  # those of the version it installed, or be refused when they are not.
  if [[ "$MODE" == "--auto" || "$MODE" == "--auto-whats-new" || "$MODE" == "--auto-wrong-notes" ]]; then
    if [[ "$MODE" != "--auto-wrong-notes" ]]; then
      EXPECTED_OFFER="^$HOST_VERSION	offer(version: \"$UPDATE_VERSION\")	notes(version: \"$UPDATE_VERSION\", cards: 3)"
    else
      EXPECTED_OFFER="^$HOST_VERSION	offer(version: \"$UPDATE_VERSION\")	notes(unavailable: wrongVersion(found: \"$WRONG_NOTES_VERSION\"))"
    fi
    if [[ "$RESULT" == "passed" ]] && ! /usr/bin/grep -q "$EXPECTED_OFFER" "$STATES_LOG"; then
      RESULT="wrong What's New"
    fi
  fi
  # The owner's path: the window was on screen, with its picture checked and
  # loaded, before anything was downloaded; and the check alone downloaded
  # nothing.
  if [[ "$MODE" == "--auto-whats-new" && "$RESULT" == "passed" ]]; then
    WINDOW_LINE="$(/usr/bin/grep -n "whats-new(version: \"$UPDATE_VERSION\", window: true)	pictures(whats-new-test.png: true)" "$STATES_LOG" | /usr/bin/head -1 | /usr/bin/cut -d: -f1)"
    AVAILABLE_LINE="$(/usr/bin/grep -n "	available(version: Optional(\"$UPDATE_VERSION\"))" "$STATES_LOG" | /usr/bin/head -1 | /usr/bin/cut -d: -f1)"
    DOWNLOAD_LINE="$(/usr/bin/grep -n "	downloading(" "$STATES_LOG" | /usr/bin/head -1 | /usr/bin/cut -d: -f1)"
    if [[ -z "$WINDOW_LINE" || -z "$AVAILABLE_LINE" || -z "$DOWNLOAD_LINE" ]] \
       || (( AVAILABLE_LINE > WINDOW_LINE || WINDOW_LINE > DOWNLOAD_LINE )) \
       || [[ ! -s "$TEST_ROOT/whats-new-window.png" ]]; then
      RESULT="What's New was not shown before the download"
    fi
  fi
  /usr/bin/pkill -f "$TEST_PROCESS_PATTERN" >/dev/null 2>&1 || true
  print
  print "States the app went through:"
  /usr/bin/cut -f1,2 "$STATES_LOG" | /usr/bin/sed 's/^/  /'
  if [[ "$MODE" == "--auto-tampered" || "$MODE" == "--auto-offline" ]]; then
    # A failure must explain itself and leave the installed app as it was.
    still="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$HOST_PLIST" 2>/dev/null || print unreadable)"
    reason="$(/usr/bin/grep -o 'failed([^)]*)' "$STATES_LOG" | /usr/bin/head -1)"
    message="$(/usr/bin/grep 'failed(' "$STATES_LOG" | /usr/bin/head -1 | /usr/bin/cut -f3)"
    if [[ "$RESULT" == "failed" && "$still" == "$HOST_VERSION" ]] \
       && /usr/bin/codesign --verify --deep --strict "$HOST_APP_PATH"; then
      print "PASS: refused with $reason: $message"
      print "      The installed $HOST_VERSION is untouched and its signature verifies."
      exit 0
    fi
    print -u2 "FAIL ($RESULT): expected an explained failure with $HOST_VERSION left in place (found $still)."
    exit 1
  fi
  if [[ "$RESULT" == "passed" ]]; then
    /usr/bin/codesign --verify --deep --strict "$HOST_APP_PATH"
    if [[ "$MODE" == "--auto-wrong-notes" ]]; then
      print "PASS: the feed carried the notes of $WRONG_NOTES_VERSION; they were not shown, and $UPDATE_VERSION still installed."
    elif [[ "$MODE" == "--auto-whats-new" ]]; then
      print "PASS: the check offered $UPDATE_VERSION and downloaded nothing; What's New opened with its picture;"
      print "      Update Now then installed $UPDATE_VERSION, and it relaunched. The window: $TEST_ROOT/whats-new-window.png"
    else
      print "PASS: $HOST_VERSION read the What's New of $UPDATE_VERSION, updated itself to it, relaunched, and the result verifies."
    fi
    exit 0
  fi
  print -u2 "FAIL ($RESULT). The bundle on disk reports: $(/usr/bin/plutil -extract CFBundleShortVersionString raw "$HOST_PLIST" 2>/dev/null || print unreadable)"
  exit 1
fi

/usr/bin/open -n "$HOST_APP_PATH"

print
print "Local update test is running. Nothing has been uploaded."
print "1. In About > Updates, click 'Check for Updates'."
print "2. What's New opens on $UPDATE_VERSION: three test cards, one with a picture. Nothing downloads yet."
print "3. Click 'Update Now' and watch the progress at the bottom of the window."
print "4. After Claude Overhead relaunches, confirm it shows Version $UPDATE_VERSION,"
print "   and that 'What's New in $UPDATE_VERSION' in About reopens the same notes."
print
print "Keep this command running while the update downloads."
print "Press Control-C after the test to stop the local server."
print "Server log: $SERVER_LOG_PATH"

wait "$SERVER_PID"
