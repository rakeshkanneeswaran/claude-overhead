# Releasing Claude Overhead

Every release is a GitHub release, built, checked and published from the
maintainer's Mac with one command. People install it with one command too,
which the website and the README show:

```sh
curl -fsSL https://github.com/rakeshkanneeswaran/claude-overhead/releases/latest/download/install.sh | bash
```

GitHub always resolves `releases/latest/download/…` to the newest release, so
the command never changes between versions, and nobody needs a GitHub account.
`install.sh` (from `Scripts/install.sh`) downloads that release's
`Claude-Overhead.dmg`, checks it against `SHA256SUMS.txt`, and installs the app.

GitHub Actions does not build releases. It runs CI on every push
(`.github/workflows/ci.yml`): build, checks, tests, every What's New drawn,
and the app packaged as a release packages it and launched once on a clean
machine. A release is published only from a commit that run passed.

## Publish a release

1. Move the release's changes from **Unreleased** into a dated section in
   `CHANGELOG.md`, for example `## [1.2.0] - 2026-12-01`. That section becomes
   the release notes on GitHub, followed by install instructions.
2. Write the release's **What's New**, `ReleaseNotes/1.2.0.json`, with the
   same date. Every release has one; see [What's New](#whats-new) below.
3. Set the same version in `Packaging/Info.plist` (`CFBundleShortVersionString`).
4. Check it and look at it:

   ```sh
   make release-notes VERSION=1.2.0   # the notes, the changelog and the version agree
   make whats-new VERSION=1.2.0       # every page, drawn to dist/whats-new/1.2.0/
   ```

5. Commit all three and push `main`. Wait for CI to pass on that commit.
6. Tag the commit, push the tag, and release:

   ```sh
   git tag -a v1.2.0 -m "Claude Overhead 1.2.0"
   git push origin v1.2.0
   make public-release TAG=v1.2.0
   ```

`make public-release` (`Scripts/public-release.sh`) stops at the first thing
that is not ready. In order, it:

- refuses a working tree with uncommitted changes, a tag that is not the
  commit checked out, a tag that is not on GitHub, and a version that differs
  from `Info.plist`;
- refuses a commit that GitHub's CI has not passed (not run, still running,
  or failed);
- reads the live update feed and takes its build number plus one. Installed
  copies are offered an update only when its build number is higher than the
  one they have, so this is never typed by hand; a version older than the
  live one, or the live one again, is refused;
- runs `make check` and `make test` here;
- refuses a version without its What's New, or whose notes disagree with
  `CHANGELOG.md` (`Scripts/check-release-notes.sh --release`);
- builds `Claude Overhead.app` (bundle id `com.rakesh.overhead`) and the DMG
  with `Scripts/build-public-dmg.sh`, which mounts the image and checks the
  app, its signature, its version and its bundle id;
- has the packaged app draw every page of its own What's New
  (`Scripts/check-release-notes.sh --app`); the pages land in
  `dist/whats-new/<version>/`;
- signs the update feed, `appcast.xml`, with the key in the login Keychain
  (`Scripts/generate-appcast.sh`). The feed carries the release's What's New,
  and the script refuses to go on unless the feed holds exactly those notes
  and the download verifies against the public key installed apps carry;
- creates the GitHub release with `Claude-Overhead.dmg` (the stable name),
  `Claude-Overhead-<version>.dmg` (the same bytes), `SHA256SUMS.txt`,
  `install.sh`, `appcast.xml` and any pictures the notes show;
- downloads the stable DMG, installer, feed and pictures anonymously and
  fails unless they serve exactly what it just uploaded.

The release appears only with its DMG attached, so the stable link never points
at a release without one.

Three switches, for the cases that need them:

- `make public-release TAG=v1.2.0 DRY_RUN=1` does everything except the
  upload: a rehearsal. The files it would publish are left in `dist/public/`.
- `CHIMLO_SKIP_CI_CHECK=1` publishes without GitHub's verdict, for when GitHub
  Actions itself is down. That release has no clean-machine build or launch
  behind it, so say so in its notes.
