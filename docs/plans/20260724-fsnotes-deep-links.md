# fsnotes deep links

## Overview

Teach the fsnotes plugin about the `fsnotes://` URL scheme so Claude can emit
clickable deep links into the FSNotes app:

- link to an **existing** note (`fsnotes://find?id=<title>`) — opens the note
  by title/filename; falls back to the search field when nothing matches,
- **open-or-create** a note (`fsnotes://open/?title=<title>`, optional
  `&txt=` appends text on open),
- select a **tag** in the sidebar (`fsnotes://open/?tag=<tag>`),
- **create** a note (`fsnotes://new/?title=<title>&txt=<text>`, optional
  `folder=<notebook>`).

The routing lives in FSNotes's `AppDelegate+URLRoutes.swift`; iOS registers
the same schemes. The nvALT aliases (`nv://`, `nvalt://`) are out of scope.

A new `scripts/fsnotes-link.sh` builds these URLs with proper
percent-encoding. Default output is a markdown link
`[Title](fsnotes://find?id=Title%20Here)`; an `--osc8` flag instead wraps the
visible text in OSC 8 escape sequences
(`\e]8;;URI\e\` … `\e]8;;\e\`) for terminals that hyperlink arbitrary
schemes (e.g. kitty). The SKILL.md gains a deep-links section telling Claude
when to emit which link, and the `fsnotes-search` agent returns each hit with
a `fsnotes://find` markdown link so results are directly clickable.

Terminal support facts (from kitty and agterm sources, verified 2026-07-24):

- OSC 8 is scheme-agnostic in kitty; clicking hands the URI to macOS `open`,
  which routes `fsnotes://` to the app. Plain-text `fsnotes://…` is NOT
  auto-detected by kitty (`url_prefixes` allowlist has no `fsnotes`).
- agterm's `LinkPolicy` permits only http/https/mailto/ftp (file:// reveals
  in Finder); any other scheme — including `fsnotes://` — is silently
  ignored. Making it clickable there requires an agterm change (see
  Post-Completion).

## Context (from discovery)

- Files/components involved:
  - `plugins/fsnotes/skills/fsnotes/SKILL.md` — operation playbook; gains a
    deep-links section and a scripts-reference entry.
  - `plugins/fsnotes/agents/fsnotes-search.md` — search subagent; output
    format gains a per-hit `fsnotes://find` link.
  - `plugins/fsnotes/scripts/fsnotes-lib.sh` — shared helpers
    (`resolve_notes_dir`, `guard_notebook`, `sanitize_title`); gains a
    `urlencode` helper.
  - `plugins/fsnotes/scripts/fsnotes-link.sh` — NEW link builder.
  - `tests/fsnotes_test.sh` — pure-bash test suite (no framework,
    `assert`/`assert_eq` helpers, `make_fixture` builds a temp store).
- Related patterns found: scripts source `fsnotes-lib.sh` via
  `$(dirname "$0")`, honor `FSNOTES_DIR`, print errors to stderr with a
  `fsnotes:` prefix and non-zero exit; notebook input goes through
  `guard_notebook`; SKILL.md references scripts as
  `"${CLAUDE_PLUGIN_ROOT}/scripts/<script>.sh"`.
- Dependencies identified: none new — pure bash. `shellcheck` must pass on
  edited shell files (repo convention).
- Repo constraint: public repository — no personal data in examples; use
  placeholder titles/paths.

## Development Approach

- **Testing approach**: TDD (tests first) — write failing tests in
  `tests/fsnotes_test.sh`, then implement to green.
- Complete each task fully before moving to the next.
- Make small, focused changes.
- **CRITICAL: every task MUST include new/updated tests** for code changes in
  that task; success and error scenarios both covered.
