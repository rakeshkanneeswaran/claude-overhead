# Releasing Claude Overhead

Every release is a GitHub release built and checked by GitHub Actions from a
version tag. People install it with one command, which the website and the
README show:

```sh
curl -fsSL https://github.com/rakeshkanneeswaran/claude-overhead/releases/latest/download/install.sh | bash
```

GitHub always resolves `releases/latest/download/…` to the newest release, so
the command never changes between versions, and nobody needs a GitHub account.
`install.sh` (from `Scripts/install.sh`) downloads that release's
`Claude-Overhead.dmg`, checks it against `SHA256SUMS.txt`, and installs the app.

## Publish a release

1. Move the release's changes from **Unreleased** into a dated section in
   `CHANGELOG.md`, for example `## [1.1.0] - 2026-12-01`. That section becomes
   the release notes on GitHub, followed by install instructions.
2. Write the release's **What's New**, `ReleaseNotes/1.1.0.json`, with the
   same date. Every release has one; see [What's New](#whats-new) below.
3. Set the same version in `Packaging/Info.plist` (`CFBundleShortVersionString`).
4. Check it and look at it:

   ```sh
   make release-notes VERSION=1.1.0   # the notes, the changelog and the version agree
   make whats-new VERSION=1.1.0       # every page, drawn to dist/whats-new/1.1.0/
   ```

5. Commit all three, push `main`, then tag that commit and push the tag:

   ```sh
   git tag -a v1.1.0 -m "Claude Overhead 1.1.0"
   git push origin v1.1.0
   ```

The **Release DMG** workflow (`.github/workflows/release.yml`) then:

- refuses a tag that differs from the version in `Info.plist`;
- refuses a version without its What's New, or whose notes disagree with
  `CHANGELOG.md` (`Scripts/check-release-notes.sh --release`);
- runs `make check` and `make test`;
- builds `Claude Overhead.app` (bundle id `com.rakesh.overhead`) and the DMG
  with `Scripts/build-public-dmg.sh`, which mounts the image and checks the
  app, its signature, its version and its bundle id before anything is
  uploaded;
- launches the packaged app once, then has that app draw every page of its
  own What's New (`Scripts/check-release-notes.sh --app`); the pages are kept
  as the run's `whats-new-<tag>` artifact;
- signs the update feed, `appcast.xml`, with the `SPARKLE_ED_PRIVATE_KEY`
  secret (`Scripts/generate-appcast.sh`). The feed carries the release's
  What's New, and the script refuses to go on unless the feed holds exactly
  those notes and the download verifies against the public key installed
  apps carry;
- creates the GitHub release with `Claude-Overhead.dmg` (the stable name),
  `Claude-Overhead-<version>.dmg` (the same bytes), `SHA256SUMS.txt`,
  `install.sh`, `appcast.xml` and any pictures the notes show;
- downloads the stable DMG, installer, feed and pictures anonymously and
  fails unless they serve exactly what it just uploaded.

The release appears only with its DMG attached, so the stable link never points
at a release without one. To rebuild an existing tag, run the workflow by hand
(**Actions → Release DMG → Run workflow**) with that tag; it replaces the
release's files. A tag is built with its own scripts: tags before 1.1.0
predate the launch check and What's New and are rebuilt without them, and
any later tag must have both.

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
| `Scripts/check-release-notes.sh --release` (first step of the release workflow) | A tag whose notes, changelog section or `Info.plist` version is missing |
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
   `CFBundleVersion` (CI uses the workflow's run number, so each release is
   higher), and skips a version whose `minimumSystemVersion` this Mac is
   below.
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
maintainer's login Keychain (account `com.rakesh.overhead`) and in the
repository secret `SPARKLE_ED_PRIVATE_KEY`. Keep a backup somewhere safe, such
as a password manager: without it, no installed copy can ever accept another
update, and everyone would have to reinstall with the Terminal command.

To set or replace the repository secret (the key touches disk only in a
private temporary file, removed straight after):

```sh
key="$(umask 077; mktemp)"
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account com.rakesh.overhead -x "$key"
gh secret set SPARKLE_ED_PRIVATE_KEY --repo rakeshkanneeswaran/claude-overhead < "$key"
rm -f "$key"
```

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

## Publish from a Mac instead

If GitHub Actions is unavailable, the same two scripts run locally, with the
GitHub CLI signed in to an account that can write to the repository:

```sh
git push origin v1.1.0          # the tag must exist on GitHub
make public-release TAG=v1.1.0 BUILD_NUMBER=<higher than the last release's>
```

It runs the same What's New checks as the workflow (the notes are ready, and
the packaged app carries and draws them) and signs the update feed with the
key in your login Keychain.

`make public-dmg VERSION=1.1.0` builds and verifies the DMG without uploading
anything; the files land in `dist/public/`.

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

With those, the workflow would import the certificate from repository secrets
into a temporary keychain and set `CHIMLO_CODE_SIGN_IDENTITY` before
`build-public-dmg.sh`. Until that is in place and verified, nothing describes a
release as signed or notarized.

## Earlier tooling

`make release`, `make release-publish`, `make release-signing-identity` and the
Sparkle appcast scripts come from Chimlo. They build releases signed by a
long-lived self-signed identity with Sparkle updates. Claude Overhead does not
use them today: no such identity exists, and Sparkle is off (no `SUFeedURL`).
They remain in the repository for a future release line that wants a stable
signing identity or in-app updates.
