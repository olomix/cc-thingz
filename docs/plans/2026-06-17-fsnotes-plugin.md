# FSNotes Plugin Implementation

## Overview

Build a Claude Code plugin (`fsnotes`) that lets Claude search, create,
edit, and delete notes managed by the FSNotes app, via natural requests.
The plugin ships inside a personal marketplace repository
(`github.com/olomix/cc-thingz`) mirroring the layout of
`github.com/umputun/cc-thingz`.

Design source:
`docs/superpowers/specs/2026-06-17-fsnotes-plugin-design.md`.

**Problem solved:** Claude otherwise does not know where FSNotes stores
notes (`~/Library/Mobile Documents/iCloud~co~fluder~fsnotes/Documents/`),
that the extension is `.markdown` not `.md`, that notebooks are subfolders,
that tags are inline hashtags, and that `Trash/`/`files/` are reserved.

**Key design refinement (vs. spec):** the real logic lives in small,
deterministic shell scripts under `plugins/fsnotes/scripts/`, so it can be
unit-tested. The SKILL.md and the search subagent invoke these scripts
rather than improvising shell each time. All scripts honor a `FSNOTES_DIR`
environment override (used by tests to target a fixture; unset in normal
use, where the iCloud path + glob fallback applies).

## Context (from discovery)

- **Reference layout:** `github.com/umputun/cc-thingz` — root
  `.claude-plugin/marketplace.json` lists plugins; each plugin under
  `plugins/<name>/` has `.claude-plugin/plugin.json`, plus `skills/`,
  `agents/`, optional `scripts/`. Skills are `skills/<name>/SKILL.md` with
  YAML frontmatter (`name`, `description`, optional `allowed-tools`).
  Agents are `agents/<name>.md` with frontmatter (`name`, `description`,
  `tools`, optional `model`).
- **Real FSNotes store inspected:** extension `.markdown` (140 files vs 1
  `.md`); no YAML frontmatter; first line `# Title`; subfolders are
  notebooks; `Trash/` and `files/` reserved; inline `#hashtags`.
- **Tooling:** `ralphex` installed at `/opt/homebrew/bin/ralphex`.
  `shellcheck` required after editing any shell script (user CLAUDE.md).
- **No traditional code** — logic extracted into bash scripts to make the
  plugin testable.

## Development Approach

- **Testing approach:** Regular (write script, then its bash test) — chosen:
  automated bash test script per the planning session.
- Each script-bearing task delivers the script **and** its test cases in
  `tests/fsnotes_test.sh`, plus a passing `shellcheck` run.
- Tests use a temporary fixture notes dir via `FSNOTES_DIR`; they never
  touch the real iCloud store.
- **CRITICAL:** every code task includes new/updated tests; all tests +
  `shellcheck` must pass before the next task.
- Markdown-only tasks (manifests, SKILL.md, agent) are verified by JSON/
  frontmatter validation assertions added to the test script.
- Update this plan file if scope changes.

## Testing Strategy

- **Unit tests:** `tests/fsnotes_test.sh` — pure-bash assertions, no
  framework. Each function/script gets success + error/edge cases.
- **Static checks:** `shellcheck` on every `.sh` file; JSON validity
  (`plutil -lint` or `python3 -m json.tool`) on every manifest; YAML
  frontmatter presence on SKILL.md / agent files.
- **No e2e/UI tests** — not a UI project.
- Test runner exits non-zero on first failure; tasks may not advance with a
  red suite.

## Progress Tracking

- Mark completed items `[x]` immediately when done.
- Newly discovered tasks: `➕` prefix. Blockers: `⚠️` prefix.
- Keep plan in sync with actual work.

## What Goes Where

- **Implementation Steps** (`[ ]`): all files and tests in this repo.
- **Post-Completion** (no checkboxes): pushing to GitHub, installing the
  plugin locally, and live verification against the real notes store.

## Implementation Steps

### Task 1: Marketplace and plugin scaffolding
- [x] create `.claude-plugin/marketplace.json` (`name: olomix-cc-thingz`,
      `owner.name`, `plugins: [{ name: fsnotes, source: ./plugins/fsnotes,
      description }]`)
