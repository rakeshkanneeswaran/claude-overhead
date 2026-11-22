# Releasing Claude Overhead

Every release is a GitHub release with one DMG, built and checked by GitHub
Actions from a version tag. The website and the README link to

```text
https://github.com/rakeshkanneeswaran/claude-overhead/releases/latest/download/Claude-Overhead.dmg
```

which GitHub always resolves to the newest release's `Claude-Overhead.dmg`, so
the link never changes between versions. Nobody needs a GitHub account to use it.

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
- creates the GitHub release with `Claude-Overhead.dmg` (the stable name),
  `Claude-Overhead-<version>.dmg` (the same bytes) and `SHA256SUMS.txt`;
- downloads the stable link anonymously and fails unless it serves exactly
  the DMG it just uploaded.

The release appears only with its DMG attached, so the stable link never points
at a release without one. To rebuild an existing tag, run the workflow by hand
(**Actions → Release DMG → Run workflow**) with that tag; it replaces the
release's files.

## Publish from a Mac instead

If GitHub Actions is unavailable, the same two scripts run locally, with the
GitHub CLI signed in to an account that can write to the repository:

```sh
git push origin v1.1.0          # the tag must exist on GitHub
make public-release TAG=v1.1.0
```

`make public-dmg VERSION=1.1.0` builds and verifies the DMG without uploading
anything; the files land in `dist/public/`.

## Signing and notarization

Releases are currently **ad-hoc signed and not notarized**. `build-public-dmg.sh`
prints the signature it made, and the release notes tell people how to approve
the first launch (**System Settings > Privacy & Security > Open Anyway**).

Opening without that step needs an Apple Developer Program membership and:

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
