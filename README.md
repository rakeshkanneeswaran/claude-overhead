# Claude Overhead

**A notch companion for Claude Code on macOS.** See every Claude Code session
from the MacBook notch, answer its questions and approve its tool requests
without switching back to the terminal, and keep an eye on context, usage,
history and GitHub in one companion window.

> Claude Overhead is an independent open-source project. It is not affiliated
> with, endorsed by, or sponsored by Anthropic.

## Install

Paste this into Terminal (macOS 14 or newer, Apple silicon):

```sh
curl -fsSL https://github.com/rakeshkanneeswaran/claude-overhead/releases/latest/download/install.sh | bash
```

[`install.sh`](Scripts/install.sh) downloads the latest release, checks it
against the release's SHA-256 checksums, copies Claude Overhead into
Applications (or `~/Applications` if Applications is not writable), and opens
it. From 1.0.4 on, Claude Overhead updates itself: it checks GitHub hourly
(or when you click **Check for Updates**), verifies each download's
signature before installing, and restarts into the new version; a failed
update leaves your copy exactly as it was and says why. On 1.0.3 or earlier,
run the same command once to update. Then Claude Overhead walks you
through connecting Claude Code: it shows exactly what it adds to
`~/.claude/settings.json` before changing anything, and keeps a backup.

To remove it, click **Disconnect** in **Settings > General**, quit Claude
Overhead, and move it to the Trash.

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
- **Live activity.** The closed notch shows what Claude is doing right now in
  its own words, such as `Bash · Run tests and commit the logo change` (turn
  it off in **Settings → Appearance**). The open notch lists every session
  (needs-you first, then running, waiting for you, recently finished), and
  clicking one opens its live feed: every tool call with its description, the
  command or file, the time, and whether it finished, failed, or never
  reported back. Nothing is summarized by a model, and commands have tokens
  and assignment values redacted.
- **Session rows** show the latest tool call, the project, running subagents
  and the linked pull request, wherever that data really exists.
- **Sound only where you want it.** Every session starts silent. Click a
  session's bell in the notch to hear it when it finishes, fails or needs
  you; other sessions stay quiet. Pick the sound, preview it and set its
  volume in **Settings → Notifications**.
- **Lock Mode.** The lock in the open notch keeps the notch closed until you
  click it. Sessions are still watched and the sounds you turned on still
  play; a permission request or question waits in the notch, never approved
  or dropped, until you open it.
- **Scripts are left alone.** A `claude -p` run has nobody to answer a prompt,
  so its permission requests stay with Claude Code and the run carries on.
  Turn on **Ask me about unattended runs** in **Settings → General** to
  approve them from the notch instead.
- **Works without a notch.** On external displays it shows as a small pill
  below the menu bar.

### GitHub Mode

Click the GitHub mark in the open notch (or press ⌃⌥G) and the notch shows
what is happening to your code after it reaches GitHub. Click it again, or
**‹ Claude**, to go back; neither mode loses its place.

- **Overview:** open pull requests, running and failed workflows, reviews
  waiting on you, and a short "needs you" list (failed workflows, merge
  conflicts and requested changes on your PRs, review requests).
- **Actions:** recent runs for the focused repository with branch, commit,
  event, duration or live elapsed time. Open a run for its jobs, failed
  steps, and a link to the log on github.com.
- **Pull requests:** filter by open, draft, review requested, changes
  requested, approved, CI failing, ready to merge or merged. Open one for its
  description, size, reviews, checks and merge state, and merge it right there
  when GitHub says it can merge. Every merge asks you to confirm the method
  and branch first, and only goes ahead if nobody pushed since you looked.
- **Repository switcher:** monitor as many repositories as you like, across
  organizations, and switch the focused one from the notch.
- One GitHub status mark: a small badge on the GitHub icon, red for a failed
  workflow, amber when something waits on you, and no badge otherwise. It
  shows in the closed notch only while an alert is outstanding. Dismiss an
  alert with its ×, or **Clear all**; dismissals are remembered across
  restarts, a genuinely new failure alerts again, and nothing is ever changed
  on GitHub. The mark turns green while workflows run, and a running workflow
  shows a turning green ring. A Claude permission request or question always
  takes the notch first.

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
- **Usage:** context per session against your thresholds; the limits Claude
  Code reports for your plan (5-hour, weekly, and per-model weekly limits such
  as Fable) with reset countdowns; and prompt-cache hit rates with a warm/cold
  estimate.
- **GitHub:** Overview, Repositories, Actions (jobs and steps), Pull
  Requests (descriptions, reviews, checks, merge) and Reviews. It shares its
  data with GitHub Mode in the notch. Until GitHub is connected it explains
  what it offers and has a **Connect GitHub** button; nothing else in Claude
  Overhead depends on it.
- **Settings:** seven tabs, one place for each choice. **General** (Claude
  Code, Lock Mode, unattended runs, login, display, updates), **Appearance** (notch layout,
  themes, motion), **Notifications** (sound and volume, every event including
  GitHub's, quiet hours, Focus), **Usage**, **Shortcuts**, **GitHub** (the
  integration: sign-in, repositories, what it watches) and **Privacy**.

### Notifications that respect you

Events are **critical** (Claude is blocked: permission, question, failure),
**informational** (completions, context and usage warnings, GitHub) or
**ambient**. Critical events always show in the notch. You choose sound and
macOS banners per event. Quiet hours, Focus mode and de-duplication keep the
rest calm. macOS banner permission is requested only when you turn a banner
on.

### Global shortcuts

Toggle the panel (⌃⌥O), show sessions (⌃⌥S), next and previous session (⌃⌥]
and ⌃⌥[), focus the terminal (⌃⌥T), history (⌃⌥H), Focus mode (⌃⌥F),
settings (⌃⌥,) and GitHub Mode (⌃⌥G). Every one can be changed. Conflicts with other actions and
with macOS shortcuts are detected, and shortcuts need no Accessibility
permission.

## Privacy

- No telemetry and no analytics. Nothing about your sessions leaves your Mac.
- The only network calls are to **api.github.com**, and only while you have
  GitHub turned on, plus Claude Code's own usage check.
- GitHub sign-in reuses the GitHub CLI (`gh auth token`). If you would rather
  paste a personal access token, it is stored only in the macOS Keychain.
  Overhead reads only the repositories you select in **Settings → GitHub**
  (each stored by GitHub's numeric id), and its only write is a merge you
  confirm (turn merging off there if you like). Workflow logs are never
  downloaded; they open on github.com.
- Session history is a summary per session in
  `~/Library/Application Support/Overhead/history/sessions.json`, readable
  only by you (mode 0600). By default it keeps your last prompt and Claude's
  last reply (capped at 2,000 characters) so you can search them. Turn that off
  in **Settings → Privacy**, where you can also set retention, export,
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

The GitHub mark is GitHub's `mark-github` from Primer Octicons (MIT), used to
link to GitHub as GitHub's logo guidelines allow.

Claude Code's pixel mascot marks Claude Code sessions in the notch. Claude
and Claude Code are Anthropic's; Claude Overhead is not affiliated with
Anthropic.

The Claude usage probe adapts code from CodexBar (MIT); see
[Vendor/CodexBar/LICENSE](Vendor/CodexBar/LICENSE).

## License

[GPL-3.0](LICENSE), the same license as Chimlo.