- `CHIMLO_REPLACE_ASSETS=1` rebuilds a version that is already published and
  replaces its files. To rebuild an old tag, check it out and use the scripts
  it has.

The launch check is CI's alone. The packaged release app is not started on
the maintainer's Mac, because it would run against their own settings and
sessions; CI starts it on a machine that has neither.

## What's New

Every release ships its own visual release notes. Someone who clicks **Check
for Updates** sees them in a walkthrough before anything is downloaded, and
**Update Now** in that window installs exactly the version they describe.
This is part of releasing, not an extra: a version without notes cannot be
packaged, signed or published, and `make check` fails on every push once the
notes, `CHANGELOG.md` and `Packaging/Info.plist` disagree.

### For each release

1. **List what changed for users** since the last release: the **Unreleased**
   section of `CHANGELOG.md` is the source. Leave out what users cannot
   notice (refactors, tests, CI).
2. **Sort it** into new features (`feature`), improvements (`improvement`)
   and bug fixes (`fix`). One card per change worth a page; gather small
   fixes into one card with a few points. Twelve cards at most.
3. **Write `ReleaseNotes/<version>.json`** ([the format](../ReleaseNotes/README.md)).
   Say what changed and why it matters, in the words the app uses.
4. **Give a card a visual only when it shows the change**: the new
   characters themselves, the notch as it now looks, a before and after. A
   bug fix that needs no picture gets none; the card is then set as text.
   Never draw something the app does not do.
5. **Run `make release-notes VERSION=<version>`**, then **`make whats-new
   VERSION=<version>`** and look at every page in `dist/whats-new/<version>/`.
6. Commit the notes with the changelog and the version bump.

### How the notes reach the app

- `Scripts/generate-appcast.sh` writes the notes in their published form
  (compact, self-contained, every picture's SHA-256 filled in) and Sparkle
  embeds them in the feed entry for that version, before the feed is signed.
  The notes and the download are therefore two parts of one signed entry: an
  installed copy cannot be shown the notes of one version and install another.
- The app reads the notes only if they are for exactly the version on offer.
  Missing, unreadable or mismatched notes are never replaced with anything
  else: the window says the notes are unavailable, links to the release on
  GitHub, and still offers the update.
- Notes are self-contained so that an **older** app can draw a **newer**
  release: a card that shows a new character carries its pixels. A picture
  (`"kind": "image"`) is published beside the download and shown only when its
  SHA-256 matches the one in the signed notes.
- Each app also carries its own version's notes
  (`Contents/Resources/WhatsNew.json`), for the **What's New** button in
  Settings. `Scripts/package-app.sh` refuses to package a release without them.

### What enforces it

| Where | What it refuses |
| --- | --- |
| `make check`, CI, `make test` | A notes file that breaks a rule; a dated `CHANGELOG.md` section from 1.1.0 on without notes, or with another date; an `Info.plist` version without notes |
| `Scripts/public-release.sh` (`make public-release`) | A commit that is not tagged, pushed and green on CI; then, through `Scripts/check-release-notes.sh --release`, a tag whose notes, changelog section or `Info.plist` version is missing |
| `Scripts/package-app.sh` | A release build without notes for its version |
| `Scripts/check-release-notes.sh --app` | A packaged app that does not carry the published notes, or whose What's New window cannot draw every page |
| `Scripts/generate-appcast.sh`, `Scripts/publish-github-release.sh` | A feed that does not carry exactly the version's notes |

The rules themselves (`ReleaseNotesValidator`, `ReleaseReadiness`,
`ReleaseNotesReader`) are in `Sources/ChimloCore` with tests.

## In-app updates

Installed copies update themselves with [Sparkle](https://sparkle-project.org):

1. Every hour, and when you click **Check for Updates**, the app reads
   `https://github.com/rakeshkanneeswaran/claude-overhead/releases/latest/download/appcast.xml`
   (`SUFeedURL` in `Packaging/Info.plist`). The feed itself must be signed.
   When it offers a newer version, a check you asked for opens that version's
   What's New; a background check shows a row in the notch that opens it.
   Nothing is downloaded until you click **Update Now** there.
2. Sparkle compares the feed's build number with the installed
   `CFBundleVersion` (the release command takes the live feed's number plus
   one, so each release is higher), and skips a version whose
   `minimumSystemVersion` this Mac is below.
3. It downloads `Claude-Overhead-<version>.dmg` and checks its EdDSA
   signature against `SUPublicEDKey`. Anything signed with another key, or
   altered after signing, is refused before it touches the installed app.
4. It replaces the app only after that, quits, and relaunches it; the
   relaunched app says "Updated to <version>". If anything fails, the
   installed app is left exactly as it was and the notch says why.

This works for copies installed with the Terminal command in Applications or
`~/Applications` (Sparkle asks for an administrator password only if the
folder is not writable).

### The signing key

The private key was generated with Sparkle's `generate_keys` and lives in the
maintainer's login Keychain (account `com.rakesh.overhead`). Every release is
signed with that copy, so keep a backup somewhere safe, such as a password
manager: without it, no installed copy can ever accept another update, and
everyone would have to reinstall with the Terminal command.

To put the key on another Mac, export it to a private temporary file, import
it there, and remove the file straight after:

```sh
key="$(umask 077; mktemp)"
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account com.rakesh.overhead -x "$key"
# copy "$key" to the other Mac by a safe route, then there:
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account com.rakesh.overhead -f "$key"
rm -f "$key"
```

The repository also holds the key as the secret `SPARKLE_ED_PRIVATE_KEY`,
from when a workflow signed the feed. Nothing reads it now.

Releases 1.0.0 to 1.0.3 shipped without a feed, so they cannot update
themselves. Their users update once with the Terminal command; every later
version updates in place.

### Test an update locally

`make update-test-auto` builds an ad-hoc signed 98.0.0 and 99.0.0, serves a
signed feed from `localhost`, and runs five unattended updates: one that must
read 99.0.0's What's New, succeed and relaunch as 99.0.0; one that takes the
owner's path (a check that downloads nothing, the What's New window on
screen with its picture, then its Update Now); one whose download
was altered after signing (it must be refused, with 98.0.0 intact); one with
nothing serving the feed (it must fail with an explanation); and one whose
feed carries another version's notes (they must not be shown, and the update
must still install). Nothing is uploaded. `make update-test` runs the same
build for clicking through by hand: Check for Updates, the What's New
window, Update Now.

