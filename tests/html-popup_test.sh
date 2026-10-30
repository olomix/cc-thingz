#!/usr/bin/env bash
# Unit tests for the html-popup plugin. Pure bash, no framework.
# Run: tests/html-popup_test.sh  (exits non-zero on first failure)
#
# Viewer tests need a real compiler and a GUI login session; they call
# skip_unless_gui and are skipped elsewhere. Tests that run the wrapper's
# build step or fake viewers need macOS (skip_unless_macos): the wrapper
# knows a viewer by its process name, which exec -a only sets on macOS.
# All other tests always run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_DIR="$REPO_ROOT/plugins/html-popup"
MARKETPLACE="$REPO_ROOT/.claude-plugin/marketplace.json"
FAKE_SWIFTC="$SCRIPT_DIR/fixtures/fake-swiftc.sh"
FAKE_OPEN="$SCRIPT_DIR/fixtures/fake-open.sh"
FIXTURES="$SCRIPT_DIR/fixtures/html-popup"
WRAPPER="$PLUGIN_DIR/scripts/html-popup.sh"
TEMPLATE="$PLUGIN_DIR/assets/template.html"
SOLAR="$PLUGIN_DIR/examples/solar-2025"
SKILL_MD="$PLUGIN_DIR/skills/html-popup/SKILL.md"
# The wrapper only treats processes named like the viewer as one.
FAKE_VIEWER_NAME=html-popup-viewer

PASS_COUNT=0
SKIP_COUNT=0
TRACKED_PIDS=()
TEMP_DIRS=()
VIEWER_BIN=""
VIEWER_CACHE=""
SESSION=""
EVENTS=""
WRAP_TMP=""

# session_pid_of <dir> : the viewer pid recorded in a session dir.
session_pid_of() {
  tr -d '[:space:]' <"$1/pid"
}

# assert exits on the first failure, so viewers and temp dirs must be cleaned
# up from a trap rather than at the end of each test.
cleanup() {
  local pid dir pidfile
  for pid in "${TRACKED_PIDS[@]+"${TRACKED_PIDS[@]}"}"; do
    kill "$pid" 2>/dev/null || true
  done
  # Viewers started through the wrapper are detached; their sessions live
  # under our temp dirs, so find them by pid file.
  for dir in "${TEMP_DIRS[@]+"${TEMP_DIRS[@]}"}"; do
    for pidfile in "$dir"/html-popup.*/pid; do
      [[ -f "$pidfile" ]] || continue
      pid="$(session_pid_of "${pidfile%/pid}")"
      [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    done
    # Viewers still starting (no pid file yet), e.g. a gated stub.
    pkill -f -- "--session $dir/" 2>/dev/null || true
  done
  for dir in "${TEMP_DIRS[@]+"${TEMP_DIRS[@]}"}"; do
    rm -rf "$dir"
  done
}
trap cleanup EXIT

# track_pid <pid> : kill this process when the suite exits.
track_pid() {
  TRACKED_PIDS+=("$1")
}

# new_tmpdir <var> : create a temp dir removed when the suite exits and store
# its path in the named variable (a subshell would lose the tracking).
new_tmpdir() {
  local new_dir
  new_dir="$(mktemp -d "${TMPDIR:-/tmp}/html-popup-test.XXXXXX")"
  TEMP_DIRS+=("$new_dir")
  printf -v "$1" '%s' "$new_dir"
}

# assert <description> <command...> : fails the suite if command exits non-zero.
assert() {
  local desc="$1"
  shift
  if "$@"; then
    PASS_COUNT=$((PASS_COUNT + 1))
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n' "$desc" >&2
    exit 1
  fi
}

# assert_eq <description> <expected> <actual>
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n' "$desc" >&2
    printf '       expected: %q\n' "$expected" >&2
    printf '       actual:   %q\n' "$actual" >&2
    exit 1
  fi
}

# contains <needle> <haystack> : true when haystack contains needle.
contains() {
  case "$2" in
    *"$1"*) return 0 ;;
    *) return 1 ;;
  esac
}

# not_contains <needle> <haystack> : true when haystack lacks needle.
not_contains() {
  ! contains "$1" "$2"
}

# skip_unless_gui <test name> : returns non-zero (and records a skip) unless a
# Swift compiler and an Aqua (GUI login) session are available.
# Usage: skip_unless_gui "viewer startup" || return 0
# Not `html-popup.sh check`: that also honours HTML_POPUP_SWIFTC, and tests
# that need the real viewer must not accept a fake compiler.
skip_unless_gui() {
  local reason=""
  if ! xcrun --find swiftc >/dev/null 2>&1; then
    reason="swiftc not found (install Xcode Command Line Tools)"
  elif [[ "$(launchctl managername 2>/dev/null)" != "Aqua" ]]; then
    reason="not in a GUI (Aqua) login session"
  fi
  if [[ -n "$reason" ]]; then
    SKIP_COUNT=$((SKIP_COUNT + 1))
    printf 'skip - %s: %s\n' "$1" "$reason"
    return 1
  fi
}

# skip_unless_macos <test name> : returns non-zero (and records a skip) off
# macOS, where the wrapper refuses to build.
skip_unless_macos() {
  [[ "$(uname -s)" == "Darwin" ]] && return 0
  SKIP_COUNT=$((SKIP_COUNT + 1))
  printf 'skip - %s: not macOS\n' "$1"
}

# --- Tests: plugin manifest and marketplace entry ----------------------------

test_manifest() {
  local manifest="$PLUGIN_DIR/.claude-plugin/plugin.json"

  assert "plugin.json exists" test -f "$manifest"
  assert "plugin.json parses" jq empty "$manifest"
  assert_eq "plugin.json name" "html-popup" "$(jq -r .name "$manifest")"
  assert_eq "plugin.json version" "0.1.0" "$(jq -r .version "$manifest")"
  assert_eq "plugin.json license" "MIT" "$(jq -r .license "$manifest")"
  assert "plugin.json has a description" \
    test -n "$(jq -r '.description // empty' "$manifest")"
  assert "plugin.json has an author" \
    test -n "$(jq -r '.author.name // empty' "$manifest")"
  assert "plugin.json has a repository" \
    test -n "$(jq -r '.repository // empty' "$manifest")"

  assert "marketplace.json parses" jq empty "$MARKETPLACE"
  assert_eq "marketplace lists html-popup once" "1" \
    "$(jq '[.plugins[] | select(.name == "html-popup")] | length' \
      "$MARKETPLACE")"
  assert_eq "marketplace source points at the plugin" "./plugins/html-popup" \
    "$(jq -r '.plugins[] | select(.name == "html-popup") | .source' \
      "$MARKETPLACE")"
  assert "marketplace entry has a description" \
    test -n "$(jq -r '.plugins[] | select(.name == "html-popup")
      | .description // empty' "$MARKETPLACE")"
}

# --- Tests: app icon assets --------------------------------------------------

test_icon_assets() {
  local viewer="$PLUGIN_DIR/viewer"

  assert "AppIcon.svg exists" test -s "$viewer/AppIcon.svg"
  assert "AppIcon.svg is an SVG" contains "<svg" "$(cat "$viewer/AppIcon.svg")"
  assert "AppIcon.icns exists" test -s "$viewer/AppIcon.icns"
  assert_eq "AppIcon.icns has the icns magic" "icns" \
    "$(head -c 4 "$viewer/AppIcon.icns")"
  assert "make-icon.sh is executable" test -x "$viewer/make-icon.sh"
}

# --- Tests: harness helpers ---------------------------------------------------

test_harness() {
  local dir out rc
  new_tmpdir dir
  assert "new_tmpdir creates a directory" test -d "$dir"
  assert "new_tmpdir tracks the directory for cleanup" \
    contains "$dir" "${TEMP_DIRS[*]}"

  # Probe in a subshell with no xcrun on PATH, so it must skip but does not
  # count as a skip of this run.
  set +e
  out="$(PATH="$dir" skip_unless_gui "harness probe")"
  rc=$?
  set -e
  assert_eq "skip_unless_gui fails without a compiler" "1" "$rc"
  assert "skip_unless_gui names the reason" contains "swiftc not found" "$out"
}

# --- Helpers: running the wrapper ---------------------------------------------

# run_capture <command...> : run command, store stdout/stderr/exit code in
# OUT, ERR and RC without tripping set -e.
run_capture() {
  local err_file
  err_file="$(mktemp "${TMPDIR:-/tmp}/html-popup-test-err.XXXXXX")"
  set +e
  OUT="$("$@" 2>"$err_file")"
  RC=$?
  set -e
  ERR="$(cat "$err_file")"
  rm -f "$err_file"
}

# copy_plugin <var> : copy the plugin into a temp dir so a test can change the
# viewer source without touching the repo; store the copy's root in <var>.
copy_plugin() {
  local copy_root
  new_tmpdir copy_root
  cp -R "$PLUGIN_DIR/." "$copy_root/"
  printf -v "$1" '%s' "$copy_root"
}

# dir_entries <dir> : names in dir, sorted and space separated.
dir_entries() {
  { find "$1" -mindepth 1 -maxdepth 1 -exec basename {} \; 2>/dev/null ||
    true; } | sort | xargs
}

# count_lines <file> : number of lines, 0 when the file does not exist.
count_lines() {
  if [[ -f "$1" ]]; then
    wc -l <"$1" | tr -d ' '
  else
    printf '0'
  fi
}

# count_messages <file> : number of non-blank lines, 0 when the file does not
# exist. Each send starts with a newline, so FIFO copies hold blank lines.
count_messages() {
  if [[ -f "$1" ]]; then
    grep -c . "$1" || true
  else
    printf '0'
  fi
}

# --- Tests: subcommand dispatch -----------------------------------------------

test_dispatch() {
  local cmd
  run_capture "$WRAPPER"
  assert_eq "no command exits 2" "2" "$RC"
  assert "no command prints usage" contains "usage:" "$ERR"

  run_capture "$WRAPPER" frobnicate
  assert_eq "unknown command exits 2" "2" "$RC"
  assert "unknown command is named" \
    contains "unknown command: frobnicate" "$ERR"

  run_capture "$WRAPPER" --help
  assert_eq "--help exits 0" "0" "$RC"

  for cmd in check build; do
    run_capture "$WRAPPER" "$cmd" extra
    assert_eq "$cmd with an argument exits 2" "2" "$RC"
    assert "$cmd names the extra argument" \
      contains "unexpected argument: extra" "$ERR"
  done
}

# --- Tests: build with hash cache ---------------------------------------------

# bundle_exec <bundle> : the viewer executable inside a built bundle.
bundle_exec() {
  printf '%s/Contents/MacOS/html-popup-viewer' "$1"
}

# matches <regex> <string> : true when string matches the extended regex.
matches() {
  [[ "$2" =~ $1 ]]
}

test_build_cache() {
  skip_unless_macos "build cache" || return 0
  local root cache calls wrapper first second third plist
  copy_plugin root
  new_tmpdir cache
  calls="$cache/calls"
  wrapper="$root/scripts/html-popup.sh"
  export CLAUDE_PLUGIN_DATA="$cache/bin" HTML_POPUP_SWIFTC="$FAKE_SWIFTC"
  export FAKE_SWIFTC_CALLS="$calls"

  run_capture "$wrapper" build
  assert_eq "build exits 0" "0" "$RC"
  first="$OUT"
  assert "bundle is named after an input hash" \
    matches "^$cache/bin/html-popup-viewer-[0-9a-f]{12}\\.app\$" "$first"
  assert_eq "bundle root holds only Contents" "Contents" \
    "$(dir_entries "$first")"
  assert "bundle executable is html-popup-viewer" \
    test -x "$first/Contents/MacOS/html-popup-viewer"
  assert "bundle has the icon" \
    cmp -s "$root/viewer/AppIcon.icns" "$first/Contents/Resources/AppIcon.icns"
  plist="$first/Contents/Info.plist"
  assert_eq "CFBundleExecutable names the executable" html-popup-viewer \
    "$(plutil -extract CFBundleExecutable raw -o - "$plist")"
  assert_eq "CFBundleName is HTML Popup" "HTML Popup" \
    "$(plutil -extract CFBundleName raw -o - "$plist")"
  assert_eq "first build compiles once" "1" "$(count_lines "$calls")"

  run_capture "$wrapper" build
  assert_eq "second build exits 0" "0" "$RC"
  assert_eq "second build reuses the bundle" "$first" "$OUT"
  assert_eq "second build does not compile" "1" "$(count_lines "$calls")"

  printf '// changed\n' >>"$root/viewer/html-popup-viewer.swift"
  run_capture "$wrapper" build
  second="$OUT"
  assert_eq "changed source builds" "0" "$RC"
  assert "changed source gets a new bundle" test "$first" != "$second"
  assert "new bundle is executable" test -x "$(bundle_exec "$second")"
  assert_eq "changed source compiles again" "2" "$(count_lines "$calls")"
  assert "bundle used within a day is kept" test -e "$first"

  printf '<!-- changed -->\n' >>"$root/viewer/Info.plist"
  run_capture "$wrapper" build
  third="$OUT"
  assert_eq "changed Info.plist builds" "0" "$RC"
  assert "changed Info.plist gets a new bundle" test "$second" != "$third"
  assert_eq "changed Info.plist compiles again" "3" "$(count_lines "$calls")"

  printf 'x' >>"$root/viewer/AppIcon.icns"
  run_capture "$wrapper" build
  assert_eq "changed icon builds" "0" "$RC"
  assert "changed icon gets a new bundle" test "$third" != "$OUT"
  assert_eq "changed icon compiles again" "4" "$(count_lines "$calls")"

  # A bundle that lost its executable is rebuilt, not reported forever.
  third="$OUT"
  rm -rf "$third/Contents/MacOS"
  run_capture "$wrapper" build
  assert_eq "partial bundle rebuilds" "0" "$RC"
  assert_eq "partial bundle keeps its path" "$third" "$OUT"
  assert "rebuilt bundle is executable" test -x "$(bundle_exec "$OUT")"
  assert_eq "rebuilt bundle root holds only Contents" "Contents" \
    "$(dir_entries "$OUT")"
  assert_eq "partial bundle compiles again" "5" "$(count_lines "$calls")"
  unset CLAUDE_PLUGIN_DATA HTML_POPUP_SWIFTC FAKE_SWIFTC_CALLS
}

