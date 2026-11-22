# Changelog

All notable changes to Claude Overhead are documented in this file. Entries
before 1.0.0 are from [Chimlo](https://github.com/kraten/chimlo), which Claude
Overhead is forked from.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/2.0.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.6] - 2026-11-23

- Fixed a crash: clicking **Connect GitHub**, **Choose repositories**,
  **Settings** or **Change monitored repositories** on the GitHub page quit
  the app (1.0.4 and 1.0.5). They now open Settings → GitHub as intended.
- Closed off a possible crash while looking for Claude Code processes, when
  another program's command line contains a line break.

## [1.0.5] - 2026-11-23

- A session you rename (in VS Code, or with `/rename`) shows its new name in
  the notch. Claude Code writes the name as `custom-title`, which was never
  read, so the notch kept Claude's automatic title. Your name now wins, the
  latest rename counts, and clearing it brings Claude's title back.

- Usage stays current. Claude Code's status line, the main source, may never
  run for sessions in an editor extension such as VS Code, and the `/usage`
  fallback ran only when the usage details were opened, so the notch could
  show hours-old numbers (64% after a reset to 19%). The fallback now
  freshens numbers over five minutes old whenever usage is on screen.
- The open notch always shows usage top left, in every layout.

## [1.0.4] - 2026-11-23

- Questions and permission requests in the notch have a × too. It hands the
  request back to Claude Code's own prompt in the terminal: nothing is
  answered, approved or dropped, so Claude is never left waiting unseen.

- Close a session's prompt-and-reply preview in the notch with its ×. Only the
  preview goes: the session, its conversation and history, and any pending
  request stay, and the notch stays open. A hairline shows the time left on
  the preview's own two-minute timer; a new reply shows again.
- Text is readable in every theme. The companion window took light or dark
  from macOS while the theme painted its background, so on a Mac in dark mode
  Arctic drew dark-mode white text on its light background. The theme now
  decides the window's appearance (Match System follows macOS, live), and the
  separate "Light or dark" choice is gone.

- Claude Overhead updates itself. The in-app updater never worked in any
  Claude Overhead release: the update feed and signing key were removed when
  it was forked from Chimlo and never replaced, so every attempt failed before
  reaching the network and the notch stuck on "Try update again". Releases
  now publish a signed `appcast.xml`, and the app shows each step (checking,
  downloading, verifying, installing, restarting, "Updated to …"). A failure
  says what went wrong and what to do, has **Retry** and a close button, and
  leaves the notch on its own after a minute; the installed app is never
  touched by a failed update. Copies on 1.0.3 or earlier update once with the
  Terminal command.
- Sound per session: every session starts silent, and a bell on each session
  in the notch turns its sounds on. Choose the sound, preview it and set its
  volume in **Settings → Notifications**. A burst of events from one session
  makes one sound.
- Lock Mode: the lock in the open notch keeps the notch closed until you
  click it, while every session is still watched and enabled sounds still
  play. Requests wait in the notch, never approved or dropped. The closed
  notch always shows the lock beside the GitHub badge: red and closed while
  locked, a white open lock otherwise.
- Settings is one row of seven tabs (General, Appearance, Notifications,
  Usage, Shortcuts, GitHub, Privacy) instead of a second sidebar of twelve
  panes, with nothing configured in two places. Focus mode is part of
  Notifications; layouts, themes and motion are Appearance.
- Settings → GitHub is the integration only: sign-in, repositories and what
  it watches. The GitHub page shows GitHub; until it is connected it explains
  what it offers and has a **Connect GitHub** button.
- Overview shows your Claude usage (the limit closest to running out) where
  Reported Cost was; cost stays in history and receipts.
- Forked Claude Code sessions are watched from their first moment (after
  Connect or Repair).
- Nothing waits forever any more: the local listener retries on its own if it
  fails to start (Claude Code falls back to its own prompts meanwhile), the
  `ps`, `lsof` and `claude agents` checks give up after 10 seconds instead of
  freezing session state, a GitHub job or pull request view says why it is
  empty instead of loading forever and reloads when GitHub reconnects, and a
  real request during the setup tour ends the tour instead of leaving a demo
  "WAIT" in the notch.
- **Focus terminal** explains when it can't find the session's terminal (tmux,
  SSH, Automation permission) instead of doing nothing; **Resume in Terminal**
  is offered only for sessions with no live process, once at a time.

- A permission or question card leaves the notch as soon as Claude Code stops
  waiting for it (you answered in the terminal, interrupted the turn, or the
  session ended). Before, it could stay for up to 10 minutes and keep the next
  real prompt out of the notch.
- In `dontAsk` and `bypassPermissions` modes, permission requests are left to
  Claude Code: the notch no longer asks where Claude Code would not.

## [1.0.3] - 2026-11-22

- The notch's usage panel shows how much of each limit you have used, the same
  number Claude Code's `/usage` shows, instead of how much is left. Bars fill
  as a limit is spent, and a limit you have used up reads 100%.

## [1.0.2] - 2026-11-22

- The closed notch's line of live activity under the camera can be turned off
  in **Settings → Notch Layouts → Show live activity in the closed notch**.
  It stays on by default.
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

[Unreleased]: https://github.com/rakeshkanneeswaran/claude-overhead/compare/v1.0.6...HEAD
[1.0.6]: https://github.com/rakeshkanneeswaran/claude-overhead/releases/tag/v1.0.6
[1.0.5]: https://github.com/rakeshkanneeswaran/claude-overhead/releases/tag/v1.0.5
[1.0.4]: https://github.com/rakeshkanneeswaran/claude-overhead/releases/tag/v1.0.4
[1.0.3]: https://github.com/rakeshkanneeswaran/claude-overhead/releases/tag/v1.0.3
[1.0.2]: https://github.com/rakeshkanneeswaran/claude-overhead/releases/tag/v1.0.2
[1.0.1]: https://github.com/rakeshkanneeswaran/claude-overhead/releases/tag/v1.0.1
[1.0.0]: https://github.com/rakeshkanneeswaran/claude-overhead/releases/tag/v1.0.0
[0.1.0]: https://github.com/kraten/chimlo/releases/tag/v0.1.0