- **CRITICAL: all tests must pass before starting next task** — no exceptions.
- **CRITICAL: update this plan file when scope changes during implementation.**
- Run tests after each change (`tests/fsnotes_test.sh`).
- Maintain backward compatibility (existing scripts' CLIs unchanged).

## Testing Strategy

- **Unit tests**: extend `tests/fsnotes_test.sh` (pure bash, exits non-zero
  on first failure). Cover `urlencode`, every `fsnotes-link.sh` route, the
  `--osc8` flag, and error cases. Doc-shaped checks (SKILL.md / agent md
  mention the new script and routes) follow the suite's existing
  `contains`/`frontmatter` helper style.
- **E2E tests**: none in this repo — not applicable.
- **Linter**: `shellcheck` on `fsnotes-link.sh`, `fsnotes-lib.sh`, and
  `tests/fsnotes_test.sh` after edits.

## Progress Tracking

- Mark completed items with `[x]` immediately when done.
- Add newly discovered tasks with ➕ prefix.
- Document issues/blockers with ⚠️ prefix.
- Update plan if implementation deviates from original scope.
- Keep plan in sync with actual work done.

## What Goes Where

- **Implementation Steps** (`[ ]` checkboxes): code, tests, docs in this
  repo.
- **Post-Completion** (no checkboxes): manual click-testing in real
  terminals, agterm LinkPolicy change.
- Checkboxes only in Task sections.

## Implementation Steps

### Task 1: Add urlencode helper to fsnotes-lib.sh

- [x] add tests to `tests/fsnotes_test.sh` for `urlencode`: passthrough of
      unreserved chars (`A-Za-z0-9.~_-`), space → `%20`, `&`, `?`, `#`, `/`,
      `%` escaping, and a multi-byte UTF-8 title (e.g. `Заметка`) encoding
      per-byte
- [x] implement `urlencode` in `plugins/fsnotes/scripts/fsnotes-lib.sh`
      (pure bash; iterate bytes under `LC_ALL=C` so UTF-8 encodes correctly)
- [x] run `tests/fsnotes_test.sh` — must pass
- [x] run `shellcheck` on `fsnotes-lib.sh` and the test file — clean

### Task 2: Create fsnotes-link.sh link builder

CLI: `fsnotes-link.sh [--osc8] <route> <args…>` with routes:

- `find <title>` → `fsnotes://find?id=<enc>`
- `open <title> [--txt <text>]` → `fsnotes://open/?title=<enc>[&txt=<enc>]`
- `tag <tag>` → `fsnotes://open/?tag=<enc>`
- `new <title> [--txt <text>] [--folder <notebook>]` →
  `fsnotes://new/?title=<enc>[&txt=<enc>][&folder=<enc>]`

Default output: `[<title>](<url>)` markdown link (link text is the raw
title/tag). With `--osc8`: `\e]8;;<url>\e\<title>\e]8;;\e\` followed by a
newline. `--folder` goes through `guard_notebook`. Empty/missing title, an
unknown route, or unknown flags → `fsnotes:`-prefixed stderr message, exit 1.

- [x] add tests: markdown output for each route (`find`, `open`,
      `open --txt`, `tag`, `new`, `new --txt --folder`), space and `&` in a
      title encode correctly inside the URL but stay raw in the link text
- [x] add tests for `--osc8` output (assert exact escape framing with
      `printf`-built expected string)
- [x] add error-case tests: no args, unknown route, empty title, reserved
      folder (`new … --folder Trash` fails via `guard_notebook`), unknown
      flag
- [x] implement `plugins/fsnotes/scripts/fsnotes-link.sh` (executable,
      sources `fsnotes-lib.sh`; no notes-dir resolution needed — links are
      title-based)
- [x] run `tests/fsnotes_test.sh` — must pass
- [x] run `shellcheck` on `fsnotes-link.sh` — clean

### Task 3: Teach SKILL.md the deep links

- [x] add doc-shaped tests to `tests/fsnotes_test.sh`: SKILL.md mentions
      `fsnotes-link.sh`, `fsnotes://find`, `fsnotes://new`, and `--osc8`;
      scripts-reference section lists the new script
- [x] add a "Deep links" section to
      `plugins/fsnotes/skills/fsnotes/SKILL.md`: when referencing an
      existing note in a reply, emit a `find` link via `fsnotes-link.sh`;
      when suggesting a note that doesn't exist yet, emit a `new` (or
      `open`) link; when pointing at a tag, emit a `tag` link; always build
      links with the script (never hand-encode); note that markdown output
      is the default and `--osc8` is for terminals that hyperlink arbitrary
      schemes