test_build_prune() {
  skip_unless_macos "build prune" || return 0
  local cache bin wrapper current old
  new_tmpdir cache
  bin="$cache/bin"
  wrapper="$PLUGIN_DIR/scripts/html-popup.sh"
  export CLAUDE_PLUGIN_DATA="$bin" HTML_POPUP_SWIFTC="$FAKE_SWIFTC"

  run_capture "$wrapper" build
  assert_eq "build exits 0" "0" "$RC"
  current="$OUT"
  # Old bundles, temp dirs and legacy loose binaries from earlier versions.
  old="$bin/html-popup-viewer-000000000000"
  mkdir -p "$old.app/Contents/MacOS" "$old.app.tmp.1/Contents"
  : >"$old" && : >"$old.tmp.2"
  mkdir -p "$bin/html-popup-viewer-111111111111.app/Contents"
  touch -t 202001010000 "$old.app" "$old.app.tmp.1" "$old" "$old.tmp.2" \
    "$current"
  run_capture "$wrapper" build
  assert_eq "cached build exits 0" "0" "$RC"
  assert "a cached build refreshes its bundle" \
    test -z "$(find "$current" -maxdepth 0 -mtime +0)"
  assert "cache hit does not prune" test -e "$old.app"

  rm -rf "$current"
  run_capture "$wrapper" build
  unset CLAUDE_PLUGIN_DATA HTML_POPUP_SWIFTC
  assert_eq "rebuild exits 0" "0" "$RC"
  assert "bundle unused for a day is removed" test ! -e "$old.app"
  assert "old temp dir is removed" test ! -e "$old.app.tmp.1"
  assert "legacy binary is removed" test ! -e "$old"
  assert "legacy temp file is removed" test ! -e "$old.tmp.2"
  assert "recently used bundle is kept" \
    test -d "$bin/html-popup-viewer-111111111111.app"
  assert "rebuilt bundle is executable" test -x "$(bundle_exec "$OUT")"
}

test_build_concurrent() {
  skip_unless_macos "concurrent builds" || return 0
  local cache wrapper out1 out2 rc1=0 rc2=0 pid1 pid2 entries
  new_tmpdir cache
  wrapper="$PLUGIN_DIR/scripts/html-popup.sh"
  export CLAUDE_PLUGIN_DATA="$cache/bin" HTML_POPUP_SWIFTC="$FAKE_SWIFTC"
  export FAKE_SWIFTC_DELAY=1 FAKE_SWIFTC_CALLS="$cache/calls"

  "$wrapper" build >"$cache/out1" 2>/dev/null &
  pid1=$!
  "$wrapper" build >"$cache/out2" 2>/dev/null &
  pid2=$!
  wait "$pid1" || rc1=$?
  wait "$pid2" || rc2=$?
  unset CLAUDE_PLUGIN_DATA HTML_POPUP_SWIFTC FAKE_SWIFTC_DELAY FAKE_SWIFTC_CALLS

  assert_eq "both builds compiled at the same time" "2" \
    "$(count_lines "$cache/calls")"
  out1="$(cat "$cache/out1")"
  out2="$(cat "$cache/out2")"
  assert_eq "first concurrent build exits 0" "0" "$rc1"
  assert_eq "second concurrent build exits 0" "0" "$rc2"
  assert_eq "concurrent builds print the same path" "$out1" "$out2"
  entries="$(dir_entries "$cache/bin")"
  assert_eq "concurrent builds leave exactly one bundle" \
    "$(basename "$out1")" "$entries"
  assert_eq "the bundle root holds only Contents" "Contents" \
    "$(dir_entries "$out1")"
  assert "the bundle executable runs" test -x "$(bundle_exec "$out1")"
}

# --- Tests: check and build errors --------------------------------------------

test_missing_jq() {
  skip_unless_macos "missing jq" || return 0
  local bin cache tool cmd
  new_tmpdir bin
  new_tmpdir cache
  # A PATH with only the tools the wrapper needs, so jq is surely absent.
  for tool in uname launchctl mkdir dirname shasum mv rm cat; do
    ln -s "$(command -v "$tool")" "$bin/$tool"
  done

  run_capture env PATH="$bin" CLAUDE_PLUGIN_DATA="$cache" \
    HTML_POPUP_SWIFTC="$FAKE_SWIFTC" /bin/bash \
    "$PLUGIN_DIR/scripts/html-popup.sh" check
  assert_eq "check without jq exits 2" "2" "$RC"
  assert "check names the missing jq" contains "jq not found" "$ERR"
  assert "check does not blame the compiler" not_contains "swiftc" "$ERR"

  for cmd in show "live wait"; do
    # shellcheck disable=SC2086 # split "live wait" into two words
    run_capture env PATH="$bin" CLAUDE_PLUGIN_DATA="$cache" /bin/bash \
      "$PLUGIN_DIR/scripts/html-popup.sh" $cmd "$FIXTURES/basic.html"
    assert_eq "$cmd without jq exits 2" "2" "$RC"
    assert "$cmd names the missing jq" contains "jq not found" "$ERR"
  done
}

test_check_ok() {
  skip_unless_gui "check passes with all dependencies" || return 0
  local cache
  new_tmpdir cache
  run_capture env CLAUDE_PLUGIN_DATA="$cache" \
    "$PLUGIN_DIR/scripts/html-popup.sh" check
  assert_eq "check exits 0 when everything is present" "0" "$RC"
  assert "check reports success" contains "all checks passed" "$OUT"
}

test_missing_compiler() {
  local cache
  new_tmpdir cache
  run_capture env CLAUDE_PLUGIN_DATA="$cache" \
    HTML_POPUP_SWIFTC="$cache/no-such-swiftc" \
    "$PLUGIN_DIR/scripts/html-popup.sh" build
  assert_eq "build with a missing compiler exits 2" "2" "$RC"
  assert "build names the missing compiler" \
    contains "HTML_POPUP_SWIFTC not found" "$ERR"
}

test_unwritable_cache() {
  skip_unless_macos "unwritable cache" || return 0
  if [[ "$(id -u)" == 0 ]]; then
    SKIP_COUNT=$((SKIP_COUNT + 1))
    printf 'skip - unwritable cache: root ignores directory modes\n'
    return 0
  fi
  local parent
  new_tmpdir parent
  chmod 555 "$parent"
  run_capture env CLAUDE_PLUGIN_DATA="$parent/cache" \
    HTML_POPUP_SWIFTC="$FAKE_SWIFTC" "$PLUGIN_DIR/scripts/html-popup.sh" build
  chmod 755 "$parent"
  assert_eq "build with an unwritable cache exits 2" "2" "$RC"
  assert "build names the unwritable cache" contains "not writable" "$ERR"
  assert "no binary path printed" test -z "$OUT"

  chmod 555 "$parent"
  run_capture env CLAUDE_PLUGIN_DATA="$parent" \
    HTML_POPUP_SWIFTC="$FAKE_SWIFTC" "$PLUGIN_DIR/scripts/html-popup.sh" check
  chmod 755 "$parent"
  assert_eq "check with a read-only cache dir exits 2" "2" "$RC"
  assert "check names the read-only cache" contains "not writable" "$ERR"
}

test_compiler_failure() {
  skip_unless_macos "compiler failure" || return 0
  local cache left
  new_tmpdir cache
  run_capture env CLAUDE_PLUGIN_DATA="$cache/bin" \
    HTML_POPUP_SWIFTC="$FAKE_SWIFTC" FAKE_SWIFTC_FAIL=1 \
    "$PLUGIN_DIR/scripts/html-popup.sh" build
  assert_eq "failed compile exits 2" "2" "$RC"
  assert "failed compile is reported" contains "failed to compile" "$ERR"
  assert "compiler output is passed through" \
    contains "simulated compile failure" "$ERR"
  left="$(dir_entries "$cache/bin")"
  assert_eq "failed compile leaves no bundle or temp dir" "" "$left"
}

test_missing_bundle_inputs() {
  skip_unless_macos "missing bundle inputs" || return 0
  local root cache file
  for file in Info.plist AppIcon.icns; do
    copy_plugin root
    new_tmpdir cache
    rm "$root/viewer/$file"
    run_capture env CLAUDE_PLUGIN_DATA="$cache/bin" \
      HTML_POPUP_SWIFTC="$FAKE_SWIFTC" "$root/scripts/html-popup.sh" build
    assert_eq "build without $file exits 2" "2" "$RC"
    assert "build names the missing $file" contains "$file" "$ERR"
    assert "build without $file prints no path" test -z "$OUT"
    assert_eq "build without $file leaves the cache empty" "" \
      "$(dir_entries "$cache/bin")"
  done
}

# Compiles the real viewer source, so it needs Xcode tools.
test_real_build() {
  skip_unless_gui "real viewer build" || return 0
  local rc=0
  ensure_viewer
  assert "real build produces an executable" test -x "$VIEWER_BIN"
  "$VIEWER_BIN" >/dev/null 2>&1 || rc=$?
  assert_eq "viewer without arguments exits 2" "2" "$rc"
}

# --- Helpers: running the real viewer -----------------------------------------

# ensure_viewer : build the real viewer once per run; VIEWER_BIN is the
# executable inside the bundle.
ensure_viewer() {
  [[ -n "$VIEWER_BIN" ]] && return 0
  new_tmpdir VIEWER_CACHE
  run_capture env CLAUDE_PLUGIN_DATA="$VIEWER_CACHE" \
    "$PLUGIN_DIR/scripts/html-popup.sh" build
  assert_eq "viewer builds for viewer tests" "0" "$RC"
  VIEWER_BIN="$(bundle_exec "$OUT")"
}

# start_viewer <args...> : start the viewer in the background (tracked for
# cleanup) and store its pid in VIEWER_PID. Collect it with finish_viewer.
# Like open --stderr, stderr goes to the session's viewer.log.
start_viewer() {
  local log=/dev/null arg prev=""
  for arg in "$@"; do
    [[ "$prev" == --session ]] && log="$arg/viewer.log"
    prev="$arg"
  done
  "$VIEWER_BIN" "$@" >/dev/null 2>>"$log" &
  VIEWER_PID=$!
  track_pid "$VIEWER_PID"
}

# finish_viewer : wait for the VIEWER_PID started by start_viewer; set RC.
finish_viewer() {
  set +e
  wait "$VIEWER_PID"
  RC=$?
  set -e
}

# run_viewer <args...> : start_viewer, then finish_viewer. Callers always
# pass --timeout, so the wait is bounded.
run_viewer() {
  start_viewer "$@"
  finish_viewer
}

# run_bounded <seconds> <command...> : run command with a watchdog; sets RC
# (124 when the watchdog had to kill it).
run_bounded() {
  local secs="$1" pid watchdog
  shift
  "$@" >/dev/null 2>&1 &
  pid=$!
  (sleep "$secs" && kill -9 "$pid" 2>/dev/null) >/dev/null 2>&1 &
  watchdog=$!
  set +e
  wait "$pid"
  RC=$?
  set -e
  if ! kill -0 "$watchdog" 2>/dev/null; then
    RC=124
  fi
  pkill -P "$watchdog" 2>/dev/null || true
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
}

# event_field <events file> <line number> <jq filter>
event_field() {
  sed -n "${2}p" "$1" | jq -r "$3"
}

# --- Tests: viewer window and session files -----------------------------------

test_viewer_startup() {
  skip_unless_gui "viewer startup and timeout" || return 0
  ensure_viewer
  local session events
  new_tmpdir session
  events="$session/events.jsonl"

  run_viewer "$FIXTURES/basic.html" --session "$session" --timeout 2 \
    --test-script "$FIXTURES/noop.js"
  assert_eq "--timeout exits 4" "4" "$RC"
  assert_eq "ready is the first event" "ready" \
    "$(event_field "$events" 1 .type)"
  assert_eq "ready has seq 1" "1" "$(event_field "$events" 1 .seq)"
  assert_eq "timeout writes closed" "closed" "$(event_field "$events" 2 .type)"
  assert_eq "closed reason is timeout" "timeout" \
    "$(event_field "$events" 2 .reason)"
  assert_eq "closed has seq 2" "2" "$(event_field "$events" 2 .seq)"
  assert_eq "exactly two events" "2" "$(count_lines "$events")"
  assert_eq "pid file holds the viewer pid" "$VIEWER_PID" \
    "$(session_pid_of "$session")"
  assert "inbound FIFO exists" test -p "$session/in"
  assert "viewer.log exists" test -f "$session/viewer.log"
}

test_viewer_errors() {
  skip_unless_gui "viewer errors" || return 0
  ensure_viewer
  local session events
  new_tmpdir session
  events="$session/events.jsonl"

  run_viewer "$session/no-such-page.html" --session "$session" --timeout 5 \
    --test-script "$FIXTURES/noop.js"
  assert_eq "missing page exits 3" "3" "$RC"
  assert_eq "missing page writes one event" "1" "$(count_lines "$events")"
  assert_eq "missing page writes closed" "closed" \
    "$(event_field "$events" 1 .type)"
  assert_eq "missing page reason is error" "error" \
    "$(event_field "$events" 1 .reason)"
  assert "missing page names the page" \
    contains "no-such-page.html" "$(event_field "$events" 1 .message)"

  # A directory passes the readable check but WebKit fails to load it.
  new_tmpdir session
  events="$session/events.jsonl"
  run_viewer "$FIXTURES" --session "$session" --timeout 5 \
    --test-script "$FIXTURES/noop.js"
  assert_eq "load failure exits 3" "3" "$RC"
  assert_eq "load failure reason is error" "error" \
    "$(event_field "$events" 1 .reason)"
  assert "load failure is logged" \
    contains "failed to load" "$(cat "$session/viewer.log")"

  new_tmpdir session
  run_capture "$VIEWER_BIN" "$FIXTURES/basic.html"
  assert_eq "missing --session exits 2" "2" "$RC"
  assert "missing --session is named" contains "missing --session" "$ERR"

  run_capture "$VIEWER_BIN" "$FIXTURES/basic.html" --session "$session" \
    --size 10
  assert_eq "bad --size exits 2" "2" "$RC"
  assert "bad --size is named" contains "bad --size" "$ERR"

  run_capture "$VIEWER_BIN" "$FIXTURES/basic.html" --session "$session" \
    --timeout soon
  assert_eq "bad --timeout exits 2" "2" "$RC"

  run_capture "$VIEWER_BIN" "$FIXTURES/basic.html" --session "$session" \
    --frobnicate
  assert_eq "unknown option exits 2" "2" "$RC"
  assert "unknown option is named" contains "unknown option" "$ERR"

  run_capture "$VIEWER_BIN" a.html b.html --session "$session"
  assert_eq "two pages exit 2" "2" "$RC"
  assert "usage errors write no events" test ! -e "$session/events.jsonl"
}

# A viewer that starts after the wrapper gave up must not open a window.
test_viewer_abandoned() {
  skip_unless_gui "late viewer of an abandoned session" || return 0
  ensure_viewer
  local session
  new_tmpdir session
  : >"$session/abandoned"
  run_viewer "$FIXTURES/basic.html" --session "$session" --timeout 5 \
    --test-script "$FIXTURES/noop.js"
  assert_eq "late viewer exits 3" "3" "$RC"
  assert_eq "late viewer writes no events" "0" \
    "$(count_lines "$session/events.jsonl")"
  assert "late viewer logs why it exits" \
    contains "abandoned" "$(cat "$session/viewer.log")"
}

