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
   the release notes, followed by install instructions.
2. Set the same version in `Packaging/Info.plist` (`CFBundleShortVersionString`).
3. Commit both, push `main`, then tag that commit and push the tag:

   ```sh
   git tag -a v1.1.0 -m "Claude Overhead 1.1.0"
   git push origin v1.1.0
   ```

The **Release DMG** workflow (`.github/workflows/release.yml`) then:

- refuses a tag that differs from the version in `Info.plist`;
- runs `make check` and `make test`;
- builds `Claude Overhead.app` (bundle id `com.rakesh.overhead`) and the DMG
  with `Scripts/build-public-dmg.sh`, which mounts the image and checks the
  app, its signature, its version and its bundle id before anything is
  uploaded;
- signs the update feed, `appcast.xml`, with the `SPARKLE_ED_PRIVATE_KEY`
  secret (`Scripts/generate-appcast.sh`), and refuses to go on unless the
  download verifies against the public key installed apps carry;
- creates the GitHub release with `Claude-Overhead.dmg` (the stable name),
  `Claude-Overhead-<version>.dmg` (the same bytes), `SHA256SUMS.txt`,
  `install.sh` and `appcast.xml`;
- downloads the stable DMG, installer and feed links anonymously and fails
  unless they serve exactly what it just uploaded.

The release appears only with its DMG attached, so the stable link never points
at a release without one. To rebuild an existing tag, run the workflow by hand
(**Actions → Release DMG → Run workflow**) with that tag; it replaces the
release's files.

## In-app updates

Installed copies update themselves with [Sparkle](https://sparkle-project.org):

1. Every hour, and when you click **Check for Updates**, the app reads
   `https://github.com/rakeshkanneeswaran/claude-overhead/releases/latest/download/appcast.xml`
   (`SUFeedURL` in `Packaging/Info.plist`). The feed itself must be signed.
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
signed feed from `localhost`, and runs three unattended updates: one that must
succeed and relaunch as 99.0.0, one whose download was altered after signing
(it must be refused, with 98.0.0 intact), and one with nothing serving the
feed (it must fail with an explanation). Nothing is uploaded. `make
update-test` runs the same build for clicking through by hand.

## Publish from a Mac instead

If GitHub Actions is unavailable, the same two scripts run locally, with the
GitHub CLI signed in to an account that can write to the repository:

```sh
git push origin v1.1.0          # the tag must exist on GitHub
make public-release TAG=v1.1.0 BUILD_NUMBER=<higher than the last release's>
```

It signs the update feed with the key in your login Keychain.

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
