# gh-lookup skill

## Overview

Add a new plugin **`gh-lookup`** to the cc-thingz marketplace that lets Claude
look up exact `gh` CLI command/flag syntax — and *discover* whether a `gh`
command exists for a given task — from the **locally installed** reference,
instead of guessing flags from memory (which drift between gh versions).

It mirrors the existing **fsnotes** plugin shape: a small deterministic shell
script (`scripts/gh-lookup.sh`) does the work, a read-only subagent
(`gh-lookup-search`) wraps it and returns compact results, and a `SKILL.md`
tells Claude *when* to reach for it. Pure-bash tests cover the script.

Two operations:

- **`discover <keywords>`** — keyword search across all command names +
  one-line descriptions in `gh reference`, returning compact hits like
  `gh pr merge — Merge a pull request`. Answers "is there a gh command for X?"
- **`show <command words>`** — authoritative per-command detail via
  `gh <command> --help` (exact usage + flags for the installed version).

Value: an **anti-hallucination guardrail**. When Claude needs precise gh syntax
or suspects a command might exist, it consults the installed manual rather than
inventing flags.

## Context (from discovery)

- Repo is a **public** Claude Code plugin marketplace; **fsnotes** is the only
  existing plugin and the template to follow.
- Per-plugin layout:
  `plugins/<name>/.claude-plugin/plugin.json`,
  `plugins/<name>/skills/<name>/SKILL.md`,
  optional `plugins/<name>/agents/*.md` and `plugins/<name>/scripts/*.sh`,
  with entries in `.claude-plugin/marketplace.json` and `README.md`.
- Tests are pure bash, no framework, run directly
  (`tests/fsnotes_test.sh`) and validated with `shellcheck`.
- fsnotes uses an env override (`FSNOTES_DIR`) purely so tests can target a
  fixture instead of the real store — the same trick applies here for stubbing
  the `gh` binary.
- `gh` v2.95.0 is installed. `gh reference` dumps the entire manual to stdout
  (local, offline, no auth). `gh <cmd> --help` prints exact per-command help.

## Development Approach

- **Testing approach: TDD (tests first)** — write the bash test, watch it fail,
  then implement.
- Complete each task fully before the next; make small, focused changes.
- **Every task with code MUST include new/updated tests** (success + error
  paths) as separate checklist items.
- **All tests + `shellcheck` must pass before starting the next task.**
- Keep this plan in sync if scope changes.

## Testing Strategy

