# Changelog

All notable changes to Claude Overhead are documented in this file. Entries
before 1.0.0 are from [Chimlo](https://github.com/kraten/chimlo), which Claude
Overhead is forked from.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/2.0.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.5.0] - 2026-11-27

A finished turn can now play a sound of its own, from 33 sounds in five
groups, each with a preview.

- **33 completion sounds.** Settings, Notifications & Sound, has a new
  Completion sound section: Victory & Achievement (a fanfare, Mission
  Complete, Level Up, Achievement Unlocked and more), Retro & Gaming (Coin,
  Power-Up, Extra Life, Stage Clear), Minimal & Professional, Futuristic &
  Cinematic, and Fun & Playful. Every sound has a play button, so you can
  hear it before you choose it; clicking a sound chooses it. The new sounds
  are original, made by Claude Overhead itself, short, and matched in
  loudness, so the volume setting means the same for all of them.
- **Your sounds are kept.** Until you choose a completion sound, a finished
  turn plays the alert sound, exactly as before. The five existing sounds
  are all in the collection, the alert sound for requests, questions and
  failures is unchanged (now labelled Alert sound), and the volume, the
  per-session bells and the completion glow work as they did. Turning on a
  session's bell plays your completion sound, so you hear what that session
  will play.

## [1.4.0] - 2026-11-27

Claude Overhead can now hide outside the notch, for fullscreen video and
anything else where it would distract, and come back with one click.

- **Hide Claude Overhead outside the notch.** A new eye button beside the
  usage readout in the open notch hides everything beside the camera, for
  fullscreen video, films and anything else where it would distract. Hidden,
  the closed notch draws nothing outside the physical notch: no character,
  no activity line, no signals, no completion glow, in any layout and in
  fullscreen apps. It does not open on hover, a failure or an update notice;
  click inside the notch to open it, and click the eye again to show Claude
  Overhead as before. Sessions are still watched and sounds you turned on
  still play. A permission request or question is never hidden: Claude is
  waiting for it, so it shows as it does today, and Lock Mode still decides
  whether the notch opens on it. Hidden is separate from the layouts and from
  Lock Mode, is kept across restarts, and is also in Settings, General,
  Behaviour, and in the notch's right-click menu.

## [1.3.0] - 2026-11-25

Settings has been redesigned from the sidebar in: every pane is built the
same way, a search field finds any setting, and the characters, the notch
layouts and the glow are shown, not described. Every setting you had keeps
the value you gave it.

- **Settings has been redesigned.** Opening Settings turns the window's
  sidebar into the Settings sidebar, with Back to the page you came from at
  its top, in place of the row of tabs across the window. Every pane is
  built from the same parts: a heading, a group of rows with the system's own
  switches, menus and sliders, and the longer explanation behind a small
  information button instead of a paragraph under each group. Every setting
  that existed is still there and keeps the value you gave it; nothing about
  how settings are stored changed.
- **Search in Settings.** A search field at the top finds a setting by name
  or by a word for it (glow, volume, repository, quiet hours, shortcut,
  characters) and takes you to it. ⌘F puts the cursor there.
- **Characters & Mascots, in Settings → Appearance.** All 46 characters are
  shown from their own artwork, by world, with a larger preview of the one
  you click. Choose the session to dress and give it a character, or the
  Claude logo back, from there. It sets exactly what clicking a session's
  logo in the notch sets, and the notch's picker works as before. Automatic
  characters (still off until you turn them on) and each project's own
  collection are in the same place.
- **Appearance shows instead of describing.** Each notch layout is drawn as
  the closed notch looks in it, and the completion glow, colour themes and
  the accessibility settings Claude Overhead follows each have their own
  group, reachable from links at the top of the page.
- **Notifications & Sound** is one pane: the sound, then one table of events
  with a column each for showing, sound and banner, GitHub's events
  included.
