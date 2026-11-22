#!/bin/zsh
# Publishes the DMG that Scripts/build-public-dmg.sh made as a GitHub release,
# then checks the public, stable download link serves those exact bytes.
#
#   Scripts/publish-github-release.sh <tag>
#
# The tag (vX.Y.Z) must already exist on GitHub. Release notes come from the
# matching CHANGELOG.md section. An existing release is never changed unless
# CHIMLO_REPLACE_ASSETS=1 (used when re-running the same tag's build).
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
TAG="${1:-}"
REPOSITORY="${GITHUB_REPOSITORY:-rakeshkanneeswaran/claude-overhead}"

if [[ ! "$TAG" =~ '^v[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$' ]]; then
  print -u2 "usage: publish-github-release.sh vX.Y.Z"
  exit 64
fi
VERSION="${TAG#v}"
OUTPUT_DIR="$PROJECT_DIR/dist/public"
VERSIONED_DMG="$OUTPUT_DIR/Claude-Overhead-$VERSION.dmg"
STABLE_DMG="$OUTPUT_DIR/Claude-Overhead.dmg"
SUMS="$OUTPUT_DIR/SHA256SUMS.txt"
APPCAST="$OUTPUT_DIR/appcast.xml"
INSTALLER="$PROJECT_DIR/Scripts/install.sh"
for file in "$VERSIONED_DMG" "$STABLE_DMG" "$SUMS" "$INSTALLER"; do
  [[ -f "$file" ]] || { print -u2 "Missing $file. Run Scripts/build-public-dmg.sh $VERSION first."; exit 1; }
done
# Without the signed feed, installed copies would never hear of this release.
[[ -f "$APPCAST" ]] || { print -u2 "Missing $APPCAST. Run Scripts/generate-appcast.sh first."; exit 1; }
/usr/bin/grep -q "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" "$APPCAST" \
  || { print -u2 "$APPCAST does not describe $VERSION."; exit 1; }
(cd "$OUTPUT_DIR" && /usr/bin/shasum -a 256 -c SHA256SUMS.txt >/dev/null) \
  || { print -u2 "The DMGs no longer match SHA256SUMS.txt."; exit 1; }

# Notes: the CHANGELOG section for this version, then how to install.
NOTES="$(mktemp "${TMPDIR:-/tmp}/overhead-notes.XXXXXX")"
trap 'rm -f "$NOTES"' EXIT
awk -v version="$VERSION" '
  $0 ~ "^## \\[" version "\\]" { found = 1; next }
  found && /^## \[/ { exit }
  found && /^\[[^]]+\]: / { exit }
  found { print }
' "$PROJECT_DIR/CHANGELOG.md" > "$NOTES"
if [[ ! -s "$NOTES" ]]; then
  print -u2 "CHANGELOG.md has no section for [$VERSION]."
  exit 1
fi
cat >> "$NOTES" <<'NOTES_END'

### Install

Paste this into Terminal:

```sh
curl -fsSL https://github.com/rakeshkanneeswaran/claude-overhead/releases/latest/download/install.sh | bash
```

It downloads `Claude-Overhead.dmg` from the latest release, checks it against
`SHA256SUMS.txt`, installs Claude Overhead into Applications, and opens it.
Read [`install.sh`](https://github.com/rakeshkanneeswaran/claude-overhead/blob/main/Scripts/install.sh)
first if you like.

Requires macOS 14 or newer on an Apple silicon Mac.
NOTES_END

if gh release view "$TAG" --repo "$REPOSITORY" >/dev/null 2>&1; then
  if [[ "${CHIMLO_REPLACE_ASSETS:-0}" != "1" ]]; then
    print -u2 "Release $TAG already exists. Set CHIMLO_REPLACE_ASSETS=1 to replace its files."
    exit 1
  fi
  gh release upload "$TAG" "$STABLE_DMG" "$VERSIONED_DMG" "$SUMS" "$INSTALLER" "$APPCAST" --repo "$REPOSITORY" --clobber
else
  gh release create "$TAG" "$STABLE_DMG" "$VERSIONED_DMG" "$SUMS" "$INSTALLER" "$APPCAST" \
    --repo "$REPOSITORY" \
    --verify-tag \
    --title "Claude Overhead $VERSION" \
    --notes-file "$NOTES" \
    --latest
fi

# The link the website uses must now serve these bytes, without signing in.
EXPECTED="$(/usr/bin/shasum -a 256 "$STABLE_DMG" | awk '{print $1}')"
LATEST="https://github.com/$REPOSITORY/releases/latest/download/Claude-Overhead.dmg"
CHECK="$(mktemp "${TMPDIR:-/tmp}/overhead-download.XXXXXX")"
trap 'rm -f "$NOTES" "$CHECK"' EXIT
for attempt in 1 2 3 4 5 6; do
  if env -u GH_TOKEN -u GITHUB_TOKEN /usr/bin/curl -fsSL --retry 2 -o "$CHECK" "$LATEST"; then
    ACTUAL="$(/usr/bin/shasum -a 256 "$CHECK" | awk '{print $1}')"
    [[ "$ACTUAL" == "$EXPECTED" ]] && break
  fi
  ACTUAL="unavailable"
  sleep 10
done
if [[ "$ACTUAL" != "$EXPECTED" ]]; then
  print -u2 "The latest-release link does not serve this DMG yet (got $ACTUAL)."
  print -u2 "If $TAG is not the newest version, that is expected: $LATEST serves the newest release."
  exit 1
fi
# The installer must be reachable at its stable address too.
INSTALL_URL="https://github.com/$REPOSITORY/releases/latest/download/install.sh"
env -u GH_TOKEN -u GITHUB_TOKEN /usr/bin/curl -fsSL --retry 3 -o "$CHECK" "$INSTALL_URL" \
  && /usr/bin/cmp -s "$CHECK" "$INSTALLER" \
  || { print -u2 "$INSTALL_URL does not serve this release's install.sh."; exit 1; }
# And the update feed installed copies poll must describe this version.
FEED_URL="https://github.com/$REPOSITORY/releases/latest/download/appcast.xml"
for attempt in 1 2 3 4 5 6; do
  if env -u GH_TOKEN -u GITHUB_TOKEN /usr/bin/curl -fsSL --retry 2 -o "$CHECK" "$FEED_URL" \
     && /usr/bin/cmp -s "$CHECK" "$APPCAST"; then
    FEED_OK=1
    break
  fi
  FEED_OK=0
  sleep 10
done
(( FEED_OK )) || { print -u2 "$FEED_URL does not serve this release's appcast.xml yet."; exit 1; }
print "Published $TAG"
print "Update feed:     $FEED_URL"
print "Install:         curl -fsSL $INSTALL_URL | bash"
print "Stable download: $LATEST"
print "This version:    https://github.com/$REPOSITORY/releases/download/$TAG/${VERSIONED_DMG:t}"
