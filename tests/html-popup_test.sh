#!/usr/bin/env bash
# Unit tests for the html-popup plugin. Pure bash, no framework.
# Run: tests/html-popup_test.sh  (exits non-zero on first failure)
#
# Viewer tests need a real compiler and a GUI login session; they call
# skip_unless_gui and are skipped elsewhere. All other tests always run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_DIR="$REPO_ROOT/plugins/html-popup"
MARKETPLACE="$REPO_ROOT/.claude-plugin/marketplace.json"
FAKE_SWIFTC="$SCRIPT_DIR/fixtures/fake-swiftc.sh"

PASS_COUNT=0
SKIP_COUNT=0
TRACKED_PIDS=()
TEMP_DIRS=()

# assert exits on the first failure, so viewers and temp dirs must be cleaned
# up from a trap rather than at the end of each test.
cleanup() {
  local pid dir
  for pid in "${TRACKED_PIDS[@]+"${TRACKED_PIDS[@]}"}"; do
    kill "$pid" 2>/dev/null || true
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
    "$(jq '[.plugins[] | select(.name == "html-popup")] | length' "$MARKETPLACE")"
  assert_eq "marketplace source points at the plugin" "./plugins/html-popup" \
    "$(jq -r '.plugins[] | select(.name == "html-popup") | .source' "$MARKETPLACE")"
  assert "marketplace entry has a description" \
    test -n "$(jq -r '.plugins[] | select(.name == "html-popup")
      | .description // empty' "$MARKETPLACE")"
}

# --- Tests: harness helpers ----------------------------------------------------

test_harness() {
  local dir rc
  new_tmpdir dir
  assert "new_tmpdir creates a directory" test -d "$dir"
  assert "new_tmpdir tracks the directory for cleanup" \
    contains "$dir" "${TEMP_DIRS[*]}"

  # Probe in a subshell so it does not count as a skip.
  set +e
  (skip_unless_gui "harness probe" >/dev/null)
  rc=$?
  set -e
  assert "skip_unless_gui returns 0 or 1" test "$rc" -le 1
}

# --- Helpers: running the wrapper ----------------------------------------------

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

# count_lines <file> : number of lines, 0 when the file does not exist.
count_lines() {
  if [[ -f "$1" ]]; then
    wc -l <"$1" | tr -d ' '
  else
    printf '0'
  fi
}

# --- Tests: subcommand dispatch ------------------------------------------------

test_dispatch() {
  local wrapper="$PLUGIN_DIR/scripts/html-popup.sh"

  run_capture "$wrapper"
  assert_eq "no command exits 2" "2" "$RC"
  assert "no command prints usage" contains "usage:" "$ERR"

  run_capture "$wrapper" frobnicate
  assert_eq "unknown command exits 2" "2" "$RC"
  assert "unknown command is named" contains "unknown command: frobnicate" "$ERR"

  run_capture "$wrapper" --help
  assert_eq "--help exits 0" "0" "$RC"
}

# --- Tests: build with hash cache ----------------------------------------------

test_build_cache() {
  local root cache calls wrapper first second hash
  copy_plugin root
  new_tmpdir cache
  calls="$cache/calls"
  wrapper="$root/scripts/html-popup.sh"
  export CLAUDE_PLUGIN_DATA="$cache/bin" HTML_POPUP_SWIFTC="$FAKE_SWIFTC"
  export FAKE_SWIFTC_CALLS="$calls"

  run_capture "$wrapper" build
  assert_eq "build exits 0" "0" "$RC"
  first="$OUT"
  hash="$(shasum -a 256 "$root/viewer/html-popup-viewer.swift")"
  assert_eq "binary is named after the source hash" \
    "$cache/bin/html-popup-viewer-${hash:0:12}" "$first"
  assert "built binary is executable" test -x "$first"
  assert_eq "first build compiles once" "1" "$(count_lines "$calls")"

  run_capture "$wrapper" build
  assert_eq "second build exits 0" "0" "$RC"
  assert_eq "second build reuses the binary" "$first" "$OUT"
  assert_eq "second build does not compile" "1" "$(count_lines "$calls")"

  printf '// changed\n' >>"$root/viewer/html-popup-viewer.swift"
  run_capture "$wrapper" build
  second="$OUT"
  assert_eq "changed source builds" "0" "$RC"
  assert "changed source gets a new binary" test "$first" != "$second"
  assert "new binary is executable" test -x "$second"
  assert_eq "changed source compiles again" "2" "$(count_lines "$calls")"

  unset CLAUDE_PLUGIN_DATA HTML_POPUP_SWIFTC FAKE_SWIFTC_CALLS
}

