.PHONY: app build check clean dmg public-dmg public-release release release-app release-publish release-signing-freeze release-signing-identity release-signing-restore signing-check signing-identity test update-test

build:
	./Scripts/swift.sh build

test:
	./Scripts/swift.sh test

update-test:
	./Scripts/test-local-update.sh

check:
	./Scripts/swift.sh run overhead-check

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

public-release:
	@test -n "$(TAG)" || (echo "TAG=vX.Y.Z is required" >&2; exit 64)
	./Scripts/build-public-dmg.sh "$(TAG)" "$(or $(BUILD_NUMBER),1)"
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
