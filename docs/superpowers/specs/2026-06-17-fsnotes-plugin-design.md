# FSNotes Plugin — Design

**Date:** 2026-06-17
**Status:** Approved design, pending implementation plan

## Goal

Let Claude Code search, create, edit, and delete notes stored by the
[FSNotes](https://github.com/glushchenko/fsnotes) app through natural
requests ("find my note about X", "create a note titled Y", "add this
to my Z note"). The plugin encodes where FSNotes stores notes and the
conventions they follow, so Claude does not have to rediscover them each
session.

The plugin must be **universal** — usable by any FSNotes user, not bound
to one person's local folder or notebook names.

## Distribution

Shipped as a Claude Code plugin inside a personal marketplace repository
that mirrors the structure of `github.com/umputun/cc-thingz`:

```
~/src/github.com/olomix/cc-thingz/        → github.com/olomix/cc-thingz
├── .claude-plugin/
│   └── marketplace.json                  # marketplace listing fsnotes (+ future plugins)
├── plugins/
│   └── fsnotes/
│       ├── .claude-plugin/plugin.json    # plugin manifest
│       ├── skills/
│       │   └── fsnotes/SKILL.md          # search/create/edit/delete logic
│       └── agents/
│           └── fsnotes-search.md         # ripgrep/grep search subagent
├── README.md
├── LICENSE
└── .gitignore
```

Install flow for an end user:

```
/plugin marketplace add olomix/cc-thingz
/plugin install fsnotes
```

## FSNotes facts the plugin encodes

These are derived from inspecting a real FSNotes store, not assumed.

- **Notes root:** `~/Library/Mobile Documents/iCloud~co~fluder~fsnotes/Documents/`
  - The container segment `iCloud~co~fluder~fsnotes` comes from the app's
    bundle ID `co.fluder.fsnotes`; it is the same for every FSNotes user
    using iCloud, so it is safe to hardcode as the primary path.
  - **Fallback:** if that exact path does not exist, glob
    `~/Library/Mobile Documents/*fsnotes*/Documents` and use the single
    match. This survives any future container-ID change. If zero or
    multiple matches are found, ask the user for the path.
- **File extension:** `.markdown` (NOT `.md` — the store overwhelmingly
  uses `.markdown`).
- **Title:** the first line of a note is a level-1 heading `# Title`.
  There is **no YAML frontmatter**.
- **Notebooks:** any subfolder directly under `Documents/` is a notebook.
  Notebook names are discovered at runtime by listing the directory — the
  plugin hardcodes **no** notebook names.
- **Reserved folders:** `Trash/` (deleted notes) and `files/`
  (attachments) are reserved and are excluded from searches and listings.
- **Tags:** inline hashtags within note bodies (e.g. `#inbox`,
  `#project`). There is no separate tag index.

## Operations

### Search — handled by the `fsnotes-search` subagent

Runs in an isolated subagent so bulk match output stays out of the main
conversation; the subagent returns only the relevant hits (file path +
matching lines / titles).

Tool detection: prefer `rg` (ripgrep). If `rg` is not on `PATH`, fall
back to `grep -r` and tell the user **once** that installing `ripgrep`
would make searches faster and more accurate.

Supported search modes (the subagent picks based on the request):

1. **Full-text** — search note bodies. Default for "find my note about X".
2. **Title / filename** — match the first `# ` heading and the filename.
3. **Hashtag** — match inline tags, e.g. "show all #project notes".
4. **Folder-scoped** — restrict any of the above to one notebook subfolder,
   e.g. "search only in <notebook>". Notebook names are discovered, not
   hardcoded.

Searches always exclude `Trash/` and `files/`.

### Create

- Writes `Documents/<Title>.markdown` with `# <Title>` as the first line.
- Sanitizes the title into a safe filename (strips/replaces filesystem-
  unsafe characters).
- If a file with that name already exists, **do not overwrite** — surface
  the conflict and ask how to proceed (different name, edit existing, etc.).
- No automatic tags; only add hashtags if the user asks.
- Default location is the `Documents/` root. The user may name a notebook
  subfolder explicitly to create the note there.

### Edit

- Locate the target note (via the search subagent if the reference is
  ambiguous), then edit the file in place. FSNotes detects external file
  changes automatically, so no app interaction is needed.
- When the target is ambiguous, confirm which note before writing.

### Delete

- **Never hard-delete.** Move the file into the existing `Trash/` folder.
- If a same-named file already exists in `Trash/`, disambiguate rather than
  clobber it.

## Out of scope (YAGNI)

- Attachment handling (the `files/` folder).
- FSNotes encryption, pinning, or other app-managed metadata.
- Creating new notebook folders (only if explicitly requested later).
- A separate tag index or tag-management commands.

## Testing / verification

- Verify path resolution: primary path present → used; primary absent →
  glob fallback resolves; ambiguous → asks user.
- Verify `rg`-present and `rg`-absent (grep fallback) search paths.
- Verify create produces a correctly named `.markdown` file with a `# Title`
  first line, and that an existing-name conflict is surfaced, not overwritten.
- Verify delete moves a file into `Trash/` and never removes it outright.
- Confirm no local notebook names are hardcoded anywhere in the plugin.
