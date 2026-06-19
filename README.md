# olomix-cc-thingz

A personal [Claude Code](https://docs.claude.com/en/docs/claude-code) plugin
marketplace. It currently ships two plugins, **fsnotes** and **gh-lookup**.

## fsnotes

Lets Claude search, create, edit, and delete notes managed by the
[FSNotes](https://fsnot.es) macOS/iOS app through natural requests — "find my
note about X", "make a note", "add to my X note", "delete that note".

FSNotes keeps each note as a plain Markdown file in iCloud, with a few
conventions Claude would otherwise have to guess. This plugin teaches it the
layout so it operates on the store reliably:

- Notes are `.markdown` files (not `.md`).
- The first line is a `# Title` heading; the filename usually matches.
- Subfolders are **notebooks**. Notebook names are discovered at runtime —
  none are hardcoded.
- Tags are inline `#hashtags` in the body; there is no YAML frontmatter.
- `Trash/` (deleted notes) and `files/` (attachments) are reserved and are
  excluded from searches.

The actual logic lives in small, deterministic shell scripts under
`plugins/fsnotes/scripts/`, so it can be unit-tested:

- `fsnotes-search.sh <mode> <query> [notebook]` — search by `text`, `title`, or
  `tag`, with an optional `[notebook]` scoping any mode to one subfolder.
  `folder` is a body search scoped to a notebook and instead takes its
  arguments as `fsnotes-search.sh folder <notebook> <query>`.
- `fsnotes-newpath.sh <title> [notebook]` — print a safe, collision-free path
  for a new note (never overwrites).
- `fsnotes-trash.sh <note-path>` — move a note into `Trash/` (never
  hard-deletes).
- `fsnotes-lib.sh` — shared helpers, sourced by the others.

A `fsnotes-search` subagent and the `fsnotes` skill wire these together so
Claude picks the right operation and returns compact results.

### Install

```
/plugin marketplace add olomix/cc-thingz
/plugin install fsnotes
```

### Recommended: ripgrep

Search uses [ripgrep](https://github.com/BurntSushi/ripgrep) (`rg`) when
available and falls back to `grep -r` otherwise, emitting a one-time hint to
install it. For best performance:

```
brew install ripgrep
```

### Notes directory resolution

The scripts locate the FSNotes store in this order:

1. `$FSNOTES_DIR`, if set and existing.
2. The iCloud primary path
   `~/Library/Mobile Documents/iCloud~co~fluder~fsnotes/Documents`.
3. A glob of `~/Library/Mobile Documents/*fsnotes*/Documents` (used only when
   it resolves to exactly one match).

The `FSNOTES_DIR` override exists so the test suite can target a temporary
fixture directory; in normal use it is unset and the iCloud path applies.

## gh-lookup

Lets Claude look up exact `gh` CLI command and flag syntax — and *discover*
whether a `gh` command exists for a given task — from the **locally installed**
reference, instead of guessing flags from memory (which drift between gh
versions). It is an anti-hallucination guardrail: when Claude needs precise gh
syntax or suspects a command might exist, it consults the installed manual
rather than inventing flags.

The logic lives in a small, deterministic shell script under
`plugins/gh-lookup/scripts/`, so it can be unit-tested:

- `gh-lookup.sh discover <keywords...>` — keyword search across all command
  names and one-line descriptions in `gh reference`, returning compact hits
  like `gh pr merge — Merge a pull request`. Answers "is there a gh command
  for X?" Matching is case-insensitive and requires all keywords; exit 1
  means no matches.
- `gh-lookup.sh show <command words...>` — authoritative per-command detail
  via `gh <command> --help` (exact usage and flags for the installed version),
  e.g. `gh-lookup.sh show pr merge`.

A `gh-lookup-search` subagent and the `gh-lookup` skill wire these together so
Claude reaches for the manual on "what's the gh command for…", "which gh
flag…", and "is there a gh command to…" requests, returning compact results.

### Install

```
/plugin marketplace add olomix/cc-thingz
/plugin install gh-lookup
```

### gh binary resolution

All `gh` calls go through a `GH_BIN` variable (`GH_BIN="${GH_BIN:-gh}"`). The
override exists so the test suite can point at a fake `gh` stub; in normal use
it is unset and the real `gh` on `PATH` applies.

## Development

```
shellcheck tests/fsnotes_test.sh plugins/fsnotes/scripts/*.sh
tests/fsnotes_test.sh

shellcheck tests/gh-lookup_test.sh plugins/gh-lookup/scripts/*.sh \
  tests/fixtures/fake-gh.sh
tests/gh-lookup_test.sh
```

Tests are pure bash with no external framework. The fsnotes tests build a
temporary fixture store via `FSNOTES_DIR` and never touch the real iCloud
notes; the gh-lookup tests stub `gh` via `GH_BIN` and synthetic fixtures, so
they never call the real binary or the network.

## License

MIT — see [LICENSE](LICENSE).