- **Settings → GitHub lists repositories under their owner.** Each owner
  opens and closes, says how many of its repositories are selected, and has
  its own All and None. Repositories with the same name under different
  owners stay separate, and the selection is still stored by GitHub's own
  ids, with Apply and Revert as before. Whether a GitHub event notifies you
  is now set in one place, Notifications & Sound.
- **Privacy starts with the short answer**, "Your data stays on this Mac",
  and keeps what is sent where (GitHub when it is on, update checks, Claude
  Code's own usage check) one click away.
- **New installations start on the Obsidian theme**, with the completion
  glow on as RGB Spectrum. This update does not change your theme: a theme
  you chose stays, and a copy that was showing Midnight because it had never
  changed a setting keeps Midnight.
- Coming back to Settings opens a pane at its top again, not at the group a
  search last landed on.
- The repository picker no longer regroups every repository once per owner
  while it draws, which matters with hundreds of repositories.
- `make settings-preview` draws every Settings pane to pictures, without
  starting the app, for looking at Settings after changing it.

## [1.2.0] - 2026-11-24

The glow that marks a finished turn is now yours to choose: ten glows, each
moving in its own way, and a switch that turns the glow off without touching
sound.

- **The completion glow has its own switch.** Settings → Appearance →
  Completion glow turns the glow off completely: no glow is started, drawn or
  timed when a turn finishes. Sound is a separate choice and is not changed by
  it. A session whose bell is on still sounds with the glow off, and the glow
  still shows for a session whose bell is off.
- **Ten glows to choose from.** RGB Spectrum is the wave the app has always
  had. The others are drawn differently, not only coloured differently:
  Golden Glow (gold with a slow shimmer), Electric Blue (rings pulsing out
  from the camera), Neon Purple (edges that breathe), Crimson Red (heat rising
  from the lower edge), Emerald Green (a beam sweeping across and back),
  Cyberpunk (pink and cyan bands crossing), Aurora (slow green and violet
  curtains), Monochrome (a still white outline) and Sunset (orange through
  pink to purple). Each is shown as a small notch in Settings, choosing one
  plays it on the real notch, and Preview plays it again.
- The glow's brightness slider no longer goes to zero, because off is now the
  switch. If you had turned the glow off with the old slider, it stays off
  after the update.
- Turning the glow off keeps your glow and brightness for when you turn it
  back on. With macOS Reduce Motion, the Minimal animation setting, the Focus
  layout, or Focus mode reducing animations, every glow holds still, as the
  wave already did.

## [1.1.1] - 2026-11-24

Fixes an old settings window that opened by itself when Claude Overhead was
started.

- **An old "Claude Overhead Settings" window no longer opens when the app
  starts.** Opening the app from Spotlight or the Dock, or restarting the
  Mac, could bring up a small settings window (General, Agents, About) left
  over from before the companion window existed. It was the only window the
  app declared to the system, so the system presented it at launch. The app
  now declares none, and that window is gone.
- **⌘, opens the real Settings.** It used to open that old window.
- **Releases are now built, tested and published from the maintainer's Mac
  with one command.** GitHub hosts the code and the downloads and no longer
  builds or tests anything. Nothing changes for installing or updating: the
  same install command and the same signed update feed serve them. The
  command refuses a commit that is not tagged and pushed, takes the build
  number from the live feed, and runs the checks, the tests and the What's
  New checks before it publishes.
- The tests no longer depend on how fast the machine running them is: speed
  is measured as the work's own CPU time and how it grows, and no test waits
  on a short deadline.

## [1.1.0] - 2026-11-24

Sessions can wear their own pixel characters, an update now shows you what is
new before anything is downloaded, and a second full audit fixed a list of
rare failures.

- **Characters for your sessions.** A session can now wear its own pixel
  character in place of the Claude logo, so sessions are easy to tell apart.
  There are 46, all drawn for Claude Overhead, in four worlds: Animals,
  Elementals, Fantasy World and Cyber World. The Claude logo stays the
  default: nothing changes until you choose a character.
- **Pick one in the notch.** Click a session's Claude logo (or its character)
  to open a picker inside the notch, grouped by world. Choosing a character
  replaces the logo for that one session at once; "Claude logo" switches it
  back, and "Surprise me" draws a random one. Your pick is kept through
  refreshes, restarts and a resume.
- **Automatic characters, if you want them.** **Settings → Appearance → Give
  sessions a character automatically** is off by default. Turned on,
  each new session gets a random character, different from the other open
  sessions where it can; when the session ends the character is free again.
  Turned off again, those sessions go back to the Claude logo and the
  characters you picked yourself stay.
- **Project collections.** On the Projects page, or in **Settings →
  Appearance**, choose which characters automatic assignment may give a
  project's sessions. A project without a collection draws from all 46.
  Changing a collection never changes a character a running session already
  wears, and you can still pick any character by hand.
- Characters bob while Claude works, and take a raised pose (or hop) when it
  is your turn, as the Claude logo does.
- **See what's new before you update.** When **Check for Updates** finds a
  newer version, a What's New window opens on it: a card for each change,
  sorted into new features, improvements and bug fixes, with the notch, the
  characters or a before-and-after drawn where that shows the change. Nothing
  is downloaded until you click **Update Now** there, and it installs exactly
  the version you were reading about: the notes travel inside the signed
  update feed, in the same entry as the download. A background check still
  shows its row in the notch; the row now opens What's New.
- **Settings says where updates stand** in one row: up to date, an update on
  offer, the progress of one being installed, or what went wrong and a way to
  try again. A **What's New** button there reopens the notes of the
  version you have.
- **Trying again after a failed update check no longer installs by itself.**
  When the update feed failed to load, **Retry** downloaded and installed
  whatever the next check found. It now offers the update with its What's
  New like any other check; only an update you had already started is retried
  straight through, and only that same version.
- **Every release now ships its What's New.** The release process refuses a
  version without its notes, checks that the feed carries exactly them, and
  has the packaged app draw every page before anything is published.
- **No more demo after setup.** The notch used to follow setup with a
  two-step tour: a made-up session and a made-up permission request marked
  "Demo only". That is gone. "See your notch" now opens the real notch once,
  on your own sessions, and it closes by itself. The notch only ever shows
  real sessions.
- **The placeholder session is gone too**, along with its setting, "Keep the
  preview session after setup". It appeared when the app could not start
  listening for Claude Code. The empty notch now says so in words: "Claude
  Overhead can't listen right now. It keeps retrying."

A second full audit of the app, after the character feature, found and fixed
the following. Each has a regression test where the rule can be tested.

- **A finished session no longer turns "Failed" by itself, and a turn that
  really failed is no longer shown as finished.** Claude Code reports a failed
  request even when the request was one it made on its own while the session
  sat idle, so one bad connection painted a session that had finished an hour
  earlier red, played the attention sound and opened the notch. And a turn
  that did fail was soon overwritten as "Done", announced as finished, with
  the model shown as `<synthetic>`. Claude Overhead now takes a failed turn
  from the session's own file, where Claude Code records a failed turn and
  nothing for its own background requests.
- **"Allow All" never covers more than the card shows, and the card says what
  it covers.** A line under the buttons now reads, for example, "Allow All
  covers Bash(npm test) in this session". A card for one file, pattern or
  address (Read, Glob, Grep, an MCP tool with a path or command) has "Allow
  All" only when Claude Code suggests a rule that names it; before, it could
  allow every use of that tool. A suggestion that also covers a tool the card
  does not show is not taken, and only a file-edit card can switch the session
  to accept edits.
- **Deny answers to a click only.** With several cards open, Escape denied
  whichever one SwiftUI picked, and Escape also closes another session's
  answer field.
- **A model name could crash the app.** A model called just `claude` (a
  gateway alias) or `claude-v-2` made the session list fail every time it was
  rebuilt, and again at each launch for a day.
- **One unreadable history record no longer hides all history.** The readable
  records load, and the original file is kept beside it first. A history file
  that merely cannot be read (permissions, a disk error) is left exactly where
  it is; before, it was moved aside as if damaged.
- **A usage number far out of range in the capacity file no longer crashes
  the usage row.**
- **Large prompts and tool results are no longer dropped.** Events over 64 KB
  were ignored, so a session with a long paste never showed it had started
  working.
- **An interactive session started from inside a `claude -p` run is no longer
  taken for an unattended one.** The launch flags that were read decide; the
  inherited variable is used only when the flags cannot be read.
- **The closed notch speaks for one session.** Its mark, mood, activity line
  and wing indicators now all follow the same session, and stay with it while
  it runs instead of swapping between two sessions on every event.
- **A failed session can be archived**, the activity feed and the character
  picker never open behind a card, a notch opened on a failure respects
  "Session failures" being turned off, and anything that moves the cards
  (the usage panel, "Show all sessions") re-arms the click guard.
- **A request with an id that is already waiting is refused**, and an answered
  card is always redrawn.
- **Setup and install.** The helper copy no longer keeps a download's
  quarantine flag, a repair that fails no longer removes hooks that were
  working, and Claude Code's settings file is written with plain slashes
  (`/Users/…`, not `\/Users\/…`).
- **GitHub settings no longer read the token to check that one is stored**, so
  a Keychain prompt after an update cannot freeze the window.
- **Releases are launched once before they are published.** The release
  workflow now starts the packaged app and waits for its helper to reach it.

Known limits:

- What's New appears before an update from the update after this one. A copy
  on 1.0.8 or earlier does not have the window, so it updates to this version
  the way it always has; the notes are then behind the **What's New** button
  in **Settings → General**.
- Releases are ad-hoc signed, so macOS treats each update as a new app: the
  Keychain may ask again for a pasted GitHub token, and macOS may ask again
  for Documents or Desktop access. A Developer ID signature is the fix.
- Where the app cannot read a session's file, a failed turn is still taken
  from the hook, and only while a turn appears to be running.
- Hook changes other than the command itself (a matcher, a timeout) do not
  reach an install made by an older version until it is repaired by hand.
- A connection file left by a crash is still trusted if its process id was
  reused by another program after a restart.
- History grows with use when it is kept for ever, and is rewritten whole on
  each change.
- The 33 newest characters have no "your turn" pose of their own; they hop.

## [1.0.8] - 2026-11-23

Fixes permission cards appearing for sessions you were not at. Someone
running a batch of `claude -p` runs from a session in Auto saw a card for every
run: the cards were real Claude Code requests, but from runs with nobody to
answer them, each in its own permission mode.

- **Runs started by a script are left alone.** A `claude -p` run (or an SDK
  run with no application answering its prompts) has nobody at a Claude Code
  prompt, so Claude Code decides a call that needs approval by itself and the
  run carries on. Claude Code still runs the permission hook first, and
  Claude Overhead used to answer it with a card: every such run stopped for up
  to ten minutes behind a card nobody expected, and a batch of them filled the
  notch even while your own session was in Auto. Those requests and questions
  are now left to Claude Code, as they are without Claude Overhead.
  **Settings → General → Ask me about unattended runs** brings them to the
  notch if you want to approve them there. Sessions you are at (the terminal,
  VS Code, the desktop app) are unchanged.
- **A permission card names the session's mode** ("Manual", "Auto", "Plan",
  "Accept edits"), so a card from a session you thought was in Auto explains
  itself. Auto falls back to Manual when the model or provider does not
  support it, and a new `claude -p` run does not take the mode of the session
  that started it.

