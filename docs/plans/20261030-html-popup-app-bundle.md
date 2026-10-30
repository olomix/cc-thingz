# html-popup: build the viewer as a local "HTML Popup" app

## Overview
- Build the html-popup viewer into a locally assembled `.app` bundle named
  "HTML Popup" with its own icon, run it as a regular macOS app, and launch
  it through LaunchServices (`open -n -a`).
- Problem: today the viewer is a loose binary with the `.accessory`
  activation policy, started by a double fork. The popup never becomes the
  active app, so the keyboard stays with the terminal until the user clicks
  the window. It also has no Dock icon and is skipped by Cmd-Tab, so once
  the user switches away there is no way back except Mission Control.
- After the change, an open popup is a normal app window: it takes focus
  when it opens, appears in Cmd-Tab and the Dock as "HTML Popup" with the
  chosen icon, and its Dock icon disappears when the window closes. Each
  popup is its own app instance (`open -n`), so two popups show as two
  Cmd-Tab entries; Cmd-` does not cycle between them.
- The wrapper's commands, options, exit codes and event format do not
  change. `SKILL.md` usage stays the same.

## Context (from discovery)
- Plugin: `plugins/html-popup/` in this repo (branch `html-popup-skill`).
- `plugins/html-popup/scripts/html-popup.sh`:
  - `viewer_path` hashes only `viewer/html-popup-viewer.swift` and returns
    `$CACHE_DIR/html-popup-viewer-<12 hex>`.
  - `build_viewer` compiles with `${HTML_POPUP_SWIFTC:-xcrun swiftc}` to
    `<bin>.tmp.$$`, then `mv -f` into place; touches the binary on a cache
    hit; prunes `html-popup-viewer-*` entries older than a day.
  - `start_session` launches the binary with a double fork, writes
    `DIR/pid` itself right away (around line 448), waits for the viewer to
    exec (`await_exec`, bounded by `CLOSE_WAIT`), then for `ready`; the
    ready deadline is saved in `DIR/ready_by` and `ask --wait` uses
    `START_BUDGET`.
  - `require_session` (around line 200) rejects a dir without `pid`.
  - `viewer_alive <dir> <pid>` accepts a pid only if the basename of
    `ps -o comm=` matches `html-popup-viewer-*` and `ps -o args=` contains
    `--session DIR`.
  - The env-var list in the header (lines ~16-20) documents overrides.
- `plugins/html-popup/viewer/html-popup-viewer.swift`:
  - `app.setActivationPolicy(.accessory)` near the end of the file.
  - Non-test launch block sets `window.level = .floating`, calls
    `makeKeyAndOrderFront`, `orderFrontRegardless`, `NSApp.activate()`;
    `windowDidBecomeKey` / `applicationDidBecomeActive` /
    `dropLaunchFloatIfFocused` reset the level later.
  - The viewer writes `DIR/pid` itself at session setup (comment ~line 199
    says the wrapper writes it too); stderr is `freopen`ed to `viewer.log`
    with "a" (~line 185); a comment near line 429 mentions "an unbundled
    binary has no menu"; there is a pre-macOS-14 activation fallback.
  - Test mode (`--test-script`): window at alpha 0, `orderFrontRegardless`,
    no activation.
- Tests: `tests/html-popup_test.sh`; fake compiler
  `tests/fixtures/fake-swiftc.sh` (writes a bash stub to `-o`, counts
  calls, `FAKE_SWIFTC_BODY`, `FAKE_SWIFTC_EXEC_DELAY`); stubs keep the
  `html-popup-viewer-*` name via `exec -a`, carry `--session DIR`, and do
  not write `DIR/pid` (the wrapper does today). Existing tests depend on
  that, e.g. "ask --wait 1 on a viewer slow to exec exits 4, not 5" and
  "viewer dying without events exits 5". GUI tests are gated by
  `skip_unless_gui`, fake-viewer tests by `skip_unless_macos`.
- Conventions (CLAUDE.md): public repo, no personal data (the bundle id
  `com.github.olomix.html-popup` is author attribution, allowed); compiled
  helpers are never committed; GUI tests skip with a clear message;
  external tools are swappable through env vars (`HTML_POPUP_SWIFTC`).

## Measured behaviour (2026-10-30, macOS 27, terminal frontmost)
A probe recorded the frontmost app and window order ~2 s after launch.
Pages lived under the system temp dir (not a TCC-protected folder).

| Launch | Policy | Floating | Popup active? | Above terminal? |
|---|---|---|---|---|
| direct exec (today) | accessory | yes | no | yes (layer 3) |
| direct exec | accessory | no | no | yes |
| direct exec | regular | no | no | yes |
| direct exec, inside `.app` | regular | no | no | yes |
| **`open -n -a X.app --args …`** | **regular** | **no** | **yes** | **yes, layer 0** |
| `open -n -a X.app --args …` | accessory | no | no | no |

Conclusion: focus needs both `.regular` and a LaunchServices launch. With
both, the floating fallback is unnecessary and is removed. Open questions
measured in Task 1 before anything depends on them: test-mode behaviour of
`open -g`, and file access to TCC-protected folders.

### Task 1 results (2026-10-30, macOS 27, terminal frontmost)
Throwaway bundles (unique test ids, viewer compiled with an argv log line)
launched with `open -n … --stdout /dev/null --stderr DIR/viewer.log
--args …`. The LaunchServices type and the front app were sampled every
~50 ms for 2 s after launch; then the probe ran.

| Launch | Plist | Policy | Mode | Front app changes? | LS type | Dock tile? |
|---|---|---|---|---|---|---|
| `open -n -g` | plain | accessory | test | no | UIElement throughout | no |
| `open -n -g` | `LSUIElement=1` | accessory | test | no | UIElement throughout | no |
| `open -n` (no `-g`) | plain | accessory | test | no | UIElement throughout | no |
| `open -n` | `LSUIElement=1` | regular | normal | **no** (popup inactive) | Foreground | yes |
| `open -n` | plain | regular | normal | yes, popup active | Foreground | yes |

- Test mode: an accessory bundle launched with `open -n -g` leaves the
  front app unchanged; no Foreground type or Dock tile was seen in any
  sample. `LSUIElement` adds nothing, and with `LSUIElement=1` a runtime
  `.regular` app does **not** become active (it still gets a Dock tile).
  Decision: no `LSUIElement` in `Info.plist`.
- Log redirection: `--stderr FILE` captures output written before the
  viewer's `freopen` (an argv line, and the usage error for a bad option),
  and appends to an existing file rather than truncating it.
- `open` exits 0 even when the viewer exits at once with status 2 (bad
  option): it reports only launch failures (a missing bundle gives exit 1
  and a message on stderr). Viewer errors must come from `viewer.log` and
  the events file, not from `open`'s status.
- argv: LaunchServices adds nothing (no `-psn_…`); argv is exactly the
  executable path followed by the `--args` values.
- TCC: page + `--data` file in a temp folder under `~/Documents`, regular
  bundle, normal mode. The first launch showed the macOS "would like to
  access files in your Documents folder" prompt (UserNotificationCenter
  frontmost, layer 8). The read blocked until the prompt was answered by a
  click on screen (not by the agent); then data and a sibling script
  loaded. A second launch of the same binary: no prompt, first event in
  0.8 s. A rebuilt binary (same bundle id, new ad-hoc signature): prompted
  again, first event after ~6 s. The launched app is its own responsible
  process, so the terminal's grant no longer covers it, and with ad-hoc
  signing a grant does not survive a rebuild of the viewer.
- Consequences: the prompt blocks the viewer before `app.run` (page check
  and data read), so the `--timeout` timer has not started and the
  wrapper's 10 s ready deadline can pass while the prompt is open. The
  abandoned check must also run after the page/data access, right before
  the window is created. Pages under the system temp dir (what agents
  normally use) are unaffected. The prompt is documented (Task 6) rather
  than avoided by staging files: a page may load sibling resources, so
  copying only the page and data into the session dir would break it.

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
- maintain backward compatibility (wrapper CLI, exit codes, event format)

## Testing Strategy
- **unit tests**: `tests/html-popup_test.sh`, same style as today.
- **build tests** keep the fake compiler and a temp cache dir; they assert
  the bundle layout instead of a loose binary.
- **fake-viewer tests never use real `open`**: a new fixture
  `tests/fixtures/fake-open.sh`, selected with `HTML_POPUP_OPEN`, launches
  the bundle executable directly and detached. Bash-script executables
  launched through real LaunchServices would bounce in the Dock.
- **GUI tests** launch the real bundle through real `open`, with `-g` in
  test mode; the viewer stays `.accessory` in test mode. Task 1 measures
  whether that keeps the frontmost app unchanged and avoids a Dock flash;
  the plan follows the measurement.
- Activation itself (popup becomes frontmost) depends on the user's
  session and is checked by hand (Post-Completion), with the probe recipe
  in Technical Details.

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope
- keep plan in sync with actual work done

## Solution Overview
- **Bundle, assembled locally:** the repo commits only static inputs:
  `viewer/Info.plist` (template), `viewer/AppIcon.svg` (icon source) and
  `viewer/AppIcon.icns` (generated once by a dev script). `build` compiles
  the Swift source as today and assembles `html-popup-viewer-<hash>.app` in
  the cache.
- **No signing or notarization:** the binary keeps the ad-hoc signature
  the linker adds. Nothing is downloaded with a quarantine flag (git
  installs the plugin, the binary is compiled on the user's Mac), so
  Gatekeeper never assesses it. The `open` launch was verified with an
  unsigned bundle.
- **Launch through LaunchServices:** `open -n -a <bundle> … --args PAGE
  --session DIR …`. The process is a child of launchd, so the double fork
  goes away. `open` does not report the pid, so the wrapper finds the
  viewer by its `--session DIR` argument (see Pid handshake).
- **Regular app:** `.regular` outside test mode; the floating fallback is
  removed in the same task as the `open` launch (they only work together).
- **Identity check unchanged:** the executable inside the bundle keeps the
  name `html-popup-viewer-<hash>`, so `viewer_alive` keeps working.

## Technical Details

### Icon (chosen variant "Minimal")
`viewer/AppIcon.svg`, 1024×1024 canvas, macOS squircle with 100-unit margin:

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
  <defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#f2f2f7"/><stop offset="1" stop-color="#c7c7cc"/>
  </linearGradient></defs>
  <rect x="100" y="100" width="824" height="824" rx="185" fill="url(#g)"/>
  <rect x="250" y="290" width="524" height="444" rx="48" fill="none"
        stroke="#1c1c1e" stroke-width="40"/>
  <path d="M250 380h524" stroke="#1c1c1e" stroke-width="40"/>
  <circle cx="310" cy="335" r="14" fill="#1c1c1e"/>
  <circle cx="356" cy="335" r="14" fill="#1c1c1e"/>
  <circle cx="402" cy="335" r="14" fill="#1c1c1e"/>
  <path d="M440 470l-80 70 80 70M584 470l80 70-80 70" fill="none"
        stroke="#0a84ff" stroke-width="40" stroke-linecap="round"
        stroke-linejoin="round"/>
</svg>
```

