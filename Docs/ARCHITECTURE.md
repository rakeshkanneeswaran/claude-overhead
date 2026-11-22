# Architecture

Claude Overhead has four deliberately narrow layers.

## ChimloCore

Pure `Codable` domain values, a deterministic session reducer, display-layout
math, and the privacy-safe projection from hooks and local JSONL metadata into
one `SessionCandidate` vocabulary. It knows nothing about AppKit, sockets, hook
file locations, or vendor configuration files. Hook events, process evidence,
cache restores, and JSONL metadata all merge through the same reducer. A live actionable request cannot be overwritten by weaker
metadata. Onboarding demo events pass through this exact reducer too.

Core also holds every rule the app's features depend on, so each is testable
without AppKit:

- **Transcript insights** (`TranscriptInsightsScanner`): context tokens and
  window, compactions, prompt-cache counters, the current tool activity,
  subagents, git branch, linked PRs, reported cost, touched files and test
  runs, read from the same JSONL lines the session scanner sees.
- **Settings** (`OverheadSettings`, `SettingsStore`): one versioned, lenient
  `Codable` value with normalisation, plus themes (`ThemeLibrary`, with WCAG
  contrast checks), notch layouts (`NotchLayoutSpec`) and shortcuts
  (`ShortcutValidator`).
- **Notification policy** (`NotificationPolicy.decide`): priority, per-event
  preferences, quiet hours, Focus, de-duplication through a bounded
  `DeliveryLedger`, and completion grouping. Events that block Claude can
  never be hidden.
- **Attention rules** (`AttentionRules.swift`): threshold crossings, session
  cycling, which transcript is current for a moved session, and GitHub event
  kinds.
- **History** (`SessionHistoryStore` actor): records, merge rules, retention,
  corruption recovery (the damaged file is moved aside, never deleted),
  read-only handling of a newer schema, search, receipts, Project Pulse,
  timelines and the daily recap.
- **Git and GitHub**: `GitRepositoryReader` runs `/usr/bin/git` with
  `--no-optional-locks` and fixed arguments (never a shell); `GitRemote`
  parses remotes; `GitHubClient` is a read-only REST client with ETag caching
  and an injected transport; `GitHubEventDiff` turns snapshots into events.
  Core does no networking itself.

## ChimloProtocol

Authenticated loopback transport, bounded message framing, runtime descriptor
storage, and request correlation. A helper discovers a descriptor owned by the
current user and proves possession of a per-launch token. A transport error
never becomes an approval.

## ChimloApp

AppKit owns the accessory-app lifecycle, top-center `NSPanel`, and screen
geometry, including a pill just below the menu bar on displays without a notch.
SwiftUI renders the island, sessions, onboarding, setup, and the companion
window. The panel is non-activating until an interaction requires keyboard
focus.

- `ApplicationModel` owns sessions, the panel, and the owner interactions. It
  reads the notch-facing settings (`applySettings`) and asks an injected
  `attentionDecider` how loudly to announce each event.
- `OverheadServices` owns the long-lived services and the wiring between
  them: `SettingsModel` (the single owner of preferences), `AttentionRouter`
  (applies the notification policy, posts banners through `SystemNotifier`),
  `HistoryModel`, `GitHubModel`, Carbon global hot keys, and the login item.
- `CompanionWindowCoordinator` hosts the companion window: Overview, Sessions,
  Projects, Agents, History, Usage, GitHub and Settings, styled by the active
  theme palette.
- `LocalSessionRuntime` restores its small cache, publishes the newest Claude
  transcript first, then enriches recent history. Cold transcript reads are
  bounded to a 128 KB head plus a 2 MB tail and continue incrementally from
  EOF. When one session has transcripts in two project folders, the most
  recently written file is current.
- `claude agents --json`, polled every 15 seconds, lists live interactive and
  background sessions with exact process ids.
- `SessionHostService` resolves, on demand, which terminal tab or editor window
  runs a session (`ps` and `lsof`, then a parent-process walk) and focuses it
  with AppleScript (Terminal, iTerm) or `NSWorkspace` (VS Code, Cursor,
  Windsurf). A terminal device is validated before it reaches AppleScript.
- `AgentIntegrationManager` installs and repairs the stable helper plus marked
  Claude observer entries after a complete preview and confirmation.
  Claude's separately marked `AskUserQuestion` and `PermissionRequest` hooks are
  synchronous and route transient owner interactions through the same
  authenticated listener.

## ChimloCLI

Development event injection and the live Claude Code hook executable
boundary. Provider codecs decode only a small allowlist of status metadata. The
helper writes only the response format required by the invoking agent to stdout.

## Provider capacity

Claude Overhead obtains capacity only through Claude Code's own runtime surfaces. The
primary source is an opt-in
status-line bridge that caches only Claude Code's documented `rate_limits`
payload and configures its documented `refreshInterval` at 60 seconds. Installing
the bridge preserves and later restores any existing custom status-line
configuration, including its previous refresh interval.

When the Claude cache is more than five minutes old and the owner opens the
Usage disclosure, Claude Overhead may launch one bounded, tool-disabled, probe-owned
Claude Code terminal and parse the provider-owned `/usage` panel. This fallback
runs only while capacity details are disclosed, reuses one probe-owned session
identity, removes its dedicated transcript artifacts after exit, and is excluded
from local-session discovery. A failed probe cools down for five minutes.

These sources keep capacity exact without reading provider credentials,
Keychain items, browser cookies, private OAuth endpoints, historical rollout
snapshots, or token-derived estimates. The `/usage` fallback stores the exact
percentages shown by Claude Code and derives reset times only from its
provider-reported relative or timezone-qualified reset labels. A still-valid
timestamp from the status-line payload remains preferred because it is more
precise. When no trustworthy value is available, Claude Overhead reports Capacity
unavailable. Claude's status line continues refreshing while an otherwise idle
session remains open.

## Safety boundaries

- Pending decisions, provider permissions, and questions are keyed by request
  and session, not screen position.
- Duplicate messages and stale per-session sequence numbers are ignored.
- Payloads and frames have explicit size limits.
- Runtime descriptors are private to the local user and short lived.
- The app being offline returns control to the native terminal interaction.
- Agent configuration changes require a preview, semantic validation, atomic
  replacement, marker-scoped uninstall, and an explicit user action.
- The session cache contains only provider, title, generic status, model,
  project path, terminal label, jump URL, phase, and timestamps.
- Session history (`~/Library/Application Support/Overhead/history`, mode
  0600) holds a summary per session. It includes the last prompt and reply
  only while **Keep your last prompt and Claude's last reply** is on, capped at
  2,000 characters, and test commands with environment assignments removed.
  It never copies transcripts, tool inputs or outputs, or file contents.
- The GitHub token, when one is pasted, lives only in the Keychain
  (`com.rakesh.overhead.github`). Tokens borrowed from `gh` stay in memory.
  Neither is logged, and `GitHubCredential` redacts itself in descriptions.
- GitHub URLs from the API are opened only when they are `https` on
  github.com; repository metadata never runs as code or reaches a shell.
- Claude question text, option descriptions, and selected answers exist only in
  memory for the lifetime of the blocking hook request.
- Claude permission paths and bounded tool previews also exist only in memory.
  Only the generic tool category reaches the persisted session reducer.

## Installer seam

Adapters expose read-only detection, a complete installation preview,
installation, removal, and health checks. Claude Overhead never silently modifies hook
trust or restores an old whole-file backup over newer user changes. The backup
is recovery evidence; uninstall removes only Claude Overhead's current marker.