test_build_concurrent() {
  local cache wrapper out1 out2 rc1=0 rc2=0 pid1 pid2 bins
  new_tmpdir cache
  wrapper="$PLUGIN_DIR/scripts/html-popup.sh"
  export CLAUDE_PLUGIN_DATA="$cache/bin" HTML_POPUP_SWIFTC="$FAKE_SWIFTC"
  export FAKE_SWIFTC_DELAY=1

  "$wrapper" build >"$cache/out1" 2>/dev/null &
  pid1=$!
  "$wrapper" build >"$cache/out2" 2>/dev/null &
  pid2=$!
  wait "$pid1" || rc1=$?
  wait "$pid2" || rc2=$?
  unset CLAUDE_PLUGIN_DATA HTML_POPUP_SWIFTC FAKE_SWIFTC_DELAY

  out1="$(cat "$cache/out1")"
  out2="$(cat "$cache/out2")"
  assert_eq "first concurrent build exits 0" "0" "$rc1"
  assert_eq "second concurrent build exits 0" "0" "$rc2"
  assert_eq "concurrent builds print the same path" "$out1" "$out2"
  bins="$(find "$cache/bin" -type f | wc -l | tr -d ' ')"
  assert_eq "concurrent builds leave exactly one file" "1" "$bins"
  assert "the one file is the executable binary" test -x "$out1"
}

# --- Tests: check and build errors ---------------------------------------------

test_missing_jq() {
  local bin cache tool
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
  local cache left
  new_tmpdir cache
  run_capture env CLAUDE_PLUGIN_DATA="$cache/bin" \
    HTML_POPUP_SWIFTC="$FAKE_SWIFTC" FAKE_SWIFTC_FAIL=1 \
    "$PLUGIN_DIR/scripts/html-popup.sh" build
  assert_eq "failed compile exits 2" "2" "$RC"
  assert "failed compile is reported" contains "failed to compile" "$ERR"
  assert "compiler output is passed through" \
    contains "simulated compile failure" "$ERR"
  left="$(find "$cache/bin" -type f | wc -l | tr -d ' ')"
  assert_eq "failed compile leaves no binary behind" "0" "$left"
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

# --- Helpers: running the real viewer ------------------------------------------

FIXTURES="$SCRIPT_DIR/fixtures/html-popup"
VIEWER_BIN=""
VIEWER_CACHE=""
SESSION=""
EVENTS=""

# ensure_viewer : compile the real viewer once per run into VIEWER_BIN.
ensure_viewer() {
  [[ -n "$VIEWER_BIN" ]] && return 0
  new_tmpdir VIEWER_CACHE
  run_capture env CLAUDE_PLUGIN_DATA="$VIEWER_CACHE" \
    "$PLUGIN_DIR/scripts/html-popup.sh" build
  assert_eq "viewer builds for viewer tests" "0" "$RC"
  VIEWER_BIN="$OUT"
}

# run_viewer <args...> : run the viewer in the background (tracked for
# cleanup), wait for it and store its exit code in RC and pid in VIEWER_PID.
# Callers always pass --timeout, so the wait is bounded.
run_viewer() {
  "$VIEWER_BIN" "$@" >/dev/null 2>&1 &
  VIEWER_PID=$!
  track_pid "$VIEWER_PID"
  set +e
  wait "$VIEWER_PID"
  RC=$?
  set -e
}

# event_field <events file> <line number> <jq filter>
event_field() {
  sed -n "${2}p" "$1" | jq -r "$3"
}

# --- Tests: viewer window and session files ------------------------------------

test_viewer_startup() {
  skip_unless_gui "viewer startup and timeout" || return 0
  ensure_viewer
  local session events
  new_tmpdir session
  events="$session/events.jsonl"

  run_viewer "$FIXTURES/basic.html" --session "$session" --timeout 2 \
    --test-script "$FIXTURES/noop.js"
  assert_eq "--timeout exits 4" "4" "$RC"
  assert_eq "ready is the first event" "ready" "$(event_field "$events" 1 .type)"
  assert_eq "ready has seq 1" "1" "$(event_field "$events" 1 .seq)"
  assert_eq "timeout writes closed" "closed" "$(event_field "$events" 2 .type)"
  assert_eq "closed reason is timeout" "timeout" \
    "$(event_field "$events" 2 .reason)"
  assert_eq "closed has seq 2" "2" "$(event_field "$events" 2 .seq)"
  assert_eq "exactly two events" "2" "$(count_lines "$events")"
  assert_eq "pid file holds the viewer pid" "$VIEWER_PID" \
    "$(tr -d '[:space:]' <"$session/pid")"
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

# --- Tests: JS bridge (page -> agent) ------------------------------------------

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
  assert_eq "object message round-trips" \
    '{"seq":2,"type":"message","data":{"action":"select","month":7,"nested":{"list":[1,"two"]}}}' \
    "$(sed -n 2p "$EVENTS")"
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

# --- Runner --------------------------------------------------------------------

main() {
  test_manifest
  test_harness
  test_dispatch
  test_build_cache
  test_build_concurrent
  test_missing_jq
  test_check_ok
  test_missing_compiler
  test_unwritable_cache
  test_compiler_failure
  test_real_build
  test_viewer_startup
  test_viewer_errors
  test_bridge_send
  test_bridge_answer
  test_bridge_data
  test_bridge_escape
  test_bridge_bad_data

  printf '\nAll %d assertions passed (%d skipped).\n' "$PASS_COUNT" "$SKIP_COUNT"
}

main "$@"