`viewer/make-icon.sh` (dev-only, never run at install time): render the
SVG to a 1024 px PNG with `qlmanage -t -s 1024`; if that gives a white
background or the wrong size, use a small CoreGraphics `make-icon.swift`
instead (deterministic, stock tools only) and log the decision. Build the
iconset with `sips -z` (16, 32, 128, 256, 512 and their @2x) and pack it
with `iconutil -c icns -o viewer/AppIcon.icns`. The area outside the
squircle stays transparent.

### Info.plist template (`viewer/Info.plist`)
Keys: `CFBundleName` and `CFBundleDisplayName` = `HTML Popup`,
`CFBundleIdentifier` = `com.github.olomix.html-popup`,
`CFBundleExecutable` = `@EXECUTABLE@` (filled in at build time),
`CFBundleIconFile` = `AppIcon`, `CFBundlePackageType` = `APPL`,
`NSHighResolutionCapable` = true, `LSMinimumSystemVersion` = `13.0` (the
viewer has a pre-14 activation fallback; adjust if the code needs more).
No `LSUIElement`: Task 1 showed quiet test runs do not need it, and with
it a runtime `.regular` app does not take focus.

### Bundle layout in the cache
```
$CACHE_DIR/html-popup-viewer-<hash>.app/
  Contents/Info.plist                     (template, @EXECUTABLE@ filled in)
  Contents/MacOS/html-popup-viewer-<hash> (compiled binary)
  Contents/Resources/AppIcon.icns
```
- `<hash>` = first 12 hex chars of
  `cat LAYOUT_VERSION_LINE swift Info.plist AppIcon.icns | shasum -a 256`,
  where the layout version is a constant in the wrapper, so a change to how
  the bundle is assembled also rebuilds.
