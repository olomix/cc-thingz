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

## Compiled helpers and GUI tests

* Do not commit compiled binaries. A plugin that needs native code ships the
  source (e.g. `plugins/html-popup/viewer/*.swift`) and its wrapper compiles
  it on first use into a cache keyed by the source hash.
* Generated static assets may be committed together with the dev script
  that regenerates them: `plugins/html-popup/viewer/AppIcon.icns` comes from
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
