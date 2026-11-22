# Claude Overhead

**A notch companion for Claude Code on macOS.** See your Claude Code sessions,
answer their questions and approve their tool requests from the MacBook notch,
without switching back to the terminal.

> Claude Overhead is an independent open-source project. It is not affiliated
> with, endorsed by, or sponsored by Anthropic.

**Status:** early development. There are no releases yet; build it from source
(below).

## What it does today

- **Live sessions.** Every running Claude Code session shows up in the notch:
  working, waiting for you, done, or failed.
- **Answer questions in place.** Claude's multiple-choice questions
  (`AskUserQuestion`) appear in the notch; pick an option and Claude continues.
- **Approve tool requests.** Deny, allow once, or allow for the current
  session. Bypass mode is never offered.
- **Usage limits.** Your 5-hour and weekly Claude usage, with reset countdowns.
- **Sound cues** when a session needs you or finishes (can be muted).
- **Works without a notch.** On external displays and Macs without a notch it
  shows as a small pill just below the menu bar.
- **Local and private.** Nothing leaves your Mac, and there is no telemetry.
  If the app is closed or anything fails, Claude Code simply asks in the
  terminal as usual: a failure never counts as an approval.

## Planned

- A cache countdown: how long until Claude's prompt cache goes cold while a
  session waits for you.
- A context meter that warns before auto-compact.
- A session receipt: cost, time, lines changed and the PR, when a session ends.
- GitHub: your PRs' checks, reviews and merge blockers, live Actions runs, and
  notifications when a build fails.

## Requirements

- macOS 14 or newer, Apple silicon
- [Claude Code](https://code.claude.com) installed
- To build: Xcode, or the Xcode Command Line Tools with Swift 6

## Build and run

```sh
git clone https://github.com/rakeshkanneeswaran/claude-overhead.git
cd claude-overhead
make app
open "dist/Claude Overhead Dev.app"
```

Then open **Settings → Agents** and click **Connect** next to Claude Code.
Claude Overhead shows you exactly what it will add to `~/.claude/settings.json`
before writing anything, keeps a backup of the original
(`settings.json.overhead-backup`), and **Disconnect** removes only its own
entries. See [Docs/AGENT_HOOKS.md](Docs/AGENT_HOOKS.md) for the details.

The app is not notarized yet. If macOS blocks the first launch, open
**System Settings → Privacy & Security** and click **Open Anyway**.

## Develop

```sh
make build   # compile
make test    # unit tests
make check   # behaviour checks (layout, protocol, fail-closed decisions)
```

With only the Command Line Tools installed (no full Xcode), the build scripts
use the macOS 26 SDK automatically, because the macOS 27 SDK's SwiftUI needs a
macro plugin that only ships with Xcode.

More reading: [Architecture](Docs/ARCHITECTURE.md) ·
[Protocol](Docs/PROTOCOL.md) · [Contributing](CONTRIBUTING.md) ·
[Security](SECURITY.md)

## Credits

Claude Overhead is a fork of [Chimlo](https://github.com/kraten/chimlo) by
Kartike Bansal, licensed under GPL-3.0. Chimlo built the notch island, the
authenticated hook protocol, and the question and permission bridges this app
is built on.

The Claude usage probe adapts code from CodexBar (MIT); see
[Vendor/CodexBar/LICENSE](Vendor/CodexBar/LICENSE).

## License

[GPL-3.0](LICENSE), the same license as Chimlo.
