# html-popup: show HTML reports in a native macOS window and talk to them

## Overview
- Add a new plugin `html-popup` with a skill of the same name. It lets an
  agent show a generated HTML page in a native macOS window (WebKit, no
  browser chrome) and get data back from it.
- Three modes:
  - **show** — open a report for viewing; return immediately.
  - **ask** — open a page and wait for the user's answer (e.g. a picked
    month); print the answer as JSON; the window closes.
  - **live** — keep the window open and exchange messages both ways: the page
    sends events to the agent, the agent sends updates to the page, until
    either side closes it.
- Problem it solves: rich, interactive output (charts, pickers, forms) without
  a browser tab, a web server or per-use boilerplate. The plugin ships the
  viewer, a CLI wrapper and an HTML template, so each later use costs only a
  page body plus one or two commands.
- Integrates as a fourth plugin in this marketplace, following the existing
  layout (`plugins/<name>/{.claude-plugin,skills,scripts}`) and bash tests in
  `tests/`.

## Context (from discovery)
- Repository: public Claude Code plugin marketplace
  (`.claude-plugin/marketplace.json`) with plugins `fsnotes`, `gh-lookup`,
  `dotfiles`.
- Plugin layout: `plugins/<name>/.claude-plugin/plugin.json`,
  `plugins/<name>/skills/<name>/SKILL.md`, `plugins/<name>/scripts/*.sh`.
  Skills call scripts as `"${CLAUDE_PLUGIN_ROOT}/scripts/<script>"`.
- Tests: pure bash, `tests/<plugin>_test.sh`, `assert`/`assert_eq` helpers,
  fixtures in `tests/fixtures/`, external tools replaced by stubs selected via
  env vars (`GH_BIN` → `tests/fixtures/fake-gh.sh`).
- CLAUDE.md: the repo is public — no personal data (no `/Users/<name>` paths,
  emails, hostnames) in code, tests, docs or examples.
- Proven prototype behavior to keep (it is not in the repo; this list is the
  spec): titled `NSWindow` with `.fullSizeContentView`, transparent title bar,
  hidden title text, `WKWebView` filling the window, a transparent drag view
  over the top 32pt calling `window.performDrag(with:)` (the web view would
  otherwise swallow title-bar drags), data injected with a `WKUserScript` at
  document start, answers via `webkit.messageHandlers.<name>.postMessage`,
  `NSApp.setActivationPolicy(.accessory)` so an unbundled binary has no Dock
  icon; on open `orderFrontRegardless` + `NSApp.activate()` (macOS 14+,
  `activate(ignoringOtherApps:)` before) and a `.floating` level only until
  the window first becomes key in an active app, because macOS may deny
  activation to the detached process; window title set from the page
  `<title>` in `webView(_:didFinish:)`, no backdrop and no permanent floating
  level (the user rejected both).
- Dependencies: macOS, `swiftc` (Xcode Command Line Tools), `jq`.

## Development Approach
- **testing approach**: Regular (code first, then tests in the same task)
- complete each task fully before moving to the next
- make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
  - tests are not optional - they are a required part of the checklist
  - write tests for new functions/subcommands
  - write tests for modified functions/subcommands
  - add new test cases for new code paths
  - update existing test cases if behavior changes
  - tests cover both success and error scenarios
- **CRITICAL: all tests must pass before starting next task** - no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- run tests after each change
- maintain backward compatibility (other plugins and their tests untouched)

## Testing Strategy
- **unit tests**: `tests/html-popup_test.sh`, pure bash in the style of
  `tests/gh-lookup_test.sh`.
- **build tests** use `HTML_POPUP_SWIFTC=tests/fixtures/fake-swiftc.sh`
  (writes a stub binary and counts calls) and a temp cache dir — fast and
  deterministic, no real compile.
