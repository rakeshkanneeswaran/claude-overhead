.PHONY: app build check clean dmg public-dmg public-release release release-app release-notes release-publish release-signing-freeze release-signing-identity release-signing-restore signing-check signing-identity test update-test update-test-auto whats-new

build:
	./Scripts/swift.sh build

test:
	./Scripts/swift.sh test

update-test:
	./Scripts/test-local-update.sh

# The whole Sparkle update, unattended: a successful update and relaunch, a
# tampered download that must be refused, and an unreachable feed that must
# be explained. Each leaves the installed test app intact or updated, never
# half-replaced. Needs the EdDSA key (login Keychain or SPARKLE_ED_KEY_FILE).
update-test-auto:
	./Scripts/test-local-update.sh --auto
	./Scripts/test-local-update.sh --auto-whats-new
	./Scripts/test-local-update.sh --auto-tampered
	./Scripts/test-local-update.sh --auto-offline
	./Scripts/test-local-update.sh --auto-wrong-notes

check:
	./Scripts/swift.sh run overhead-check
	./Scripts/swift.sh run overhead-release-notes check

# What's New (see Docs/RELEASING.md). `make release-notes` checks every file
# in ReleaseNotes/ against CHANGELOG.md; with VERSION=X.Y.Z it also checks
# that X.Y.Z is ready to publish. `make whats-new VERSION=X.Y.Z` draws every
# page of that release's walkthrough to dist/whats-new/X.Y.Z/ to look at.
release-notes:
	./Scripts/check-release-notes.sh $(if $(VERSION),--release "$(VERSION)")

whats-new:
	@test -n "$(VERSION)" || (echo "VERSION=X.Y.Z is required" >&2; exit 64)
	./Scripts/check-release-notes.sh --render "$(VERSION)"

app:
	CHIMLO_PACKAGE_VARIANT=development ./Scripts/package-app.sh

release-app:
	CHIMLO_PACKAGE_VARIANT=release ./Scripts/package-app.sh

dmg: release-app
	./Scripts/package-dmg.sh

release-signing-identity:
	@test -n "$(BACKUP_ONE)" || (echo "BACKUP_ONE=/absolute/path/Overhead-Release.p12 is required" >&2; exit 64)
	@test -n "$(BACKUP_TWO)" || (echo "BACKUP_TWO=/different/device/Overhead-Release.p12 is required" >&2; exit 64)
	./Scripts/setup-release-signing.sh "$(BACKUP_ONE)" "$(BACKUP_TWO)"

release-signing-restore:
	@test -n "$(BACKUP)" || (echo "BACKUP=/absolute/path/Overhead-Release.p12 is required" >&2; exit 64)
	./Scripts/restore-release-signing.sh "$(BACKUP)"

release-signing-freeze: release-app
	./Scripts/verify-release-identity.sh "dist/Claude Overhead.app" --initialize

# Public DMG releases (see Docs/RELEASING.md). CI runs these on every v* tag.
public-dmg:
	@test -n "$(VERSION)" || (echo "VERSION=X.Y.Z is required" >&2; exit 64)
	./Scripts/build-public-dmg.sh "$(VERSION)" "$(or $(BUILD_NUMBER),1)"

# Sparkle offers an update only when its build number is higher than the
# installed one, so a release from a Mac must name one above the last
# release's (CI uses the workflow's run number).
public-release:
	@test -n "$(TAG)" || (echo "TAG=vX.Y.Z is required" >&2; exit 64)
	@test -n "$(BUILD_NUMBER)" || (echo "BUILD_NUMBER is required and must be higher than the last release's CFBundleVersion" >&2; exit 64)
	./Scripts/check-release-notes.sh --release "$(TAG)"
	./Scripts/build-public-dmg.sh "$(TAG)" "$(BUILD_NUMBER)"
	./Scripts/check-release-notes.sh --release "$(TAG)" --app "dist/Claude Overhead.app"
	CHIMLO_RELEASE_TAG="$(TAG)" ./Scripts/generate-appcast.sh "dist/public/Claude-Overhead-$(patsubst v%,%,$(TAG)).dmg" dist/public/appcast.xml
	./Scripts/publish-github-release.sh "$(TAG)"

release:
	@test -n "$(TAG)" || (echo "TAG=vX.Y.Z is required" >&2; exit 64)
	@test -n "$(BUILD_NUMBER)" || (echo "BUILD_NUMBER=N is required" >&2; exit 64)
	./Scripts/release-local.sh "$(TAG)" "$(BUILD_NUMBER)"

release-publish:
	@test -n "$(TAG)" || (echo "TAG=vX.Y.Z is required" >&2; exit 64)
	./Scripts/publish-release.sh "$(TAG)"

signing-identity:
	./Scripts/setup-local-signing.sh

signing-check: app
	./Scripts/check-stable-signing.sh

clean:
	swift package clean