Known limits:

- Claude Overhead tells an unattended run by the flags Claude Code was started
  with. A Claude Code installed through npm can hide those flags; a run
  started from inside another session is then treated as attended and still
  gets a card, as before.
- Background sessions (`claude --bg`) and applications other than the
  terminal, VS Code and the desktop app were not tried. Anything unclear is
  treated as attended, and a wrong guess can only move a request between the
  notch and Claude Code; it never approves anything.

## [1.0.7] - 2026-11-23

A reliability release from a full audit of the app: every area was reviewed,
the fixes below were made, and each has a regression test where the rule can
be tested.

### Approving stays in your hands

- Approving is always a click. **Allow Once** and **Approve** no longer answer
  to Return: after you typed an "Other…" answer the notch could keep the
  keyboard while your terminal looked frontmost, so a Return meant for the
  terminal could allow a request. The notch now also gives the keyboard back
  when the answer field closes.
- A click counts only on the card you were looking at. Clicks are ignored for
  0.4 seconds after a card appears or moves, and each click names its request,
  so a double-click can no longer answer the next question or allow the next
  session's card that slid under the pointer.
- **Allow All** never grants more than the card shows. For a Bash command too
  long to name in a rule (over 4 KB), the session rule used to be written
  without the command, which allowed every Bash command for the session. That
  card now offers **Allow Once** and **Deny** only.
