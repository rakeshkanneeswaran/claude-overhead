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
**Settings → Privacy → Keep your last prompt and Claude's last reply**
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
restores your original status line. A status line you set yourself after
connecting is yours: Disconnect leaves it exactly as it is.

The settings file is written atomically, through a symlink if it is one (a
file kept in a dotfiles repository stays where it is), never over a version
Claude Code saved in the meantime, and only when something in it actually
changes. The first write keeps a one-time copy of your original file beside it
as `settings.json.overhead-backup`.

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
changes and `bypassPermissions` are never surfaced or returned. **Allow All**
is offered only when a rule can be written that grants what the card shows and
no more: a Bash command too long to name in a rule gets **Allow Once** and
**Deny** only, because a rule without the command would allow every command.

**Allow All** is no wider than the card. A rule suggested by Claude Code is
used only if every rule in it is for the tool on the card, and a rule with no
content (every use of a tool) is used only when the card names no command,
file, address or pattern of its own. A card for one file or pattern therefore
has **Allow All** only when Claude Code suggests a rule that names it. Only a
file-edit card can switch the session to accept edits. The card states what
**Allow All** would allow in a line under the buttons.

Approving and denying are always a click. No key answers a card, and a click
counts only if it names the request that is showing and the cards have been
still for 0.4 seconds, so a double-click can never answer the next question or
approve the next card unread.

A request leaves the notch as soon as Claude Code stops waiting for it: when
you answer in the terminal, interrupt the turn, or the session ends, Claude
Code stops the helper, its connection closes, and Claude Overhead cancels the
request without answering it. In `dontAsk` and `bypassPermissions` modes, where
you chose never to be asked, permission requests are left to Claude Code and
never reach the notch. Claude Code's idle notices ("Claude is waiting for your
input") are not questions and never become one.

### Failed turns

Claude Code runs the `StopFailure` hook whenever a request ends in an API
error. That includes requests it makes by itself for a session that is idle (a
recap for when you come back, a prompt suggestion), and the hook input does not
say which kind of request failed. Taken at face value, one bad connection
turned a session that had finished an hour earlier red.

So for a session whose file Claude Overhead reads, the file decides. Claude
Code writes a turn that ended in an API error into the session file as an
assistant line marked `isApiErrorMessage`, and writes nothing there for its
own background requests. That line marks the session failed (not finished,
although its stop reason reads like a normal end), and the failure is
announced once, when it is fresh. The hook's report is not applied for these
sessions.

Only where the app has no session file to read is the hook used, and then only
while a turn appears to be running; a failure reported for a session that is
finished, waiting on a card or unknown is dropped. Hook helpers can arrive out
of order, so a dropped failure is remembered for three seconds in case the
prompt that started the turn arrives right behind it. Events an adapter
numbers itself (`overhead emit --sequence`) are taken as sent.

### Runs nobody is watching

Claude Code runs the `PermissionRequest` hook in two situations: when it is
about to show its own prompt, and when nobody can be prompted and it would
otherwise deny the call at once. The second is a `claude -p` run, or an SDK run
with no application answering its prompts. A hook that waits for a click turns
that into a run that stops for up to ten minutes, so by default Claude Overhead
leaves these runs to Claude Code: the helper answers `{}` and the run behaves
as it does without Claude Overhead. **Settings → General → Ask me about
unattended runs** sends their permission requests and questions to the notch
instead; the card is then labelled "Unattended run".

The hook input does not say which situation it is, so the helper looks at how
the Claude Code process above it was started:

- `-p`, `--print`, `--output-format`, `--input-format` or `--sdk-url` means
  Claude Code is running without its own interface.
- `--permission-prompt-tool stdio` means an application answers its prompts
  (the VS Code extension, the desktop app, an SDK application with its own
  approval screen), so the session is attended whatever else is set.
- If the arguments cannot be read, `CLAUDE_CODE_ENTRYPOINT=sdk-cli` means a
  `claude -p` run. The variable alone is not enough: a run started from inside
  another session inherits that session's value.

Anything unclear counts as attended, which is how every session was treated
before. A wrong guess can only move a request between the notch and Claude
Code; it never approves anything. Only the launch flags are read. Arguments
are not stored, logged or sent, and the request carries one yes-or-no value.

A permission card also names the session's permission mode ("Manual", "Auto",
"Plan", "Accept edits"). Permission mode belongs to each Claude Code process: a
`claude -p` run does not take the mode of the session that started it, and
Auto falls back to Manual when the model or provider does not support it.

A missing app, timeout, malformed payload, or transport error can never imply
approval or fabricate an answer.

The helper reserves stdout for Claude Code's hook response. It emits `{}` for
observation and for any unanswered question or permission fallback, and exits
successfully even when Claude Overhead is unavailable.
