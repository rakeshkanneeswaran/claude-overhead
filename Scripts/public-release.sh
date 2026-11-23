#!/bin/zsh
# Builds, checks and publishes a release from this Mac. This is how every
# Claude Overhead release is made (Docs/RELEASING.md):
#
#   Scripts/public-release.sh vX.Y.Z        (or: make public-release TAG=vX.Y.Z)
#
# It publishes only a commit that is ready to be a release, and stops at the
# first thing that is not:
#
#   1. the working tree is clean, the tag is the commit checked out, and the
#      same tag is on GitHub;
#   2. GitHub's CI built, tested and launched this commit on a clean machine;
#   3. the build number is higher than the release people have now, so their
#      copies are offered this one (read from the live update feed);
#   4. the checks and the whole test suite pass here;
#   5. the release has its What's New, the packaged app carries it and draws
#      every page of it;
#   6. the update feed is signed and carries exactly those notes;
#   7. the published files are downloaded again and compared.
#
# CHIMLO_DRY_RUN=1 does everything except the upload, to rehearse a release.
# CHIMLO_SKIP_CI_CHECK=1 publishes without GitHub's verdict (step 2), for when
#   GitHub Actions itself is down. Say so in the release if you use it.
# CHIMLO_BUILD_NUMBER=N names the build number; it must still be higher than
#   the live one.
# CHIMLO_REPLACE_ASSETS=1 rebuilds a version that is already published.
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
TAG="${1:-}"
REPOSITORY="${GITHUB_REPOSITORY:-rakeshkanneeswaran/claude-overhead}"
DRY_RUN="${CHIMLO_DRY_RUN:-0}"

fail() {
  print -u2 "error: $1"
  shift
  for line in "$@"; do print -u2 "       $line"; done
  exit 1
}

step() {
  print
  print "==> $1"
}

if [[ ! "$TAG" =~ '^v[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  print -u2 "usage: public-release.sh vX.Y.Z"
  exit 64
fi
VERSION="${TAG#v}"
cd "$PROJECT_DIR"

step "This commit is the release"
if [[ -n "$(git status --porcelain)" ]]; then
  fail "The working tree has changes that are not committed." \
       "A release is built from exactly what the tag names."
fi
HEAD_COMMIT="$(git rev-parse HEAD)"
TAG_COMMIT="$(git rev-parse --verify --quiet "refs/tags/$TAG^{commit}" || true)"
[[ -n "$TAG_COMMIT" ]] \
  || fail "There is no tag $TAG." "Create it on the release commit: git tag -a $TAG -m \"Claude Overhead $VERSION\""
[[ "$TAG_COMMIT" == "$HEAD_COMMIT" ]] \
  || fail "$TAG is not the commit checked out." "Check out the tag, or move to the commit it names."
# An annotated tag has two lines on the remote; the one ending in ^{} names its commit.
REMOTE_TAG="$(git ls-remote --tags origin "refs/tags/$TAG" "refs/tags/$TAG^{}")"
REMOTE_COMMIT="$(print -r -- "$REMOTE_TAG" | /usr/bin/awk '$2 ~ /\^\{\}$/ { print $1 }')"
[[ -n "$REMOTE_COMMIT" ]] || REMOTE_COMMIT="$(print -r -- "$REMOTE_TAG" | /usr/bin/awk 'NR == 1 { print $1 }')"
[[ "$REMOTE_COMMIT" == "$HEAD_COMMIT" ]] \
  || fail "$TAG on GitHub is not this commit (it names ${REMOTE_COMMIT:-nothing})." "Push it: git push origin $TAG"
INFO_VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw Packaging/Info.plist)"
[[ "$INFO_VERSION" == "$VERSION" ]] \
  || fail "Packaging/Info.plist is at $INFO_VERSION, not $VERSION."
print "$TAG is ${HEAD_COMMIT[1,7]}, here and on GitHub."

step "GitHub built, tested and launched this commit"
if [[ "${CHIMLO_SKIP_CI_CHECK:-0}" == "1" ]]; then
  print "Skipped (CHIMLO_SKIP_CI_CHECK=1). This release has no clean-machine check behind it."
else
  CI_STATE="$(gh run list --repo "$REPOSITORY" --workflow CI --commit "$HEAD_COMMIT" --limit 1 \
    --json status,conclusion --jq 'if length == 0 then "none" else "\(.[0].status) \(.[0].conclusion)" end')" \
    || fail "Could not ask GitHub about this commit's CI run." "Is the GitHub CLI signed in? (gh auth status)"
  case "$CI_STATE" in
    "completed success")
      print "CI passed for ${HEAD_COMMIT[1,7]}."
      ;;
    none)
      fail "GitHub has no CI run for this commit." "Push it to main and wait for the run: git push origin HEAD:main"
      ;;
    completed*)
      fail "CI did not pass for this commit ($CI_STATE)." "Fix it and tag the commit that passes."
      ;;
    *)
      fail "CI is still running for this commit ($CI_STATE)." "Wait for it: gh run watch --repo $REPOSITORY"
      ;;
  esac
