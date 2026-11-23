---
name: session-park
description: >-
  Park the current Claude Code session so it can be resumed later: add its
  directory and `claude --resume <id>` command to the top of the user's
  FSNotes note that lists unfinished Claude sessions, unless the session is
  already there. Use when the user says "park this session", "save this
  session for later", "add this to my unfinished sessions", or wants to stop
  now and come back to this work. Needs the `fsnotes` plugin.
allowed-tools: Bash, Read, Write, Skill, Task
---

You record the current session in the user's note of unfinished Claude
sessions. The note is a list of entries, newest first, each in this shape:

````
## <short title>
```bash
cd <directory the session started in>
claude --resume <session ID>
```
````

The check for an existing entry and the insert are done by a deterministic
script, `P` below. `R` is the plugin root: `${CLAUDE_PLUGIN_ROOT}` when
installed as a plugin, otherwise two levels above this skill's base directory
(e.g. a skill symlinked into `~/.claude/skills/`).

```sh
R="${CLAUDE_PLUGIN_ROOT:-<this skill's base directory>/../..}"
P="$R/scripts/session-park.sh"
"$P" <command> <args...>
```

The script finds the session ID (`CLAUDE_CODE_SESSION_ID`) and the directory
the session started in (from the session transcript) by itself. Do not work
them out by hand and do not edit the note yourself to add the entry.

## Steps

1. **Find the note with the `fsnotes` skill.** Invoke the `fsnotes:fsnotes`
   skill (`fsnotes` when that one is also a symlinked skill) and follow its
   search playbook: a `title` search for `unfinished claude sessions`. If the
   user named a different note, search for that one instead.
   - **Several hits:** use the most recently modified note
     (`ls -t <paths> | head -1`).
   - **No hit:** try a `text` search for `claude --resume`. Use a hit only if
     the note is clearly a list of sessions, not a note that mentions the
     command in passing. If there is still no list, create one with the
     `fsnotes` create playbook: title `Unfinished Claude sessions`, body just
     the `# Unfinished Claude sessions` line. Tell the user you created it.
2. **Write a title.** A few words that say what this session is about, under
   one line, specific enough to recognise in a long list (for example
   `billing: retry webhook deliveries`). If the list prefixes titles with a
   project name, do the same.
3. **Park the session.**

   ```
   "$P" add "<note-path>" "<title>"
   ```

   `<note-path>` is the absolute path of the note, or the path relative to
   the notes directory as the search printed it.
4. **Report the result** in one line, with an `fsnotes://` link to the note
   built by the `fsnotes` skill's link script:
   - `parked: <title>` — the entry is now at the top of the note.
   - `already parked: <heading>` — the note already holds this session; it
     was not changed. Say under which heading it is.

## Script reference

- `session-park.sh add [--session-id ID] [--dir DIR] <note-path> <title>` —
  add the entry below the note's `# Title` line unless the note already
  holds the session ID. Never writes a second entry for the same session.
- `session-park.sh info [--session-id ID] [--dir DIR]` — print `id=…` and
  `dir=…` without touching any note; use it to answer "what is this
  session's ID?".

Exit codes: 0 ok (parked or already parked), 1 runtime error (no session ID,
note not found), 2 usage error.

If the script reports that `CLAUDE_CODE_SESSION_ID` is unset, pass the ID
with `--session-id`; this session's ID is `${CLAUDE_SESSION_ID}`. If it warns
that there is no transcript, the entry uses the current directory: pass
`--dir` with the directory the session started in when you know it differs.
