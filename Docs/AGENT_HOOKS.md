# Claude Code sessions

Claude Overhead combines three local signals so a running session does not
disappear just because one of them is unavailable:

- terminal process liveness and working-directory discovery
- incremental metadata-only reads of recent Claude Code JSONL records
- Claude Code's documented command hooks

All reconciliation happens on this Mac. Claude Overhead does not use Keychain or
upload session data. Claude Code questions and tool permissions can be answered
in Claude Overhead, with Claude Code's native UI as the fallback.

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

The JSONL scanner follows the same boundary. It extracts only session ID,
workspace path, model label, timestamp, and lifecycle record type. Reads are
incremental after the first bounded scan. Prompt bodies, assistant content,
tool arguments, tool results, and file contents never enter Claude Overhead's
session model or local session cache.

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
require an explicit Send action. **Answer in Claude Code** releases the hook
without an answer so the native prompt takes over.

Claude Code tool permissions show the real bounded action preview with
**Deny**, **Allow Once**, and **Allow All**. Allow All always stays in memory
for the current session. Claude Overhead prefers Claude's own suggestion,
narrows its destination to `session`, and uses Claude's `acceptEdits` session
mode for file changes when no compatible suggestion exists. Persistent settings
changes and `bypassPermissions` are never surfaced or returned.

A missing app, timeout, malformed payload, or transport error can never imply
approval or fabricate an answer.

The helper reserves stdout for Claude Code's hook response. It emits `{}` for
observation and for any unanswered question or permission fallback, and exits
successfully even when Claude Overhead is unavailable.
