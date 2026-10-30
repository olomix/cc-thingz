# olomix-cc-thingz

A personal [Claude Code](https://docs.claude.com/en/docs/claude-code) plugin
marketplace. It currently ships four plugins, **fsnotes**, **gh-lookup**,
**dotfiles**, and **html-popup**.

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
- `fsnotes-link.sh [--osc8] <route> <args…>` — build a clickable `fsnotes://`
  deep link into the FSNotes app (routes: `find`, `open`, `tag`, `new`).
  Default output is a markdown link; `--osc8` emits OSC 8 escapes for
  terminals that hyperlink arbitrary schemes.
- `fsnotes-lib.sh` — shared helpers, sourced by the others.

A `fsnotes-search` subagent and the `fsnotes` skill wire these together so
Claude picks the right operation and returns compact results. When Claude
mentions a note in a reply, it emits a `fsnotes://` deep link so you can jump
straight to it in the FSNotes app.

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

### Requirements

Requires the GitHub CLI (`gh`) on `PATH`. The `discover` mode relies on
`gh reference`, available in recent `gh` releases (verified against gh
v2.95.0). `show` (`gh <command> --help`) works on any version.

### Install

```
/plugin marketplace add olomix/cc-thingz
/plugin install gh-lookup
```

### gh binary resolution

All `gh` calls go through a `GH_BIN` variable (`GH_BIN="${GH_BIN:-gh}"`). The
override exists so the test suite can point at a fake `gh` stub; in normal use
it is unset and the real `gh` on `PATH` applies.

## dotfiles

Teaches Claude to operate a **bare-repo dotfiles** setup — the git directory
kept separate from a `$HOME` work-tree, managed through a `dotfiles` git wrapper
— and prompts to commit whenever Claude edits a file that is *tracked* in the
dotfiles repo. After such an edit, Claude asks whether to commit and offers a
proposed message; it never commits without consent.

The plugin has two parts:

- A **`dotfiles` skill** teaching the bare-repo model and the
  add/commit/diff/log/rollback recipes, how to detect whether a file is tracked,
  and the secrets caution (never add private keys, credentials, or history
  files).
- A **PostToolUse hook** backed by a small, deterministic shell script under
  `plugins/dotfiles/scripts/`, so it can be unit-tested:
  - `dotfiles-tracked.sh` — reads the hook payload on stdin, checks whether the
    edited file is tracked via
    `git --git-dir=… --work-tree=… ls-files --error-unmatch`, and on a match
    prints the commit prompt. If no dotfiles repo is present (or `jq` is
    missing, or the path is untracked/external), it is a silent no-op, so the
    plugin is harmless to install even without a dotfiles setup.

See [`plugins/dotfiles/README.md`](plugins/dotfiles/README.md) for the one-time
bare-repo setup (`git init --bare`, `status.showUntrackedFiles no`, the shell
alias).

### Install

```
/plugin marketplace add olomix/cc-thingz
/plugin install dotfiles
```

### Repo resolution

The plugin resolves the two locations from environment variables, with safe
defaults — nothing hardcodes a username or absolute path:

- `DOTFILES_GIT_DIR` — the bare repo's git directory (default `$HOME/.dotfiles`).
- `DOTFILES_WORK_TREE` — the work-tree, your home dir (default `$HOME`).

Set these only if your repo lives somewhere other than `$HOME/.dotfiles`. The
overrides also let the test suite target a temporary sandbox; if
`DOTFILES_GIT_DIR` does not point at a directory, the plugin stays silent.

## html-popup

Lets Claude show a generated HTML page — a report, chart, table, form, or
dialog — in a native macOS window and get data back from it, without a browser
tab or a web server. Claude reaches for it on "show it in a window", "chart
this", "ask me which month", or when it needs you to pick or fill in
something.

The window is a small WebKit viewer with a native frame: a transparent title
bar, draggable, standard Edit shortcuts in form fields, Esc/Cmd-W to close,
and no Dock icon. It runs detached from the calling command, so a Bash call
that times out or is killed never closes it. There are three modes:

- **show** — open a page for viewing and return once it has loaded.
- **ask** — open a page and wait for your answer (e.g. a picked month), print
  it as one JSON line, and close the window. A slow answer can be resumed with
  `ask --resume`.
- **live** — keep the window open and exchange messages both ways: the page
  sends events to Claude, Claude sends updates back, until either side closes
  it.

Pages talk to Claude through an injected `window.htmlPopup` object
(`data`, `answer`, `cancel`, `send`, `onMessage`), so they need no script
include. Data is passed as a JSON file with `--data` rather than inlined into
the page. Everything goes through one wrapper script,
`plugins/html-popup/scripts/html-popup.sh` (`check`, `build`, `show`, `ask`,
`live start|send|wait|close`). Its exit codes: 0 ok, 1 window closed
without an answer (or its `--timeout` hit), 2 usage or setup error, 3 page or
data invalid or page not ready, 4 `--wait` expired with the window still
open (call again), 5 viewer crashed; the skill's `SKILL.md` has details. The
plugin also ships a native-looking starter page (`assets/template.html`,
light/dark aware) and a live example, `examples/solar-2025/`, a 2025 US
solar generation report from public EIA data where choosing a month gets a
details panel computed by `run.sh`.

The viewer is a single Swift source file, compiled with `swiftc` on first use
(a few seconds) and cached by source hash in
`${CLAUDE_PLUGIN_DATA:-~/Library/Caches/html-popup}`; no binary is committed,
and plugin updates rebuild it automatically.

### Requirements

macOS with a GUI session, the Xcode Command Line Tools (`swiftc`), and `jq`.
`html-popup.sh check` reports any missing piece. Sandboxed Bash may block the
cache dir or the window server.

### Install

```
/plugin marketplace add olomix/cc-thingz
/plugin install html-popup
```

## Development

```
shellcheck tests/fsnotes_test.sh plugins/fsnotes/scripts/*.sh
tests/fsnotes_test.sh

shellcheck tests/gh-lookup_test.sh plugins/gh-lookup/scripts/*.sh \
  tests/fixtures/fake-gh.sh
tests/gh-lookup_test.sh

shellcheck tests/dotfiles_test.sh plugins/dotfiles/scripts/*.sh
tests/dotfiles_test.sh

shellcheck tests/html-popup_test.sh plugins/html-popup/scripts/*.sh \
  plugins/html-popup/examples/*/*.sh tests/fixtures/fake-swiftc.sh
tests/html-popup_test.sh
```

Tests are pure bash with no external framework. The fsnotes tests build a
temporary fixture store via `FSNOTES_DIR` and never touch the real iCloud
notes; the gh-lookup tests stub `gh` via `GH_BIN` and synthetic fixtures, so
they never call the real binary or the network; the dotfiles tests build a
throwaway bare repo and work-tree in a temp dir via `DOTFILES_GIT_DIR` /
`DOTFILES_WORK_TREE` and never touch the real `~/.dotfiles` or `$HOME`; the
html-popup build tests use a fake compiler via `HTML_POPUP_SWIFTC` and a temp
cache dir, while its viewer tests compile the real viewer and drive invisible
windows with `HTML_POPUP_TEST_SCRIPT`. Those viewer tests are skipped unless
`swiftc` is installed and the session is a GUI (Aqua) login, and tests that
run the wrapper's build step or fake viewers are skipped off macOS.

## License

MIT — see [LICENSE](LICENSE).