## Build without publishing

`make public-dmg VERSION=1.2.0` builds and verifies the DMG alone, with
nothing signed or uploaded; the files land in `dist/public/`. For the whole
release short of the upload, use `make public-release TAG=v1.2.0 DRY_RUN=1`.

## Signing and notarization

Releases are currently **ad-hoc signed and not notarized**. `build-public-dmg.sh`
prints the signature it made. The Terminal installer is unaffected: macOS only
checks notarization for files a browser downloaded (they carry the quarantine
flag), and a copy made with `curl` has none. Someone who downloads the DMG from
the releases page in a browser would still need **System Settings > Privacy &
Security > Open Anyway** on first launch.

Notarizing, so that a browser download opens without that step too, needs an
Apple Developer Program membership and:

1. A **Developer ID Application** certificate, exported as a `.p12`.
2. Hardened runtime and the Apple Events entitlement
   (`com.apple.security.automation.apple-events`), which Claude Overhead uses
   to focus a Terminal or iTerm tab.
3. Notarization with `xcrun notarytool` (an Apple ID app-specific password or
   an App Store Connect API key) and `xcrun stapler staple` on the DMG.

With those, the certificate goes into the maintainer's Keychain and
`CHIMLO_CODE_SIGN_IDENTITY` names it for `build-public-dmg.sh`. Until that is in place and verified, nothing describes a
release as signed or notarized.

## Earlier tooling

`make release`, `make release-publish`, `make release-signing-identity` and the
Sparkle appcast scripts come from Chimlo. They build releases signed by a
long-lived self-signed identity with Sparkle updates. Claude Overhead does not
use them today: no such identity exists, and Sparkle is off (no `SUFeedURL`).
They remain in the repository for a future release line that wants a stable
signing identity or in-app updates.