# --- Tests: JS bridge (page -> agent) -----------------------------------------

# run_bridge <test script> [viewer args...] : run bridge.html in a fresh
# session with the given test script; sets SESSION, EVENTS, RC.
run_bridge() {
  local script="$1"
  shift
  new_tmpdir SESSION
  EVENTS="$SESSION/events.jsonl"
  run_viewer "$FIXTURES/bridge.html" --session "$SESSION" --timeout 10 \
    --test-script "$FIXTURES/$script" "$@"
}

test_bridge_send() {
  skip_unless_gui "bridge send" || return 0
  ensure_viewer
  run_bridge send.js
  assert_eq "send then cancel exits 0" "0" "$RC"
  assert_eq "send writes ready, three messages and closed" "5" \
    "$(count_lines "$EVENTS")"
  local object='{"seq":2,"type":"message","data":'
  object+='{"action":"select","month":7,"nested":{"list":[1,"two"]}}}'
  assert_eq "object message round-trips" "$object" "$(sed -n 2p "$EVENTS")"
  assert_eq "string message round-trips" \
    '{"seq":3,"type":"message","data":"plain text"}' "$(sed -n 3p "$EVENTS")"
  assert_eq "float message keeps every digit" \
    '{"seq":4,"type":"message","data":0.30000000000000004}' \
    "$(sed -n 4p "$EVENTS")"
  assert_eq "cancel closes with reason cancel" \
    '{"seq":5,"type":"closed","reason":"cancel"}' "$(sed -n 5p "$EVENTS")"
}

test_bridge_answer() {
  skip_unless_gui "bridge answer" || return 0
  ensure_viewer
  run_bridge answer.js
  assert_eq "answer exits 0" "0" "$RC"
  assert_eq "answer writes three events" "3" "$(count_lines "$EVENTS")"
  assert_eq "answer event carries the value" \
    '{"seq":2,"type":"answer","data":{"month":7}}' "$(sed -n 2p "$EVENTS")"
  assert_eq "answer closes with reason answer" \
    '{"seq":3,"type":"closed","reason":"answer"}' "$(sed -n 3p "$EVENTS")"
}

test_bridge_data() {
  skip_unless_gui "bridge data" || return 0
  ensure_viewer
  run_bridge data.js --data "$FIXTURES/data.json"
  assert_eq "data echo exits 0" "0" "$RC"
  assert_eq "htmlPopup.data round-trips --data" \
    "$(jq -cS . "$FIXTURES/data.json")" \
    "$(event_field "$EVENTS" 2 '.data' | jq -cS .)"

  run_bridge data.js
  assert_eq "htmlPopup.data is null without --data" "null" \
    "$(event_field "$EVENTS" 2 '.data')"
}

test_bridge_escape() {
  skip_unless_gui "bridge escape" || return 0
  ensure_viewer
  run_bridge escape-input.js
  assert_eq "Esc in an input keeps the window open" "still open" \
    "$(event_field "$EVENTS" 2 .data)"
  assert_eq "window closes later by cancel" "cancel" \
    "$(event_field "$EVENTS" 3 .reason)"

  run_bridge escape.js
  assert_eq "Esc outside inputs exits 0" "0" "$RC"
  assert_eq "Esc outside inputs closes with reason user" \
    '{"seq":2,"type":"closed","reason":"user"}' "$(sed -n 2p "$EVENTS")"

  run_bridge escape-variants.js
  assert_eq "Esc variants keep the window open until cancel" \
    'textarea select div closeOnEscape off prevented' \
    "$(jq -r 'select(.type == "message") | .data' "$EVENTS" | paste -sd ' ' -)"
  assert_eq "Esc variants end with cancel" "cancel" \
    "$(tail -n 1 "$EVENTS" | jq -r .reason)"
}

test_bridge_raw_posts() {
  skip_unless_gui "bridge direct posts" || return 0
  ensure_viewer
  local log
  run_bridge bridge-raw.js
  assert_eq "direct posts exit 0" "0" "$RC"
  assert_eq "only strict one-line JSON values become events" \
    '{"seq":2,"type":"message","data":null}
{"seq":3,"type":"message","data":{"a":1}}
{"seq":4,"type":"message","data":{"b":"x,}"}}
{"seq":5,"type":"closed","reason":"cancel"}' "$(sed -n '2,$p' "$EVENTS")"
  log="$(cat "$SESSION/viewer.log")"
  assert "multi-line and non-JSON values are logged" \
    contains "dropped send with a value that is not one-line JSON" "$log"
  assert "unknown type is logged" contains "unknown bridge message type" "$log"
  assert "malformed body is logged" contains "malformed bridge message" "$log"
}

test_bridge_child_frame() {
  skip_unless_gui "bridge ignores child frames" || return 0
  ensure_viewer
  run_bridge child-frame.js
  assert_eq "child-frame post leaves the cancel exit 0" "0" "$RC"
  assert_eq "iframe answer never reaches the event log" \
    '{"seq":2,"type":"closed","reason":"cancel"}' "$(sed -n '2,$p' "$EVENTS")"
  assert "dropped child-frame message is logged" \
    contains "dropped bridge message from a child frame" \
    "$(cat "$SESSION/viewer.log")"
}

test_viewer_size() {
  skip_unless_gui "viewer --size" || return 0
  ensure_viewer
  run_bridge size.js --size 500x400
  assert_eq "--size sets the page size" "[500,400]" \
    "$(event_field "$EVENTS" 2 '.data | tojson')"
}

test_bridge_bad_data() {
  skip_unless_gui "bridge invalid data" || return 0
  ensure_viewer
  run_bridge noop.js --data "$FIXTURES/bad-data.json"
  assert_eq "invalid --data exits 3" "3" "$RC"
  assert_eq "invalid --data writes only closed" "1" "$(count_lines "$EVENTS")"
  assert_eq "invalid --data reason is error" "error" \
    "$(event_field "$EVENTS" 1 .reason)"
  assert "invalid --data is explained" \
    contains "not valid JSON" "$(event_field "$EVENTS" 1 .message)"

  run_bridge noop.js --data "$SESSION/no-such-data.json"
  assert_eq "missing --data exits 3" "3" "$RC"
  assert "missing --data is explained" \
    contains "no-such-data.json" "$(event_field "$EVENTS" 1 .message)"
}

# --- Tests: inbound FIFO (agent -> page) --------------------------------------

