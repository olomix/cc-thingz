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
  local pid dir pidfile
  for pid in "${TRACKED_PIDS[@]+"${TRACKED_PIDS[@]}"}"; do
    kill "$pid" 2>/dev/null || true
  done
  # Viewers started through the wrapper are detached; their sessions live
  # under our temp dirs, so find them by pid file.
  for dir in "${TEMP_DIRS[@]+"${TEMP_DIRS[@]}"}"; do
    for pidfile in "$dir"/html-popup.*/pid; do
      [[ -f "$pidfile" ]] || continue
      pid="$(tr -d '[:space:]' <"$pidfile")"
      [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    done
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

# --- Tests: inbound FIFO (agent -> page) ---------------------------------------

# start_viewer <args...> : start the viewer in the background (tracked for
# cleanup) and store its pid in VIEWER_PID. Collect it with finish_viewer.
start_viewer() {
  "$VIEWER_BIN" "$@" >/dev/null 2>&1 &
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

# fifo_write <fifo> <text> : write text plus a newline to the FIFO. A
# read-write open never blocks, but a large write blocks until the viewer
# reads it, so a watchdog bounds the call in case the viewer is gone.
fifo_write() {
  local writer watchdog rc=0
  (
    exec 3<>"$1"
    printf '%s\n' "$2" >&3
  ) &
  writer=$!
  # Detached from our stdout, so a lingering sleep cannot hold a pipe open.
  (sleep 10 && kill "$writer" 2>/dev/null) >/dev/null 2>&1 &
  watchdog=$!
  wait "$writer" || rc=$?
  pkill -P "$watchdog" 2>/dev/null || true
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
  return "$rc"
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
  local big
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

  assert "close line is written" fifo_write "$SESSION/in" '{"htmlPopup":"close"}'
  finish_viewer
  assert_eq "close line exits 0" "0" "$RC"
  assert_eq "close line closes with reason agent" \
    '{"seq":4,"type":"closed","reason":"agent"}' "$(tail -n 1 "$EVENTS")"
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

  assert "close line is written" fifo_write "$SESSION/in" '{"htmlPopup":"close"}'
  finish_viewer
  assert_eq "close after invalid input exits 0" "0" "$RC"
  assert_eq "close reason is agent" "agent" "$(tail -n 1 "$EVENTS" | jq -r .reason)"
}

# --- Helpers: running the wrapper against sessions -----------------------------

WRAPPER="$PLUGIN_DIR/scripts/html-popup.sh"
WRAP_TMP=""

# wrap <test script|-> <args...> : run the wrapper with sessions under
# WRAP_TMP and the cached real viewer; sets OUT, ERR, RC. "-" means no
# test script (only for calls that never open a window).
wrap() {
  local script="$1"
  shift
  [[ "$script" == - ]] && script="" || script="$FIXTURES/$script"
  run_capture env TMPDIR="$WRAP_TMP" CLAUDE_PLUGIN_DATA="${VIEWER_CACHE:-$WRAP_TMP/cache}" \
    HTML_POPUP_SWIFTC="${WRAP_SWIFTC:-}" HTML_POPUP_TEST_SCRIPT="$script" \
    "$WRAPPER" "$@"
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

# fake_session <var> <pid> [events...] : make a session dir without a viewer
# and store its path in <var>.
fake_session() {
  local var="$1" pid="$2" dir line
  shift 2
  dir="$(mktemp -d "$WRAP_TMP/html-popup.XXXXXX")"
  printf '%s\n' "$pid" >"$dir/pid"
  mkfifo "$dir/in"
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

# live_pid : print the pid of a tracked idle process that stays alive.
live_pid() {
  sleep 120 >/dev/null 2>&1 &
  track_pid "$!"
  LIVE_PID=$!
}

# session_pid_of <dir> : the viewer pid recorded in a session dir.
session_pid_of() {
  tr -d '[:space:]' <"$1/pid"
}

# --- Tests: wrapper arguments and sessions without a viewer --------------------

test_wrapper_args() {
  new_tmpdir WRAP_TMP
  local session stale fresh alive dead

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

  # Stale cleanup runs before validation, so a failing call still prunes.
  dead="$(dead_pid)"
  live_pid
  alive="$LIVE_PID"
  fake_session stale "$dead"
  fake_session fresh "$dead"
  fake_session session "$alive"
  touch -t 202001010000 "$stale" "$session"
  wrap - show "$WRAP_TMP/no-such-page.html"
  assert "old session with a dead viewer is removed" test ! -e "$stale"
  assert "recent session is kept" test -d "$fresh"
  assert "old session with a live viewer is kept" test -d "$session"
}

test_wrapper_fake_sessions() {
  new_tmpdir WRAP_TMP
  local session dead
  dead="$(dead_pid)"
  live_pid

  fake_session session "$LIVE_PID" '{"seq":1,"type":"ready"}'
  wrap - live send "$session" '{"broken":'
  assert_eq "send of invalid JSON exits 2" "2" "$RC"
  wrap - live send "$session" '1 2'
  assert_eq "send of two values exits 2" "2" "$RC"
  wrap - live send "$session"
  assert_eq "send without JSON exits 2" "2" "$RC"
  wrap - live wait "$session" --wait 0
  assert_eq "wait prints the new event" '{"seq":1,"type":"ready"}' "$OUT"
  assert_eq "wait with new events exits 0" "0" "$RC"
  assert_eq "wait stores the cursor" "1" "$(tr -d '[:space:]' <"$session/cursor")"
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
}

# --- Tests: wrapper with the real viewer ---------------------------------------

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
  assert_eq "ask exits 4 when the window times out" "4" "$RC"

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
  local session pid i closer

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
  wait "$closer" || true
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

# A Bash tool timeout kills the caller's whole process group; the window
# must survive that and stay reachable through its session dir.
test_wrapper_caller_killed() {
  skip_unless_gui "window outlives a killed wrapper" || return 0
  ensure_viewer
  new_tmpdir WRAP_TMP
  local caller session pid tries=100

  # Job control puts the background wrapper in its own process group.
  set -m
  env TMPDIR="$WRAP_TMP" CLAUDE_PLUGIN_DATA="$VIEWER_CACHE" \
    HTML_POPUP_TEST_SCRIPT="$FIXTURES/noop.js" \
    "$WRAPPER" ask "$FIXTURES/bridge.html" --timeout 30 >/dev/null 2>&1 &
  caller=$!
  set +m
  track_pid "$caller"
  until session="$(find "$WRAP_TMP" -maxdepth 1 -name 'html-popup.*' | head -n 1)" &&
    [[ -n "$session" ]] && grep -q '"ready"' "$session/events.jsonl" 2>/dev/null; do
    ((tries-- > 0)) || break
    sleep 0.1
  done
  assert "ask opened a window" test -s "$session/pid"
  pid="$(session_pid_of "$session")"

  kill -KILL -- -"$caller"
  wait "$caller" 2>/dev/null || true
  assert "viewer survives its killed process group" kill -0 "$pid"
  assert "viewer leads its own process group" \
    test "$(ps -o pgid= -p "$pid" | tr -d ' ')" != "$caller"
  wrap - ask --resume "$session" --wait 1
  assert_eq "killed ask can be resumed" "4" "$RC"
  wrap - live close "$session"
  assert_eq "surviving window closes" "agent" \
    "$(tail -n 1 "$session/events.jsonl" | jq -r .reason)"
}

# --- Tests: starter template -------------------------------------------------

TEMPLATE="$PLUGIN_DIR/assets/template.html"

test_template_static() {
  assert "template exists" test -f "$TEMPLATE"
  assert "template references no remote resources" \
    not_contains "http://" "$(cat "$TEMPLATE")"
  assert "template references no https resources" \
    not_contains "https://" "$(cat "$TEMPLATE")"
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
}

# --- Tests: solar example --------------------------------------------------------

SOLAR="$PLUGIN_DIR/examples/solar-2025"

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

  events="$(cat "$WRAP_TMP"/html-popup.*/events.jsonl)"
  assert "choosing a month emits its number" \
    contains '"type":"message","data":{"month":6}' "$events"
  assert "details from the agent render in the panel" \
    contains '"data":{"hidden":false,"text":"JuneTotal solar42,002 GWh' \
    "$events"
  assert "Done answers null" contains '"type":"answer","data":null' "$events"
  assert "Done closes the window" contains '"reason":"answer"' "$events"
}

# --- Tests: SKILL.md ------------------------------------------------------------

SKILL_MD="$PLUGIN_DIR/skills/html-popup/SKILL.md"

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
  assert "SKILL.md uses the wrapper via CLAUDE_PLUGIN_ROOT" \
    contains '"${CLAUDE_PLUGIN_ROOT}/scripts/html-popup.sh"' "$(cat "$SKILL_MD")"
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
  test_inbound_echo
  test_inbound_invalid
  test_wrapper_args
  test_wrapper_fake_sessions
  test_wrapper_show
  test_wrapper_ask
  test_wrapper_live
  test_wrapper_live_races
  test_wrapper_caller_killed
  test_template_static
  test_template_headless
  test_solar_static
  test_solar_live
  test_skill

  printf '\nAll %d assertions passed (%d skipped).\n' "$PASS_COUNT" "$SKIP_COUNT"
}

main "$@"
