# Claude Overhead

**A notch companion for Claude Code on macOS.** See every Claude Code session
from the MacBook notch, answer its questions and approve its tool requests
without switching back to the terminal, and keep an eye on context, usage,
history and GitHub in one companion window.

> Claude Overhead is an independent open-source project. It is not affiliated
> with, endorsed by, or sponsored by Anthropic.

**Status:** early development. There are no releases yet; build it from source
(below).

## Features

### In the notch

- **Live sessions.** Each running Claude Code session shows as working, waiting
  for permission, asking a question, done, or failed, plus what it is doing
  right now ("Running a command", "Reading files", "Delegating to agents").
- **Answer questions in place.** Claude's `AskUserQuestion` choices appear in
  the notch. Pick an option, or choose **Other…** and type your own answer, the
  same as Claude Code's own "Other".
- **Approve tool requests.** Deny, Allow Once, or Allow All for the current
  session. Bypass mode is never offered, and nothing is ever approved silently.
- **A completion wave.** When Claude finishes a turn, a colour wave fills the
  closed notch for a moment. The notch does not pop open.
- **Five notch layouts.** Minimal, Classic, Expanded (activity, context ring
  and agent dots), Focus (still, opens only on click) and Agent View.
- **Session rows** show the git branch, context meter, running subagents and
  the linked pull request, wherever that data really exists.
- **Works without a notch.** On external displays it shows as a small pill
  below the menu bar.

### In the companion window

Open it from the gear button in the open notch, with the Open settings
shortcut (⌃⌥ and comma), or by opening the app again.

- **Overview:** active and blocked sessions, today's recap, usage and recent
  notifications.
- **Sessions:** search, group by project, focus the terminal tab or editor
  window a session runs in, and resume a finished session with
  `claude --resume`.
- **Projects:** Project Pulse for each project (active, needs-you, recent
  outcomes, linked PRs) and a timeline.
- **Agents:** each session's subagents, what they were asked to do, and
  whether they finished.
- **History:** local session history with search and filters, plus a
  **receipt** per session: duration, model, branch, files changed with git's
  own line counts, commits made in that window, tests run, PRs and reported
  cost.
- **Usage:** context per session against your thresholds, the 5-hour and
  weekly limits with reset countdowns, and prompt-cache hit rates with a
  warm/cold estimate.
- **GitHub:** open PRs with CI and review state, Actions runs, and review
  requests for the repositories Claude works in.
- **Settings:** General, Personalization, Notch Layouts, Themes (Midnight,
  Graphite, Obsidian, Warm Amber, Arctic, Match System), Sessions,
  Notifications, Agents, Context & Usage, GitHub, Focus Mode, Shortcuts,
  Privacy & Data, Advanced.

### Notifications that respect you

Events are **critical** (Claude is blocked: permission, question, failure),
**informational** (completions, context and usage warnings, GitHub) or
**ambient**. Critical events always show in the notch. You choose sound and
macOS banners per event. Quiet hours, Focus mode and de-duplication keep the
rest calm. macOS banner permission is requested only when you turn a banner
on.

### Global shortcuts

Toggle the panel (⌃⌥O), show sessions (⌃⌥S), next and previous session (⌃⌥]
and ⌃⌥[), focus the terminal (⌃⌥T), history (⌃⌥H), Focus mode (⌃⌥F) and
settings (⌃⌥,). Every one can be changed. Conflicts with other actions and
with macOS shortcuts are detected, and shortcuts need no Accessibility
permission.

## Privacy

- No telemetry and no analytics. Nothing about your sessions leaves your Mac.
- The only network calls are to **api.github.com**, and only while you have
  GitHub turned on, plus Claude Code's own usage check.
- GitHub sign-in reuses the GitHub CLI (`gh auth token`). If you would rather
  paste a personal access token, it is stored only in the macOS Keychain.
- Session history is a summary per session in
  `~/Library/Application Support/Overhead/history/sessions.json`, readable
  only by you (mode 0600). By default it keeps your last prompt and Claude's
  last reply (capped at 2,000 characters) so you can search them. Turn that off
  in **Settings → Privacy & Data**, where you can also set retention, export,
  or delete history. Claude Code's own transcripts are never copied or
  changed.
- **Permissions.** Claude Overhead needs no Accessibility or Screen Recording
  permission. For a project in Documents, Desktop, Downloads or iCloud Drive,
  macOS asks before any app can read it, so git-backed receipts and GitHub
  repository discovery there wait until you click **Include git changes** or
  **Look for repositories there**. Until then they use Claude Code's own
  numbers. Focusing a Terminal or iTerm tab asks macOS for Automation
  permission the first time.
- If the app is closed or anything fails, Claude Code simply asks in the
  terminal as usual. A failure never counts as an approval.

## Requirements

- macOS 14 or newer, Apple silicon
- [Claude Code](https://code.claude.com) installed
- Optional: the [GitHub CLI](https://cli.github.com), signed in, for GitHub
- To build: Xcode, or the Xcode Command Line Tools with Swift 6

## Build and run

```sh
git clone https://github.com/rakeshkanneeswaran/claude-overhead.git
cd claude-overhead
make app
open "dist/Claude Overhead Dev.app"
```

On first launch a setup window walks you through connecting Claude Code.
Claude Overhead shows exactly what it will add to `~/.claude/settings.json`
before writing anything, keeps a backup of the original
(`settings.json.overhead-backup`), and **Disconnect** removes only its own
entries. See [Docs/AGENT_HOOKS.md](Docs/AGENT_HOOKS.md) for the details.

The app is not notarized yet. If macOS blocks the first launch, open
**System Settings → Privacy & Security** and click **Open Anyway**.

To quit, right-click the notch and choose **Quit Claude Overhead**, or use
**Settings → General → Quit**.

## Develop

```sh
make build   # compile
make test    # unit tests (Swift Testing)
make check   # behaviour checks (layout, protocol, fail-closed decisions)
make app     # build dist/Claude Overhead Dev.app
```

With only the Command Line Tools installed (no full Xcode), the build scripts
use the macOS 26 SDK automatically, because the macOS 27 SDK's SwiftUI needs a
macro plugin that only ships with Xcode.

More reading: [Architecture](Docs/ARCHITECTURE.md) ·
[Claude Code hooks](Docs/AGENT_HOOKS.md) · [Protocol](Docs/PROTOCOL.md) ·
[Contributing](CONTRIBUTING.md) · [Security](SECURITY.md)

## Credits

Claude Overhead is a fork of [Chimlo](https://github.com/kraten/chimlo) by
Kartike Bansal, licensed under GPL-3.0. Chimlo built the notch island, the
authenticated hook protocol, and the question and permission bridges this app
is built on.

The Claude usage probe adapts code from CodexBar (MIT); see
[Vendor/CodexBar/LICENSE](Vendor/CodexBar/LICENSE).

## License

[GPL-3.0](LICENSE), the same license as Chimlo.