# wait_for_event <events file> <jq condition> <seconds> : poll until some
# event matches the condition; non-zero when time runs out.
wait_for_event() {
  local file="$1" cond="$2" tries=$(($3 * 10))
  while ((tries-- > 0)); do
    if [[ -f "$file" ]] &&
      jq -en "any(inputs; $cond)" "$file" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

# fifo_append <fifo> <text> : write text plus a newline to the FIFO.
fifo_append() {
  exec 3<>"$1"
  printf '%s\n' "$2" >&3
}

# fifo_write <fifo> <text> : fifo_append under a watchdog. A read-write open
# never blocks, but a large write blocks until the viewer reads it.
fifo_write() {
  run_bounded 10 fifo_append "$@"
  return "$RC"
}

# start_echo : run echo.html in a fresh session and wait for ready; sets
# SESSION, EVENTS and VIEWER_PID.
start_echo() {
  new_tmpdir SESSION
  EVENTS="$SESSION/events.jsonl"
  start_viewer "$FIXTURES/echo.html" --session "$SESSION" --timeout 20 \
    --test-script "$FIXTURES/noop.js"
  assert "echo page becomes ready" \
    wait_for_event "$EVENTS" '.type == "ready"' 10
}

test_inbound_echo() {
  skip_unless_gui "inbound messages" || return 0
  ensure_viewer
  local big tricky
  start_echo

  assert "small message is written" \
    fifo_write "$SESSION/in" '{"action":"select","month":7}'
  assert "small message comes back as a message event" \
    wait_for_event "$EVENTS" '.type == "message" and .data.month == 7' 5
  assert_eq "small message round-trips exactly" \
    '{"seq":2,"type":"message","data":{"action":"select","month":7}}' \
    "$(sed -n 2p "$EVENTS")"

  # Larger than any pipe buffer, so it arrives in several reads.
  big="$(jq -cn '{blob: ("0123456789abcdef" * 4500), n: 1.5}')"
  assert "message is over 64 KB" test "${#big}" -gt 65536
  assert "large message is written" fifo_write "$SESSION/in" "$big"
  assert "large message comes back" \
    wait_for_event "$EVENTS" '.type == "message" and .data.n == 1.5' 10
  assert_eq "large message arrives intact" "$big" \
    "$(jq -c 'select(.data.n == 1.5) | .data' "$EVENTS")"

  # Agent text reaches the page as data, never as page source.
  tricky='{"s":"q\" \\ </script> \"); htmlPopup.send(\"pwned\"); (\"",'
  tricky+='"u":"\u2028—✓"}'
  assert "tricky message is written" fifo_write "$SESSION/in" "$tricky"
  assert "tricky message comes back" \
    wait_for_event "$EVENTS" '.type == "message" and .data.u != null' 5
  assert_eq "tricky message round-trips exactly" "$(jq -c . <<<"$tricky")" \
    "$(jq -c 'select(.data.u != null) | .data' "$EVENTS")"
  assert "no injected message" not_contains '"data":"pwned"' "$(cat "$EVENTS")"

  assert "close line is written" \
    fifo_write "$SESSION/in" '{"htmlPopup":"close"}'
  finish_viewer
  assert_eq "close line exits 0" "0" "$RC"
  assert_eq "close line closes with reason agent" \
    '{"seq":5,"type":"closed","reason":"agent"}' "$(tail -n 1 "$EVENTS")"
}

test_inbound_invalid() {
  skip_unless_gui "inbound invalid lines" || return 0
  ensure_viewer
  start_echo

  assert "invalid line is written" fifo_write "$SESSION/in" '{"broken":'
  assert "blank line is written" fifo_write "$SESSION/in" ''
  assert "valid line after it is written" fifo_write "$SESSION/in" '"after"'
  assert "valid line after an invalid one arrives" \
    wait_for_event "$EVENTS" '.type == "message"' 5
  assert_eq "only the valid line reaches the page" \
    '{"seq":2,"type":"message","data":"after"}' "$(sed -n 2p "$EVENTS")"
  assert "invalid line is logged" \
    contains "not JSON" "$(cat "$SESSION/viewer.log")"

  # Two messages in one write still arrive as two events.
  assert "two lines in one write" \
    fifo_write "$SESSION/in" "$(printf '1\n[2]')"
  assert "both lines of one write arrive" \
    wait_for_event "$EVENTS" '.seq == 4 and .data == [2]' 5
  assert_eq "first line of one write arrives first" "1" \
    "$(event_field "$EVENTS" 3 .data)"

  # Only the exact close object closes; near misses are plain messages.
  assert "close with extra keys is written" \
    fifo_write "$SESSION/in" '{"htmlPopup":"close","x":1}'
  assert "other htmlPopup value is written" \
    fifo_write "$SESSION/in" '{"htmlPopup":"other"}'
  assert "near misses arrive as messages" \
    wait_for_event "$EVENTS" '.seq == 6 and .data.htmlPopup == "other"' 5
  assert_eq "close with extra keys is a message" \
    '{"htmlPopup":"close","x":1}' "$(event_field "$EVENTS" 5 '.data | tojson')"

  assert "spaced close line is written" \
    fifo_write "$SESSION/in" '{ "htmlPopup" : "close" }'
  finish_viewer
  assert_eq "close after invalid input exits 0" "0" "$RC"
  assert_eq "spaced close line closes with reason agent" \
    '{"seq":7,"type":"closed","reason":"agent"}' "$(tail -n 1 "$EVENTS")"
}

test_inbound_throwing_handler() {
  skip_unless_gui "inbound throwing handler" || return 0
  ensure_viewer
  new_tmpdir SESSION
  EVENTS="$SESSION/events.jsonl"
  start_viewer "$FIXTURES/bridge.html" --session "$SESSION" --timeout 20 \
    --test-script "$FIXTURES/throw-handler.js"
  assert "bridge page becomes ready" \
    wait_for_event "$EVENTS" '.type == "ready"' 10
  assert "message is written" fifo_write "$SESSION/in" '5'
  assert "handler after a throwing one still runs" \
    wait_for_event "$EVENTS" '.type == "message" and .data.got == 5' 5
  assert "close line is written" \
    fifo_write "$SESSION/in" '{"htmlPopup":"close"}'
  finish_viewer
  assert_eq "viewer closes normally" "0" "$RC"
}

# --- Helpers: running the wrapper against sessions ----------------------------

# wrap <test script|-> <args...> : run the wrapper with sessions under
# WRAP_TMP and the cached real viewer launched by real open; sets OUT, ERR,
# RC. "-" means no test script and a fake compiler and launcher with their
# own cache (only for calls that never open a window), so results do not
# depend on earlier GUI tests.
wrap() {
  local script="$1"
  shift
  if [[ "$script" == - ]]; then
    run_capture env TMPDIR="$WRAP_TMP" CLAUDE_PLUGIN_DATA="$WRAP_TMP/cache" \
      HTML_POPUP_SWIFTC="$FAKE_SWIFTC" HTML_POPUP_OPEN="$FAKE_OPEN" \
      HTML_POPUP_TEST_SCRIPT= "$WRAPPER" "$@"
  else
    run_capture env TMPDIR="$WRAP_TMP" CLAUDE_PLUGIN_DATA="$VIEWER_CACHE" \
      HTML_POPUP_SWIFTC= HTML_POPUP_OPEN= \
      HTML_POPUP_TEST_SCRIPT="$FIXTURES/$script" "$WRAPPER" "$@"
  fi
}

# fake_session <var> <pid|live> [events...] : make a session dir without a
# real viewer and store its path in <var>. `live` starts an idle fake viewer
# for the dir (see idle_viewer) and records its pid.
fake_session() {
  local var="$1" pid="$2" dir line
  shift 2
  dir="$(mktemp -d "$WRAP_TMP/html-popup.XXXXXX")"
  mkfifo "$dir/in"
  if [[ "$pid" == live ]]; then
    idle_viewer "$dir"
    pid="$IDLE_PID"
  fi
  printf '%s\n' "$pid" >"$dir/pid"
  : >"$dir/events.jsonl"
  for line in "$@"; do
    printf '%s\n' "$line" >>"$dir/events.jsonl"
  done
  printf -v "$var" '%s' "$dir"
}

# dead_pid : print the pid of a process that has already exited.
dead_pid() {
  local pid
  sleep 0 &
  pid=$!
  wait "$pid" || true
  printf '%s' "$pid"
}

# idle_viewer <dir> : set IDLE_PID to a tracked idle process that looks like
# the viewer of session dir: named like one, with --session DIR in its args.
# Like the viewer it holds the FIFO open but never reads it. It is not our
# child, so once killed it is reaped and kill -0 fails. Short sleeps leave
# no orphan behind when it is killed.
idle_viewer() {
  # shellcheck disable=SC2016 # loop code for the idle bash, not for us
  (
    exec -a "$FAKE_VIEWER_NAME" /bin/bash -c \
      'exec 3<>"$2/in"; for ((i = 0; i < 600; i++)); do sleep 0.2; done' \
      "$FAKE_VIEWER_NAME" --session "$1" >/dev/null 2>&1 &
    printf '%s' "$!" >"$1.idle"
  )
  IDLE_PID="$(cat "$1.idle")"
  rm -f "$1.idle"
  track_pid "$IDLE_PID"
}

# other_pid : set OTHER_PID to a tracked idle process that is not a viewer,
# standing in for a dead viewer's recycled pid.
other_pid() {
  sleep 120 >/dev/null 2>&1 &
  track_pid "$!"
  OTHER_PID=$!
}

# --- Tests: wrapper arguments and sessions without a viewer -------------------

test_wrapper_args() {
  skip_unless_macos "wrapper arguments" || return 0
  new_tmpdir WRAP_TMP
  local session stale fresh dead

  wrap - show "$WRAP_TMP/no-such-page.html"
  assert_eq "show with a missing page exits 3" "3" "$RC"
  assert "missing page is named" contains "no-such-page.html" "$ERR"

  wrap - ask "$FIXTURES/basic.html" --data "$FIXTURES/bad-data.json"
  assert_eq "ask with invalid data exits 3" "3" "$RC"
  assert "invalid data is explained" contains "not valid JSON" "$ERR"

  wrap - live start "$FIXTURES/basic.html" --data "$WRAP_TMP/no-such.json"
  assert_eq "live start with missing data exits 3" "3" "$RC"
  assert "no session dir is created before validation" \
    test -z "$(find "$WRAP_TMP" -maxdepth 1 -name 'html-popup.*')"

  wrap - show
  assert_eq "show without a page exits 2" "2" "$RC"
  wrap - show "$FIXTURES/basic.html" --frobnicate
  assert_eq "show with an unknown option exits 2" "2" "$RC"
  wrap - show "$FIXTURES/basic.html" --wait 5
  assert_eq "show rejects --wait" "2" "$RC"
  wrap - ask "$FIXTURES/basic.html" --wait soon
  assert_eq "ask with a bad --wait exits 2" "2" "$RC"
  wrap - ask --resume "$WRAP_TMP/nowhere"
  assert_eq "ask --resume of a non-session exits 2" "2" "$RC"
  wrap - live frobnicate
  assert_eq "unknown live command exits 2" "2" "$RC"
  wrap - show "$FIXTURES/basic.html" --size 10
  assert_eq "show with a bad --size exits 2" "2" "$RC"
  assert "bad --size is named" contains "bad --size" "$ERR"
  wrap - live start "$FIXTURES/basic.html" --timeout 0
  assert_eq "live start with a zero --timeout exits 2" "2" "$RC"
  wrap - ask "$FIXTURES/basic.html" --timeout soon
  assert_eq "ask with a bad --timeout exits 2" "2" "$RC"
  wrap - live close
  assert_eq "live close without DIR exits 2" "2" "$RC"
  wrap - live close "$WRAP_TMP" extra
  assert_eq "live close with extra args exits 2" "2" "$RC"
  wrap - live wait
  assert_eq "live wait without DIR exits 2" "2" "$RC"
  wrap - live wait "$WRAP_TMP" extra
  assert_eq "live wait with extra args exits 2" "2" "$RC"

  # Stale cleanup runs before validation, so a failing call still prunes.
  dead="$(dead_pid)"
  fake_session stale "$dead"
  fake_session fresh "$dead"
  fake_session session live
  touch -t 202001010000 "$stale" "$session"
  wrap - show "$WRAP_TMP/no-such-page.html"
  assert "old session with a dead viewer is removed" test ! -e "$stale"
  assert "recent session is kept" test -d "$fresh"
  assert "old session with a live viewer is kept" test -d "$session"
}

test_wrapper_fake_sessions() {
  skip_unless_macos "wrapper with fake sessions" || return 0
  new_tmpdir WRAP_TMP
  local session dead
  dead="$(dead_pid)"

  fake_session session live '{"seq":1,"type":"ready"}'
  wrap - live send "$session" '{"broken":'
  assert_eq "send of invalid JSON exits 2" "2" "$RC"
  wrap - live send "$session" '1 2'
  assert_eq "send of two values exits 2" "2" "$RC"
  wrap - live send "$session"
  assert_eq "send without JSON exits 2" "2" "$RC"
  wrap - live wait "$session" --wait 0
  assert_eq "wait prints the new event" '{"seq":1,"type":"ready"}' "$OUT"
  assert_eq "wait with new events exits 0" "0" "$RC"
  assert_eq "wait stores the cursor" "1" \
    "$(tr -d '[:space:]' <"$session/cursor")"
  wrap - live wait "$session" --wait 1
  assert_eq "wait with nothing new exits 4" "4" "$RC"
  assert "wait with nothing new prints nothing" test -z "$OUT"

  # A torn last line is left for the next call.
  printf '{"seq":2,"type":"message","data":"a"}\n{"seq":3,"ty' \
    >>"$session/events.jsonl"
  wrap - live wait "$session" --wait 0
  assert_eq "wait skips an incomplete line" \
    '{"seq":2,"type":"message","data":"a"}' "$OUT"
  printf 'pe":"closed","reason":"user"}\n' >>"$session/events.jsonl"
  wrap - live wait "$session" --wait 0
  assert_eq "wait with closed in the batch exits 1" "1" "$RC"
  assert_eq "wait prints the completed line" \
    '{"seq":3,"type":"closed","reason":"user"}' "$OUT"
  run_bounded 3 env TMPDIR="$WRAP_TMP" "$WRAPPER" live wait "$session"
  assert_eq "wait after closed exits 1 at once" "1" "$RC"
  wrap - live send "$session" '{"late":true}'
  assert_eq "send after closed exits 1" "1" "$RC"
  wrap - live close "$session"
  assert_eq "close of a closed session exits 0" "0" "$RC"

  fake_session session "$dead" '{"seq":1,"type":"ready"}'
  wrap - live wait "$session" --wait 0
  assert_eq "first wait still gets the ready event" "0" "$RC"
  wrap - live wait "$session" --wait 5
  assert_eq "wait on a crashed viewer exits 5" "5" "$RC"
  assert "crash is reported" contains "without a closed event" "$ERR"
  wrap - live send "$session" '1'
  assert_eq "send to a dead viewer exits 1" "1" "$RC"
  wrap - live close "$session"
  assert_eq "close of a dead session exits 0" "0" "$RC"
  wrap - ask --resume "$session" --wait 5
  assert_eq "ask --resume on a crashed viewer exits 5" "5" "$RC"

  # A corrupt cursor starts over from the first event.
  fake_session session live '{"seq":1,"type":"ready"}'
  printf 'garbage\n' >"$session/cursor"
  wrap - live wait "$session" --wait 0
  assert_eq "corrupt cursor restarts at seq 1" '{"seq":1,"type":"ready"}' "$OUT"

  fake_session session live '{"seq":1,"type":"ready"}'
  rm "$session/in"
  wrap - live send "$session" '1'
  assert_eq "send to a session without a FIFO exits 1" "1" "$RC"
  wrap - ask --resume "$session" "$FIXTURES/basic.html"
  assert_eq "ask --resume with a page exits 2" "2" "$RC"
}

# A viewer that died without a closed event and whose pid was recycled by an
# unrelated process: the session is over and that process is left alone.
test_wrapper_recycled_pid() {
  skip_unless_macos "recycled viewer pid" || return 0
  new_tmpdir WRAP_TMP
  local session
  other_pid
  fake_session session "$OTHER_PID" '{"seq":1,"type":"ready"}'

  wrap - live send "$session" '1'
  assert_eq "send to a recycled pid exits 1" "1" "$RC"
  wrap - live wait "$session" --wait 0
  assert_eq "first wait still gets the ready event" "0" "$RC"
  wrap - live wait "$session" --wait 5
  assert_eq "wait on a recycled pid exits 5" "5" "$RC"
  wrap - ask --resume "$session" --wait 5
  assert_eq "ask --resume on a recycled pid exits 5" "5" "$RC"
  wrap - live close "$session"
  assert_eq "close of a recycled pid exits 0" "0" "$RC"
  assert "close does not terminate anything" not_contains "terminating" "$ERR"
  assert "unrelated process survives close" kill -0 "$OTHER_PID"
  assert_eq "close writes no event" '{"seq":1,"type":"ready"}' \
    "$(cat "$session/events.jsonl")"

  touch -t 202001010000 "$session"
  wrap - show "$WRAP_TMP/no-such-page.html"
  assert "old session with a recycled pid is removed" test ! -e "$session"
  assert "unrelated process survives stale cleanup" kill -0 "$OTHER_PID"
}

# A crashed session whose pid now belongs to another session's viewer: the
# stale session is over and the other window is left alone.
test_wrapper_session_identity() {
  skip_unless_macos "session identity" || return 0
  new_tmpdir WRAP_TMP
  local session other pid
  fake_session other live '{"seq":1,"type":"ready"}'
  pid="$(session_pid_of "$other")"
  fake_session session "$pid" '{"seq":1,"type":"ready"}'

  wrap - live send "$session" '1'
  assert_eq "send to another session's viewer exits 1" "1" "$RC"
  wrap - live wait "$session" --wait 0
  assert_eq "first wait still gets the ready event" "0" "$RC"
  wrap - live wait "$session" --wait 5
  assert_eq "wait on another session's viewer exits 5" "5" "$RC"
  wrap - ask --resume "$session" --wait 5
  assert_eq "ask --resume on another session's viewer exits 5" "5" "$RC"
  wrap - live close "$session"
  assert_eq "close of the stale session exits 0" "0" "$RC"
  assert "close does not terminate the other viewer" \
    not_contains "terminating" "$ERR"
  assert "other session's viewer survives close" kill -0 "$pid"

  touch -t 202001010000 "$session"
  wrap - show "$WRAP_TMP/no-such-page.html"
  assert "stale session is removed" test ! -e "$session"
  assert "other session's viewer survives stale cleanup" kill -0 "$pid"
  wrap - live send "$other" '1'
  assert_eq "other session still accepts sends" "0" "$RC"
}

# read_fifo <dir> <out> : copy the session FIFO to out until killed; sets
# READER_PID. The read-write open never sees EOF between senders.
read_fifo() {
  # shellcheck disable=SC2016 # code for the reader bash, not for us
  /bin/bash -c 'exec 3<>"$1"; exec cat <&3 >"$2"' _ "$1/in" "$2" &
  READER_PID=$!
  track_pid "$READER_PID"
}

# Lines over the pipe's atomic write size must not interleave when several
# senders write to one session at once.
test_wrapper_concurrent_sends() {
  skip_unless_macos "concurrent sends" || return 0
  new_tmpdir WRAP_TMP
  local session out="$WRAP_TMP/received" big i tries=50
  local -a pids=()
  fake_session session live '{"seq":1,"type":"ready"}'
  read_fifo "$session" "$out"
  big="$(head -c 72000 /dev/zero | tr '\0' a)"
  for i in 1 2 3 4; do
    env TMPDIR="$WRAP_TMP" "$WRAPPER" live send "$session" \
      "{\"id\":$i,\"k\":\"$big\"}" >/dev/null 2>&1 &
    pids+=("$!")
  done
  for i in "${pids[@]}"; do
    assert "concurrent send $i exits 0" wait "$i"
  done
  while ((tries-- > 0)) && (($(count_messages "$out") < 4)); do
    sleep 0.1
  done
  kill "$READER_PID" 2>/dev/null || true
  assert_eq "every concurrent line arrives whole" "1,2,3,4 72000" \
    "$(jq -rs '"\(map(.id) | sort | join(",")) \(map(.k | length) | min)"' \
      "$out" 2>/dev/null)"
  assert "send locks are released" test -z "$(held_locks "$session")"

  # A lock left by a killed sender is passed over, not deleted.
  rm -f "$session"/in.lock.*
  ln -s "$(dead_pid)" "$session/in.lock.1"
  wrap - live send "$session" '"after stale lock"'
  assert_eq "send takes over a stale lock" "0" "$RC"
  assert_eq "taken-over lock is released" "in.lock.1" "$(held_locks "$session")"

  # A live sender stuck on a viewer that stopped reading must not hang close.
  ln -s "$$" "$session/in.lock.3"
  run_capture env TMPDIR="$WRAP_TMP" "$WRAPPER" live close "$session"
  assert_eq "close with a busy send lock exits 0" "0" "$RC"
  assert "busy close terminates the viewer" contains "terminating it" "$ERR"
  assert_eq "busy close writes a closed event" \
    '{"seq":2,"type":"closed","reason":"agent"}' \
    "$(tail -n 1 "$session/events.jsonl")"
  rm -f "$session"/in.lock.*
}

# send_big <dir> <id> [env...] : start a background live send of a line over
# the pipe buffer; sets SEND_PID.
send_big() {
  local big
  big="$(head -c 300000 /dev/zero | tr '\0' a)"
  env TMPDIR="$WRAP_TMP" "${@:3}" "$WRAPPER" live send "$1" \
    "{\"id\":$2,\"k\":\"$big\"}" >/dev/null 2>&1 &
  SEND_PID=$!
}

# received_ids <file> <count> : wait for count lines, stop the reader, then
# print their ids and payload lengths in order, or nothing if a line is torn.
received_ids() {
  local tries=50
  while ((tries-- > 0)) && (($(count_messages "$1") < $2)); do
    sleep 0.1
  done
  kill "$READER_PID" 2>/dev/null || true
  jq -rs '"\(map(.id) | join(",")) \(map(.k | length) | join(","))"' \
    "$1" 2>/dev/null || true
}

# wrap_bg_small <dir> : start a background live send of a short line;
# sets SEND_PID.
wrap_bg_small() {
  env TMPDIR="$WRAP_TMP" "$WRAPPER" live send "$1" '{"id":2}' \
    >/dev/null 2>&1 &
  SEND_PID=$!
}

# lock_links <dir> : names of the session's send lock links, one per line.
lock_links() {
  find "$1" -maxdepth 1 -name 'in.lock*' -exec basename {} \; | sort
}

# held_locks <dir> : send lock links not yet released, one per line.
held_locks() {
  local link
  for link in "$1"/in.lock.*; do
    if [[ "$link" =~ \.[0-9]+$ && ! -e "$link.done" ]]; then
      basename "$link"
    fi
  done
}

# fifo_writers <dir> : number of bash processes other than the viewer that
# have the session FIFO open. lsof by path misses FIFOs here, so filter all.
fifo_writers() {
  lsof -n -P -c bash -Fpn 2>/dev/null |
    awk -v suffix="/${1##*/}/in" -v viewer="$(session_pid_of "$1")" '
      /^p/ { pid = substr($0, 2) }
      /^n/ && pid != viewer && substr($0, length($0) - length(suffix) + 1) \
        == suffix { seen[pid] = 1 }
      END { n = 0; for (p in seen) n++; print n }'
}

# Two senders both find the same dead owner before either takes over; a
# slow readlink holds them in that window. Only one may write at a time.
test_wrapper_stale_lock_race() {
  skip_unless_macos "stale send lock race" || return 0
  new_tmpdir WRAP_TMP
  local session out="$WRAP_TMP/received" shim="$WRAP_TMP/shim" real first got
  real="$(command -v readlink)"
  fake_session session live '{"seq":1,"type":"ready"}'
  ln -s "$(dead_pid)" "$session/in.lock.1"
  mkdir "$shim"
  # The first call pauses less, so one sender takes over while the other
  # still holds the stale owner it read.
  cat >"$shim/readlink" <<EOF
#!/bin/bash
"$real" "\$@"
rc=\$?
if mkdir "$shim/first" 2>/dev/null; then sleep 0.3; else sleep 0.8; fi
exit \$rc
EOF
  chmod +x "$shim/readlink"
  send_big "$session" 1 PATH="$shim:$PATH"
  first="$SEND_PID"
  send_big "$session" 2 PATH="$shim:$PATH"
  # Both are past the takeover by now; one writes, the other waits its turn.
  sleep 2
  assert_eq "one racing sender holds the FIFO" "1" "$(fifo_writers "$session")"
  read_fifo "$session" "$out"
  assert "first racing sender exits 0" wait "$first"
  assert "second racing sender exits 0" wait "$SEND_PID"
  got="$(received_ids "$out" 2)"
  assert "racing takeovers do not interleave ($got)" \
    test "$got" == "1,2 300000,300000" -o "$got" == "2,1 300000,300000"
  assert "racing senders release their locks" \
    test "$(held_locks "$session")" == in.lock.1
}

# A waiter reads the owner of in.lock.N, then that owner releases and a new
# sender takes the next lock. The waiter then finds its stale owner dead and
# must not take a lock beside the new holder.
test_wrapper_released_lock_reuse() {
  skip_unless_macos "released send lock reuse" || return 0
  new_tmpdir WRAP_TMP
  local session out="$WRAP_TMP/received" shim="$WRAP_TMP/shim" real
  local first waiter tries=50
  real="$(command -v readlink)"
  fake_session session live '{"seq":1,"type":"ready"}'
  mkdir "$shim"
  # Hold the waiter after its first readlink until the test lets it go.
  cat >"$shim/readlink" <<EOF
#!/bin/bash
"$real" "\$@"
rc=\$?
if mkdir "$shim/read" 2>/dev/null; then
  while [[ ! -e "$shim/go" ]]; do sleep 0.05; done
fi
exit \$rc
EOF
  chmod +x "$shim/readlink"
  send_big "$session" 1
  first="$SEND_PID"
  while ((tries-- > 0)) && [[ -z "$(lock_links "$session")" ]]; do
    sleep 0.1
  done
  sleep 0.3
  send_big "$session" 2 PATH="$shim:$PATH"
  waiter="$SEND_PID"
  tries=50
  while ((tries-- > 0)) && [[ ! -e "$shim/read" ]]; do
    sleep 0.1
  done
  # Let the first sender finish and release, then stop reading again.
  read_fifo "$session" "$out"
  assert "first sender exits 0" wait "$first"
  assert_eq "first line arrives whole" "1 300000" "$(received_ids "$out" 1)"
  send_big "$session" 3
  sleep 0.5
  touch "$shim/go"
  sleep 0.5
  assert_eq "one sender holds the FIFO after a release" "1" \
    "$(fifo_writers "$session")"
  read_fifo "$session" "$out.next"
  assert "waiting sender exits 0" wait "$waiter"
  assert "new sender exits 0" wait "$SEND_PID"
  assert_eq "senders after a release do not interleave" \
    "3,2 300000,300000" "$(received_ids "$out.next" 2)"
  assert "senders after a release free their locks" \
    test -z "$(held_locks "$session")"
}

# A wrapper killed while its write is blocked leaves its writer running; the
# next sender must wait for that writer instead of writing alongside it.
test_wrapper_killed_sender() {
  skip_unless_macos "killed sender" || return 0
  new_tmpdir WRAP_TMP
  local session out="$WRAP_TMP/received" first tries=50
  fake_session session live '{"seq":1,"type":"ready"}'
  send_big "$session" 1
  first="$SEND_PID"
  while ((tries-- > 0)) && [[ -z "$(lock_links "$session")" ]]; do
    sleep 0.1
  done
  # Let the writer fill the pipe and block, then kill only the wrapper.
  sleep 0.3
  kill -9 "$first"
  wait "$first" 2>/dev/null || true
  wrap_bg_small "$session"
  sleep 0.5
  read_fifo "$session" "$out"
  assert "send after a killed sender exits 0" wait "$SEND_PID"
  assert_eq "killed sender's line arrives whole, then the next" \
    "1,2 300000,0" \
    "$(received_ids "$out" 2)"
  assert "writer of the killed sender releases its lock" \
    test -z "$(held_locks "$session")"
}

# Killing the sender's whole process group mid-write kills its writer too and
# leaves a partial line in the FIFO; the next message must still arrive whole.
test_wrapper_killed_sender_group() {
  skip_unless_macos "killed sender group" || return 0
  new_tmpdir WRAP_TMP
  local session out="$WRAP_TMP/received" group tries=50 tree
  fake_session session live '{"seq":1,"type":"ready"}'
  # Job control puts the background wrapper in its own process group.
  set -m
  send_big "$session" 1
  set +m
  group="$SEND_PID"
  while ((tries-- > 0)) && [[ -z "$(lock_links "$session")" ]]; do
    sleep 0.1
  done
  # Let the writer fill the pipe and block, then kill the group and tree.
  sleep 0.3
  tree="$(descendants "$group")"
  # shellcheck disable=SC2086 # one pid per word
  kill -KILL $tree "$group" 2>/dev/null || true
  kill -KILL -- -"$group" 2>/dev/null || true
  wait "$group" 2>/dev/null || true
  wrap_bg_small "$session"
  sleep 0.5
  read_fifo "$session" "$out"
  assert "send after a killed sender group exits 0" wait "$SEND_PID"
  tries=50
  while ((tries-- > 0)) && ! grep -q '"id":2' "$out"; do
    sleep 0.1
  done
  kill "$READER_PID" 2>/dev/null || true
  assert "killed writer left a partial line" \
    test "$(grep -c '^{"id":1,"k":"a*$' "$out")" == 1
  assert_eq "next message arrives intact on its own line" '{"id":2}' \
    "$(grep '"id":2' "$out")"
}

# The window closes between live wait reading new events and checking for
# closed: the final events must still be printed.
test_wrapper_wait_close_race() {
  skip_unless_macos "wait racing a close" || return 0
  new_tmpdir WRAP_TMP
  local session shim="$WRAP_TMP/shim" real
  real="$(command -v jq)"
  fake_session session live '{"seq":1,"type":"ready"}'
  printf '1\n' >"$session/cursor"
  mkdir "$shim"
  # A jq that appends the final events right after the first new_events call.
  cat >"$shim/jq" <<EOF
#!/bin/bash
"$real" "\$@"
rc=\$?
if [[ "\$*" == *"--argjson c"* && ! -e "$shim/done" ]]; then
  : >"$shim/done"
  printf '%s\n' '{"seq":2,"type":"answer","data":7}' \\
    '{"seq":3,"type":"closed","reason":"answer"}' >>"$session/events.jsonl"
fi
exit \$rc
EOF
  chmod +x "$shim/jq"
  run_capture env TMPDIR="$WRAP_TMP" PATH="$shim:$PATH" \
    "$WRAPPER" live wait "$session" --wait 5
  assert_eq "wait racing a close exits 1" "1" "$RC"
  assert_eq "wait racing a close prints the final events" \
    '{"seq":2,"type":"answer","data":7}
{"seq":3,"type":"closed","reason":"answer"}' "$OUT"
}

# --wait values with leading zeros are decimal, not octal.
test_wrapper_wait_decimal() {
  skip_unless_macos "decimal --wait" || return 0
  new_tmpdir WRAP_TMP
  local session
  fake_session session live '{"seq":1,"type":"ready"}'
  wrap - live wait "$session" --wait 08
  assert_eq "live wait accepts --wait 08" "0" "$RC"
  assert_eq "live wait --wait 08 prints the event" \
    '{"seq":1,"type":"ready"}' "$OUT"
  fake_session session live '{"seq":1,"type":"ready"}' \
    '{"seq":2,"type":"answer","data":1}' \
    '{"seq":3,"type":"closed","reason":"answer"}'
  wrap - ask --resume "$session" --wait 09
  assert_eq "ask accepts --wait 09" "0" "$RC"
  assert_eq "ask --wait 09 prints the answer" "1" "$OUT"
}

test_wrapper_resume_outcomes() {
  skip_unless_macos "resume outcomes" || return 0
  new_tmpdir WRAP_TMP
  local session

  fake_session session live '{"seq":1,"type":"ready"}' \
    '{"seq":2,"type":"answer","data":{"month":7}}' \
    '{"seq":3,"type":"closed","reason":"answer"}'
  wrap - ask --resume "$session" --wait 0
  assert_eq "resume after an answer exits 0" "0" "$RC"
  assert_eq "resume prints the answer" '{"month":7}' "$OUT"

  fake_session session live '{"seq":1,"type":"ready"}' \
    '{"seq":2,"type":"closed","reason":"user"}'
  wrap - ask --resume "$session" --wait 0
  assert_eq "resume after a user close exits 1" "1" "$RC"
  assert "user close prints no answer" test -z "$OUT"

  fake_session session live '{"seq":1,"type":"ready"}' \
    '{"seq":2,"type":"closed","reason":"timeout"}'
  wrap - ask --resume "$session" --wait 0
  assert_eq "resume after a window timeout exits 1, not 4" "1" "$RC"
  assert "window timeout is reported" \
    contains "window timed out without an answer" "$ERR"

  fake_session session live '{"seq":1,"type":"ready"}' \
    '{"seq":2,"type":"closed","reason":"error","message":"boom"}'
  wrap - ask --resume "$session" --wait 0
  assert_eq "resume after an error exits 3" "3" "$RC"
  assert "error message is passed on" contains "boom" "$ERR"

  fake_session session live '{"seq":1,"type":"ready"}'
  wrap - ask --resume "$session" --wait 0
  assert_eq "resume of an open window exits 4" "4" "$RC"
  assert "open window gets a resume hint" contains "still waiting" "$ERR"
}

# A viewer that never reads its FIFO: live close must terminate it and still
# leave a closed event behind.
test_wrapper_close_stuck() {
  skip_unless_macos "close of a stuck viewer" || return 0
  new_tmpdir WRAP_TMP
  local session stuck
  fake_session session live '{"seq":1,"type":"ready"}'
  stuck="$(session_pid_of "$session")"
  wrap - live close "$session"
  assert_eq "close of a stuck viewer exits 0" "0" "$RC"
  assert "stuck viewer is reported" contains "terminating it" "$ERR"
  assert "stuck viewer is gone" sh -c "! kill -0 $stuck 2>/dev/null"
  assert_eq "wrapper writes the missing closed event" \
    '{"seq":2,"type":"closed","reason":"agent"}' \
    "$(tail -n 1 "$session/events.jsonl")"
  wrap - live wait "$session" --wait 0
  assert_eq "wait after a forced close exits 1, not 5" "1" "$RC"
}

# A malformed line in events.jsonl (a fragment cut by a forced kill) is
# skipped: wait, resume and close still see the valid events around it.
test_wrapper_malformed_events() {
  skip_unless_macos "malformed event lines" || return 0
  new_tmpdir WRAP_TMP
  local session bad='{"seq":2,"type":"message","data":{"a":1,}}'

  fake_session session live '{"seq":1,"type":"ready"}' "$bad" \
    '{"seq":3,"type":"message","data":"after"}'
  wrap - live wait "$session" --wait 0
  assert_eq "live wait past a malformed line exits 0" "0" "$RC"
  assert_eq "live wait skips the malformed line" \
    $'{"seq":1,"type":"ready"}\n{"seq":3,"type":"message","data":"after"}' \
    "$OUT"
  printf '{"seq":4,"type":"message","data":"later"}\n' \
    >>"$session/events.jsonl"
  wrap - live wait "$session" --wait 0
  assert_eq "next live wait sees the later event" \
    '{"seq":4,"type":"message","data":"later"}' "$OUT"

  fake_session session live '{"seq":1,"type":"ready"}' "$bad" \
    '{"seq":3,"type":"answer","data":{"month":7}}' \
    '{"seq":4,"type":"closed","reason":"answer"}'
  wrap - ask --resume "$session" --wait 0
  assert_eq "resume past a malformed line exits 0" "0" "$RC"
  assert_eq "resume past a malformed line prints the answer" \
    '{"month":7}' "$OUT"

  fake_session session live '{"seq":1,"type":"ready"}' "$bad"
  printf '{"seq":3,"type":"mess' >>"$session/events.jsonl"
  wrap - live close "$session"
  assert_eq "close after a partial tail exits 0" "0" "$RC"
  assert_eq "closed lands on its own line after the partial tail" \
    '{"seq":2,"type":"closed","reason":"agent"}' \
    "$(tail -n 1 "$session/events.jsonl")"
  assert_eq "partial tail is kept on its own line" '{"seq":3,"type":"mess' \
    "$(tail -n 2 "$session/events.jsonl" | head -n 1)"
  wrap - live wait "$session" --wait 0
  assert_eq "wait after the forced close exits 1" "1" "$RC"
  assert "wait after the forced close reports closed" \
    contains '"type":"closed"' "$OUT"
}

# Two closes terminating the same stuck viewer append one closed event; a
# slow tail holds each between its closed check and its append.
test_wrapper_concurrent_close() {
  skip_unless_macos "concurrent close of a stuck viewer" || return 0
  new_tmpdir WRAP_TMP
  local session shim="$WRAP_TMP/shim" real first
  real="$(command -v tail)"
  fake_session session live '{"seq":1,"type":"ready"}'
  mkdir "$shim"
  cat >"$shim/tail" <<EOF
#!/bin/bash
sleep 0.5
exec "$real" "\$@"
EOF
  chmod +x "$shim/tail"
  env TMPDIR="$WRAP_TMP" PATH="$shim:$PATH" "$WRAPPER" live close \
    "$session" >/dev/null 2>&1 &
  first=$!
  run_capture env TMPDIR="$WRAP_TMP" PATH="$shim:$PATH" "$WRAPPER" \
    live close "$session"
  assert_eq "second concurrent close exits 0" "0" "$RC"
  assert "first concurrent close exits 0" wait "$first"
  assert_eq "concurrent closes append one closed event" \
    $'{"seq":1,"type":"ready"}\n{"seq":2,"type":"closed","reason":"agent"}' \
    "$(grep . "$session/events.jsonl")"
}

# Waiters that find the viewer killed by a forced close before its closed
# event is appended wait for that event instead of reporting a crash; a slow
# tail holds the close between the kill and the append.
test_wrapper_wait_forced_close() {
  skip_unless_macos "wait during a forced close" || return 0
  new_tmpdir WRAP_TMP
  local session shim="$WRAP_TMP/shim" real closer asker pid tries=150
  real="$(command -v tail)"
  fake_session session live '{"seq":1,"type":"ready"}'
  printf '1\n' >"$session/cursor"
  pid="$(session_pid_of "$session")"
  mkdir "$shim"
  cat >"$shim/tail" <<EOF
#!/bin/bash
sleep 3
exec "$real" "\$@"
EOF
  chmod +x "$shim/tail"
  env TMPDIR="$WRAP_TMP" PATH="$shim:$PATH" "$WRAPPER" live close \
    "$session" >/dev/null 2>&1 &
  closer=$!
  while ((tries-- > 0)) && kill -0 "$pid" 2>/dev/null; do
    sleep 0.1
  done
  assert "forced close killed the viewer" \
    sh -c "! kill -0 $pid 2>/dev/null"
  assert "closed event is not appended yet" \
    not_contains closed "$(cat "$session/events.jsonl")"
  env TMPDIR="$WRAP_TMP" "$WRAPPER" ask --resume "$session" --wait 10 \
    >/dev/null 2>&1 &
  asker=$!
  wrap - live wait "$session" --wait 10
  assert_eq "live wait during a forced close exits 1, not 5" "1" "$RC"
  assert_eq "live wait prints the forced closed event" \
    '{"seq":2,"type":"closed","reason":"agent"}' "$OUT"
  RC=0
  wait "$asker" || RC=$?
  assert_eq "ask --resume during a forced close exits 1, not 5" "1" "$RC"
  assert "forced close exits 0" wait "$closer"
}

# ask --wait bounds the wait for ready: a slow page gets exit 4 with a
# resumable session; a page that never gets ready still fails on resume.
test_wrapper_ask_budget() {
  skip_unless_macos "ask --wait bounds startup" || return 0
  new_tmpdir WRAP_TMP
  local page="$FIXTURES/basic.html" start session pid gate tries
  # shellcheck disable=SC2016 # stub shell code, expanded by the stub
  local head='DIR=$3; ev() { printf "%s\n" "$1" >>"$DIR/events.jsonl"; }'
  local ready='{"seq":1,"type":"ready"}'
  local answer='{"seq":2,"type":"answer","data":5}'
  local answered='{"seq":3,"type":"closed","reason":"answer"}'
  local agent='{"seq":1,"type":"closed","reason":"agent"}'

  # The page gets ready only once the test creates the gate file.
  gate="$WRAP_TMP/ready.gate"
  start=$SECONDS
  stub_wrap "$head; for ((i = 0; i < 600; i++)); do [[ -e '$gate' ]] &&
    break; sleep 0.05; done; ev '$ready'; ev '$answer'; ev '$answered'" \
    ask "$page" --wait 1
  assert_eq "ask --wait 1 on a slow page exits 4" "4" "$RC"
  assert "slow page wait is bounded by --wait" \
    test $((SECONDS - start)) -le 5
  assert "slow page gets a resume hint" contains "ask --resume" "$ERR"
  session="${ERR##*--resume }"
  track_pid "$(session_pid_of "$session")"
  touch "$gate"
  wrap - ask --resume "$session" --wait 10
  assert_eq "resume after a slow page exits 0" "0" "$RC"
  assert_eq "resume after a slow page prints the answer" "5" "$OUT"

  stub_wrap 'idle 60' ask "$page" --wait 1
  assert_eq "ask --wait 1 on a never-ready page exits 4" "4" "$RC"
  session="${ERR##*--resume }"
  pid="$(session_pid_of "$session")"
  track_pid "$pid"
  # Skip the 10 s ready deadline instead of sleeping through it.
  printf '%s\n' "$(($(date +%s) - 1))" >"$session/ready_by"
  wrap - ask --resume "$session" --wait 10
  assert_eq "resume of a never-ready page exits 3" "3" "$RC"
  assert "never-ready resume is reported" contains "page not ready" "$ERR"
  assert "never-ready viewer is killed" sh -c "! kill -0 $pid 2>/dev/null"
  assert_eq "never-ready resume writes closed/error" "error" \
    "$(tail -n 1 "$session/events.jsonl" | jq -r .reason)"

  # --wait may run out before the viewer has started and written its pid.
  gate="$WRAP_TMP/start.gate"
  FAKE_SWIFTC_START_GATE="$gate" \
    stub_wrap "$head; ev '$ready'; ev '$answer'; ev '$answered'" \
    ask "$page" --wait 1
  assert_eq "ask --wait 1 on a viewer still starting exits 4" "4" "$RC"
  assert "still-starting viewer gets a resume hint" \
    contains "ask --resume" "$ERR"
  session="${ERR##*--resume }"
  assert "still-starting viewer has no pid yet" test ! -e "$session/pid"
  wrap - ask --resume "$session" --wait 0
  assert_eq "resume of a still-starting session exits 4" "4" "$RC"
  touch "$gate"
  wrap - ask --resume "$session" --wait 10
  assert_eq "resume picks up the late viewer's answer" "0" "$RC"
  assert_eq "late viewer's answer is printed" "5" "$OUT"

  # A viewer that starts after its session was closed exits on its own.
  gate="$WRAP_TMP/abandon.gate"
  FAKE_SWIFTC_START_GATE="$gate" stub_wrap "$head; ev '$ready'; idle 60" \
    ask "$page" --wait 1
  assert_eq "ask --wait 1 before the viewer starts exits 4" "4" "$RC"
  session="${ERR##*--resume }"
  wrap - live close "$session"
  assert_eq "close before the viewer starts exits 0" "0" "$RC"
  touch "$gate"
  tries=100
  while ((tries-- > 0)) && [[ ! -s "$session/pid" ]]; do
    sleep 0.1
  done
  pid="$(session_pid_of "$session")"
  track_pid "$pid"
  tries=100
  while ((tries-- > 0)) && kill -0 "$pid" 2>/dev/null; do
    sleep 0.1
  done
  assert "late viewer of a closed session exits" \
    sh -c "! kill -0 $pid 2>/dev/null"
  assert_eq "late viewer adds no events" "$agent" \
    "$(grep . "$session/events.jsonl")"
}

# A forced close whose owner was killed before appending closed is finished
# by the next close, whether the owner died before or after its kill.
test_wrapper_close_owner_killed() {
  skip_unless_macos "close after a killed close owner" || return 0
  new_tmpdir WRAP_TMP
  local session pid shim="$WRAP_TMP/shim" closer tries=100
  local closed='{"seq":2,"type":"closed","reason":"agent"}'

  fake_session session live '{"seq":1,"type":"ready"}'
  pid="$(session_pid_of "$session")"
  ln -s "$(dead_pid)" "$session/close.lock.1"
  wrap - live close "$session"
  assert_eq "close after a dead owner's lock exits 0" "0" "$RC"
  assert "close after a dead owner's lock kills the viewer" \
    sh -c "! kill -0 $pid 2>/dev/null"
  assert_eq "close after a dead owner's lock appends one closed" \
    $'{"seq":1,"type":"ready"}\n'"$closed" "$(grep . "$session/events.jsonl")"
  wrap - live wait "$session" --wait 0
  assert_eq "wait after the taken-over close exits 1" "1" "$RC"

  # The tail before the append parks the first close, which is then killed.
  fake_session session live '{"seq":1,"type":"ready"}'
  pid="$(session_pid_of "$session")"
  mkdir "$shim"
  cat >"$shim/tail" <<EOF
#!/bin/bash
printf '%s\n' "\$\$" >"$shim/pid"
exec sleep 30
EOF
  chmod +x "$shim/tail"
  env TMPDIR="$WRAP_TMP" PATH="$shim:$PATH" "$WRAPPER" live close \
    "$session" >/dev/null 2>&1 &
  closer=$!
  while ((tries-- > 0)) && [[ ! -s "$shim/pid" ]]; do
    sleep 0.2
  done
  assert "first close reached the append" test -s "$shim/pid"
  kill -9 "$closer"
  wait "$closer" 2>/dev/null || true
  kill "$(cat "$shim/pid")"
  assert "first close killed the viewer" sh -c "! kill -0 $pid 2>/dev/null"
  assert "killed close appended nothing" \
    not_contains closed "$(cat "$session/events.jsonl")"
  printf '1\n' >"$session/cursor"
  wrap - live wait "$session" --wait 10
  assert_eq "wait with a dead close owner reports a crash" "5" "$RC"
  wrap - live close "$session"
  assert_eq "close after a killed close owner exits 0" "0" "$RC"
  assert_eq "close after a killed close owner appends one closed" \
    $'{"seq":1,"type":"ready"}\n'"$closed" "$(grep . "$session/events.jsonl")"
  wrap - live wait "$session" --wait 0
  assert_eq "wait after the finished close exits 1" "1" "$RC"
}

# A close that found the close lock's owner dead must not take a lock beside
# a close that took over meanwhile. Shims park the first close after its
# owner readlink and the second (now the owner) before its append.
test_wrapper_close_lock_takeover_race() {
  skip_unless_macos "close lock takeover race" || return 0
  new_tmpdir WRAP_TMP
  local session shim="$WRAP_TMP/shim" first second tries=50 cmd
  fake_session session "$(dead_pid)" '{"seq":1,"type":"ready"}'
  ln -s "$(dead_pid)" "$session/close.lock.1"
  mkdir "$shim"
  for cmd in readlink tail; do
    cat >"$shim/$cmd" <<EOF
#!/bin/bash
"$(command -v "$cmd")" "\$@"
rc=\$?
if mkdir "$shim/$cmd.parked" 2>/dev/null; then
  while [[ ! -e "$shim/$cmd.go" ]]; do sleep 0.05; done
fi
exit \$rc
EOF
    chmod +x "$shim/$cmd"
  done
  env TMPDIR="$WRAP_TMP" PATH="$shim:$PATH" "$WRAPPER" live close \
    "$session" >/dev/null 2>&1 &
  first=$!
  while ((tries-- > 0)) && [[ ! -e "$shim/readlink.parked" ]]; do
    sleep 0.1
  done
  assert "first close parked after its owner check" \
    test -e "$shim/readlink.parked"
  env TMPDIR="$WRAP_TMP" PATH="$shim:$PATH" "$WRAPPER" live close \
    "$session" >/dev/null 2>&1 &
  second=$!
  tries=50
  while ((tries-- > 0)) && [[ ! -e "$shim/tail.parked" ]]; do
    sleep 0.1
  done
  assert "second close parked holding the lock" test -e "$shim/tail.parked"
  touch "$shim/readlink.go"
  sleep 0.5
  touch "$shim/tail.go"
  assert "first racing close exits 0" wait "$first"
  assert "second racing close exits 0" wait "$second"
  assert_eq "racing closes append one closed event" \
    $'{"seq":1,"type":"ready"}\n{"seq":2,"type":"closed","reason":"agent"}' \
    "$(grep . "$session/events.jsonl")"
  assert_eq "racing closes hold one lock beside the dead one" \
    "close.lock.1 close.lock.2" \
    "$(cd "$session" && printf '%s\n' close.lock.* | xargs)"
}

# stub_wrap <stub body> <args...> : run the wrapper with a fake viewer whose
# shell body is given (args: PAGE --session DIR ...), launched by the fake
# open; sets OUT, ERR, RC.
stub_wrap() {
  local body="$1" cache
  shift
  # One cache per body: the cache key is the real source hash.
  cache="$(mktemp -d "$WRAP_TMP/cache.XXXXXX")"
  run_capture env TMPDIR="$WRAP_TMP" CLAUDE_PLUGIN_DATA="$cache" \
    HTML_POPUP_SWIFTC="$FAKE_SWIFTC" FAKE_SWIFTC_BODY="$body" \
    HTML_POPUP_OPEN="$FAKE_OPEN" HTML_POPUP_TEST_SCRIPT= "$WRAPPER" "$@"
}

# Startup paths of the wrapper, driven by scripted fake viewers.
test_wrapper_startup() {
  skip_unless_macos "wrapper startup with fake viewers" || return 0
  new_tmpdir WRAP_TMP
  local page="$FIXTURES/basic.html" ev pid start session big launcher
  # shellcheck disable=SC2016 # stub shell code, expanded by the stub
  ev='printf "%s\n" "$1" >>"$DIR/events.jsonl"'
  local head="DIR=\$3; ev() { $ev; }"
  local ready='{"seq":1,"type":"ready"}'
  local error='{"seq":1,"type":"closed","reason":"error","message":"bad"}'
  local user='{"seq":1,"type":"closed","reason":"user"}'
  local answer='{"seq":1,"type":"answer","data":5}'
  local answered='{"seq":2,"type":"closed","reason":"answer"}'
  local timed_out='{"seq":1,"type":"closed","reason":"timeout"}'

  stub_wrap "$head; ev '$ready'; idle 60" show "$page"
  assert_eq "show with a ready viewer exits 0" "0" "$RC"
  session="$OUT"
  pid="$(session_pid_of "$session")"
  track_pid "$pid"
  assert "viewer is running" kill -0 "$pid"
  assert_eq "viewer is not a child of the wrapper" "1" \
    "$(ps -o ppid= -p "$pid" | tr -d ' ')"
  kill "$pid"

  # A large log after ready: has_event must not fail on SIGPIPE.
  big="$WRAP_TMP/big.jsonl"
  {
    printf '%s\n' "$ready"
    jq -cn 'range(2; 6000) | {seq: ., type: "message", data: ("x" * 40)}'
  } >"$big"
  stub_wrap "$head; cat '$big' >>\"\$DIR/events.jsonl\"; idle 60" \
    show "$page"
  assert_eq "show with a large event log exits 0" "0" "$RC"
  kill "$(session_pid_of "$OUT")" 2>/dev/null || true

  stub_wrap 'echo "stub viewer broke" >&2; exit 2' show "$page"
  assert_eq "viewer dying without events exits 5" "5" "$RC"
  assert "log tail is shown" contains "stub viewer broke" "$ERR"

  stub_wrap "$head; echo 'bad data' >&2; ev '$error'" live start "$page"
  assert_eq "closed/error before ready exits 3" "3" "$RC"
  assert "error log tail is shown" contains "bad data" "$ERR"

  stub_wrap "$head; ev '$user'" show "$page"
  assert_eq "show of a window closed before ready exits 1" "1" "$RC"

  stub_wrap "$head; ev '$answer'; ev '$answered'" ask "$page"
  assert_eq "ask with an answer before ready exits 0" "0" "$RC"
  assert_eq "early answer is printed" "5" "$OUT"

  stub_wrap "$head; ev '$timed_out'" ask "$page"
  assert_eq "ask with a window timeout before ready exits 1" "1" "$RC"

  start=$SECONDS
  HTML_POPUP_READY_WAIT=1 stub_wrap 'idle 60' show "$page"
  assert_eq "page never ready exits 3" "3" "$RC"
  assert "not-ready wait is bounded" test $((SECONDS - start)) -le 5
  assert "not-ready is reported" contains "page not ready" "$ERR"
  session="$(grep -l '"reason":"error","message":"page not ready' \
    "$WRAP_TMP"/html-popup.*/events.jsonl | head -n 1)"
  assert "not-ready session gets a closed/error event" test -n "$session"
  session="$(dirname "$session")"
  assert "never-ready viewer is killed" \
    sh -c "! kill -0 $(session_pid_of "$session") 2>/dev/null"

  # A viewer that fails before writing its pid (e.g. a bad option) only
  # leaves its log; a launcher writing that log stands in for it.
  launcher="$WRAP_TMP/failing-open"
  cat >"$launcher" <<'EOF'
#!/bin/bash
while (($# > 0)); do
  [[ "$1" == --stderr ]] && printf 'html-popup-viewer: bad option\n' >"$2"
  shift
done
EOF
  chmod +x "$launcher"
  start=$SECONDS
  run_capture env TMPDIR="$WRAP_TMP" CLAUDE_PLUGIN_DATA="$WRAP_TMP/cache" \
    HTML_POPUP_SWIFTC="$FAKE_SWIFTC" HTML_POPUP_OPEN="$launcher" \
    HTML_POPUP_TEST_SCRIPT= "$WRAPPER" show "$page"
  assert_eq "viewer failing before its pid exits 5" "5" "$RC"
  assert "early failure is reported at once" test $((SECONDS - start)) -le 3
  assert "early failure shows the log tail" contains "bad option" "$ERR"

  FAKE_OPEN_FAIL="LSOpenURLsWithRole() failed" stub_wrap 'exit 0' \
    show "$page"
  assert_eq "open failing exits 2" "2" "$RC"
  assert "open's message is shown" contains "LSOpenURLsWithRole" "$ERR"

  # A launcher that starts nothing: no viewer is ever seen.
  new_tmpdir WRAP_TMP
  start=$SECONDS
  run_capture env TMPDIR="$WRAP_TMP" CLAUDE_PLUGIN_DATA="$WRAP_TMP/cache" \
    HTML_POPUP_SWIFTC="$FAKE_SWIFTC" HTML_POPUP_OPEN=true \
    HTML_POPUP_READY_WAIT=1 HTML_POPUP_TEST_SCRIPT= "$WRAPPER" show "$page"
  assert_eq "no viewer before the ready deadline exits 3" "3" "$RC"
  assert "missing viewer wait is bounded" test $((SECONDS - start)) -le 5
  session="$(find "$WRAP_TMP" -maxdepth 2 -name abandoned | head -n 1)"
  assert "missing viewer abandons the session" test -n "$session"
  session="$(dirname "$session")"
  assert_eq "abandoned session gets closed/error" "error" \
    "$(tail -n 1 "$session/events.jsonl" | jq -r .reason)"
}

# Launch arguments as the fake open receives them.
test_wrapper_launch_args() {
  skip_unless_macos "wrapper launch arguments" || return 0
  new_tmpdir WRAP_TMP
  local args="$WRAP_TMP/open-args" session cwd nl=$'\n'
  # shellcheck disable=SC2016 # stub shell code, expanded by the stub
  local ready='printf "%s\n" "{\"seq\":1,\"type\":\"ready\"}" >>"$3/events.jsonl"'
  cp "$FIXTURES/basic.html" "$WRAP_TMP/rel.html"
  printf '{"a":1}\n' >"$WRAP_TMP/rel.json"
  printf '\n' >"$WRAP_TMP/rel.js"

  cd "$WRAP_TMP"
  cwd="$PWD"
  run_capture env TMPDIR="$WRAP_TMP" CLAUDE_PLUGIN_DATA="$WRAP_TMP/cache" \
    HTML_POPUP_SWIFTC="$FAKE_SWIFTC" FAKE_SWIFTC_BODY="$ready; idle 60" \
    HTML_POPUP_OPEN="$FAKE_OPEN" FAKE_OPEN_ARGS="$args" \
    HTML_POPUP_TEST_SCRIPT=rel.js "$WRAPPER" show rel.html --data rel.json
  cd - >/dev/null
  assert_eq "show with relative paths exits 0" "0" "$RC"
  session="$OUT"
  track_pid "$(session_pid_of "$session")"
  kill "$(session_pid_of "$session")"
  assert_eq "every popup is a new instance" "-n" "$(head -n 1 "$args")"
  # Options before --args belong to open; later ones go to the viewer.
  assert "test mode launches in the background" \
    contains "$nl-g$nl" "$(sed '/^--args$/q' "$args")"
  assert "page path is absolute" contains "$nl$cwd/rel.html$nl" \
    "$(cat "$args")"
  assert "--data path is absolute" \
    contains "$nl--data$nl$cwd/rel.json$nl" "$(cat "$args")"
  assert "--test-script path is absolute" \
    contains "$nl--test-script$nl$cwd/rel.js" "$(cat "$args")"
  assert "viewer stderr goes to the session log" \
    contains "$nl--stderr$nl$session/viewer.log$nl" "$(cat "$args")"

  : >"$args"
  FAKE_OPEN_ARGS="$args" stub_wrap "$ready; idle 60" show "$WRAP_TMP/rel.html"
  assert_eq "show outside test mode exits 0" "0" "$RC"
  kill "$(session_pid_of "$OUT")"
  assert "normal mode launches in the foreground" \
    not_contains "$nl-g$nl" "$(sed '/^--args$/q' "$args")"
}

# A session whose viewer has not started yet: ready_by but no pid.
test_wrapper_starting_session() {
  skip_unless_macos "still-starting session" || return 0
  new_tmpdir WRAP_TMP
  local session cmd
  session="$(mktemp -d "$WRAP_TMP/html-popup.XXXXXX")"
  printf '%s\n' "$(($(date +%s) + 60))" >"$session/ready_by"

  wrap - live wait "$session" --wait 0
  assert_eq "live wait on a starting session exits 4" "4" "$RC"
  wrap - ask --resume "$session" --wait 0
  assert_eq "ask --resume on a starting session exits 4" "4" "$RC"
  wrap - live send "$session" '{"a":1}'
  assert_eq "live send on a starting session exits 4" "4" "$RC"
  assert "live send says the window is starting" contains "starting" "$ERR"
  wrap - live close "$session"
  assert_eq "live close of a starting session exits 0" "0" "$RC"
  assert "close abandons the starting session" test -e "$session/abandoned"
  assert_eq "close appends closed/agent" "agent" \
    "$(tail -n 1 "$session/events.jsonl" | jq -r .reason)"

  session="$(mktemp -d "$WRAP_TMP/html-popup.XXXXXX")"
  printf '%s\n' "$(($(date +%s) - 1))" >"$session/ready_by"
  wrap - ask --resume "$session" --wait 5
  assert_eq "resume past the deadline with no viewer exits 3" "3" "$RC"
  assert "it abandons the session" test -e "$session/abandoned"
  assert_eq "resume past the deadline appends closed/error" "error" \
    "$(tail -n 1 "$session/events.jsonl" | jq -r .reason)"

  for cmd in "live wait" "live send"; do
    session="$(mktemp -d "$WRAP_TMP/html-popup.XXXXXX")"
    printf '%s\n' "$(($(date +%s) - 1))" >"$session/ready_by"
    # shellcheck disable=SC2086 # split "live wait" into two words
    if [[ "$cmd" == "live wait" ]]; then
      wrap - $cmd "$session" --wait 5
    else
      wrap - $cmd "$session" '{"a":1}'
    fi
    assert_eq "$cmd past the deadline with no viewer exits 3" "3" "$RC"
    assert "$cmd past the deadline abandons the session" \
      test -e "$session/abandoned"
    assert_eq "$cmd past the deadline appends closed/error" "error" \
      "$(tail -n 1 "$session/events.jsonl" | jq -r .reason)"
  done
}

# --- Tests: wrapper with the real viewer --------------------------------------

test_wrapper_show() {
  skip_unless_gui "wrapper show and live start" || return 0
  ensure_viewer
  new_tmpdir WRAP_TMP
  local start session cmd

  for cmd in show "live start"; do
    start=$SECONDS
    # shellcheck disable=SC2086 # split "live start" into two words
    wrap noop.js $cmd "$FIXTURES/basic.html" --timeout 30
    assert_eq "$cmd exits 0" "0" "$RC"
    assert "$cmd returns within 3 s" test $((SECONDS - start)) -le 3
    session="$OUT"
    assert "$cmd prints a session dir" test -f "$session/events.jsonl"
    assert_eq "$cmd session is under TMPDIR" "$WRAP_TMP" "$(dirname "$session")"
    assert "$cmd leaves the viewer running" \
      kill -0 "$(session_pid_of "$session")"
    assert "$cmd waited for ready" \
      contains '"type":"ready"' "$(cat "$session/events.jsonl")"
    wrap - live close "$session"
    assert_eq "$cmd window closes" "0" "$RC"
    assert_eq "$cmd close reason is agent" "agent" \
      "$(tail -n 1 "$session/events.jsonl" | jq -r .reason)"
  done

  # jq accepts an empty file, the viewer does not.
  : >"$WRAP_TMP/empty.json"
  wrap noop.js show "$FIXTURES/basic.html" --data "$WRAP_TMP/empty.json" \
    --timeout 30
  assert_eq "show with empty --data exits 3" "3" "$RC"
  assert "empty --data is explained" contains "not valid JSON" "$ERR"
}

# The real viewer launched by open: relative paths from another cwd still
# load, and a test-mode window leaves the user's frontmost app alone.
test_wrapper_open_launch() {
  skip_unless_gui "wrapper launch through open" || return 0
  ensure_viewer
  new_tmpdir WRAP_TMP
  local front session pid
  cp "$FIXTURES/bridge.html" "$FIXTURES/data.json" "$FIXTURES/data.js" \
    "$WRAP_TMP/"

  cd "$WRAP_TMP"
  run_capture env TMPDIR="$WRAP_TMP" CLAUDE_PLUGIN_DATA="$VIEWER_CACHE" \
    HTML_POPUP_SWIFTC= HTML_POPUP_OPEN= HTML_POPUP_TEST_SCRIPT=data.js \
    "$WRAPPER" ask bridge.html --data data.json --timeout 20
  cd - >/dev/null
  assert_eq "relative paths: the page cancels after echoing" "1" "$RC"
  assert_eq "relative --data reaches the page" \
    "$(jq -cS . "$FIXTURES/data.json")" \
    "$(cat "$WRAP_TMP"/html-popup.*/events.jsonl |
      jq -cS 'select(.type == "message") | .data')"

  # Switching apps by hand during the run makes this check fail.
  front="$(lsappinfo front)"
  wrap noop.js show "$FIXTURES/basic.html" --timeout 30
  assert_eq "test-mode show exits 0" "0" "$RC"
  session="$OUT"
  pid="$(session_pid_of "$session")"
  assert_eq "test-mode window leaves the frontmost app" "$front" \
    "$(lsappinfo front)"
  assert "viewer runs from the app bundle" \
    test "$(ps -ww -p "$pid" -o comm=)" -ef "$VIEWER_BIN"
  assert_eq "viewer's parent is launchd" "1" \
    "$(ps -o ppid= -p "$pid" | tr -d ' ')"
  wrap - live close "$session"
  assert_eq "launched window closes" "0" "$RC"
}

test_wrapper_ask() {
  skip_unless_gui "wrapper ask" || return 0
  ensure_viewer
  new_tmpdir WRAP_TMP
  local session

  wrap answer.js ask "$FIXTURES/bridge.html" --timeout 20
  assert_eq "ask exits 0 on answer" "0" "$RC"
  assert_eq "ask prints the answer JSON" '{"month":7}' "$OUT"

  wrap send.js ask "$FIXTURES/bridge.html" --timeout 20
  assert_eq "ask exits 1 when the page cancels" "1" "$RC"
  assert "ask prints no answer on cancel" test -z "$OUT"

  wrap noop.js ask "$FIXTURES/bridge.html" --timeout 2
  assert_eq "ask exits 1 when the window times out" "1" "$RC"
  assert "window timeout is reported" \
    contains "window timed out without an answer" "$ERR"

  wrap answer-later.js ask "$FIXTURES/bridge.html" --timeout 30 --wait 1
  assert_eq "ask --wait 1 expires with exit 4" "4" "$RC"
  assert "expired ask prints a resume hint" \
    contains "still waiting; resume with: html-popup.sh ask --resume" "$ERR"
  session="${ERR##*--resume }"
  assert "resume hint names a session" test -f "$session/pid"
  assert "window stays open after the wait expires" \
    kill -0 "$(session_pid_of "$session")"
  wrap - ask --resume "$session" --wait 10
  assert_eq "ask --resume exits 0" "0" "$RC"
  assert_eq "ask --resume prints the answer" '{"month":3}' "$OUT"
}

test_wrapper_live() {
  skip_unless_gui "wrapper live round trip" || return 0
  ensure_viewer
  new_tmpdir WRAP_TMP
  local session events="" tries=10

  wrap noop.js live start "$FIXTURES/echo.html" --timeout 30
  assert_eq "live start exits 0" "0" "$RC"
  session="$OUT"
  wrap - live send "$session" '{"details": {"total": 43929}}'
  assert_eq "live send exits 0" "0" "$RC"
  while ((tries-- > 0)) && not_contains '"type":"message"' "$events"; do
    wrap - live wait "$session" --wait 5
    assert_eq "live wait exits 0 while open" "0" "$RC"
    events+="$OUT"$'\n'
  done
  assert "wait sees ready" contains '{"seq":1,"type":"ready"}' "$events"
  assert "wait sees the echo" \
    contains '{"seq":2,"type":"message","data":{"details":{"total":43929}}}' \
    "$events"

  wrap - live close "$session"
  assert_eq "live close exits 0" "0" "$RC"
  wrap - live wait "$session" --wait 5
  assert_eq "wait after close exits 1" "1" "$RC"
  assert_eq "wait prints the closed event" \
    '{"seq":3,"type":"closed","reason":"agent"}' "$OUT"
  wrap - live wait "$session" --wait 5
  assert_eq "wait after consumed closed exits 1" "1" "$RC"
  assert "it prints nothing new" test -z "$OUT"
  wrap - live close "$session"
  assert_eq "second close exits 0" "0" "$RC"
}

test_wrapper_live_races() {
  skip_unless_gui "wrapper live races and crashes" || return 0
  ensure_viewer
  new_tmpdir WRAP_TMP
  local session pid i closer rc

  wrap noop.js live start "$FIXTURES/echo.html" --timeout 30
  session="$OUT"
  env TMPDIR="$WRAP_TMP" "$WRAPPER" live close "$session" >/dev/null 2>&1 &
  closer=$!
  for i in 1 2 3 4 5 6 7 8 9 10; do
    run_bounded 5 env TMPDIR="$WRAP_TMP" \
      "$WRAPPER" live send "$session" "{\"n\":$i}"
    assert "send $i racing close does not hang" test "$RC" -ne 124
    assert "send $i racing close exits 0 or 1" test "$RC" -le 1
  done
  rc=0
  wait "$closer" || rc=$?
  assert_eq "close racing sends exits 0" "0" "$rc"
  run_bounded 5 env TMPDIR="$WRAP_TMP" "$WRAPPER" live send "$session" '1'
  assert_eq "send after close exits 1 without hanging" "1" "$RC"

  wrap noop.js live start "$FIXTURES/echo.html" --timeout 30
  session="$OUT"
  pid="$(session_pid_of "$session")"
  kill -9 "$pid"
  while kill -0 "$pid" 2>/dev/null; do sleep 0.1; done
  wrap - live wait "$session" --wait 5
  assert_eq "wait first drains ready" "0" "$RC"
  wrap - live wait "$session" --wait 5
  assert_eq "wait on a killed viewer exits 5" "5" "$RC"
  wrap - live close "$session"
  assert_eq "close on a gone session exits 0" "0" "$RC"
}

# descendants <pid> : print every descendant pid, one per line.
descendants() {
  local child
  for child in $(pgrep -P "$1"); do
    printf '%s\n' "$child"
    descendants "$child"
  done
}

# A Bash tool timeout kills the caller's process group or tree; the window
# must survive that and stay reachable through its session dir.
test_wrapper_caller_killed() {
  skip_unless_gui "window outlives a killed wrapper" || return 0
  ensure_viewer
  new_tmpdir WRAP_TMP
  local caller session pid tries=100 tree

  # Job control puts the background wrapper in its own process group.
  set -m
  env TMPDIR="$WRAP_TMP" CLAUDE_PLUGIN_DATA="$VIEWER_CACHE" \
    HTML_POPUP_TEST_SCRIPT="$FIXTURES/noop.js" \
    "$WRAPPER" ask "$FIXTURES/bridge.html" --timeout 30 >/dev/null 2>&1 &
  caller=$!
  set +m
  track_pid "$caller"
  until
    session="$(find "$WRAP_TMP" -maxdepth 1 -name 'html-popup.*' |
      head -n 1)" &&
      [[ -n "$session" ]] &&
      grep -q '"ready"' "$session/events.jsonl" 2>/dev/null
  do
    ((tries-- > 0)) || break
    sleep 0.1
  done
  assert "ask opened a window" test -s "$session/pid"
  pid="$(session_pid_of "$session")"

  # Kill like a tree-kill would: every descendant by parent pid, then the
  # process group.
  tree="$(descendants "$caller")"
  assert "viewer is not a descendant of the wrapper" \
    not_contains $'\n'"$pid"$'\n' $'\n'"$tree"$'\n'
  # shellcheck disable=SC2086 # one pid per word
  kill -KILL $tree "$caller" 2>/dev/null || true
  kill -KILL -- -"$caller" 2>/dev/null || true
  wait "$caller" 2>/dev/null || true
  assert "viewer survives its killed process tree" kill -0 "$pid"
  assert_eq "viewer was reparented to launchd" "1" \
    "$(ps -o ppid= -p "$pid" | tr -d ' ')"
  assert "viewer leads its own process group" \
    test "$(ps -o pgid= -p "$pid" | tr -d ' ')" != "$caller"
  wrap - ask --resume "$session" --wait 1
  assert_eq "killed ask can be resumed" "4" "$RC"
  wrap - live close "$session"
  assert_eq "surviving window closes" "agent" \
    "$(tail -n 1 "$session/events.jsonl" | jq -r .reason)"
}

# --- Tests: starter template -------------------------------------------------

# no_relative_remote <file> : true unless a src/href uses a //host URL.
no_relative_remote() {
  ! grep -Eq "(src|href)=[\"']?//" "$1"
}

test_template_static() {
  assert "template exists" test -f "$TEMPLATE"
  assert "template references no remote resources" \
    not_contains "http://" "$(cat "$TEMPLATE")"
  assert "template references no https resources" \
    not_contains "https://" "$(cat "$TEMPLATE")"
  assert "template has no protocol-relative URLs" no_relative_remote "$TEMPLATE"
  assert "template follows light/dark appearance" \
    contains "prefers-color-scheme: dark" "$(cat "$TEMPLATE")"
  assert "template uses the bridge answer hook" \
    contains "htmlPopup.answer(" "$(cat "$TEMPLATE")"
  assert "template uses the bridge send hook" \
    contains "htmlPopup.send(" "$(cat "$TEMPLATE")"
  assert "template uses the bridge onMessage hook" \
    contains "htmlPopup.onMessage(" "$(cat "$TEMPLATE")"
}

test_template_headless() {
  skip_unless_gui "template headless run" || return 0
  ensure_viewer
  new_tmpdir WRAP_TMP
  local session events="" tries=10

  wrap template-answer.js ask "$TEMPLATE" --timeout 20
  assert_eq "template Done button answers" "0" "$RC"
  assert_eq "template answer JSON" '{"ok":true}' "$OUT"

  wrap template-details.js live start "$TEMPLATE" --timeout 30
  assert_eq "template live start exits 0" "0" "$RC"
  session="$OUT"
  wrap - live send "$session" '{"details":{"Total":"43,929 GWh"}}'
  assert_eq "template live send exits 0" "0" "$RC"
  while ((tries-- > 0)) && not_contains '"type":"message"' "$events"; do
    wrap - live wait "$session" --wait 5
    events+="$OUT"$'\n'
  done
  assert "template renders agent details in the panel" \
    contains '"data":{"hidden":false,"text":"Total43,929 GWh"}' "$events"
  wrap - live close "$session"
  assert_eq "template window closes" "0" "$RC"

  new_tmpdir WRAP_TMP
  wrap template-enter.js ask "$TEMPLATE" --timeout 20
  assert_eq "template Return answers" '{"ok":true}' "$OUT"
  events="$(cat "$WRAP_TMP"/html-popup.*/events.jsonl)"
  assert "Return in a contenteditable does not answer" \
    contains '"data":"contenteditable"' "$events"
  assert "Return with preventDefault does not answer" \
    contains '"data":"prevented"' "$events"

  # SKILL.md says to delete the Details button and panel outside live mode.
  new_tmpdir WRAP_TMP
  sed -e '/id="send"/d' -e '/id="details"/d' \
    -e 's|^</script>|window.templateInitialized = true;\n</script>|' \
    "$TEMPLATE" >"$WRAP_TMP/page.html"
  assert "stripped template has no Details button" \
    not_contains 'id="send"' "$(cat "$WRAP_TMP/page.html")"
  wrap template-init.js ask "$WRAP_TMP/page.html" --timeout 20
  assert_eq "stripped template answers" '{"initialized":true}' "$OUT"
}

# --- Tests: solar example -----------------------------------------------------

test_solar_static() {
  local data="$SOLAR/data.json"

  assert "solar data.json parses" jq empty "$data"
  assert_eq "solar data has 12 months" "12" "$(jq '.months | length' "$data")"
  assert_eq "every month has all fields" "true" "$(jq '.months | all(. as $m
    | ["name", "short", "utility", "small", "thermal", "total", "wind",
       "total2024"] | all(. as $k | $m | has($k)))' "$data")"
  assert_eq "monthly fields are numbers" "true" "$(jq '[.months[]
    | .utility, .small, .thermal, .total, .wind, .total2024 | numbers]
    | length == 72' "$data")"
  assert_eq "totals equal utility + small + thermal within 1" "true" \
    "$(jq '[.months[] | .utility + .small + .thermal - .total
      | fabs <= 1] | all' "$data")"
  assert_eq "solar data has unit, title and source" "true" \
    "$(jq '.unit and .title and .source' "$data")"
  assert "solar source names the EIA URL" \
    contains "https://www.eia.gov/electricity/monthly/" \
    "$(jq -r .source "$data")"
  assert "solar report references no remote resources" \
    not_contains "://" "$(cat "$SOLAR/report.html")"
  assert "solar report has no protocol-relative URLs" \
    no_relative_remote "$SOLAR/report.html"
  assert "run.sh is executable" test -x "$SOLAR/run.sh"
}

