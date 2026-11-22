# Claude Code sessions

Claude Overhead combines three local signals so a running session does not
disappear just because one of them is unavailable:

- terminal process liveness and working-directory discovery
- incremental metadata-only reads of recent Claude Code JSONL records
- Claude Code's documented command hooks

All reconciliation happens on this Mac. Claude Overhead never uploads session
data. (Its only Keychain item is an optional GitHub token; see
[ARCHITECTURE.md](ARCHITECTURE.md).) Claude Code questions and tool permissions
can be answered in Claude Overhead, with Claude Code's native UI as the
fallback.

A fourth, optional signal is `claude agents --json`, Claude Code's own listing
of live interactive and background sessions. Claude Overhead runs it every 15
seconds when the Claude Code command line is installed.

The packaged helper is:

```text
~/Library/Application Support/Overhead/bin/overhead
```

The app refreshes this stable copy from the signed app bundle, so moving or
renaming `Claude Overhead.app` does not break an installed hook.

The helper reads one hook payload from standard input, keeps only the opaque
session ID, project basename, model label, hook kind, and safe tool category,
and sends that small event to Claude Overhead's authenticated loopback
listener. Prompt text, assistant text, transcript paths, tool inputs, tool
outputs, environment values, and file contents are not retained. The one
deliberate exception is Claude Code's blocking owner interactions: an
`AskUserQuestion` prompt and its choices, or a `PermissionRequest` tool name,
path, and bounded action preview, live in memory only while Claude is waiting.
They are never written to Claude Overhead's session cache or archive.

The `PreToolUse` observer turns the tool name into a live activity label
("Running a command", "Reading files", "Searching", "Delegating to agents"),
and `UserPromptSubmit` and `PostToolUse` mean "Thinking". Tool inputs are not
kept.

The JSONL reader extracts session metadata (session ID, workspace path, model,
timestamps, lifecycle) and, for the insights shown in the notch and companion
window, a bounded set of facts: token usage and prompt-cache counters, context
compactions, the git branch Claude Code recorded, subagent launches (their
description, type and model, never their prompt), linked pull requests, the
reported cost and line counts, the paths of files Claude edited, and test-runner
commands with environment assignments removed. Reads are incremental after the
first bounded scan (a 128 KB head plus a 2 MB tail). Tool results and file
contents are never read into Claude Overhead's model.

The session list shows your latest prompt and Claude's latest reply, as Claude
Code's transcript has them. Session history keeps them only while
**Settings → Privacy & Data → Keep your last prompt and Claude's last reply**
is on.

## Configure Claude Code

Use **Connect** beside Claude Code in Claude Overhead Settings to preview and
add Claude Overhead's marked hooks to `~/.claude/settings.json`. The merge
preserves every existing hook, keeps one backup of the original file
(`settings.json.overhead-backup`), validates the result, and can remove only
Claude Overhead's marked entries.
[`Integrations/claude-hooks.json`](../Integrations/claude-hooks.json) is also
available as a manual merge fragment. Replace `/Users/YOU` with the local home
path and never replace the whole settings file.

Observation hooks are asynchronous where Claude Code supports it. Claude
Overhead also adds one narrow, synchronous `PreToolUse` hook matching only
`AskUserQuestion`. It waits for a choice in Claude Overhead and returns the
original question plus the selected answer through Claude Code's documented
`updatedInput` contract. If Claude Overhead is closed, unreachable, or times
out, the hook returns no decision and Claude Code shows its native question UI.
A second narrow, synchronous hook handles `PermissionRequest` in the same way.

Connecting also installs a reversible status-line bridge. It passes Claude
Code's status-line JSON to any status line you already had, unchanged, and
caches only the `rate_limits` part for the usage display. Disconnecting
restores your original status line.

## Questions and permission behavior

Claude Code multiple-choice questions can be answered directly in Claude
Overhead. A single-select choice is sent immediately; multi-select questions
require an explicit Send action. **Other…** opens a text field for a typed
answer, the same as Claude Code's own "Other": it must be non-blank and at most
1,000 characters, or the hook falls back to Claude Code. **Answer in Claude
Code** releases the hook without an answer so the native prompt takes over.

Claude Code tool permissions show the real bounded action preview with
**Deny**, **Allow Once**, and **Allow All**. Allow All always stays in memory
for the current session. Claude Overhead prefers Claude's own suggestion,
narrows its destination to `session`, and uses Claude's `acceptEdits` session
mode for file changes when no compatible suggestion exists. Persistent settings
changes and `bypassPermissions` are never surfaced or returned.

A request leaves the notch as soon as Claude Code stops waiting for it: when
you answer in the terminal, interrupt the turn, or the session ends, Claude
Code stops the helper, its connection closes, and Claude Overhead cancels the
request without answering it. In `dontAsk` and `bypassPermissions` modes, where
you chose never to be asked, permission requests are left to Claude Code and
never reach the notch. Claude Code's idle notices ("Claude is waiting for your
input") are not questions and never become one.

A missing app, timeout, malformed payload, or transport error can never imply
approval or fabricate an answer.

The helper reserves stdout for Claude Code's hook response. It emits `{}` for
observation and for any unanswered question or permission fallback, and exits
successfully even when Claude Overhead is unavailable.
