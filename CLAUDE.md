# Claude Overhead: notes for coding agents

- Build with `make build`, verify with `make check` and `make test`. The app
  target has no tests of its own: rules go in `Sources/ChimloCore` with a
  Swift Testing suite (see `CONTRIBUTING.md`).
- A change users will notice goes into **Unreleased** in `CHANGELOG.md`.
- **Every release ships its What's New.** When asked to cut or prepare a
  release, write `ReleaseNotes/<version>.json` from the Unreleased changes
  (features, improvements, bug fixes; a visual only where it shows the
  change), run `make release-notes VERSION=<version>` and `make whats-new
  VERSION=<version>`, and look at every rendered page before tagging. The
  steps are in `Docs/RELEASING.md`, the format in `ReleaseNotes/README.md`.
  Never bypass or weaken these checks to get a release out.
- Never commit, push, tag or publish a release without the maintainer's
  explicit go-ahead.