test_solar_live() {
  skip_unless_gui "solar example live run" || return 0
  ensure_viewer
  new_tmpdir WRAP_TMP
  local events

  run_capture env TMPDIR="$WRAP_TMP" CLAUDE_PLUGIN_DATA="$VIEWER_CACHE" \
    HTML_POPUP_TEST_SCRIPT="$FIXTURES/solar-select.js" \
    "$SOLAR/run.sh" --timeout 30
  assert_eq "run.sh exits 0 after Done" "0" "$RC"
  assert "run.sh prints the chosen month" \
    contains "June 2025 — US solar generation" "$OUT"
  assert "run.sh prints the total" contains "42,002 GWh" "$OUT"
  assert "run.sh prints year over year" \
    contains "+27.2% year over year" "$OUT"
  assert "run.sh prints the rank" contains "#2 of 12" "$OUT"
  assert "run.sh prints solar vs wind" contains "solar = 1.16× wind" "$OUT"
  assert_eq "invalid month requests are ignored" "1" \
    "$(grep -c "US solar generation" <<<"$OUT")"

  events="$(cat "$WRAP_TMP"/html-popup.*/events.jsonl)"
  assert "choosing a month emits its number" \
    contains '"type":"message","data":{"month":6}' "$events"
  assert "details from the agent render in the panel" \
    contains '"data":{"hidden":false,"text":"JuneTotal solar42,002 GWh' \
    "$events"
  assert "Done answers null" contains '"type":"answer","data":null' "$events"
  assert "Done closes the window" contains '"reason":"answer"' "$events"
}

