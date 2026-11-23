# Security Policy

## Reporting a Vulnerability

Claude Overhead handles authenticated local protocols and agent approval surfaces, so
security issues are taken seriously.

**Please do not open a public GitHub issue for security vulnerabilities.**

Instead, report vulnerabilities privately through GitHub: open the repository's
**Security** tab and choose **Report a vulnerability**. Include:

1. A description of the vulnerability
2. Steps to reproduce (or a proof of concept)
3. The potential impact
4. Any suggested fix, if you have one

You will receive an acknowledgment within **48 hours** and a detailed response
within **5 business days** with next steps.

## Scope

The following areas are in scope for security reports:

- **ChimloProtocol** — Authenticated loopback transport, token validation,
  message framing, descriptor storage
- **ChimloCLI** — Hook payload processing, input validation, stdout response
  format
- **ChimloApp** — Runtime descriptor access, session data handling, agent
  configuration merges
- **ChimloCore**: reducer logic affecting approval state transitions, the
  question-answer validation, history storage, and git or GitHub parsing
- **GitHub credentials**: Keychain storage of a pasted token, borrowing the
  GitHub CLI's token, and anything that could log or persist a token
- **Local history**: the history file's permissions, retention, and whether it
  can hold more than documented
- **Terminal focus and resume**: AppleScript built from session data (terminal
  device paths and session ids are validated before use)

## Out of Scope

- Issues in upstream dependencies (report those to the upstream project)
- Social engineering attacks
- Denial of service against the local loopback listener
- Issues requiring physical access to an unlocked Mac

## Supported Versions

| Version | Supported |
|:--------|:----------|
| Latest  | ✅         |
| Older   | ❌         |

## Security Design

Claude Overhead's security posture is documented in
[Docs/ARCHITECTURE.md](Docs/ARCHITECTURE.md) under "Safety boundaries." Key
principles:

- Pending decisions are keyed by request and session, not screen position
- Duplicate messages and stale sequence numbers are ignored
- Payloads and frames have explicit size limits
- Runtime descriptors are private to the local user and short-lived
- The app being offline returns control to the native terminal interaction
- A transport error never becomes an approval
- No telemetry; the only network destinations are api.github.com, and only
  while GitHub is turned on, and the signed update feed with its release
  files on github.com
- A release's What's New travels inside the signed update feed; a picture in
  it is shown only when its SHA-256 matches the one the feed pins
- A pasted GitHub token lives only in the Keychain and is never logged
- The only write to GitHub is a pull request merge the owner confirms, pinned
  to the head commit they were shown
- External tools run with fixed argument lists, never through a shell