- A session with a question open can no longer be archived out of sight, and a
  session with a card open is not removed from the notch while it waits.

### Claude Code never left waiting

- If Claude Overhead quit without cleaning up (a crash, a force quit, a
  restart), Claude Code's next question or permission request waited about 10
  minutes before showing its own prompt. It now falls back at once (0.04 s
  measured). The leftover connection file of a dead app is ignored, which also
  stops another program on that port from being sent the request.
- Large file writes and edits (hook input over 64 KB) reach the notch instead
  of silently going to the terminal only.
- A listener that stops after it started is noticed and restarted.

### Your Claude Code settings

- The status line works. Its command was written to `settings.json` without
  quotes, and the path has a space in it ("Application Support"), so the shell
  never ran it. Usage therefore came only from the slower `/usage` check, and a
  status line you already had went blank after Connect. Existing installs are
  corrected the next time the app starts; your own status line is passed
  through again.
- **Disconnect** leaves a status line you set after connecting exactly as it
  is, instead of removing it or bringing an older one back.
- A `settings.json` that is a symlink (kept in a dotfiles repository) stays a
  symlink; the real file is edited.
- The settings file is not rewritten at launch when nothing changed, and never
  over a version Claude Code saved in the meantime.
- Per-model weekly limits stay on screen when the status line (which reports
  only the 5-hour and weekly limits) updates usage.

