# Repository Conventions

## Public repository — no personal data

This repository is **public**. Personal data must never be committed to it,
neither in tracked files nor in git history (commit metadata is exempt only for
authorship attribution that is intentionally public).

This is a hard rule for both **writing code** and **reviewing changes**:

* Do **not** introduce real personal data: email addresses, phone numbers,
  home/work paths containing usernames (e.g. `/Users/<name>/...`), real
  notebook/folder names, private hostnames, or any other identifying details.
* Use placeholders or generic examples (`/path/to/notes`, `user@example.com`)
  in code, tests, and documentation.
* Author/copyright attribution (the project author's name in `LICENSE`,
  `plugin.json`, `marketplace.json`) is intentional and allowed.
* When reviewing a diff, flag any newly added personal data as a blocker.

## Plugin layout and paths

Every plugin here is installed as a plugin from the local `directory`
marketplace (this checkout). Never symlink a skill into
`~/.claude/skills/`. A local-directory plugin loads in place, so an edit
applies at the next session start or after `/reload-plugins`, with no
version bump.

Where a plugin keeps its scripts depends on what else it ships:

* **Self-contained skill** — the plugin has a skill and nothing else (no
  `agents/`, no `hooks/`). Keep every file the skill uses inside the skill
  directory (`skills/<name>/scripts/`, `assets/`, ...). Refer to them from
  `SKILL.md` as `${CLAUDE_SKILL_DIR}/scripts/...`. Examples: `html-popup`,
  `session-park`.
* **Skill with other components** — the plugin also ships an agent or a
  hook. Keep the scripts at the plugin root (`plugins/<name>/scripts/`) and
  refer to them everywhere — `SKILL.md`, `agents/*.md`, `hooks/hooks.json` —
  as `${CLAUDE_PLUGIN_ROOT}/scripts/...`. The skill is not usable without
  those components, so it never needs to work outside the plugin. Examples:
  `fsnotes`, `gh-lookup` (agents), `dotfiles` (hook).

Use one variable per plugin. Never write a fallback such as
`${CLAUDE_PLUGIN_ROOT:-...}` or a `${CLAUDE_SKILL_DIR}/../..` path. In
`hooks.json` and agent files only `${CLAUDE_PLUGIN_ROOT}` exists.

A script finds its own siblings relative to itself
(`"$(dirname "${BASH_SOURCE[0]}")"`), never through these variables, so the
tests can run it straight from the repository.

## Compiled helpers and GUI tests

* Do not commit compiled binaries. A plugin that needs native code ships the
  source (e.g. `plugins/html-popup/skills/html-popup/viewer/*.swift`) and
  its wrapper compiles it on first use into a cache keyed by the source
  hash.
* Generated static assets may be committed together with the dev script
  that regenerates them:
  `plugins/html-popup/skills/html-popup/viewer/AppIcon.icns` comes from
  `AppIcon.svg` via `viewer/make-icon.sh`; rerun it after editing the SVG.
* Swap external tools through env vars so tests never run the real ones:
  `HTML_POPUP_SWIFTC` (compiler) and `HTML_POPUP_OPEN` (LaunchServices
  launcher, faked by `tests/fixtures/fake-open.sh`).
* A viewer launched via `open` writes its own `DIR/pid`; its stderr goes to
  `DIR/viewer.log` (`open --stderr`). Until the pid file appears the session
  has only `ready_by`.
* Tests that need macOS, a compiler or a GUI session must skip with a clear
  message when those are missing (see `skip_unless_macos` and
  `skip_unless_gui` in `tests/html-popup_test.sh`); all other tests must run
  everywhere.