- **viewer tests** compile the real viewer once per test run through
  `html-popup.sh build` (temp cache dir) and drive it headless:
  - `HTML_POPUP_TEST_SCRIPT=FILE` (env var, forwarded by the wrapper as the
    viewer's `--test-script`) evaluates JS after page load to click, send or
    answer. Keeps the public CLI clean.
  - In test mode the window is ordered front at alpha 0 (not hidden, so
    WebKit keeps `visibilityState=visible`, timers and rAF running), with
    `.accessory` activation and no activation steal.
  - Every viewer call gets `--timeout` so nothing hangs.
  - Assert on DOM state and events, never pixels.
- Viewer tests skip with a clear message unless `xcrun --find swiftc`
  succeeds and `launchctl managername` prints `Aqua` (a GUI login session).
  Wrapper argument, dependency and build tests always run.
- The test file installs `trap cleanup EXIT` that kills every viewer pid it
  started and removes its temp dirs, because `assert` exits on first failure.
- No e2e UI framework in this repo; visual checks are in Post-Completion.

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope
- keep plan in sync with actual work done

## Solution Overview
- **Viewer** (`viewer/html-popup-viewer.swift`): one Swift source file,
  compiled on first use by the wrapper with `swiftc -O` into a cache
  directory. No binary is committed. The cache key is the source's SHA-256,
  so plugin updates rebuild automatically.
- **Every window runs as a session.** The wrapper creates a session directory
  and starts the viewer detached from the caller. `show`, `ask` and `live` are
  thin wrapper policies over that one mechanism. Consequence: a blocked agent
  Bash call that times out or is killed never takes the window with it, and
  `ask` can be resumed.
- **Native window**: as in the prototype list above, plus a main menu with
  Edit (Undo/Redo/Cut/Copy/Paste/Select All) and Window → Close (Cmd-W), so
  form inputs get standard shortcuts in an unbundled binary.
- **JS bridge** injected by the viewer at document start, so pages need no
  script include:
  - `htmlPopup.data` — contents of `--data FILE` (JSON), or `null`.
  - `htmlPopup.answer(value)` — finish with a result; window closes.
  - `htmlPopup.cancel()` — finish without a result; window closes.
  - `htmlPopup.send(value)` — emit an event; window stays open.
  - `htmlPopup.onMessage(fn)` — receive messages sent by the agent.
  - `htmlPopup.closeOnEscape` — default `true`; Esc closes the window
    (`reason: user`) unless focus is in an `input`, `textarea`, `select` or
    `contenteditable`, or a page listener called `preventDefault()` (the
    bridge decides after the keydown dispatch has finished).
  - Values cross the bridge as `JSON.stringify` strings in both directions,
    so numbers, nesting and top-level scalars survive exactly.
- **Transport**: JS never touches files. Page → bridge → Swift appends a JSON
  line to `DIR/events.jsonl`. Agent → `html-popup.sh live send` → FIFO
  `DIR/in` → Swift reader thread → page `onMessage` handlers.
- **Links**: `http(s)` links open in the default browser; the popup itself
  only navigates within local files (`loadFileURL` with read access to the
  page's directory, so relative assets load).
- **Wrapper CLI** (`scripts/html-popup.sh`): checks dependencies, builds and
  caches the viewer, manages sessions, and exposes `check`, `build`, `show`,
  `ask`, `live start|send|wait|close`.
- **Template** (`assets/template.html`): native-looking starter page (system
  font, light/dark via `prefers-color-scheme`, top padding for traffic
  lights, keyboard hints). The agent copies it and fills in the body.

## Technical Details

### Viewer CLI (called only by the wrapper)
```
html-popup-viewer PAGE.html --session DIR [--data FILE] [--title TEXT]
                  [--size WxH] [--timeout SEC] [--test-script FILE]
```
- On start: `setsid()` (leave the caller's process group), `mkfifo DIR/in`,
  write `DIR/pid`, redirect its own logging to `DIR/viewer.log`.
- `--data` must be UTF-8 JSON (a leading BOM is stripped), since the page
  reads it with `JSON.parse`.
- `--size` default `980x640`. `--title` overrides the page `<title>`.
- After page load appends `ready`. Page `send(v)` appends `message`;
  `answer(v)` appends `answer` then closes; `cancel()` closes.
- Every close path appends exactly one `closed` event with a `reason`
  (`answer`, `cancel`, `user` — close button/Cmd-W/Cmd-Q/Esc, `agent`,
  `timeout`, `error` — load failure, invalid `--data`, crashed web content
  process), then exits. A viewer killed by a signal writes nothing; the
  wrapper writes the `closed` event for viewers it terminates itself.
- Page posts that are not strict one-line JSON values (trailing commas and
  a leading BOM included) are logged and dropped. Wrapper readers skip
  `events.jsonl` lines that are not JSON objects with a numeric `seq`.
  Inbound messages that arrive before `ready` are logged and dropped (the
  wrapper hands out DIR only after `ready`).
- Exit codes: 0 normal close (any reason except below), 3 page failed to load
  or `--data` is not valid JSON (appends `closed` with `reason: error` and a
  `message`), 4 `--timeout` reached, 2 usage error.

### Event line format (`DIR/events.jsonl`)
One JSON object per line, `seq` increasing from 1, written with a single
`write` per line:
```json
{"seq":1,"type":"ready"}
{"seq":2,"type":"message","data":{"action":"select","month":7}}
{"seq":3,"type":"answer","data":{"month":7}}
{"seq":4,"type":"closed","reason":"answer"}
```

### Inbound messages (`DIR/in` FIFO)
- One JSON value per line. The viewer opens the FIFO read-write (never sees
  EOF between writers) and buffers partial lines across `read()` chunks,
  because writes over PIPE_BUF (512 bytes on macOS) are not atomic.
- The reserved line `{"htmlPopup":"close"}` closes the window
  (`reason: agent`). Other lines are validated with `JSONSerialization`; valid
  ones are passed to the page as a JS string literal and `JSON.parse`d there
  (never evaluated as source). Invalid lines are logged to `viewer.log` and
  dropped.

### Wrapper CLI
```
html-popup.sh check                     # macOS, swiftc, jq, writable cache, GUI session
html-popup.sh build                     # (re)build viewer if needed, print its path
html-popup.sh show PAGE [opts]          # open, wait until loaded, print DIR
html-popup.sh ask PAGE [opts] [--wait SEC]   # wait for answer; print answer JSON
html-popup.sh ask --resume DIR [--wait SEC]  # keep waiting on an earlier ask
html-popup.sh live start PAGE [opts]    # open, wait for "ready", print DIR
html-popup.sh live send DIR JSON        # deliver one message to the page
html-popup.sh live wait DIR [--wait SEC]     # print new events
html-popup.sh live close DIR            # close the window (ok if already gone)
```
- `opts` = `--data FILE`, `--title TEXT`, `--size WxH`, `--timeout SEC`
  (window lifetime). `--wait SEC` = how long this one CLI call blocks,
  counted from the start of the call (so a first-use compile and the page
  load count too), default 100 s — below the Bash tool's 120 s default
  timeout. `--wait` is whole seconds, read as decimal (`08` is 8).
- **Detaching**: the viewer is started with a double fork,
  `( "$viewer" ... </dev/null >>"$DIR/viewer.log" 2>&1 & echo $! >"$DIR/pid" )`,
  so it is reparented to launchd at once and is never a descendant of the
  wrapper; the viewer also calls `setsid()`. A process-group kill or a
  tree kill of the caller cannot reach it. `show` and `live start` must
  return while the window stays open.
- **Validation before detaching**: page exists and is readable, `--data`
  passes `jq empty`, `--size` is `WxH` and `--timeout` a positive number.
  Errors are reported synchronously (exit 3 for page/data, 2 for options),
  since a detached viewer cannot report them.
- **Startup**: build first (if needed), then start the viewer, then wait up to
  10 s for `ready` while polling the viewer pid. The wrapper cannot `wait`
  for a detached viewer, so outcomes come from `events.jsonl`: `closed` with
  `reason: error` → exit 3 with the last lines of `viewer.log`; another
  `closed` (e.g. an early answer) → `ask` reads it, `show`/`live start` exit
  1; viewer gone without events → exit 5 with the log tail; not ready in
  10 s → terminate it, write `closed`/`error`, exit 3. `ask` bounds the
  ready wait by its remaining `--wait` and then exits 4 with the resume
  hint; the 10 s deadline is kept in `DIR/ready_by` and enforced by
  `ask --resume` too. The compile itself is not bounded.
- **`ask`**: wait for an `answer` or `closed` event. `answer` → print `data`
  as one JSON line, exit 0. `closed` without answer → exit 1, including a
  window `--timeout` (`window timed out without an answer`); `closed` with
  `reason: error` → exit 3. `--wait` expired → exit 4 and print to stderr:
  `still waiting; resume with: html-popup.sh ask --resume <DIR>`. The
  window stays open; exit 4 always means that.
- **Viewer liveness**: a session pid counts as its viewer only while
  `kill -0` succeeds, `ps -o comm=` ends in `html-popup-viewer-*` and
  `ps -o args=` holds `--session DIR` for this session's DIR (compared with
  `-ef`). A viewer that died without `closed` may have its pid recycled, by
  an unrelated process or another session's viewer; such a pid is treated
  as dead and never signalled. Startup first waits (up to 5 s) until the
  fresh child, a bash subshell until it execs, is the viewer or gone.
- **`live send`**: validate with `jq -c` (exit 2 if it is not exactly one
  JSON value); if the session has a `closed` event or a dead pid → exit 1;
  otherwise a background writer process takes the per-session send lock and
  writes the line to `DIR/in` (opened write-only via a read-write open, so
  the open never blocks and a dead viewer fails the write instead of
  hanging it). A write larger than the pipe buffer blocks until the viewer
  reads it, so the wrapper kills the writer and exits 1 if the viewer dies
  meanwhile. The lock exists because pipe writes over `PIPE_BUF`
  interleave. It is owned by the writer, not the wrapper, so a killed
  wrapper whose writer still runs keeps it. Lock links are
  `DIR/in.lock.N` → owner pid and the highest N counts; N is free once
  `DIR/in.lock.N.done` exists (normal release) or its owner is dead. No
  lock file is ever deleted, so a name is never reused: the next sender
  creates N+1 with `ln -s`, and racing takers have exactly one winner even
  when one acted on a stale read. Leftover files are bounded by the
  session's sends and go with the session dir. Each send writes `"\n" + JSON + "\n"`:
  a writer killed mid-write leaves a partial line, and the leading newline
  ends it, so the viewer drops that fragment as invalid and the next message
  arrives whole.
- **`live wait`**: keeps the last consumed `seq` in `DIR/cursor`; consumes
  only complete (newline-terminated) lines; polls every 0.2 s.
  - Prints the new events and exits 0 if they contain no `closed`.
  - Exits 1 if the printed batch contains `closed`, or `closed` was already
    consumed (returns at once).
  - Exits 5 if the pid is dead and no `closed` was written (viewer crashed),
    unless a live process holds the close lock (a forced close): then it
    waits up to 5 s for that `closed` (same for `ask`).
  - Before exiting 1 or 5 it reads new events once more, so events written
    just before `closed` are always printed.
  - Exits 4 when `--wait` expires with nothing new.
- **`live close`**: write the close line (giving up after 5 s if the send
  lock or the write stays blocked), wait up to 5 s for `closed`; if it
  does not come, SIGTERM the viewer (SIGKILL after 5 s more) and append the
  `closed` event (`reason: agent`) itself. Concurrent closes serialize that
  kill and append with a lock (`DIR/close.lock.N` → owner pid, never
  removed), taken before the kill so waiters can tell a forced close from a
  crash: the owner appends one `closed`, the others wait up to 5 s for it.
  An owner killed before appending is taken over by linking N+1 for the
  same N read once and found dead (one winner, the send lock's helper); a
  later close finishes it even if the viewer is gone. Exit 0,
  also when the viewer was already gone. Keeps `events.jsonl` for reading.
- **Build cache**: `${CLAUDE_PLUGIN_DATA:-$HOME/Library/Caches/html-popup}`,
  binary `html-popup-viewer-<12 hex of sha256>`; compile to
  `<bin>.tmp.$$`, then `mv` into place (safe under concurrent first use).
  Compiler: `$HTML_POPUP_SWIFTC` or else `xcrun swiftc` (the Xcode toolchain
  with the AppKit/WebKit SDK, not an OSS `swiftc` first in PATH); presence
  is checked with `xcrun --find swiftc`, because `/usr/bin/swiftc` exists as
  a shim even without the Command Line Tools. Each use touches the cached
  binary; after a fresh build, viewer binaries and temp files unused for
  over a day are removed, so concurrent plugin versions sharing the cache
  never delete each other's fresh binary.
- **Session dirs**: `mktemp -d "${TMPDIR:-/tmp}/html-popup.XXXXXX"`.
  `show`/`ask`/`live start` remove `html-popup.*` dirs older than one day
  whose pid is dead. A session without `--timeout` stays open until the user
  or agent closes it; that is intended.

### Exit codes (wrapper)
| Code | Meaning |
|------|---------|
| 0 | ok / answered |
| 1 | window closed (no answer for `ask`, incl. window `--timeout`; session over for `wait`/`send`) |
| 2 | usage error (incl. bad `--size`/`--timeout`, `live send` text that is not exactly one JSON value), missing dependency, build failure, DIR is not a session |
| 3 | page or data invalid, page failed to load, page not ready in 10 s |
| 4 | `--wait` expired; the window is still open |
| 5 | viewer died without a `closed` event |

### Typical agent flows (for SKILL.md)
```sh
P="${CLAUDE_PLUGIN_ROOT}/scripts/html-popup.sh"
# ask: one answer; resume if the user is slow
choice=$("$P" ask report.html --data data.json); jq -r .month <<<"$choice"
# exit 4 → "$P" ask --resume "$dir"

# live: loop until the user is done
dir=$("$P" live start report.html --data data.json)
"$P" live wait "$dir"                 # → {"seq":2,"type":"message","data":{...}}
"$P" live send "$dir" '{"details":{"total":43929}}'   # page updates in place
"$P" live close "$dir"
```
For long human think time the skill recommends the Monitor tool on
`events.jsonl` (or the Bash tool's `run_in_background`) instead of repeated
`wait` calls.

### Example data (Task 9) — public, US EIA
Source: EIA Electric Power Monthly, Table 1.1.A, 2025 values final,
https://www.eia.gov/electricity/monthly/epm_table_grapher.php?t=epmt_1_01_a
Units: GWh (= thousand MWh). Columns: utility-scale PV, small-scale PV
(estimated), solar thermal, total solar, wind, total solar same month 2024.

| Month | utility | small | thermal | total | wind | total2024 |
|-------|--------:|------:|--------:|------:|-----:|----------:|
| Jan | 15622 | 5414 | 88 | 21123 | 42711 | 14309 |
| Feb | 16531 | 5826 | 139 | 22496 | 38726 | 17882 |
| Mar | 23555 | 7988 | 170 | 31714 | 49673 | 23132 |
| Apr | 26927 | 8768 | 298 | 35993 | 45483 | 27073 |
| May | 29931 | 9306 | 330 | 39566 | 37127 | 30910 |
| Jun | 32198 | 9416 | 387 | 42002 | 36107 | 33012 |
| Jul | 33713 | 9847 | 369 | 43929 | 31890 | 33262 |
| Aug | 32129 | 9312 | 337 | 41778 | 27661 | 32741 |
| Sep | 28335 | 8126 | 257 | 36718 | 26046 | 28049 |
| Oct | 24867 | 7544 | 234 | 32645 | 39518 | 26564 |
| Nov | 18457 | 5955 | 130 | 24542 | 40138 | 19234 |
| Dec | 15183 | 5538 | 116 | 20838 | 46497 | 17585 |

## What Goes Where
- **Implementation Steps** (`[ ]` checkboxes): plugin files, viewer, wrapper,
  template, example, skill doc, tests, README/marketplace updates.
- **Post-Completion** (no checkboxes): visual checks on a real desktop,
  sandbox-mode check, installing the plugin from the marketplace.

## Implementation Steps

### Task 1: Scaffold the html-popup plugin and test harness

**Files:**
- Create: `plugins/html-popup/.claude-plugin/plugin.json`
- Modify: `.claude-plugin/marketplace.json`
- Create: `tests/html-popup_test.sh`

- [x] create `plugin.json` (name `html-popup`, version `0.1.0`, author,
      homepage, repository, license — same shape as `gh-lookup`)
- [x] add the `html-popup` entry to `.claude-plugin/marketplace.json`
- [x] create `tests/html-popup_test.sh` with `assert`/`assert_eq`, a
      `trap cleanup EXIT` that kills tracked viewer pids and removes temp
      dirs, and `skip_unless_gui` (`xcrun --find swiftc` + `launchctl
      managername` = `Aqua`)
- [x] write tests: `plugin.json` and `marketplace.json` parse with `jq` and
      contain the `html-popup` entry
- [x] run `tests/html-popup_test.sh` and the other plugin tests — must pass
      before task 2

### Task 2: Wrapper — check and build with hash cache

**Files:**
- Create: `plugins/html-popup/scripts/html-popup.sh`
- Create: `plugins/html-popup/viewer/html-popup-viewer.swift` (minimal stub:
  parses args, exits 2 on usage error)
- Create: `tests/fixtures/fake-swiftc.sh`
- Modify: `tests/html-popup_test.sh`

- [x] implement subcommand dispatch and usage (unknown subcommand → exit 2)
- [x] implement `check`: macOS (`uname`), `xcrun --find swiftc` (skipped
      when `HTML_POPUP_SWIFTC` is set), `jq`, writable cache dir, Aqua
      session; one clear message and exit 2 per missing piece
- [x] implement `build`: sha256 cache key, compile to `.tmp.$$` then `mv`,
      reuse when present, print the path
- [x] create `fake-swiftc.sh` (writes an executable stub to `-o`, appends to
      a call-count file)
- [x] run `shellcheck` on the wrapper and fixture
- [x] write tests: build compiles once and reuses; a changed source hash
      rebuilds; two concurrent builds both succeed and leave one binary
- [x] write tests for errors: `jq` missing (PATH without jq, via a temp bin
      dir of symlinks) → exit 2 with message; unwritable cache dir → exit 2;
      compiler failure (fake exits 1) → exit 2 and no binary left behind
- [x] run tests — must pass before task 3

### Task 3: Viewer — native window, session files and startup

**Files:**
- Modify: `plugins/html-popup/viewer/html-popup-viewer.swift`
- Create: `tests/fixtures/html-popup/basic.html`
- Create: `tests/fixtures/html-popup/noop.js` (empty test script: test mode, no actions)
- Modify: `tests/html-popup_test.sh`

- [x] parse `PAGE --session DIR [--data] [--title] [--size] [--timeout]
      [--test-script]`; exit 2 on usage errors
- [x] on start: `setsid()`, `mkfifo DIR/in`, write `DIR/pid`; event writer
      with increasing `seq`, one `write` per line
- [x] native window per the prototype spec: titled + full-size content,
      transparent title bar, drag view, title from page or `--title`,
      `.accessory` activation + activate, main menu with Edit and Window →
      Close; test mode orders front at alpha 0 without activating
- [x] page load via `loadFileURL` with read access to the page dir; `ready`
      after load; load failure → `closed` `reason: error`, exit 3;
      `--timeout` → `closed` `reason: timeout`, exit 4; close button/Cmd-W →
      `closed` `reason: user`, exit 0
- [x] open `http(s)` link navigations in the default browser and cancel them
      in the popup
- [x] write tests (headless, viewer started directly with a temp session
      dir): `ready` is the first event; `pid` and `in` exist; `--timeout 2`
      → `closed`/`timeout` and exit 4
- [x] write tests for errors: missing page → exit 3 with `closed`/`error`;
      bad args → exit 2
- [x] run tests — must pass before task 4

### Task 4: Viewer — JS bridge (page → agent)

**Files:**
- Modify: `plugins/html-popup/viewer/html-popup-viewer.swift`
- Create: `tests/fixtures/html-popup/*.js` (test scripts)
- Modify: `tests/html-popup_test.sh`

- [x] inject the bridge at document start: `data`, `answer`, `cancel`,
      `send`, `onMessage`, `closeOnEscape`; values posted as
      `JSON.stringify` strings and written to events as-is
- [x] validate `--data` as JSON before load (invalid → `closed`/`error`,
      exit 3); expose it as `htmlPopup.data`
- [x] implement `answer` (event, then `closed`/`answer`), `cancel`
      (`closed`/`cancel`), `send` (`message` event, window stays open), Esc
      handling in the bridge (skip when an editable element has focus)
- [x] write tests: `send` of an object, a string and a float round-trips
      exactly; `answer` gives `answer` then `closed`; `data` round-trips
      `--data`
- [x] write tests for edge cases: `cancel` → `closed`/`cancel`; Esc
      simulated in an input does not close; invalid `--data` → exit 3
- [x] run tests — must pass before task 5

### Task 5: Viewer — inbound FIFO (agent → page)

**Files:**
- Modify: `plugins/html-popup/viewer/html-popup-viewer.swift`
- Create: `tests/fixtures/html-popup/echo.html`
- Modify: `tests/html-popup_test.sh`

- [x] reader thread on `DIR/in` opened read-write; buffer partial lines;
      validate JSON; deliver as a string literal `JSON.parse`d in the page
      on the main thread
- [x] handle `{"htmlPopup":"close"}` → `closed`/`agent`; log invalid lines
      to `viewer.log` and drop them
- [x] write tests (echo page re-sends every received message): a written
      line comes back as a `message` event; a >64 KB message arrives intact
- [x] write tests for edge cases: an invalid line is dropped and the next
      valid one still arrives; close line → `closed`/`agent` and exit 0
- [x] run tests — must pass before task 6

### Task 6: Wrapper — show, ask and live commands

**Files:**
- Modify: `plugins/html-popup/scripts/html-popup.sh`
- Modify: `tests/html-popup_test.sh`

- [x] shared session start: stale-dir cleanup, validation before
      detaching, build, detached start with `</dev/null >>log 2>&1 & disown`,
      wait for `ready` while polling the pid; forward `HTML_POPUP_TEST_SCRIPT`
      as `--test-script`
- [x] implement `show`, `live start` (print DIR) and `ask` / `ask --resume`
      with `--wait` (default 100 s) and the resume hint on exit 4
- [x] implement `live send` (jq validation, closed/pid check, `exec 3<>`
      write), `live wait` (cursor, complete lines only, exit 0/1/4/5 as
      specified) and `live close` (idempotent)
- [x] run `shellcheck` and fix findings
- [x] write tests: `show` and `live start` return within 3 s while the
      viewer stays alive; `ask` prints the answer JSON (test script answers);
      `ask --wait 1` → exit 4 with resume hint, then `ask --resume` gets the
      answer; full live round trip start → send → wait sees echo → close →
      wait exits 1
- [x] write tests for errors: missing page / invalid data → exit 3
      synchronously; send invalid JSON → 2; send after close → 1 without
      hanging; send racing a closing viewer never hangs (bounded by a
      watchdog); wait after `closed` returns 1 at once; viewer killed with
      `kill -9` → wait exits 5; `close` on a gone session → 0
- [x] run tests — must pass before task 7

### Task 7: HTML starter template

**Files:**
- Create: `plugins/html-popup/assets/template.html`
- Modify: `tests/html-popup_test.sh`

- [x] native-looking template: system font, light/dark via
      `prefers-color-scheme`, 44px top padding for traffic lights, header,
      content slot, footer with keyboard hints, no external resources
- [x] minimal commented hooks: a button calling `answer`, one calling
      `send`, an `onMessage` handler that fills a details panel
- [x] write tests: no `http://`/`https://` resource references; headless run
      with a test script clicking the answer button returns the expected JSON
- [x] run tests — must pass before task 8

### Task 8: Reference example — 2025 US solar report

**Files:**
- Create: `plugins/html-popup/examples/solar-2025/report.html`
- Create: `plugins/html-popup/examples/solar-2025/data.json`
- Create: `plugins/html-popup/examples/solar-2025/run.sh`
- Modify: `tests/html-popup_test.sh`

- [x] `data.json` with the 12 months from the Example data table above,
      `unit`, `title` and the `source` line with the EIA URL
- [x] `report.html` built from the template (no duplicated hooks): stacked
      bars (utility + thermal, small-scale), summary tiles (annual total,
      growth vs 2024, peak month, rooftop share), arrow keys + Return
- [x] live behavior: choosing a month sends `{"month":N}`; a details
      message from the agent renders in a side panel without closing; Done
      calls `answer(null)`
- [x] `run.sh`: `live start`, loop `live wait` → compute details with `jq`
      (total, split, YoY, rank, share of year, solar/wind ratio) → `live
      send`, until `closed`
- [x] write tests: `data.json` has 12 months with all fields and totals equal
      utility + small + thermal within ±1; headless run selects a month and
      emits `{"month":N}`; a sent details message renders (test script sends
      the panel text back)
- [x] run `shellcheck` on `run.sh`; run tests — must pass before task 9

### Task 9: SKILL.md — how agents use html-popup

**Files:**
- Create: `plugins/html-popup/skills/html-popup/SKILL.md`
- Modify: `tests/html-popup_test.sh`

- [x] frontmatter: `name: html-popup`, trigger-rich `description` (show an
      HTML report/chart/dialog in a window, ask the user to pick, live
      interactive page), `allowed-tools: Bash, Read, Write`
- [x] document modes, bridge API, exit codes and wrapper commands with
      copy-ready snippets for show, ask (+ resume) and a live loop
- [x] Bash-tool guidance: `--wait` default 100 s, exit 4 means call again;
      use Monitor on `events.jsonl` or `run_in_background` for long waits;
      never send input to the agent's own pane
- [x] token-saving rules: copy `assets/template.html` and fill only the
      body; pass data with `--data`; read the solar example only when a full
      live pattern is needed; write generated pages to a temp/scratch dir
- [x] constraints: macOS + Xcode CLT + `jq`; local files only (no CDN
      scripts or remote fonts); run `check` first on errors; note that
      sandboxed Bash may block the cache dir or window access
- [x] write tests: frontmatter has `name: html-popup` and a description;
      every `scripts/`, `assets/` and `examples/` path mentioned exists
- [x] run tests — must pass before task 10

### Task 10: Verify acceptance criteria
- [x] verify show, ask (with resume) and live modes work as in Overview
- [x] verify the window is native (titled, transparent title bar,
      draggable, Edit shortcuts in inputs, Esc/Cmd-W/close) and never dims
      other windows (one layer-0 window, no backdrop, accessory process, Esc
      covered by tests; drag, Edit shortcuts and Cmd-W skipped - screen was
      locked and not automatable, see Post-Completion)
- [x] verify a killed or timed-out wrapper call leaves the window open
      (➕ regression test `test_wrapper_caller_killed`)
- [x] verify no personal data in any new file (paths, emails, hostnames)
- [x] run full test suite: `for t in tests/*_test.sh; do "$t" || exit 1; done`
- [x] run `shellcheck plugins/html-popup/scripts/*.sh
      plugins/html-popup/examples/*/*.sh tests/html-popup_test.sh
      tests/fixtures/fake-swiftc.sh`
- ⚠️ with the screen locked, pages report `visibilityState=hidden` and rAF
  stalls (both alpha-0 test windows and real ones); timers still run, so the
  tests pass. Recheck on an unlocked desktop.

### Task 11: [Final] Update documentation
- [x] add an `html-popup` section to `README.md` (purpose, requirements,
      install, modes) and update the plugin count in the intro
- [x] update `CLAUDE.md` if new conventions emerged (e.g. compiled-on-use
      Swift sources, GUI-gated tests)
- [x] move this plan to `docs/plans/completed/` (done by the orchestrator after reviews)

## Post-Completion
*Items requiring manual intervention or external systems - no checkboxes, informational only*

**Manual verification**:
- run the solar example on a real desktop with dark windows behind it; check
  the native frame, dragging, keyboard navigation and live detail updates
- check light and dark system appearance with the template
- first-run build time with a cold cache (expect a few seconds)
- run `check` and the solar example from Claude Code with Bash sandboxing
  enabled; note required permissions in SKILL.md if any
- popup appears in front of the terminal and accepts Return/Esc; after it
  gets focus it drops behind other apps when they are clicked (not floating)

**External system updates**:
- install with `/plugin marketplace update` and `/plugin install html-popup`
  on the user's machine