### Lighter

- After the setup window closed, its animation kept running out of sight and
  used 6 to 20% of a CPU core for as long as the app ran. It now stops; the
  idle app uses about 1 to 2%.
- Memory no longer grows with every transcript ever scanned, and the app's
  background checks no longer leave stuck threads behind.

### Notch and companion

- **Show the notch on** (General) now does what it says. On Macs without a
  notch and with two displays, the notch could stop responding to the mouse
  after you clicked a window on the other display; it now stays on one
  display.
- Leaving the first-run tour with a shortcut no longer leaves its demo session
  behind as a "WAIT" nobody can answer.
- The Focus button turns Focus off during a scheduled window (it pauses the
  schedule until that window ends).
- A first click on a card that opened under a resting pointer is no longer
  lost to the app underneath. A failed session keeps the notch open for 4
  seconds instead of half a second.
- Recording a shortcut and then clicking another row no longer swallows your
  next key press or saves it as a global shortcut.
- The "couldn't find the terminal" alert no longer freezes the notch while it
  is open. Reduce Motion and Increase Contrast changes apply without a
  restart. **Open at login** shows what macOS really has. A typed "Other…"
  answer is not carried into the next question. A receipt lists each run of
  the same test command with its own result.
- The usage check stops when the companion window is closed.

### GitHub

- Old news is no longer announced as new, and dismissed alerts stay dismissed:
  a pull request that got no review or check lookup in a refresh keeps its
  last known state instead of dropping to "unknown" and coming back.
- Notifications found in a refresh that was cut short (a rate limit, a manual
  refresh) are delivered instead of lost.
- Many monitored repositories no longer exhaust GitHub's rate limit: the
  response cache holds a whole refresh, and a rate-limited repository says so
  instead of showing old data as current.
