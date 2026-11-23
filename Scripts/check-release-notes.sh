#!/bin/zsh
# The release-readiness check for What's New. Every release ships its own
# visual release notes (Docs/RELEASING.md); this is what enforces it.
#
#   Scripts/check-release-notes.sh
#       Every file in ReleaseNotes/ is well formed and agrees with
#       CHANGELOG.md and Packaging/Info.plist. `make check` and CI run this.
#
#   Scripts/check-release-notes.sh --release vX.Y.Z
#       ...and X.Y.Z itself is ready: its notes exist, CHANGELOG.md has its
#       dated section, and Info.plist is at that version.
#
#   Scripts/check-release-notes.sh --release vX.Y.Z --app "dist/Claude Overhead.app"
#       ...and the packaged app carries exactly those notes and its own
#       What's New window can draw every page of them. The release workflow
#       runs this on the app it is about to publish.
#
#   Scripts/check-release-notes.sh --render X.Y.Z
#       Draws every page of X.Y.Z's walkthrough with a development build, to
#       dist/whats-new/X.Y.Z/, so the notes can be looked at before tagging.
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
RELEASE=""
APP=""
RENDER=""

while (( $# > 0 )); do
  case "$1" in
    --release) RELEASE="${2:-}"; shift 2 ;;
    --app) APP="${2:-}"; shift 2 ;;
    --render) RENDER="${2:-}"; shift 2 ;;
    *)
      print -u2 "usage: check-release-notes.sh [--release vX.Y.Z [--app <Claude Overhead.app>]] | --render X.Y.Z"
      exit 64
      ;;
  esac
done
RELEASE="${RELEASE#v}"
RENDER="${RENDER#v}"
for version in "$RELEASE" "$RENDER"; do
  if [[ -n "$version" && ! "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
    print -u2 "Not a version of the form 1.2.3: $version"
    exit 64
  fi
done
if [[ -n "$APP" && -z "$RELEASE" ]]; then
  print -u2 "--app needs --release, to know which version the app should carry."
  exit 64
fi

cd "$PROJECT_DIR"
# The notes, CHANGELOG.md and Packaging/Info.plist are read from here; another
# root (CHIMLO_WHATS_NEW_ROOT) lets a release be rehearsed before the version
# is bumped.
NOTES_ROOT="${CHIMLO_WHATS_NEW_ROOT:-$PROJECT_DIR}"
tool() { "$SCRIPT_DIR/swift.sh" run overhead-release-notes "$@" --root "$NOTES_ROOT"; }

# The pages a release's notes must draw: the overview, then one per card.
expected_pages() {
  print $(( $(/usr/bin/plutil -extract cards raw -expect array "$1") + 1 ))
}

drawn_pages() {
  typeset -a pages
  pages=("$1"/*.png(N))
  print ${#pages}
}

if [[ -n "$RENDER" ]]; then
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/overhead-whats-new.XXXXXX")"
  trap 'rm -rf "$WORK"' EXIT
  tool emit "$RENDER" --output "$WORK/notes.json" --assets "$WORK/assets" >/dev/null
  "$SCRIPT_DIR/swift.sh" build --product ChimloApp >/dev/null
  BINARY="$("$SCRIPT_DIR/swift.sh" build --show-bin-path | /usr/bin/tail -1)/ChimloApp"
  OUTPUT="$PROJECT_DIR/dist/whats-new/$RENDER"
  rm -rf "$OUTPUT"
  # Drawn as an update from the version currently in Info.plist, when that is older.
  FROM="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$NOTES_ROOT/Packaging/Info.plist")"
  typeset -a from_args
  [[ "$FROM" != "$RENDER" ]] && from_args=(--from "$FROM")
  "$BINARY" --render-whats-new "$WORK/notes.json" --assets "$WORK/assets" --output "$OUTPUT" "${from_args[@]}"
  if [[ "$(drawn_pages "$OUTPUT")" != "$(expected_pages "$WORK/notes.json")" ]]; then
    print -u2 "Expected $(expected_pages "$WORK/notes.json") pages in $OUTPUT, found $(drawn_pages "$OUTPUT")."
    exit 1
  fi
  print "Look at them before tagging: open \"$OUTPUT\""
  exit 0
fi

if [[ -n "$RELEASE" ]]; then
  tool check --release "$RELEASE"
else
  tool check
fi

if [[ -n "$APP" ]]; then
  BUNDLED="$APP/Contents/Resources/WhatsNew.json"
  BINARY="$APP/Contents/MacOS/Overhead"
  [[ -x "$BINARY" ]] || { print -u2 "No app binary at $BINARY"; exit 1; }
  [[ -s "$BUNDLED" ]] || { print -u2 "$APP carries no What's New (Contents/Resources/WhatsNew.json)."; exit 1; }
  INSIDE="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
  [[ "$INSIDE" == "$RELEASE" ]] || { print -u2 "$APP is version $INSIDE, not $RELEASE."; exit 1; }

  WORK="$(mktemp -d "${TMPDIR:-/tmp}/overhead-whats-new.XXXXXX")"
  trap 'rm -rf "$WORK"' EXIT
  tool emit "$RELEASE" --output "$WORK/notes.json" --assets "$WORK/assets" >/dev/null
  /usr/bin/cmp -s "$WORK/notes.json" "$BUNDLED" \
    || { print -u2 "$APP does not carry the published notes of $RELEASE."; exit 1; }
  for picture in "$WORK/assets"/*.png(N); do
    /usr/bin/cmp -s "$picture" "$APP/Contents/Resources/WhatsNew/${picture:t}" \
      || { print -u2 "$APP is missing the picture ${picture:t}."; exit 1; }
  done

  # The decisive check: the app being published draws its own notes.
  OUTPUT="$PROJECT_DIR/dist/whats-new/$RELEASE"
  rm -rf "$OUTPUT"
  "$BINARY" --render-whats-new "$BUNDLED" --assets "$APP/Contents/Resources/WhatsNew" --output "$OUTPUT"
  if [[ "$(drawn_pages "$OUTPUT")" != "$(expected_pages "$BUNDLED")" ]]; then
    print -u2 "Expected $(expected_pages "$BUNDLED") pages in $OUTPUT, found $(drawn_pages "$OUTPUT")."
    exit 1
  fi
  print "The packaged app carries the What's New of $RELEASE and draws all $(drawn_pages "$OUTPUT") pages."
fi
