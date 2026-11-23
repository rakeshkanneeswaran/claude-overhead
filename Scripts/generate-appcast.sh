#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
ARCHIVE_PATH="${1:-}"
OUTPUT_PATH="${2:-$PROJECT_DIR/dist/appcast.xml}"
GENERATE_APPCAST="$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
RELEASE_TAG="${CHIMLO_RELEASE_TAG:-}"

if [[ -z "$ARCHIVE_PATH" || ! -f "$ARCHIVE_PATH" ]]; then
  print -u2 "Usage: $0 <release.dmg> [output-appcast.xml]"
  exit 1
fi

if [[ -z "$RELEASE_TAG" ]]; then
  print -u2 "CHIMLO_RELEASE_TAG is required to generate release download URLs."
  exit 1
fi

if [[ ! -x "$GENERATE_APPCAST" ]]; then
  print -u2 "Sparkle's generate_appcast tool is unavailable. Run 'swift package resolve' first."
  exit 1
fi

if [[ "$OUTPUT_PATH" != /* ]]; then
  OUTPUT_PATH="$PROJECT_DIR/$OUTPUT_PATH"
fi

STAGING_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/overhead-appcast.XXXXXX")"

cleanup_staging() {
  rm -rf "$STAGING_ROOT"
}
trap cleanup_staging EXIT

/usr/bin/ditto "$ARCHIVE_PATH" "$STAGING_ROOT/${ARCHIVE_PATH:t}"

# What's New travels inside the signed feed, in the same entry as the
# download it describes, so an installed copy shows the notes of exactly the
# version it is offered. Sparkle embeds a text file named like the archive.
# The published notes and any pictures land in <output folder>/whats-new/.
VERSION="${RELEASE_TAG#v}"
WHATS_NEW_DIR="${OUTPUT_PATH:h}/whats-new"
rm -rf "$WHATS_NEW_DIR"
"$SCRIPT_DIR/swift.sh" run overhead-release-notes emit "$VERSION" \
  --root "${CHIMLO_WHATS_NEW_ROOT:-$PROJECT_DIR}" \
  --output "$WHATS_NEW_DIR/notes.json" \
  --assets "$WHATS_NEW_DIR" >/dev/null
if [[ ! -s "$WHATS_NEW_DIR/notes.json" ]]; then
  print -u2 "There are no publishable release notes for $VERSION (ReleaseNotes/$VERSION.json)."
  exit 1
fi
cp "$WHATS_NEW_DIR/notes.json" "$STAGING_ROOT/${ARCHIVE_PATH:t:r}.txt"

typeset -a appcast_args
appcast_args=(
  --download-url-prefix "https://github.com/rakeshkanneeswaran/claude-overhead/releases/download/$RELEASE_TAG/"
  --link "https://github.com/rakeshkanneeswaran/claude-overhead"
  --maximum-versions 1
  --maximum-deltas 0
  --embed-release-notes
  -o "$STAGING_ROOT/appcast.xml"
  "$STAGING_ROOT"
)

SIGN_UPDATE="${GENERATE_APPCAST:h}/sign_update"

# The private EdDSA key, in order of preference: SPARKLE_ED_PRIVATE_KEY (the
# key itself, as CI passes its secret; sent on stdin, never written or
# printed), SPARKLE_ED_KEY_FILE, or the login Keychain account.
with_key() {
  if [[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
    print -rn -- "$SPARKLE_ED_PRIVATE_KEY" | "$@" --ed-key-file -
  elif [[ -n "${SPARKLE_ED_KEY_FILE:-}" ]]; then
    "$@" --ed-key-file "$SPARKLE_ED_KEY_FILE"
  else
    "$@" --account "${SPARKLE_KEY_ACCOUNT:-com.rakesh.overhead}"
  fi
}

with_key "$GENERATE_APPCAST" "${appcast_args[@]}"

if [[ ! -f "$STAGING_ROOT/appcast.xml" ]]; then
  print -u2 "Sparkle did not generate appcast.xml."
  exit 1
fi

# Installed apps refuse a feed or a download that is not signed with the key
# their SUPublicEDKey matches, so check both before anything is published.
/usr/bin/xmllint --noout "$STAGING_ROOT/appcast.xml"
with_key "$SIGN_UPDATE" --verify "$STAGING_ROOT/appcast.xml"
ARCHIVE_SIGNATURE="$(/usr/bin/xmllint --xpath \
  'string(//*[local-name()="enclosure"]/@*[local-name()="edSignature"])' "$STAGING_ROOT/appcast.xml")"
ENCLOSURE_URL="$(/usr/bin/xmllint --xpath \
  'string(//*[local-name()="enclosure"]/@url)' "$STAGING_ROOT/appcast.xml")"
EXPECTED_URL="https://github.com/rakeshkanneeswaran/claude-overhead/releases/download/$RELEASE_TAG/${ARCHIVE_PATH:t}"
if [[ -z "$ARCHIVE_SIGNATURE" || "$ENCLOSURE_URL" != "$EXPECTED_URL" ]]; then
  print -u2 "The appcast does not point at a signed $EXPECTED_URL."
  exit 1
fi
with_key "$SIGN_UPDATE" --verify "$ARCHIVE_PATH" "$ARCHIVE_SIGNATURE"
# The feed must describe this version and carry exactly its notes.
FEED_VERSION="$(/usr/bin/xmllint --xpath \
  'string(//*[local-name()="item"]/*[local-name()="shortVersionString"])' "$STAGING_ROOT/appcast.xml")"
EMBEDDED_NOTES="$(/usr/bin/xmllint --xpath \
  'string(//*[local-name()="item"]/*[local-name()="description"])' "$STAGING_ROOT/appcast.xml")"
if [[ "$FEED_VERSION" != "$VERSION" || "$EMBEDDED_NOTES" != "$(<"$WHATS_NEW_DIR/notes.json")" ]]; then
  print -u2 "The appcast does not carry the What's New of $VERSION (it describes ${FEED_VERSION:-nothing})."
  exit 1
fi
# The decisive check: the key installed apps carry accepts this download.
PUBLIC_KEY="$(/usr/bin/plutil -extract SUPublicEDKey raw "$PROJECT_DIR/Packaging/Info.plist")"
swift "$SCRIPT_DIR/verify-update-signature.swift" "$PUBLIC_KEY" "$ARCHIVE_PATH" "$ARCHIVE_SIGNATURE"

mkdir -p "${OUTPUT_PATH:h}"
cp "$STAGING_ROOT/appcast.xml" "$OUTPUT_PATH"

echo "$OUTPUT_PATH"