- [x] create `plugins/fsnotes/.claude-plugin/plugin.json` (`name`,
      `description`, `version: 0.1.0`, `author`, `homepage`/`repository`
      = the cc-thingz repo, `license: MIT`)
- [x] add root `LICENSE` (MIT) and `.gitignore` (OS cruft: `.DS_Store`)
- [x] create `tests/fsnotes_test.sh` skeleton: bash strict mode, a
      `fixture` setup that builds a temp notes dir with sample
      `.markdown` notes, a notebook subfolder, `Trash/` and `files/`, an
      `assert` helper, and a final pass/fail summary with non-zero exit on
      failure
- [x] add test: both manifests are valid JSON and contain required keys
- [x] run `shellcheck tests/fsnotes_test.sh` - must pass
- [x] run `tests/fsnotes_test.sh` - must pass before Task 2

### Task 2: Notes-directory resolution library
- [x] create `plugins/fsnotes/scripts/fsnotes-lib.sh` with
      `resolve_notes_dir`: if `FSNOTES_DIR` set and exists → use it; else
      use the iCloud primary path if it exists; else glob
      `~/Library/Mobile Documents/*fsnotes*/Documents`; on exactly one
      match → use it; on zero or many → print a clear error to stderr and
      return non-zero
- [x] add `sanitize_title` helper (title → filesystem-safe base name;
      strips/replaces `/`, control chars, leading dots; collapses spaces)
- [x] make the library safe to `source` (no side effects, no top-level
      execution)
- [x] write tests: `FSNOTES_DIR` override resolves; missing primary →
      glob fallback resolves (simulate via a temp `*fsnotes*/Documents`);
      ambiguous → non-zero; `sanitize_title` success + nasty-input cases
- [x] run `shellcheck` on the new script - must pass
- [x] run `tests/fsnotes_test.sh` - must pass before Task 3

### Task 3: Search script
- [x] create `plugins/fsnotes/scripts/fsnotes-search.sh` sourcing
      `fsnotes-lib.sh`; usage:
      `fsnotes-search.sh <mode> <query> [notebook]` where mode ∈
      `text|title|tag|folder` (folder = restrict another mode to a
      subfolder; accept notebook as the optional 3rd arg for any mode)
- [x] detect `rg`; if absent fall back to `grep -r` and emit a one-time
      stderr hint to install ripgrep
- [x] implement modes: `text` (body match), `title` (first `# ` heading +
      filename), `tag` (inline `#query`); always exclude `Trash/` and
      `files/`; output `relative/path:line` hits
- [x] write tests for each mode against the fixture (success + no-match);
      verify `Trash/` and `files/` are excluded; force the grep path
      (e.g. `PATH`-shadow `rg`) and assert same results + hint emitted
- [x] run `shellcheck` on the script - must pass
- [x] run `tests/fsnotes_test.sh` - must pass before Task 4

### Task 4: New-note path helper
- [x] create `plugins/fsnotes/scripts/fsnotes-newpath.sh` sourcing the
      lib; given a title (and optional notebook), print the absolute
      target `.markdown` path; exit non-zero with a clear message if the
      target already exists (never overwrite)
- [x] write tests: fresh title → expected sanitized path; existing title →
      non-zero + message; title placed into a notebook subfolder
- [x] run `shellcheck` on the script - must pass
- [x] run `tests/fsnotes_test.sh` - must pass before Task 5

### Task 5: Trash (delete) script
- [x] create `plugins/fsnotes/scripts/fsnotes-trash.sh` sourcing the lib;
      move a given note file into `<notes>/Trash/`, creating `Trash/` if
      absent; never hard-delete
- [x] on name collision in `Trash/`, disambiguate (e.g. numeric suffix)
      instead of clobbering
- [x] write tests: move succeeds and source no longer exists; collision in
      `Trash/` preserves both files; missing source → non-zero
- [x] run `shellcheck` on the script - must pass
- [x] run `tests/fsnotes_test.sh` - must pass before Task 6