- A revoked saved token no longer hides a working `gh` sign-in.
- A merge made in the app is counted once in the daily recap.

### History, usage and installing

- A session that died mid-turn no longer shows "Running" in History for good.
  After 12 hours without activity it is marked interrupted, and your retention
  setting then applies to it like any finished session.
- Reset times shown on the hour ("Resets 3pm") are read.
- The Terminal installer puts the new copy beside the old one and swaps them,
  so a failed copy never leaves you without the app, and it waits for the old
  copy to quit.

### Known limits

- The display choice and the keyboard hand-back were checked on one built-in
  display; a two-display setup has not been tried.
- A sandboxed command's network approval and MCP input requests are still
  answered only in Claude Code's own prompt.
- After a failed tool call the notch can keep the previous activity label
  until Claude's next step.
- With a few dozen repositories selected, a reset rate limit shows as
  "rate limit reached" on each repository until GitHub lifts it.

## [1.0.6] - 2026-11-23

- Fixed a crash: clicking **Connect GitHub**, **Choose repositories**,
  **Settings** or **Change monitored repositories** on the GitHub page quit
  the app (1.0.4 and 1.0.5). They now open Settings → GitHub as intended.
- Closed off a possible crash while looking for Claude Code processes, when
  another program's command line contains a line break.

## [1.0.5] - 2026-11-23

- A session you rename (in VS Code, or with `/rename`) shows its new name in
  the notch. Claude Code writes the name as `custom-title`, which was never
  read, so the notch kept Claude's automatic title. Your name now wins, the
  latest rename counts, and clearing it brings Claude's title back.

- Usage stays current. Claude Code's status line, the main source, may never
  run for sessions in an editor extension such as VS Code, and the `/usage`
  fallback ran only when the usage details were opened, so the notch could
  show hours-old numbers (64% after a reset to 19%). The fallback now
  freshens numbers over five minutes old whenever usage is on screen.
- The open notch always shows usage top left, in every layout.

## [1.0.4] - 2026-11-23

- Questions and permission requests in the notch have a × too. It hands the
  request back to Claude Code's own prompt in the terminal: nothing is
  answered, approved or dropped, so Claude is never left waiting unseen.

- Close a session's prompt-and-reply preview in the notch with its ×. Only the
  preview goes: the session, its conversation and history, and any pending
  request stay, and the notch stays open. A hairline shows the time left on
  the preview's own two-minute timer; a new reply shows again.
- Text is readable in every theme. The companion window took light or dark
  from macOS while the theme painted its background, so on a Mac in dark mode
  Arctic drew dark-mode white text on its light background. The theme now
  decides the window's appearance (Match System follows macOS, live), and the
  separate "Light or dark" choice is gone.

- Claude Overhead updates itself. The in-app updater never worked in any
  Claude Overhead release: the update feed and signing key were removed when
  it was forked from Chimlo and never replaced, so every attempt failed before
  reaching the network and the notch stuck on "Try update again". Releases
  now publish a signed `appcast.xml`, and the app shows each step (checking,
  downloading, verifying, installing, restarting, "Updated to …"). A failure
  says what went wrong and what to do, has **Retry** and a close button, and
  leaves the notch on its own after a minute; the installed app is never
  touched by a failed update. Copies on 1.0.3 or earlier update once with the
  Terminal command.
- Sound per session: every session starts silent, and a bell on each session
  in the notch turns its sounds on. Choose the sound, preview it and set its
  volume in **Settings → Notifications**. A burst of events from one session
  makes one sound.
- Lock Mode: the lock in the open notch keeps the notch closed until you
  click it, while every session is still watched and enabled sounds still
  play. Requests wait in the notch, never approved or dropped. The closed
  notch always shows the lock beside the GitHub badge: red and closed while
  locked, a white open lock otherwise.