fi

step "The build number"
# An installed copy is offered an update only when its build number is higher
# than the one it has, so this is one more than the newest release's.
FEED_URL="https://github.com/$REPOSITORY/releases/latest/download/appcast.xml"
LIVE_FEED="$(mktemp "${TMPDIR:-/tmp}/overhead-live-feed.XXXXXX")"
trap 'rm -f "$LIVE_FEED"' EXIT
env -u GH_TOKEN -u GITHUB_TOKEN /usr/bin/curl -fsSL --retry 2 -o "$LIVE_FEED" "$FEED_URL" \
  || fail "Could not read the live update feed, so the build number cannot be chosen." "$FEED_URL"
LIVE_BUILD="$(/usr/bin/xmllint --xpath 'string(//*[local-name()="item"]/*[local-name()="version"])' "$LIVE_FEED")"
LIVE_VERSION="$(/usr/bin/xmllint --xpath 'string(//*[local-name()="item"]/*[local-name()="shortVersionString"])' "$LIVE_FEED")"
[[ "$LIVE_BUILD" =~ '^[0-9]+$' && -n "$LIVE_VERSION" ]] \
  || fail "The live update feed names no version and build number."
BUILD_NUMBER="${CHIMLO_BUILD_NUMBER:-$(( LIVE_BUILD + 1 ))}"
[[ "$BUILD_NUMBER" =~ '^[0-9]+$' ]] && (( BUILD_NUMBER > LIVE_BUILD )) \
  || fail "Build $BUILD_NUMBER is not higher than the live release's ($LIVE_VERSION is build $LIVE_BUILD)." \
          "Installed copies would never be offered it."
NEWEST="$(print -l -- "$LIVE_VERSION" "$VERSION" | /usr/bin/sort -V | /usr/bin/tail -1)"
if [[ "$LIVE_VERSION" == "$VERSION" ]]; then
  [[ "${CHIMLO_REPLACE_ASSETS:-0}" == "1" ]] \
    || fail "$VERSION is already the live release." "To rebuild it on purpose, set CHIMLO_REPLACE_ASSETS=1."
elif [[ "$NEWEST" != "$VERSION" ]]; then
  fail "$VERSION is older than the live release ($LIVE_VERSION)." \
       "It would replace a newer version as the latest one."
fi
print "Live: $LIVE_VERSION (build $LIVE_BUILD). This release: $VERSION (build $BUILD_NUMBER)."

step "Checks and tests"
make check
make test

step "What's New is ready"
./Scripts/check-release-notes.sh --release "$TAG"

step "Build and verify the app and its disk image"
./Scripts/build-public-dmg.sh "$TAG" "$BUILD_NUMBER"

step "The packaged app carries and draws its What's New"
./Scripts/check-release-notes.sh --release "$TAG" --app "dist/Claude Overhead.app"

step "Sign the update feed"
CHIMLO_RELEASE_TAG="$TAG" ./Scripts/generate-appcast.sh "dist/public/Claude-Overhead-$VERSION.dmg" dist/public/appcast.xml

if [[ "$DRY_RUN" == "1" ]]; then
  step "Rehearsal: nothing was uploaded"
  print "These are the files a real run would publish as $TAG:"
  ls -1 dist/public | /usr/bin/sed 's/^/  /'
  print "The pages of its What's New: dist/whats-new/$VERSION/"
  exit 0
fi

step "Publish, then download and compare"
./Scripts/publish-github-release.sh "$TAG"