- Assemble into `<bundle>.tmp.$$/`, then `mv "$tmp" "$bundle"`. BSD `mv`
  has no `-T`: if another builder finished first, the temp dir lands
  inside the bundle. After the `mv`, remove `"$bundle/${tmp##*/}"` if it
  exists. The bundle root must contain only `Contents`.
- `build` prints the bundle path. Touch the bundle on a cache hit.
- Prune `html-popup-viewer-*.app` and `*.app.tmp.*` unused for over a day
  with `rm -rf`, and legacy loose `html-popup-viewer-<hash>` binaries.
  Optionally `lsregister -u` pruned bundles (stale LaunchServices entries
  are otherwise harmless).

### Launch
```sh
"${HTML_POPUP_OPEN:-open}" -n [-g in test mode] -a "$bundle" \
  --stdout /dev/null --stderr "$DIR/viewer.log" \
  --args "$page" --session "$DIR" [viewer options...]
```
- `open` opens `--stdout`/`--stderr` paths separately (append behaviour
  undocumented), so stdout goes to `/dev/null` and only stderr to the log;
  the viewer's own `freopen(…, "a")` keeps appending. Task 1 confirmed
  that pre-`freopen` output (e.g. option parse errors) reaches `viewer.log`
  and that `--stderr` appends.