- [x] update the "Scripts reference" list with
      `fsnotes-link.sh [--osc8] <route> <args…>`
- [x] run `tests/fsnotes_test.sh` — must pass

### Task 4: Link-enabled search agent output

- [ ] add doc-shaped tests: `agents/fsnotes-search.md` mentions
      `fsnotes-link.sh` and `fsnotes://find`
- [ ] update `plugins/fsnotes/agents/fsnotes-search.md` "What to return":
      after the hit list, append one markdown `find` link per distinct
      matched note, built with
      `"${CLAUDE_PLUGIN_ROOT}/scripts/fsnotes-link.sh" find <title>` where
      the title is the hit's filename without the `.markdown` extension;
      keep the hit-list format itself unchanged
- [ ] run `tests/fsnotes_test.sh` — must pass

### Task 5: Verify acceptance criteria

- [ ] verify all requirements from Overview are implemented (all four
      routes, markdown default, `--osc8`, SKILL.md guidance, agent links)
- [ ] verify edge cases are handled (UTF-8 titles, `&`/`?` in titles,
      reserved folders, empty input)
- [ ] run full test suite: `tests/fsnotes_test.sh` and the other suites in
      `tests/` — all pass
- [ ] run `shellcheck` on all touched shell files — clean
- [ ] grep the diff for personal data (usernames, real note titles, private
      paths) — none introduced

### Task 6: Update documentation

- [ ] update `README.md` if it describes the fsnotes plugin's capabilities
- [ ] bump the plugin version in
      `plugins/fsnotes/.claude-plugin/plugin.json` if the repo convention is
      to version plugin changes (check dotfiles plugin history)

## Technical Details

- **URL formats** (from FSNotes `AppDelegate+URLRoutes.swift`):
  - `fsnotes://find?id=Note%20Title` — open by title/filename; falls back
    to the search field on no match. Same format the app generates for
    `[[wiki links]]`.
  - `fsnotes://open/?title=Note%20Title[&txt=…]` — open, creating if
    missing; `txt` appends on open.
  - `fsnotes://open/?tag=work` — select tag in sidebar.
  - `fsnotes://new/?title=…&txt=…[&folder=…]` — create a note.
- **Percent-encoding**: encode everything except `A-Za-z0-9.~_-` (RFC 3986
  unreserved). Spaces become `%20`. Iterate the string byte-wise under
  `LC_ALL=C` so multi-byte UTF-8 is encoded per byte
  (`printf -v c '%%%02X' "'$c"`).
- **OSC 8 framing**: `ESC ] 8 ; ; URI ESC \` opens, text, `ESC ] 8 ; ; ESC \`
  closes. Only ASCII printable chars are allowed inside the OSC payload —
  guaranteed here because the URI is fully percent-encoded. No `id=` param
  needed (single-run links).
- **Processing flow**: `fsnotes-link.sh` parses `--osc8` + route, validates
  args, `urlencode`s each query value, assembles the URL, prints markdown or
  OSC 8 form. No filesystem access except `guard_notebook` (string-only).

## Post-Completion

**Manual verification:**

- In kitty (or another OSC-8 terminal): run
  `fsnotes-link.sh --osc8 find "Some Note"` and click the output — FSNotes
  should open the note. Verify `open "fsnotes://find?id=…"` works as a
  baseline.
- In Claude Code's own renderer: confirm how markdown `fsnotes://` links are
  displayed and whether they are clickable there.

**External system updates:**

- agterm ignores non-web schemes (`LinkPolicy.swift` permits only
  http/https/mailto/ftp). To make `fsnotes://` clickable in agterm, its
  LinkPolicy would need an allowlist entry or a user-configurable scheme
  list — a change in the agterm project, not this repo.