# --- Tests: SKILL.md ----------------------------------------------------------

# skill_frontmatter : print the lines between the opening and closing ---.
skill_frontmatter() {
  awk 'NR == 1 && $0 == "---" { inside = 1; next }
    inside && $0 == "---" { exit }
    inside { print }' "$SKILL_MD"
}

test_skill() {
  local front path paths

  assert "SKILL.md exists" test -f "$SKILL_MD"
  front="$(skill_frontmatter)"
  assert "frontmatter names the skill" \
    contains $'\nname: html-popup\n' $'\n'"$front"$'\n'
  assert "frontmatter has a description" contains $'\ndescription:' \
    $'\n'"$front"
  assert "frontmatter allows Bash, Read and Write" \
    contains "allowed-tools: Bash, Read, Write" "$front"

  paths="$(grep -oE '(scripts|assets|examples)/[A-Za-z0-9._/-]*[A-Za-z0-9_/]' \
    "$SKILL_MD" | sort -u)"
  assert "SKILL.md mentions plugin paths" test -n "$paths"
  while IFS= read -r path; do
    assert "SKILL.md path exists: $path" test -e "$PLUGIN_DIR/$path"
  done <<<"$paths"
  # shellcheck disable=SC2016 # literal text the skill must contain
  assert "SKILL.md roots paths at CLAUDE_PLUGIN_ROOT" \
    contains 'R="${CLAUDE_PLUGIN_ROOT:-' "$(cat "$SKILL_MD")"
  # shellcheck disable=SC2016 # literal text the skill must contain
  assert "SKILL.md calls the wrapper under the plugin root" \
    contains 'P="$R/scripts/html-popup.sh"' "$(cat "$SKILL_MD")"
}