- An app launched by LaunchServices starts with cwd `/` and without the
  caller's environment, so the wrapper passes absolute paths for the page,
  `--data`, `--session` and the test script, and forwards
  `HTML_POPUP_TEST_SCRIPT` as `--test-script`.
- If `open` exits non-zero, startup fails with exit 2 and its message.
  `open` exits 0 even when the viewer itself fails right away (Task 1), so
  that case is still detected by the pid handshake and ready wait.

### Pid handshake
- After `open` returns, the wrapper polls (every `FIFO_POLL`) for a
  process whose `viewer_alive "$DIR" PID` is true, found via
  `pgrep -f -- "--session $DIR"` or `DIR/pid` written by the viewer,
  whichever comes first, and writes `DIR/pid` itself as today.
- The wait is bounded by the remaining ready budget (`ready_by`, and the
  `ask --wait` budget), not by `CLOSE_WAIT`.
- `require_session` accepts a session that has `ready_by` but no `pid` yet
  ("still starting"): `ask --resume` / `live wait` keep waiting and exit 4
  while it is still starting, so the "slow to exec exits 4" behaviour is
  kept.
- When the ready deadline passes with no viewer, the wrapper writes
  `DIR/abandoned`, appends `closed` with `reason: error` and exits 3 (as
  for "not ready in 10 s" today). A viewer that starts later sees
  `DIR/abandoned` right after its session setup, or again after the page
  and data access (a TCC prompt can block there, Task 1), and exits
  without opening a window, so no untracked window is left.
- A viewer that dies before any event keeps being reported as exit 5 once
  its pid was seen; if it was never seen, the abandoned path applies.

