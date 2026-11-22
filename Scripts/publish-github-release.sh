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
for file in "$VERSIONED_DMG" "$STABLE_DMG" "$SUMS"; do
  [[ -f "$file" ]] || { print -u2 "Missing $file. Run Scripts/build-public-dmg.sh $VERSION first."; exit 1; }
done
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
cat >> "$NOTES" <<NOTES_END

### Install

1. Download **Claude-Overhead.dmg** below and open it.
2. Drag **Claude Overhead** into **Applications**.
3. Open it from Applications. This build is not notarized by Apple yet, so the
   first time macOS says it cannot verify the app: open **System Settings >
   Privacy & Security**, scroll down, and click **Open Anyway** next to Claude
   Overhead. You only need to do this once.

Requires macOS 14 or newer on an Apple silicon Mac. \`SHA256SUMS.txt\` lists
the checksums of both DMGs, which are the same file.
NOTES_END

if gh release view "$TAG" --repo "$REPOSITORY" >/dev/null 2>&1; then
  if [[ "${CHIMLO_REPLACE_ASSETS:-0}" != "1" ]]; then
    print -u2 "Release $TAG already exists. Set CHIMLO_REPLACE_ASSETS=1 to replace its files."
    exit 1
  fi
  gh release upload "$TAG" "$STABLE_DMG" "$VERSIONED_DMG" "$SUMS" --repo "$REPOSITORY" --clobber
else
  gh release create "$TAG" "$STABLE_DMG" "$VERSIONED_DMG" "$SUMS" \
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
print "Published $TAG"
print "Stable download: $LATEST"
print "This version:    https://github.com/$REPOSITORY/releases/download/$TAG/${VERSIONED_DMG:t}"
