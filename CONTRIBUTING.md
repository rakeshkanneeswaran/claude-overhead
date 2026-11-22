# Contributing to Claude Overhead

Thank you for your interest in contributing! Claude Overhead values small,
safety-backed changes.

## Getting Started

### Prerequisites

- macOS 14 or newer
- A matching Swift 6.0 toolchain (Xcode or Command Line Tools)
- Git

### Development Setup

```sh
git clone https://github.com/rakeshkanneeswaran/claude-overhead.git
cd claude-overhead

# Run the check suite (framework-independent core + loopback verification)
make check

# Run the Swift Testing suites (works with the Command Line Tools)
make test

# Build the app bundle and open it
make app
open "dist/Claude Overhead Dev.app"
```

### Project Structure

| Directory | Purpose |
|:---|:---|
| `Sources/ChimloCore` | Pure domain values, reducer, display math, and every testable rule: insights, settings, notification policy, history, git and GitHub |
| `Sources/ChimloProtocol` | Authenticated loopback transport and framing |
| `Sources/ChimloApp` | AppKit lifecycle, NSPanel, SwiftUI island and companion window, services wiring |
| `Sources/ChimloCLI` | Hook executable and development event injection |
| `Sources/ChimloChecks` | Framework-independent verification suite |
| `Tests/` | Swift Testing suites for Core and Protocol |
| `Integrations/` | Claude Code hook configuration fragment |
| `Docs/` | Architecture, protocol spec, and agent hook guides |

📖 See [Docs/ARCHITECTURE.md](Docs/ARCHITECTURE.md) for a detailed layer breakdown.

### Where code goes

`ChimloApp` is an executable target, so tests cannot import it. Put every
decision a feature makes (a mapping, a threshold, a merge rule, a parser) in
`ChimloCore` with a Swift Testing suite, and keep `ChimloApp` to wiring and
views. `ChimloCore` does no networking itself: inject a transport, as
`GitHubClient` does.

## Before Opening a Pull Request

1. **Keep agent-specific formats behind an adapter boundary.**
2. **Add Core tests** for every new event path, rule, or parser.
3. **Include asset provenance** for art, sound, or type changes.
4. **Run `make test`** with a matching Swift and macOS SDK.
5. **Exercise every changed control** with keyboard and pointer input.
6. **Check Reduce Motion, Increase Contrast,** and a display without a notch.

## What Not to Include

Do not include API keys, prompts, transcripts, terminal history, signed license
data, or extracted files from another application in issues, PRs, or fixtures.

## Issue Labels

| Label | Use for |
|:---|:---|
| `bug` | Something isn't working as expected |
| `enhancement` | New feature or improvement |
| `good-first-issue` | Approachable for new contributors |
| `documentation` | Docs improvements |
| `accessibility` | Keyboard, Reduce Motion, VoiceOver |

## Code Style

- Follow the existing Swift style in the codebase
- Use Swift's structured concurrency (`async`/`await`, actors)
- Keep layers isolated: `ChimloCore` must not import AppKit or SwiftUI, or use URLSession
- Run external tools with `Process` and fixed argument lists (see `CommandRunner`), never through a shell
- Never log tokens, prompts, or transcript content

## Need Help?

Open a [Discussion](https://github.com/rakeshkanneeswaran/claude-overhead/discussions) for questions,
ideas, or anything that isn't a clear bug or feature request.