# --- Runner -------------------------------------------------------------------

main() {
  test_manifest
  test_icon_assets
  test_harness
  test_dispatch
  test_build_cache
  test_build_prune
  test_build_concurrent
  test_missing_jq
  test_check_ok
  test_missing_compiler
  test_unwritable_cache
  test_compiler_failure
  test_missing_bundle_inputs
  test_real_build
  test_viewer_startup
  test_viewer_errors
  test_viewer_abandoned
  test_bridge_send
  test_bridge_answer
  test_bridge_data
  test_bridge_escape
  test_bridge_raw_posts
  test_bridge_child_frame
  test_viewer_size
  test_bridge_bad_data
  test_inbound_echo
  test_inbound_invalid
  test_inbound_throwing_handler
  test_wrapper_args
  test_wrapper_fake_sessions
  test_wrapper_recycled_pid
  test_wrapper_session_identity
  test_wrapper_concurrent_sends
  test_wrapper_stale_lock_race
  test_wrapper_released_lock_reuse
  test_wrapper_killed_sender
  test_wrapper_killed_sender_group
  test_wrapper_wait_close_race
  test_wrapper_wait_decimal
  test_wrapper_resume_outcomes
  test_wrapper_close_stuck
  test_wrapper_malformed_events
  test_wrapper_concurrent_close
  test_wrapper_wait_forced_close
  test_wrapper_ask_budget
  test_wrapper_close_owner_killed
  test_wrapper_close_lock_takeover_race
  test_wrapper_startup
  test_wrapper_launch_args
  test_wrapper_starting_session
  test_wrapper_show
  test_wrapper_open_launch
  test_wrapper_ask
  test_wrapper_live
  test_wrapper_live_races
  test_wrapper_caller_killed
  test_template_static
  test_template_headless
  test_solar_static
  test_solar_live
  test_skill

  printf '\nAll %d assertions passed (%d skipped).\n' \
    "$PASS_COUNT" "$SKIP_COUNT"
}

main "$@"