### Fake viewers
- `tests/fixtures/fake-open.sh`: parses `-n`, `-g`, `-a BUNDLE`,
  `--stdout F`, `--stderr F`, `--args …`; double-forks (so "parent is pid
  1" assertions keep their meaning) and execs
  `BUNDLE/Contents/MacOS/*` with the arguments and redirections.
- The fake-swiftc stub writes `$$` to the `--session` dir's `pid` after
  its `exec -a` and before its body, like the real viewer, with a knob for
  a stub that never writes it.

### Viewer
- `app.setActivationPolicy(testMode ? .accessory : .regular)`, set after
  options are parsed.
- Remove the floating fallback (`window.level = .floating`,
  `windowDidBecomeKey`, `applicationDidBecomeActive`,
  `dropLaunchFloatIfFocused`). Keep `makeKeyAndOrderFront`,
  `orderFrontRegardless` and `NSApp.activate()`.
- Exit early if `DIR/abandoned` exists after session setup, and check
  again after the page check and data load, before the window is made.
- `window.isRestorable = false` (a regular app with a fixed bundle id may
  otherwise get saved-state restore).
- Update stale comments (wrapper writes pid; "unbundled binary has no
  menu"); update the wrapper header (double fork, `HTML_POPUP_OPEN`).

### Manual activation check (probe recipe)
With the terminal frontmost, open a popup, then within ~2 s check
`NSWorkspace.shared.frontmostApplication` (should be "HTML Popup") and the
on-screen order from `CGWindowListCopyWindowInfo` (popup above the
terminal, layer 0).

## What Goes Where
- **Implementation Steps** (`[ ]` checkboxes): measurements, icon, plist,
  bundle build, `open` launch with the policy change, tests, docs.
- **Post-Completion** (no checkboxes): on-screen checks of focus, Cmd-Tab,
  Dock icon, icon appearance, protected folders.

## Implementation Steps

### Task 1: Measure the open questions before building on them

**Files:**
- Modify: `docs/plans/20261030-html-popup-app-bundle.md` (record results)

Use a throwaway bundle in a temp dir (not the repo), a probe like the one
in Technical Details, and unregister/delete the bundle afterwards.

- [x] test-mode launch: `open -n -g -a` an accessory-policy bundle while
      the terminal is frontmost; record whether the frontmost app changes
      and whether a Dock tile appears; repeat with `LSUIElement=1` in the
      plist; also check that `LSUIElement=1` + runtime `.regular` +
      `open` without `-g` still makes the popup active
- [x] TCC: launch the regular bundle with a page and a `--data` file in a
      temp folder under `~/Documents` (removed afterwards); record whether
      a permission prompt appears or loading fails
- [x] log redirection: confirm `--stderr` captures output written before
      the viewer's `freopen`, and appends rather than truncates
- [x] argv: confirm LaunchServices adds nothing (e.g. `-psn_…`) to argv
- [x] write the results into this plan (Measured behaviour) and adjust
      Tasks 3–4 and the Info.plist decision if any result differs from
      the assumptions; if TCC prompts, add a task to document it in
      SKILL.md/README (or stage files into the session dir) and log the
      decision
- [x] no code or tests change in this task; run the existing suite to
      confirm nothing else changed

### Task 2: Icon assets for the HTML Popup app

**Files:**
- Create: `plugins/html-popup/viewer/AppIcon.svg`
- Create: `plugins/html-popup/viewer/make-icon.sh` and `make-icon.swift`
- Create: `plugins/html-popup/viewer/AppIcon.icns`
- Modify: `tests/html-popup_test.sh`

- [x] add `AppIcon.svg` with the SVG from Technical Details
- [x] write the dev script and run `shellcheck` on it
- [x] generate and commit `AppIcon.icns`; check that the area outside the
      squircle is transparent
- [x] write a test: `AppIcon.svg` and `AppIcon.icns` exist (`.icns` starts
      with the `icns` magic)
- [x] run tests — must pass before task 3

Result: `qlmanage -t` flattened the SVG onto a white background, so
`make-icon.sh` renders the 1024 px master with `make-icon.swift` (NSImage
loads the SVG, drawn into a clear RGBA bitmap; needs macOS 14+), then
`sips`/`iconutil`. A 256 px preview from the `.icns` has alpha 0 in the
margin and squircle corners.

### Task 3: Build the viewer into a cached .app bundle

**Files:**
- Create: `plugins/html-popup/viewer/Info.plist`
- Modify: `plugins/html-popup/scripts/html-popup.sh`
- Modify: `tests/fixtures/fake-swiftc.sh` (stub writes its pid; knob for
  never writing it)
- Modify: `tests/html-popup_test.sh`

- [x] add the `Info.plist` template from Technical Details
- [x] cache key over the layout version, Swift source, plist and icon
- [x] assemble the bundle in a temp dir and install it; remove a nested
      temp dir left by a concurrent builder
- [x] print the bundle path; touch on cache hit; prune old bundles, temp
      dirs and legacy loose binaries with `rm -rf`
- [x] update callers so the rest of the wrapper still works with the
      bundle (still launched directly in this task; launch changes in
      Task 4); update the fake-swiftc stub to write its pid
- [x] run `shellcheck`
- [x] write tests: bundle layout and filled-in `CFBundleExecutable`
      (`plutil -extract`); cache hit does not recompile; changing
      `Info.plist` or the icon rebuilds; concurrent builds leave one bundle
      whose root holds only `Contents`; old bundles and legacy binaries are
      pruned
- [x] write tests for errors: compiler failure leaves no bundle or temp
      dir; missing `Info.plist`/icon → exit 2 with a message
- [x] run tests — must pass before task 4

Result: on macOS 27 `mv` onto an existing non-empty bundle fails with
"Directory not empty" instead of moving the temp dir inside, so the
install step ignores the `mv` status, removes our temp dir from either
place and then requires the bundle executable to exist. The fake-swiftc
stub writes its pid unless built with `FAKE_SWIFTC_NO_PID=1`.

### Task 4: Launch through LaunchServices as a regular app

**Files:**
- Modify: `plugins/html-popup/scripts/html-popup.sh`
- Modify: `plugins/html-popup/viewer/html-popup-viewer.swift`
- Create: `tests/fixtures/fake-open.sh`
- Modify: `tests/html-popup_test.sh`

- [x] wrapper: launch with `${HTML_POPUP_OPEN:-open} -n [-g] -a …
      --stdout /dev/null --stderr LOG --args …` using absolute paths; drop
      the double fork
- [x] wrapper: pid handshake as in Technical Details (find the viewer by
      `--session DIR`, bounded by the ready budget, "still starting"
      sessions accepted by `require_session`, `DIR/abandoned` on give-up)
- [x] viewer: `.regular` outside test mode, `.accessory` in test mode;
      remove the floating fallback; exit early on `DIR/abandoned` (after
      session setup and again after the page/data access); `isRestorable
      = false`
- [x] update stale comments in the viewer and the wrapper header
      (`HTML_POPUP_OPEN`, no double fork)
- [x] add `tests/fixtures/fake-open.sh`; point every fake-viewer test at
      it via `HTML_POPUP_OPEN`
- [x] run `shellcheck`; viewer compiles with no warnings
- [x] write tests: show / ask / live round trip with the real bundle
      (GUI-gated); the viewer's parent is launchd; a killed wrapper leaves
      the window running; relative page/`--data` paths run from another
      cwd still load; a GUI test run leaves the frontmost app unchanged
- [x] update and write tests for errors: `open` failing → exit 2 with its
      message; "slow to exec" with `ask --wait 1` → exit 4 and
      `ask --resume` works on a session with no pid yet; "dies without
      events" → exit 5; no viewer before the ready deadline → exit 3 and a
      late viewer exits without a window
- [x] run tests — must pass before task 5

Result: the wrapper launches the bundle with `open` and no longer forks or
waits for exec (`await_exec` is gone). `find_viewer` resolves the pid
lazily (DIR/pid, else `pgrep -f -- "--session DIR"` checked by
`viewer_alive`); a still-starting session is accepted everywhere: `ask
--resume` and `live wait` exit 4, `live close` abandons it with reason
`agent`, and any wait past the ready deadline with no viewer abandons it
(exit 3). A late viewer exits 3 without events. `fake-open.sh` also
records its arguments (`FAKE_OPEN_ARGS`) and can fail (`FAKE_OPEN_FAIL`).

### Task 5: Verify acceptance criteria
- [ ] verify the bundle is built locally, launched with `open -n -a`, uses
      `.regular`, and has no floating fallback
- [ ] verify wrapper commands, options, exit codes and events are unchanged
- [ ] verify no personal data in any new or changed file
- [ ] run full test suite: `for t in tests/*_test.sh; do "$t" || exit 1; done`
- [ ] run `shellcheck plugins/html-popup/scripts/*.sh
      plugins/html-popup/viewer/*.sh plugins/html-popup/examples/*/*.sh
      tests/html-popup_test.sh tests/fixtures/*.sh`

### Task 6: [Final] Update documentation
- [ ] README html-popup section: the viewer is built as a local "HTML
      Popup" app, shows in Cmd-Tab/Dock while open, no signing needed,
      each popup is its own Cmd-Tab entry
- [ ] SKILL.md: only agent-visible changes (TCC note: Task 1 found that a
      page or `--data` under `~/Documents`, `~/Desktop` or `~/Downloads`
      triggers a macOS access prompt, again after each viewer rebuild, and
      startup may time out (exit 3) while it is open, so write generated
      pages to the system temp dir; sandboxed Bash may also need access to
      LaunchServices)
- [ ] ➕ README: the same TCC note for users (one prompt per viewer
      build for pages under protected folders)
- [ ] CLAUDE.md: committed generated assets (`AppIcon.icns`) with their
      regeneration script, and the `HTML_POPUP_OPEN` test override
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion
*Items requiring manual intervention or external systems - no checkboxes, informational only*

**Manual verification**:
- with the terminal frontmost, `show`/`ask` a page: the popup becomes the
  active app, takes keyboard input (Return/Esc work without clicking), and
  is a normal window (clicking the terminal puts it behind)
- Cmd-Tab and the Dock show "HTML Popup" with the Minimal icon while a
  popup is open; the icon disappears when it closes; two popups show as
  two Cmd-Tab entries
- the icon looks right at Dock and Cmd-Tab sizes in light and dark mode
- a page and data under `~/Documents` or `~/Desktop` load after the
  documented prompt (Task 1: it appears once per viewer build)

**External system updates**:
- reload the plugin or skill after merging; the first use rebuilds the
  viewer into the new bundle layout