- Settings is one row of seven tabs (General, Appearance, Notifications,
  Usage, Shortcuts, GitHub, Privacy) instead of a second sidebar of twelve
  panes, with nothing configured in two places. Focus mode is part of
  Notifications; layouts, themes and motion are Appearance.
- Settings → GitHub is the integration only: sign-in, repositories and what
  it watches. The GitHub page shows GitHub; until it is connected it explains
  what it offers and has a **Connect GitHub** button.
- Overview shows your Claude usage (the limit closest to running out) where
  Reported Cost was; cost stays in history and receipts.
- Forked Claude Code sessions are watched from their first moment (after
  Connect or Repair).
- Nothing waits forever any more: the local listener retries on its own if it
  fails to start (Claude Code falls back to its own prompts meanwhile), the
  `ps`, `lsof` and `claude agents` checks give up after 10 seconds instead of
  freezing session state, a GitHub job or pull request view says why it is
  empty instead of loading forever and reloads when GitHub reconnects, and a
  real request during the setup tour ends the tour instead of leaving a demo
  "WAIT" in the notch.
- **Focus terminal** explains when it can't find the session's terminal (tmux,
  SSH, Automation permission) instead of doing nothing; **Resume in Terminal**
  is offered only for sessions with no live process, once at a time.

- A permission or question card leaves the notch as soon as Claude Code stops
  waiting for it (you answered in the terminal, interrupted the turn, or the
  session ended). Before, it could stay for up to 10 minutes and keep the next
  real prompt out of the notch.
- In `dontAsk` and `bypassPermissions` modes, permission requests are left to
  Claude Code: the notch no longer asks where Claude Code would not.

## [1.0.3] - 2026-11-22

- The notch's usage panel shows how much of each limit you have used, the same
  number Claude Code's `/usage` shows, instead of how much is left. Bars fill
  as a limit is spent, and a limit you have used up reads 100%.

## [1.0.2] - 2026-11-22

- The closed notch's line of live activity under the camera can be turned off
  in **Settings → Notch Layouts → Show live activity in the closed notch**.
  It stays on by default.
- Running GitHub workflows show a turning green ring instead of a blue dotted
  circle, and running is green throughout GitHub Mode. Queued runs keep their
  clock.
- GitHub is checked every 30 seconds by default instead of every 5 minutes,
  so a new pull request or run shows up in the notch within half a minute.
  Choose a longer interval in **GitHub → Integration**; an interval you set
  before carries over.

## [1.0.1] - 2026-11-22

- Install from Terminal with one command, which checks the download's checksum
  and needs no Gatekeeper approval:
  `curl -fsSL https://github.com/rakeshkanneeswaran/claude-overhead/releases/latest/download/install.sh | bash`
- The usage panel shows per-model weekly limits, such as Fable, beside the
  all-models limit, and warns when one crosses your threshold.
- Plans without a 5-hour window no longer show an empty "5H —%" row.
- Weekly reset times parse even when Claude Code draws the panel without
  spaces between words.

## [1.0.0] - 2026-11-22

Claude Overhead's first public release: a notch companion for Claude Code.

### Highlights

- Every Claude Code session in the MacBook notch: working, waiting for your
  permission, asking a question, done, or failed. Sessions are ordered by what
  needs you first, and stale work is never shown as running.
- Live activity in Claude's own words. The closed notch shows the current tool
  call, for example `Bash · Run tests and commit the logo change`; click a
  session in the open notch for its live feed of tool calls, each with its
  command or file, time and outcome.
- Answer Claude's questions and approve or deny its tool requests from the
  notch. Nothing is ever approved silently, and if Claude Overhead is
  unavailable the question goes back to the terminal.
- GitHub Mode (⌃⌥G): pull requests, workflow runs, reviews and merging for the
  repositories you choose, with one red or amber badge on the GitHub icon for
  alerts you can dismiss.
- A companion window with sessions, projects, agents, history, usage, GitHub
  and settings; themes, five notch layouts, Focus mode and shortcuts.

### Before you install