- **Unit tests** (`tests/gh-lookup_test.sh`, pure bash): required per task.
  - No network, no real `gh` call: tests stub `gh` via a fake script and a
    `GH_BIN` env override (the analogue of fsnotes' `FSNOTES_DIR`).
  - Synthetic fixtures only — see Constraints; do **not** commit the real
    manual.
- **E2E:** none (no UI). A manual smoke test against the real `gh` is in
  Post-Completion.
- `shellcheck` on every `.sh` file (script + tests) is part of each task's
  "must pass" gate (global rule).

## Progress Tracking

- Mark items `[x]` immediately when done.
- `➕` prefix for newly discovered tasks; `⚠️` prefix for blockers.
- Update the plan if scope shifts.

## What Goes Where

- **Implementation Steps** (`[ ]`): all changes inside this repo — script,
  subagent, skill, plugin/marketplace wiring, README, tests.
- **Post-Completion** (no checkboxes): manual smoke test against real `gh`,
  install verification.

## Constraints

- **Public repo, no personal data.** Use generic examples only.
- **Do not commit the full `gh reference` output** as a fixture: it is large
  and is GitHub's documentation content. Tests use a **small synthetic
  fixture** that imitates the real format (a few fake commands).
- **`shellcheck` must pass** on every shell file.
- Target the installed gh (`gh reference` present in v2.95.0). If `gh` is
  missing or `gh reference` is unavailable, the script must fail with a clear
  message, not a confusing one.
- The script invokes gh through a `GH_BIN` variable (`GH_BIN="${GH_BIN:-gh}"`)
  so tests can point it at a fake; in normal use it is unset and real `gh`
  applies.

## Implementation Steps

### Task 1: Confirm `gh reference` format and build the test harness
- [x] run `gh reference` and note the exact shape of command headers and
      one-line descriptions (record findings in this plan's Technical Details)
- [x] create `tests/fixtures/fake-gh.sh`: a stub that, given `reference`, cats
      a synthetic reference fixture, and given `<cmd...> --help`, cats a
      synthetic help fixture (keyed by command); honors no network/auth
- [x] create `tests/fixtures/gh-reference-sample.txt`: a **small synthetic**
      reference (e.g. fake `gh pr merge`, `gh issue create`, `gh widget make`)
      matching the real format — never the real manual
- [x] create one or more synthetic `--help` fixtures used by `show` tests
- [x] add a test bootstrap in `tests/gh-lookup_test.sh` that points `GH_BIN`
      at `fake-gh.sh` and provides assert helpers (mirror `fsnotes_test.sh`)
- [x] run `shellcheck tests/gh-lookup_test.sh tests/fixtures/fake-gh.sh` — must pass

### Task 2: Implement `discover` mode (TDD)
- [x] write failing tests in `tests/gh-lookup_test.sh` for `discover`:
      keyword match returns `gh <cmd> — <description>` lines; multiple hits;
      case-insensitive match; multi-word query; **no-match exits non-zero**
      with nothing on stdout
- [x] create `plugins/gh-lookup/scripts/gh-lookup.sh` with `discover` mode:
      pipe `"$GH_BIN" reference`, search command/description lines for the
      keywords, emit compact `gh <cmd> — <description>` hits
- [x] handle no-match (exit code distinct from usage errors, e.g. 1)
- [x] run `shellcheck` on the script + tests, then run the test suite — must pass

### Task 3: Implement `show` mode + dispatch/errors (TDD)
- [x] write failing tests for `show`: returns the `--help` text for a given
      command (via stubbed gh); passes through multi-word commands
- [x] write failing tests for errors: unknown mode → usage on stderr, exit 2;
      missing query → usage, exit 2; `GH_BIN` not found / `gh` missing →
      clear error, exit 3
- [x] implement `show` mode: `"$GH_BIN" <command words> --help`
- [x] implement top-level arg dispatch, `usage()`, and a `gh` presence check
- [x] run `shellcheck` + full test suite — must pass

### Task 4: Add the `gh-lookup-search` subagent and `SKILL.md`
- [x] create `plugins/gh-lookup/agents/gh-lookup-search.md` mirroring
      `fsnotes-search`: read-only (tools: Bash, Read), runs
      `"${CLAUDE_PLUGIN_ROOT}/scripts/gh-lookup.sh"`, returns compact hits for
      `discover` / the relevant excerpt for `show`, never dumps the whole manual
- [x] create `plugins/gh-lookup/skills/gh-lookup/SKILL.md` (frontmatter:
      `name`, `description`, `allowed-tools: Bash, Task, Read`): instruct Claude
      to dispatch the `gh-lookup-search` subagent when it needs exact gh syntax
      or suspects a gh command exists for a task — `discover` to find candidates,
      `show` to confirm flags — instead of guessing
- [x] document the two script modes and the `${CLAUDE_PLUGIN_ROOT}` invocation
      convention in `SKILL.md`
- [x] verify the skill `description` triggers on relevant phrasing ("what's the
      gh command for…", "which gh flag…", "is there a gh command to…")
- [x] sanity-check markdown structure against the fsnotes equivalents

### Task 5: Wire the plugin into the marketplace and README
- [x] create `plugins/gh-lookup/.claude-plugin/plugin.json` (name, description,
      version `0.1.0`, author "Oleg Lomaka", homepage/repo, MIT) modeled on
      fsnotes
- [x] add a `gh-lookup` entry to `.claude-plugin/marketplace.json`
- [x] add a `## gh-lookup` section to `README.md` (what it does, the two modes,
      install snippet, `GH_BIN` test-override note) and add
      `tests/gh-lookup_test.sh` to the Development section
- [x] run `shellcheck` on all shell files and the full test suite — must pass

### Task 6: Verify acceptance criteria
- [x] verify Overview requirements are met: `discover` finds commands by
      keyword; `show` returns exact help; subagent + skill wire them together
- [x] verify error/edge cases (unknown mode, missing query, gh absent, no match)
- [x] run `tests/gh-lookup_test.sh` (and `tests/fsnotes_test.sh` to confirm no
      regression in shared conventions)
- [x] run `shellcheck` across `tests/*.sh` and `plugins/*/scripts/*.sh` — clean
- [x] confirm no real personal data or full-manual content was committed

### Task 7: [Final] Documentation polish
- [x] re-read README additions for accuracy and tone consistency with fsnotes
- [x] ensure SKILL.md and the subagent agree on modes and output shape

*Note: ralphex automatically moves completed plans to `docs/plans/completed/`.*

## Technical Details

- **Script CLI:** `gh-lookup.sh <mode> <args...>`
  - `discover <keywords...>` → search `gh reference`, print
    `gh <cmd> — <one-line description>` per match.
  - `show <command words...>` → print `gh <command> --help`.
- **gh invocation indirection:** `GH_BIN="${GH_BIN:-gh}"`; all gh calls go
  through `"$GH_BIN"`. Tests set `GH_BIN` to `tests/fixtures/fake-gh.sh`.
- **Exit codes:** `0` success; `1` no matches (discover); `2` usage error
  (unknown mode / missing args); `3` gh not found / `gh reference` unavailable.
- **`gh reference` format:** (confirmed against gh v2.95.0) the manual is a
  single markdown-ish stream on stdout, offline, no auth. Command headers are
  Markdown ATX headings that always start with `gh `:
  - `## gh <group> <command>` — a command *group* (e.g. `## gh pr <command>`),
    followed by a blank line then a one-line group description.
  - `### gh <full command path> [usage args] [flags]` — a concrete command
    (e.g. `### gh pr merge [<number> | <url> | <branch>] [flags]`), followed by
    a blank line then a one-line description.
  - Top-level commands may appear as a single `## gh <name> ...` header with no
    deeper level (e.g. `## gh api <endpoint> [flags]`).
  - The **command name** is the leading `gh <word> <word>...` tokens of the
    heading, stopping at the first usage placeholder token — one beginning with
    `[`, `{`, or `<` (e.g. heading `### gh pr merge [<number>] [flags]` →
    command `gh pr merge`). The `discover` parser strips these placeholders.
  - The **description** is the first non-blank line after the heading.
  The synthetic fixture (`tests/fixtures/gh-reference-sample.txt`) reproduces
  this exact shape with a few fake commands (`gh pr merge`, `gh issue create`,
  `gh widget make`).
- **`gh <cmd> --help` format:** (confirmed) freeform text — a description
  paragraph, then `USAGE`, `FLAGS`, `INHERITED FLAGS`, and `LEARN MORE`
  sections. `show` passes this through verbatim; fixtures live at
  `tests/fixtures/gh-help-<cmd-words-joined-by-hyphen>.txt`.
- **No caching:** `gh reference` is a fast local dump; run it per `discover`
  call for simplicity (revisit only if measurably slow).
- **Subagent output discipline:** return compact hits, not the full manual —
  the same restraint as `fsnotes-search`.

## Post-Completion

*Manual / external — informational only.*

**Manual verification:**
- Smoke-test against the real binary:
  - `plugins/gh-lookup/scripts/gh-lookup.sh discover "merge a pull request"`
    surfaces `gh pr merge`.
  - `plugins/gh-lookup/scripts/gh-lookup.sh show "pr merge"` prints real
    `gh pr merge --help`.
- Install end-to-end and confirm the skill/subagent load:
  - `/plugin marketplace add olomix/cc-thingz`
  - `/plugin install gh-lookup`
  - ask Claude a "what's the gh command for…" question and confirm it routes
    through the `gh-lookup-search` subagent.