### Task 6: Search subagent
- [x] create `plugins/fsnotes/agents/fsnotes-search.md` with frontmatter
      (`name: fsnotes-search`, `description` covering all four modes and
      "returns only matching paths/lines", `tools: Bash, Read`)
- [x] body instructs the agent to call `fsnotes-search.sh`, choose the mode
      from the request, pass a notebook when folder-scoped, and return a
      compact hit list (path + matched line/title) — not full note dumps
- [x] write test: agent file has valid frontmatter with required keys and
      references the search script path
- [x] run `tests/fsnotes_test.sh` - must pass before Task 7

### Task 7: fsnotes skill (wiring)
- [x] create `plugins/fsnotes/skills/fsnotes/SKILL.md` with frontmatter
      (`name: fsnotes`, `description` triggering on note search/create/
      edit/delete; `allowed-tools: Bash, Read, Edit, Write, Task`)
- [x] document conventions (`.markdown`, `# Title`, notebooks =
      subfolders, reserved `Trash/`/`files/`, inline hashtags) and the
      operation playbook: search → delegate to the `fsnotes-search`
      subagent; create → `fsnotes-newpath.sh` then `Write` (surface
      conflicts, no auto-tags); edit → locate then `Edit` in place, confirm
      when ambiguous; delete → `fsnotes-trash.sh`
- [x] explicitly state notebook names are discovered at runtime (none
      hardcoded) and reference scripts via the plugin scripts dir
- [x] write test: SKILL.md has valid frontmatter with required keys and
      mentions each of the four scripts; grep the whole `plugins/` tree to
      assert no real-world local notebook names are hardcoded
- [x] run `tests/fsnotes_test.sh` - must pass before Task 8

### Task 8: Verify acceptance criteria
- [x] verify all spec operations (search 4 modes, create, edit, delete) are
      represented by scripts + skill instructions
- [x] run `shellcheck` on every `.sh` under `plugins/` and `tests/` - clean
- [x] validate every manifest JSON and every markdown frontmatter block
- [x] run the full `tests/fsnotes_test.sh` suite - all pass
- [x] confirm no hardcoded local notebook names and no reliance on the real
      iCloud store in any test

### Task 9: [Final] Documentation
- [ ] write root `README.md` (marketplace + fsnotes plugin: what it does,
      install steps `/plugin marketplace add olomix/cc-thingz` →
      `/plugin install fsnotes`, the conventions it assumes, ripgrep
      recommendation)
- [ ] note in README that scripts honor `FSNOTES_DIR` for testing

## Technical Details

- **Scripts** (`plugins/fsnotes/scripts/`): `fsnotes-lib.sh` (sourced),
  `fsnotes-search.sh`, `fsnotes-newpath.sh`, `fsnotes-trash.sh`. Bash,
  strict mode (`set -euo pipefail`), `FSNOTES_DIR` override, stderr for
  errors/hints, stdout for results.
- **Path resolution order:** `FSNOTES_DIR` → iCloud primary
  (`~/Library/Mobile Documents/iCloud~co~fluder~fsnotes/Documents`) →
  glob `~/Library/Mobile Documents/*fsnotes*/Documents` (unique match) →
  error.
- **Search exclusions:** `Trash/`, `files/` always skipped.
- **Manifests:** marketplace `name: olomix-cc-thingz`; plugin
  `name: fsnotes`, `version: 0.1.0`.
- **Test harness:** single `tests/fsnotes_test.sh`, no external deps, temp
  fixture under `mktemp -d`, cleaned up on exit.

## Post-Completion

*Manual / external — no checkboxes:*

**Publish & install:**
- Create `github.com/olomix/cc-thingz`, push the repo.
- `/plugin marketplace add olomix/cc-thingz`, then `/plugin install fsnotes`.

**Live verification against the real store:**
- Run a real search ("find my note about …") and confirm hits.
- Create a test note; confirm it appears in FSNotes with the right title.
- Edit it; confirm FSNotes reflects the external change.
- Delete it; confirm it lands in `Trash/` and not removed outright.
- Confirm ripgrep is installed (or observe the grep-fallback hint).
