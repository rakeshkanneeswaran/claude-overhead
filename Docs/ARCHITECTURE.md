# Architecture

Claude Overhead has four deliberately narrow layers.

## ChimloCore

Pure `Codable` domain values, a deterministic session reducer, display-layout
math, and the privacy-safe projection from hooks and local JSONL metadata into
one `SessionCandidate` vocabulary. It knows nothing about AppKit, sockets, hook
file locations, or vendor configuration files. Hook events, process evidence,
cache restores, and JSONL metadata all merge through the same reducer. A live actionable request cannot be overwritten by weaker
metadata.

Core also holds every rule the app's features depend on, so each is testable
without AppKit:

- **What's New** (`ReleaseNotes.swift`, `ReleaseNotesValidation.swift`,
  `WhatsNewWalkthrough.swift`): the format of a release's visual notes, the
  rules they must pass to be published (`ReleaseNotesValidator`,
  `ReleaseReadiness`), how an installed copy reads them (`ReleaseNotesReader`:
  only for exactly the version on offer, leaving out what it cannot draw), and
  the rule that only the version whose notes were shown is installed
  (`UpdateInstallGuard`). The notes travel in the signed update feed, in the
  same entry as the download. `Sources/ChimloReleaseNotes` is the small tool
  that checks and publishes them; `WhatsNewWindow.swift` and
  `WhatsNewVisuals.swift` in the app only draw what the notes say. See
  [RELEASING.md](RELEASING.md#whats-new).
- **Transcript insights** (`TranscriptInsightsScanner`): context tokens and
  window, compactions, prompt-cache counters, the current tool activity,
  subagents, git branch, linked PRs, reported cost, touched files and test
  runs, read from the same JSONL lines the session scanner sees. It also keeps
  a bounded activity log (`SessionActivity`, newest 120 main-chain tool calls)
  with Claude's own description, a redacted target (`ActivityText`), and a
  status from the matching `tool_result`: running, completed, failed, or
  unknown once the turn ends without one. Lines may arrive out of order or
  repeat; results seen before their call are held briefly.
- **Session standing** (`SessionActivity.swift`): `SessionRunState` (needs
  you, failed, running, waiting for input, recently completed, older; stale
  work is never "running"), `SessionOrdering`, `NotchActivityFocus` and
  `CompactActivityLine` for the closed notch's activity strip, which
  `OverheadSettings.showsClosedNotchActivity` can turn off.
- **Updates** (`AppUpdatePresentation.swift`): the update lifecycle
  (`AppUpdatePhase`), failures in the owner's words from Sparkle's error codes
  (`AppUpdateFailure`), the notch row that is dismissed or expires and so can
  never stay (`AppUpdateNotice`), and version comparison. `ChimloUpdater`
  drives Sparkle against the signed appcast of the latest GitHub release;
  see Docs/RELEASING.md.
- **Session characters** (`SessionCharacter.swift`, `CharacterArtwork.swift`,
  `CharacterAssignments.swift`): `CharacterCatalog` holds the 46 characters,
  each an original 16 × 16 drawing with one letter per colour, grouped into
  `CharacterWorld`s. The Claude logo is the default and the fallback whenever
  a session has no character to show. `CharacterAssignments` records what
  each session wears and who chose it. The owner's pick in the notch (a
  character, a random one they asked for, or the Claude logo) always applies.
  Automatic assignment is a setting, off by default: while it is on, a listed
  session with nothing stored draws at random from its project's pool (or
  the whole catalogue), preferring a character no listed session wears, then
  one no session of the same project wears, then the least worn. A character
  handed out that way shows only while the setting is on, and is kept rather
  than erased while it is off (`shownCharacter(for:automatic:)`). A session
  keeps its record for as long as it is remembered (the 512 most recently
  seen), across restarts and a resume; only listed sessions count as "in
  use", so a character is free once its session leaves the list. In the app,
  `SessionMark` is the one view that draws a session's mark, so the closed
  notch, the rows, the activity feed and the companion's session list always
  agree.
- **Sound and Lock Mode** (`SessionSound.swift`): `SessionSoundPreferences`
  (which sessions may sound, off for all by default, kept for the session's
  lifetime), `SessionSoundGate` (a session's events need its toggle, one sound
  per session per burst) and `NotchLockPolicy` (what may open the notch).
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
  and an injected transport; `GitHubEventDiff` and `GitHubRunEventDiff` turn
  snapshots into events. Core does no networking itself.
