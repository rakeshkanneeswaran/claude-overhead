# Release notes (What's New)

One file per release: `ReleaseNotes/<version>.json`. It is what users see in
the **What's New** window before they update, and behind the **What's New**
button in Settings afterwards. Every release has one; the process and
what enforces it are in [Docs/RELEASING.md](../Docs/RELEASING.md#whats-new).

```sh
make release-notes                  # check every file here against CHANGELOG.md
make release-notes VERSION=1.2.0    # ...and that 1.2.0 is ready to publish
make whats-new VERSION=1.2.0        # draw every page to dist/whats-new/1.2.0/
```

## The file

```json
{
  "schema": 1,
  "version": "1.2.0",
  "date": "2026-12-01",
  "introduction": "One or two sentences on the release as a whole.",
  "cards": [
    {
      "id": "short-lower-case-id",
      "category": "feature",
      "title": "What changed, in a few words",
      "summary": "One or two sentences: what changed and why it matters.",
      "details": ["An optional further point.", "At most five."],
      "visual": { "kind": "sprites", "sprites": [{ "character": "animals.cat" }] }
    }
  ]
}
```

| Field | Rule |
| --- | --- |
| `schema` | `1`. |
| `version` | The release, as `1.2.0`. It must be the file's name. |
| `date` | The release date, as `2026-12-01`: the same as its `CHANGELOG.md` section. |
| `introduction` | One line, at most 280 characters. |
| `cards` | 1 to 12, in the order they are shown. Features first reads best. |
| `id` | Lower-case letters, digits and hyphens; unique in the file. |
| `category` | `feature`, `improvement` or `fix`. |
| `title` | At most 60 characters. |
| `summary` | One line, at most 240 characters. |
| `details` | Optional: 1 to 5 points of at most 200 characters. |
| `visual` | Optional. Leave it out when no picture shows the change. |

Text is plain: no Markdown, no line breaks. The whole file, once published,
must stay under 64 KB, because it travels in the update feed.

## Visuals

A visual must show the actual change. A card without one is set as a clean
text card, which is the right choice for most bug fixes.

**`sprites`**: 1 to 12 pixel characters, with an optional caption. Name one of
the app's characters and its pixels are written into the published notes, so
an older app can draw a character it does not have yet.

```json
{ "kind": "sprites", "caption": "Optional", "sprites": [{ "character": "fantasy.unicorn" }] }
```

**`notch`**: the open notch with 1 to 3 session rows, as the list shows them.
`status` is `working`, `needsYou`, `done`, `failed` or `idle`. A row may wear
a character (`sprite`, as above; the Claude logo otherwise), have a `detail`
line, and show a `permission` card.

```json
{ "kind": "notch", "caption": "Optional", "rows": [
  { "title": "api-server", "status": "needsYou",
    "permission": { "tool": "Bash", "request": "npm test",
                    "buttons": ["Deny", "Allow Once", "Allow All"],
                    "caption": "Allow All covers Bash(npm test) in this session" } }
] }
```

**`comparison`**: before and now, each with a label and 1 or 2 session rows.

```json
{ "kind": "comparison",
  "before": { "label": "Before", "rows": [{ "title": "api-server", "status": "done", "detail": "Shown as done" }] },
  "after": { "label": "Now", "rows": [{ "title": "api-server", "status": "failed", "detail": "The turn failed" }] } }
```

**`image`**: a PNG in `ReleaseNotes/<version>/`, for a real screenshot. Give
the file name and what it shows; its SHA-256 and size are filled in when the
notes are published, the file is uploaded beside the download, and the app
shows it only when the bytes match. Use real screenshots of the app only.

```json
{ "kind": "image", "image": { "file": "picker.png", "alt": "The character picker open in the notch." } }
```

Row and card texts are short on purpose (they are drawn at the notch's real
size); `make release-notes` says which one is too long.

## Compatibility

The notes of version N are drawn by the app at version N-1. So:

- Adding a visual kind or an optional field is safe: an app that does not
  know it leaves that one visual out and shows the card as text. Check how the
  card reads without it.
- Never rely on something only the new app has. That is why characters are
  written out as pixels and pictures are files.
- Raise `schema` only for a change an older app would misread. An older app
  then shows no notes for that release at all (it says so and still offers
  the update), so avoid it.
