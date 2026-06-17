---
name: fsnotes
description: >-
  Search, create, edit, and delete notes in the user's FSNotes store. Use
  whenever the user wants to find a note, jot one down, append to or change
  an existing note, or remove one ("find my note about X", "make a note",
  "add to my X note", "delete that note"). Knows FSNotes conventions:
  `.markdown` files, a `# Title` first line, notebooks as subfolders, inline
  `#hashtags`, and reserved `Trash/`/`files/` folders.
allowed-tools: Bash, Read, Edit, Write, Task
---

You manage the user's FSNotes notes. FSNotes is a macOS/iOS notes app that
stores each note as a plain Markdown file in an iCloud folder. This skill
wraps that store so you can search and edit it without guessing its layout.

## Conventions (how the store is shaped)

- **Files:** each note is a `.markdown` file (not `.md`).
- **Title:** the first line is a `# Title` heading; the filename usually
  matches the title.
- **Notebooks:** subfolders are notebooks. A note inside `Foo/` belongs to
  the `Foo` notebook. Notebook names are **discovered at runtime** from the
  store — never assume or hardcode any.
- **Tags:** tags are inline `#hashtags` in the body. There is no YAML
  frontmatter and no separate tags field.
- **Reserved folders:** `Trash/` (deleted notes) and `files/` (attachments)
  are never treated as notebooks and are excluded from searches.

The scripts below resolve the notes directory themselves (honoring a
`FSNOTES_DIR` override, otherwise the iCloud path). Always invoke them by
their absolute path under the plugin's scripts dir:

```
"${CLAUDE_PLUGIN_ROOT}/scripts/<script>.sh"
```

## Operation playbook

### Search → delegate to the `fsnotes-search` subagent

For any "find / look up / which note" request, dispatch the
`fsnotes-search` subagent via the Task tool rather than searching yourself.
It runs `scripts/fsnotes-search.sh <mode> <query> [notebook]` and returns a
compact hit list (`relative/path:line`) without dumping note bodies. Pick
the mode from the request — `text` (body), `title` (heading/filename),
`tag` (`#hashtag`), or `folder` (restrict a body search to one notebook) —
and pass a notebook when the user scopes the search to one. Open a matched
note with `Read` only when the user wants its contents.

### Create → `fsnotes-newpath.sh` then `Write`

1. Run `scripts/fsnotes-newpath.sh <title> [notebook]` to get the absolute
   target path. It sanitizes the title and **refuses to overwrite**: a
   non-zero exit means a note with that title already exists. Surface that
   conflict to the user (offer a different title or to edit the existing
   note) — do not force it.
2. `Write` the note to the returned path. Start the body with a
   `# Title` line matching the requested title. Add `#hashtags` only if the
   user asked for them — never invent tags.

### Edit → locate, then `Edit` in place

Find the note first (use the search subagent if the user named it loosely),
then `Edit` the file directly to append or change content, preserving the
`# Title` line. If more than one note could match, confirm which one with
the user before editing.

### Delete → `fsnotes-trash.sh`

Run `scripts/fsnotes-trash.sh <note-path>` to move the note into the
store's `Trash/` (created on demand; collisions get a numeric suffix). This
never hard-deletes, mirroring FSNotes's own delete. Relative paths resolve
against the notes dir; absolute paths are used as-is.

## Scripts reference

- `scripts/fsnotes-search.sh <mode> <query> [notebook]` — search.
- `scripts/fsnotes-newpath.sh <title> [notebook]` — safe path for a new note.
- `scripts/fsnotes-trash.sh <note-path>` — move a note to `Trash/`.
- `scripts/fsnotes-lib.sh` — sourced by the others; not called directly.
