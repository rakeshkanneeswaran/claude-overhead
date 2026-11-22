# Changelog

All notable changes to Claude Overhead are documented in this file. Entries
before 1.0.0 are from [Chimlo](https://github.com/kraten/chimlo), which Claude
Overhead is forked from.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/2.0.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

- The closed notch no longer shows a line of live activity under the camera;
  it is back to Claude, its signals and the GitHub badge. The open notch keeps
  every session's latest activity and the live feed.
- Running GitHub workflows show a turning green ring instead of a blue dotted
  circle, and running is green throughout GitHub Mode. Queued runs keep their
  clock.
- GitHub is checked every 30 seconds by default instead of every 5 minutes,
  so a new pull request or run shows up in the notch within half a minute.
  Choose a longer interval in **GitHub → Integration**; an interval you set
  before carries over.

## [1.0.1] - 2026-11-22

- Install from Terminal with one command, which checks the download's checksum
  and needs no Gatekeeper approval:
  `curl -fsSL https://github.com/rakeshkanneeswaran/claude-overhead/releases/latest/download/install.sh | bash`
- The usage panel shows per-model weekly limits, such as Fable, beside the
  all-models limit, and warns when one crosses your threshold.
- Plans without a 5-hour window no longer show an empty "5H —%" row.
- Weekly reset times parse even when Claude Code draws the panel without
  spaces between words.

## [1.0.0] - 2026-11-22

Claude Overhead's first public release: a notch companion for Claude Code.

### Highlights

- Every Claude Code session in the MacBook notch: working, waiting for your
  permission, asking a question, done, or failed. Sessions are ordered by what
  needs you first, and stale work is never shown as running.
- Live activity in Claude's own words. The closed notch shows the current tool
  call, for example `Bash · Run tests and commit the logo change`; click a
  session in the open notch for its live feed of tool calls, each with its
  command or file, time and outcome.
- Answer Claude's questions and approve or deny its tool requests from the
  notch. Nothing is ever approved silently, and if Claude Overhead is
  unavailable the question goes back to the terminal.
- GitHub Mode (⌃⌥G): pull requests, workflow runs, reviews and merging for the
  repositories you choose, with one red or amber badge on the GitHub icon for
  alerts you can dismiss.
- A companion window with sessions, projects, agents, history, usage, GitHub
  and settings; themes, five notch layouts, Focus mode and shortcuts.

### Before you install

- Requires macOS 14 or newer on an Apple silicon Mac.
- Install it with the Terminal command in the README. This build is ad-hoc
  signed, not notarized by Apple: the Terminal install opens without any
  prompt, but a DMG downloaded in a browser needs **Open Anyway** in **System
  Settings > Privacy & Security** on first launch.
- Claude Overhead runs locally. It has no telemetry and sends your prompts,
  transcripts and activity nowhere.

## [0.1.0] - 2026-07-22

Chimlo's first public release puts your local coding agents, media, and system
controls in the MacBook notch.

### Highlights

- Watch Codex and Claude Code sessions as they work, wait for input, finish, or
  fail.
- See recent agent activity, completion details, and how long each session has
  been active. Archive finished sessions or jump back into current work.
- Answer Claude Code questions and approve or deny requested actions without
  returning to the terminal.
- Check your real Codex and Claude usage windows without connecting another
  account or sharing credentials.
- View Now Playing information and control media from the notch. Chimlo gets
  out of the way during fullscreen playback and returns automatically.
- Replace the standard volume and brightness display with compact pixel-art
  feedback that matches Chimlo.
- Recognize idle, working, waiting, completed, and failed states through
  animated pixel companions.
- Follow a guided setup for Codex, Claude Code, Accessibility access, media,
  appearance, and updates.
- Check for new versions from Settings, then download, install, and relaunch
  Chimlo in one flow.
- Use Chimlo across notched displays, external monitors, fullscreen apps,
  Reduce Motion, and increased contrast settings.

### Privacy and reliability

- Chimlo runs locally and has no telemetry by default. Agent prompts,
  responses, questions, and permission details are not sent to a Chimlo
  service.
- Connecting or disconnecting an agent preserves your existing Codex and
  Claude Code configuration.
- If Chimlo is unavailable, questions and approvals return to the terminal.
  A connection problem never counts as approval.
- Updates are verified before installation, and existing Chimlo preferences
  stay in place after updating.

### Before you install

- Chimlo requires macOS 14 or newer on an Apple silicon Mac.
- Chimlo is not notarized by Apple yet. On first launch, macOS may require you
  to approve it with **Open Anyway** in **System Settings > Privacy &
  Security**.
- Accessibility permission is needed for Chimlo's volume and brightness
  controls. Agent activity remains available without it.

[Unreleased]: https://github.com/rakeshkanneeswaran/claude-overhead/compare/v1.0.1...HEAD
[1.0.1]: https://github.com/rakeshkanneeswaran/claude-overhead/releases/tag/v1.0.1
[1.0.0]: https://github.com/rakeshkanneeswaran/claude-overhead/releases/tag/v1.0.0
[0.1.0]: https://github.com/kraten/chimlo/releases/tag/v0.1.0