- **GitHub Mode** (`GitHubRepositories.swift`, `GitHubActivity.swift`,
  `GitHubMode.swift`): `GitHubRepositorySelection` (a collection of GitHub
  repository ids plus a focused id and an exclusion set), `GitHubOverview`,
  `GitHubIndicator`, pull request filters, run status, per-repository alert
  levels, notice grouping, the polling budget, and `GitHubNavigation`, which
  keeps GitHub Mode's tab and detail apart from every Claude property.
  `GitHubAlerts.swift` gives every alert a stable id (a run attempt, a pull
  request, or a pull request's head commit for failing checks) and keeps
  `GitHubAlertDismissals`: dismissed alerts stop raising `GitHubBadge`, an
  alert that clears is marked resolved and alerts again if it recurs, and an
  absence only counts as cleared where the data could have shown it.

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
- `GitHubModel` is the single source of GitHub data for the notch, the
  companion window and notifications. It polls only the selected
  repositories: a parallel quick look (runs and the PR list) for anything new,
  then a full pass with reviews and checks, every 30 seconds by default.
  Requests are conditional, so an unchanged repository costs nothing against
  the rate limit. With a longer interval, repositories with running workflows
  are still checked every 45 seconds. A refresh is never
  cancelled halfway; a change during one queues another pass. Jobs and pull
  request details load only when opened.
- GitHub Mode lives in the open notch (`IslandGitHubViews`,
  `IslandGitHubDetails`). `ApplicationModel.notchContent` resolves to Claude
  whenever Claude waits on the owner, so a permission request or question is
  never hidden; GitHub's place is kept for afterwards.
- Using GitHub is the companion window's `GitHubPage` (`GitHubPageTab`:
  Overview, Repositories, Actions, Pull Requests, Reviews); setting it up is
  Settings → GitHub (`GitHubIntegrationView`), the integration only. Before
  GitHub is set up the page shows `GitHubSetupState`'s explanation and a
  Connect GitHub button that opens that pane, and the notch's "set up" links
  open it too. Both edit `settings.github`, which `GitHubModel` and GitHub
  Mode read. Settings is seven tabs (`SettingsPaneID`), one place per choice.
- `CompanionWindowCoordinator` hosts the companion window: Overview, Sessions,
  Projects, Agents, History, Usage, GitHub and Settings, styled by the active
  theme palette.
- `LocalSessionRuntime` restores its small cache, publishes the newest Claude
  transcript first, then enriches recent history. Cold transcript reads are
  bounded to a 128 KB head plus a 2 MB tail and continue incrementally from
  EOF. A full pass runs every 8 seconds; between passes, transcripts written
  in the last 10 minutes are tailed every second (one `stat` each, bytes read
  only when a file grew, a fresh cold start when one shrank). When one session
  has transcripts in two project folders, the most recently written file is
  current.
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

When the Claude cache is more than five minutes old and usage is on screen
(the open notch, which shows it top left, or a usage card in the companion
window), Claude Overhead may launch one bounded, tool-disabled, probe-owned
Claude Code terminal and parse the provider-owned `/usage` panel. This fallback
runs only while usage is on screen, reuses one probe-owned session
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
session remains open. The status line is a terminal feature: sessions in an
editor extension may never run it, and then this fallback is the only source,
which is why it also runs whenever usage is shown.

## Safety boundaries

- Pending decisions, provider permissions, and questions are keyed by request
  and session, not screen position.
- Duplicate messages and stale per-session sequence numbers are ignored.
- A permission, question or decision request lives only as long as the hook
  helper's connection: when Claude Code stops the helper, the listener
  cancels the request (never approving it), and a session that ends closes
  its open requests (`OwnerInteractionLifetime`).
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
- The live activity feed is held in memory only. It keeps Claude's own tool
  call descriptions and what each call acts on (a command's first line with
  credentials and assignment values redacted, a file path, a search pattern
  or query, a URL without its query), never tool output, file contents,
  prompts, or MCP tool inputs.
- GitHub alert dismissals are stored locally under
  `overhead.github.dismissedAlerts` as alert ids and dates. Dismissing sends
  nothing to GitHub.
- The GitHub token, when one is pasted, lives only in the Keychain
  (`com.rakesh.overhead.github`). Tokens borrowed from `gh` stay in memory.
  Neither is logged, and `GitHubCredential` redacts itself in descriptions.
- GitHub URLs from the API are opened only when they are `https` on
  github.com; repository metadata never runs as code or reaches a shell.
- GitHub's critical events (failed workflow, failed checks, requested changes,
  merge conflicts) show and may sound, but never expand the notch: only
  Claude's own requests may open it. Workflow logs are never downloaded.
- The one GitHub write is a pull request merge (`PUT .../pulls/{n}/merge`).
  It is offered only when GitHub's own `mergeable` and `mergeable_state` say
  the pull request can merge (`GitHubMergeEligibility`), needs a separate
  confirmation each time, sends the head SHA the owner saw so a later push
  makes GitHub refuse, and is never retried automatically.
- Git never runs in a macOS-protected folder (Documents, Desktop, Downloads,
  iCloud Drive, other volumes) until the owner asks (`FolderAccess`,
  `FolderAccessModel`). macOS's folder prompt blocks the git process until it
  is answered, so a background read there would surface a prompt with no
  context. Each folder is remembered once git has succeeded in it.
- Claude question text, option descriptions, and selected answers exist only in
  memory for the lifetime of the blocking hook request.
- Claude permission paths and bounded tool previews also exist only in memory.
  Only the generic tool category reaches the persisted session reducer.

## Installer seam

Adapters expose read-only detection, a complete installation preview,
installation, removal, and health checks. Claude Overhead never silently modifies hook
trust or restores an old whole-file backup over newer user changes. The backup
is recovery evidence; uninstall removes only Claude Overhead's current marker.