- Requires macOS 14 or newer on an Apple silicon Mac.
- Install it with the Terminal command in the README. This build is ad-hoc
  signed, not notarized by Apple: the Terminal install opens without any
  prompt, but a DMG downloaded in a browser needs **Open Anyway** in **System
  Settings > Privacy & Security** on first launch.
- Claude Overhead runs locally. It has no telemetry and sends your prompts,
  transcripts and activity nowhere.

## [0.1.0] - 2026-07-22

Chimlo's first public release puts your local coding agents, media, and system
controls in the MacBook notch.

### Highlights

- Watch Codex and Claude Code sessions as they work, wait for input, finish, or
  fail.
- See recent agent activity, completion details, and how long each session has
  been active. Archive finished sessions or jump back into current work.
- Answer Claude Code questions and approve or deny requested actions without
  returning to the terminal.
- Check your real Codex and Claude usage windows without connecting another
  account or sharing credentials.
- View Now Playing information and control media from the notch. Chimlo gets
  out of the way during fullscreen playback and returns automatically.
- Replace the standard volume and brightness display with compact pixel-art
  feedback that matches Chimlo.
- Recognize idle, working, waiting, completed, and failed states through
  animated pixel companions.
- Follow a guided setup for Codex, Claude Code, Accessibility access, media,
  appearance, and updates.
- Check for new versions from Settings, then download, install, and relaunch
  Chimlo in one flow.
- Use Chimlo across notched displays, external monitors, fullscreen apps,
  Reduce Motion, and increased contrast settings.

### Privacy and reliability

- Chimlo runs locally and has no telemetry by default. Agent prompts,
  responses, questions, and permission details are not sent to a Chimlo
  service.
- Connecting or disconnecting an agent preserves your existing Codex and
  Claude Code configuration.
- If Chimlo is unavailable, questions and approvals return to the terminal.
  A connection problem never counts as approval.
- Updates are verified before installation, and existing Chimlo preferences
  stay in place after updating.

### Before you install

- Chimlo requires macOS 14 or newer on an Apple silicon Mac.
- Chimlo is not notarized by Apple yet. On first launch, macOS may require you
  to approve it with **Open Anyway** in **System Settings > Privacy &
  Security**.
- Accessibility permission is needed for Chimlo's volume and brightness
  controls. Agent activity remains available without it.

[Unreleased]: https://github.com/rakeshkanneeswaran/claude-overhead/compare/v1.1.1...HEAD
[1.3.0]: https://github.com/rakeshkanneeswaran/claude-overhead/releases/tag/v1.3.0
[1.2.0]: https://github.com/rakeshkanneeswaran/claude-overhead/releases/tag/v1.2.0
[1.1.1]: https://github.com/rakeshkanneeswaran/claude-overhead/releases/tag/v1.1.1
[1.1.0]: https://github.com/rakeshkanneeswaran/claude-overhead/releases/tag/v1.1.0
[1.0.8]: https://github.com/rakeshkanneeswaran/claude-overhead/releases/tag/v1.0.8
[1.0.7]: https://github.com/rakeshkanneeswaran/claude-overhead/releases/tag/v1.0.7
[1.0.6]: https://github.com/rakeshkanneeswaran/claude-overhead/releases/tag/v1.0.6
[1.0.5]: https://github.com/rakeshkanneeswaran/claude-overhead/releases/tag/v1.0.5
[1.0.4]: https://github.com/rakeshkanneeswaran/claude-overhead/releases/tag/v1.0.4
[1.0.3]: https://github.com/rakeshkanneeswaran/claude-overhead/releases/tag/v1.0.3
[1.0.2]: https://github.com/rakeshkanneeswaran/claude-overhead/releases/tag/v1.0.2
[1.0.1]: https://github.com/rakeshkanneeswaran/claude-overhead/releases/tag/v1.0.1
[1.0.0]: https://github.com/rakeshkanneeswaran/claude-overhead/releases/tag/v1.0.0
[0.1.0]: https://github.com/kraten/chimlo/releases/tag/v0.1.0
