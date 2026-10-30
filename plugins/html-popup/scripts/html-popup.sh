#!/usr/bin/env bash
# html-popup.sh — show an HTML page in a native macOS window and exchange
# data with it. Builds and caches the Swift viewer on first use.
#
# Usage: html-popup.sh <command> [args...]  (see usage below)
#
# Every window runs as a session: a temp dir holding `pid`, `in` (FIFO to
# the page), `events.jsonl` (events from the page) and `viewer.log`. The
# viewer runs detached, so a killed wrapper call never closes the window.
#
# Exit codes: 0 ok / answered; 1 window closed (no answer, session over,
# window --timeout reached); 2 usage error, missing dependency, build
# failure; 3 page or data invalid, page failed to load or not ready in 10 s;
# 4 --wait expired, window still open; 5 viewer died without a closed event.
#
# Environment:
#   CLAUDE_PLUGIN_DATA      cache dir (default: ~/Library/Caches/html-popup)
#   HTML_POPUP_SWIFTC       compiler to use instead of xcrun swiftc
#                           (tests use a fake)
#   HTML_POPUP_TEST_SCRIPT  JS file run after page load; headless test mode
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VIEWER_SRC="$PLUGIN_ROOT/viewer/html-popup-viewer.swift"
CACHE_DIR="${CLAUDE_PLUGIN_DATA:-$HOME/Library/Caches/html-popup}"
TMP_ROOT="${TMPDIR:-/tmp}"
TMP_ROOT="${TMP_ROOT%/}"

DEFAULT_WAIT=100
READY_WAIT=10
CLOSE_WAIT=5
POLL=0.2
# Short: a blocked FIFO write only waits for the viewer to read.
FIFO_POLL=0.05

# xcrun picks the Xcode toolchain with the AppKit/WebKit SDK, not whatever
# swiftc (e.g. an OSS toolchain) comes first in PATH.
if [[ -n "${HTML_POPUP_SWIFTC:-}" ]]; then
  SWIFTC=("$HTML_POPUP_SWIFTC")
else
  SWIFTC=(xcrun swiftc)
fi

usage() {
  cat >&2 <<'EOF'
usage: html-popup.sh <command> [args...]
  check                          verify macOS, swiftc, jq, cache, GUI session
  build                          build the viewer if needed, print its path
  show PAGE [opts]               open, wait until the page loads, print DIR
  ask PAGE [opts] [--wait SEC]   wait for the answer, print it as JSON
  ask --resume DIR [--wait SEC]  keep waiting on an earlier ask
  live start PAGE [opts]         open, wait until ready, print DIR
  live send DIR JSON             deliver one JSON value to the page
  live wait DIR [--wait SEC]     print new events as JSON lines
  live close DIR                 close the window (ok if already gone)
opts: --data FILE  --title TEXT  --size WxH  --timeout SEC (window lifetime)
--wait SEC: how long this call blocks, from its start (default 100)
EOF
}

die() {
  printf 'html-popup: %s\n' "$1" >&2
  exit "${2:-2}"
}

# missing_* : true (and print one message) when the piece is missing.
missing_macos() {
  [[ "$(uname -s)" == "Darwin" ]] && return 1
  printf 'html-popup: macOS is required\n' >&2
}

# /usr/bin/swiftc is a shim that exists even without the Command Line Tools,
# so ask xcrun whether a real compiler is installed.
missing_compiler() {
  if [[ -n "${HTML_POPUP_SWIFTC:-}" ]]; then
    command -v "$HTML_POPUP_SWIFTC" >/dev/null 2>&1 && return 1
    printf 'html-popup: HTML_POPUP_SWIFTC not found: %s\n' \
      "$HTML_POPUP_SWIFTC" >&2
    return 0
  fi
  xcrun --find swiftc >/dev/null 2>&1 && return 1
  printf 'html-popup: swiftc not found; %s\n' \
    'install the Xcode Command Line Tools: xcode-select --install' >&2
}

missing_jq() {
  command -v jq >/dev/null 2>&1 && return 1
  printf 'html-popup: jq not found; install it, e.g. brew install jq\n' >&2
}

missing_cache_dir() {
  if mkdir -p "$CACHE_DIR" 2>/dev/null && [[ -w "$CACHE_DIR" ]]; then
    return 1
  fi
  printf 'html-popup: cache dir is not writable: %s\n' "$CACHE_DIR" >&2
}

missing_gui() {
  [[ "$(launchctl managername 2>/dev/null)" == "Aqua" ]] && return 1
  printf 'html-popup: no GUI login session %s\n' \
    '(launchctl managername is not Aqua)' >&2
}

cmd_check() {
  (($# == 0)) || die "unexpected argument: $1"
  local failed=0
  missing_macos && failed=1
  missing_compiler && failed=1
  missing_jq && failed=1
  missing_cache_dir && failed=1
  missing_gui && failed=1
  ((failed == 0)) || exit 2
  printf 'html-popup: all checks passed\n'
}

pid_alive() {
  [[ -n "$1" ]] && kill -0 "$1" 2>/dev/null
}

# viewer_path : print the cached binary path for the current viewer source.
# The source hash is the cache key, so plugin updates rebuild automatically.
viewer_path() {
  local hash
  hash="$(shasum -a 256 "$VIEWER_SRC")"
  printf '%s/html-popup-viewer-%s' "$CACHE_DIR" "${hash:0:12}"
}

# build_viewer : compile the viewer unless cached; print its path.
build_viewer() {
  (($# == 0)) || die "unexpected argument: $1"
  local failed=0 bin tmp
  missing_macos && failed=1
  missing_compiler && failed=1
  missing_cache_dir && failed=1
  ((failed == 0)) || exit 2
  [[ -r "$VIEWER_SRC" ]] || die "viewer source not found: $VIEWER_SRC"

  bin="$(viewer_path)"
  # Touch on use: pruning below spares binaries used within the last day.
  if [[ -x "$bin" ]] && touch "$bin"; then
    printf '%s\n' "$bin"
    return 0
  fi
  # A per-process temp name plus an atomic mv keeps concurrent first uses
  # from running a half-written binary.
  tmp="$bin.tmp.$$"
  if ! "${SWIFTC[@]}" -O -o "$tmp" "$VIEWER_SRC" >&2; then
    rm -f "$tmp"
    die "failed to compile the viewer"
  fi
  mv -f "$tmp" "$bin"
  # Other plugin versions may build or launch their binary right now, so
  # drop only binaries and temp files unused for over a day.
  find "$CACHE_DIR" -maxdepth 1 -name 'html-popup-viewer-*' -mtime +0 \
    -exec rm -f {} + 2>/dev/null || true
  printf '%s\n' "$bin"
}

# --- Sessions -----------------------------------------------------------
# A viewer may write its last events just before it exits, so each wait
# loop reads the events once more after it finds the viewer gone.

require_jq() {
  missing_jq && exit 2
  return 0
}

# parse_wait <value> : validate a --wait value (whole seconds) and print it
# in decimal; arithmetic would read a leading zero as octal.
parse_wait() {
  [[ "$1" =~ ^[0-9]+$ ]] || die "bad --wait: $1 (whole seconds)"
  printf '%s' "$((10#$1))"
}

# viewer_alive <dir> <pid> : true when pid is the viewer of session dir. A
# dead viewer's pid may be recycled by an unrelated process or by another
# session's viewer, so check the name and the --session argument.
viewer_alive() {
  local comm args rest
  pid_alive "$2" || return 1
  comm="$(ps -ww -p "$2" -o comm= 2>/dev/null)" || return 1
  [[ "${comm##*/}" == html-popup-viewer-* ]] || return 1
  args="$(ps -ww -p "$2" -o args= 2>/dev/null)" || return 1
  # The page path or title may contain " --session ", so try each one.
  rest="$args"
  while [[ "$rest" == *" --session "* ]]; do
    rest="${rest#* --session }"
    [[ "${rest%% --*}" -ef "$1" ]] && return 0
  done
  return 1
}

session_pid() {
  tr -d '[:space:]' 2>/dev/null <"$1/pid" || true
}

# require_session <dir> : exit 2 unless dir looks like a session dir.
require_session() {
  [[ -n "$1" ]] || die "missing session DIR"
  [[ -f "$1/pid" ]] || die "not an html-popup session: $1"
}

# complete_events <dir> : print the newline-terminated lines of events.jsonl;
# a line still being written is left for the next call.
complete_events() {
  local file="$1/events.jsonl" snapshot
  [[ -f "$file" ]] || return 0
  snapshot="$(cat "$file"; printf x)"
  snapshot="${snapshot%x}"
  [[ "$snapshot" == *$'\n'* ]] || return 0
  printf '%s\n' "${snapshot%$'\n'*}"
}

# has_event <dir> <type>... : true when a complete event of one of those
# types exists. jq reads all input: stopping at a match would SIGPIPE the
# writer and fail the pipeline under pipefail.
has_event() {
  complete_events "$1" |
    jq -e -n '[inputs | select(.type | IN($ARGS.positional[]))] | any' \
      --args "${@:2}" >/dev/null 2>&1
}

# SECONDS truncates to whole seconds, so "SECONDS > end" never ends a wait
# early. A zero wait checks once.
deadline_start() {
  WAIT_END=$((SECONDS + $1))
  WAIT_ONCE=$(($1 == 0))
}

deadline_passed() {
  ((WAIT_ONCE == 1 || SECONDS > WAIT_END))
}

# need_value <option> [value...] : exit 2 unless the option has a value.
need_value() {
  (($# >= 2)) || die "missing value for $1"
}

# first_event <dir> <type>... : print the first complete event of one of
# those types.
first_event() {
  complete_events "$1" |
    jq -c -n '[inputs | select(.type | IN($ARGS.positional[]))][0] // empty' \
      --args "${@:2}" 2>/dev/null
}

# new_events <dir> <cursor> : print complete events with seq above cursor.
new_events() {
  complete_events "$1" | jq -c --argjson c "$2" 'select(.seq > $c)' \
    2>/dev/null || true
}

# terminate_viewer <dir> <pid> <reason> [message] : kill a viewer that did
# not close by itself and append the closed event it could not write.
terminate_viewer() {
  local dir="$1" pid="$2" file="$1/events.jsonl" seq
  if viewer_alive "$dir" "$pid"; then
    kill "$pid" 2>/dev/null || true
    deadline_start "$CLOSE_WAIT"
    while viewer_alive "$dir" "$pid" && ! deadline_passed; do
      sleep "$POLL"
    done
    if viewer_alive "$dir" "$pid"; then
      kill -9 "$pid" 2>/dev/null || true
    fi
  fi
  has_event "$dir" closed && return 0
  # Concurrent closes may all get here: only the mkdir winner appends, the
  # others wait for its event. The lock dir is never removed.
  if ! mkdir "$dir/close.lock" 2>/dev/null; then
    deadline_start "$CLOSE_WAIT"
    until has_event "$dir" closed || deadline_passed; do
      sleep "$POLL"
    done
    return 0
  fi
  has_event "$dir" closed && return 0
  if [[ -s "$file" && -n "$(tail -c 1 "$file")" ]]; then
    printf '\n' >>"$file"
  fi
  seq="$(complete_events "$dir" | jq -s 'map(.seq) | max // 0')"
  jq -cn --argjson seq "$((seq + 1))" --arg reason "$3" --arg msg "${4:-}" \
    '{seq: $seq, type: "closed", reason: $reason}
      + if $msg == "" then {} else {message: $msg} end' >>"$file"
}

# remove_stale_sessions : drop session dirs older than a day whose viewer is
# gone. Windows without --timeout may live long, so a live pid is kept.
remove_stale_sessions() {
  local dir
  while IFS= read -r dir; do
    viewer_alive "$dir" "$(session_pid "$dir")" || rm -rf "$dir"
  done < <(find "$TMP_ROOT" -maxdepth 1 -type d -name 'html-popup.*' \
    -mtime +0 2>/dev/null)
}

# startup_failed <code> : report a viewer that ended before ready, then exit.
startup_failed() {
  printf 'html-popup: viewer exited before the page was ready; log:\n' >&2
  tail -n 5 "$SESSION_DIR/viewer.log" >&2 || true
  exit "$1"
}

# start_session <page> [opts...] : validate, build, start a detached viewer
# and wait until the page is ready; sets SESSION_DIR. If the window closed
# before that without an error (e.g. an early answer), sets EARLY_CLOSE=1.
start_session() {
  local page="" data="" bin pid closed
  local -a viewer_args=()
  EARLY_CLOSE=0
  while (($# > 0)); do
    case "$1" in
      --data)
        need_value "$@"
        data="$2"
        ;;
      --title) need_value "$@" ;;
      --size)
        need_value "$@"
        [[ "$2" =~ ^[1-9][0-9]*x[1-9][0-9]*$ ]] || die "bad --size: $2 (WxH)"
        ;;
      --timeout)
        need_value "$@"
        [[ "$2" =~ ^[0-9]*\.?[0-9]+$ && "$2" =~ [1-9] ]] ||
          die "bad --timeout: $2 (seconds)"
        ;;
      -*) die "unknown option: $1" ;;
      *)
        [[ -z "$page" ]] || die "only one PAGE allowed"
        page="$1"
        shift
        continue
        ;;
    esac
    viewer_args+=("$1" "$2")
    shift 2
  done
  [[ -n "$page" ]] || die "missing PAGE"
  require_jq

  remove_stale_sessions

  # A detached viewer cannot report errors to the caller, so check first.
  [[ -f "$page" && -r "$page" ]] ||
    die "page not found or not readable: $page" 3
  if [[ -n "$data" ]]; then
    [[ -f "$data" && -r "$data" ]] ||
      die "data not found or not readable: $data" 3
    jq empty "$data" >/dev/null 2>&1 || die "data is not valid JSON: $data" 3
  fi
  if [[ -n "${HTML_POPUP_TEST_SCRIPT:-}" ]]; then
    viewer_args+=(--test-script "$HTML_POPUP_TEST_SCRIPT")
  fi

  bin="$(build_viewer)" || exit 2
  SESSION_DIR="$(mktemp -d "$TMP_ROOT/html-popup.XXXXXX")"

  # Double fork: the subshell exits at once, so the viewer is reparented to
  # launchd and a caller that kills our process tree cannot reach it.
  (
    "$bin" "$page" --session "$SESSION_DIR" \
      "${viewer_args[@]+"${viewer_args[@]}"}" \
      </dev/null >>"$SESSION_DIR/viewer.log" 2>&1 &
    printf '%s\n' "$!" >"$SESSION_DIR/pid"
  )
  pid="$(session_pid "$SESSION_DIR")"

  deadline_start "$READY_WAIT"
  until has_event "$SESSION_DIR" ready; do
    closed="$(first_event "$SESSION_DIR" closed)"
    if [[ -n "$closed" ]]; then
      [[ "$(jq -r .reason <<<"$closed")" == error ]] && startup_failed 3
      EARLY_CLOSE=1
      return 0
    fi
    # Plain liveness: until exec, our fresh child is still a bash subshell.
    if ! pid_alive "$pid"; then
      has_event "$SESSION_DIR" ready closed || startup_failed 5
      continue
    fi
    if deadline_passed; then
      terminate_viewer "$SESSION_DIR" "$pid" error \
        "page not ready after ${READY_WAIT}s"
      die "page not ready after ${READY_WAIT}s; see $SESSION_DIR/viewer.log" 3
    fi
    sleep "$POLL"
  done
}

cmd_show() {
  start_session "$@"
  ((EARLY_CLOSE == 0)) ||
    die "window closed before the page was ready: $SESSION_DIR" 1
  printf '%s\n' "$SESSION_DIR"
}

# wait_answer <dir> <wait> : print the answer and exit per the ask contract.
wait_answer() {
  local dir="$1" event type pid message
  pid="$(session_pid "$dir")"
  deadline_start "$2"
  while :; do
    event="$(first_event "$dir" answer closed)"
    if [[ -n "$event" ]]; then
      type="$(jq -r .type <<<"$event")"
      if [[ "$type" == answer ]]; then
        jq -c .data <<<"$event"
        exit 0
      fi
      case "$(jq -r .reason <<<"$event")" in
        timeout) die "window timed out without an answer" 1 ;;
        error)
          message="$(jq -r '.message // ""' <<<"$event")"
          die "window closed with an error: $message" 3
          ;;
        *) die "window closed without an answer" 1 ;;
      esac
    fi
    if ! viewer_alive "$dir" "$pid"; then
      has_event "$dir" answer closed && continue
      die "viewer died without a closed event; see $dir/viewer.log" 5
    fi
    if deadline_passed; then
      printf 'html-popup: still waiting; resume with: %s\n' \
        "html-popup.sh ask --resume $dir" >&2
      exit 4
    fi
    sleep "$POLL"
  done
}

cmd_ask() {
  local dir="" wait="$DEFAULT_WAIT" resume=0
  local -a args=()
  while (($# > 0)); do
    case "$1" in
      --resume)
        need_value "$@"
        dir="$2"
        resume=1
        ;;
      --wait)
        need_value "$@"
        wait="$(parse_wait "$2")"
        ;;
      -*)
        # start_session validates window options; pass each with its value.
        args+=("${@:1:2}")
        shift "$(($# >= 2 ? 2 : 1))"
        continue
        ;;
      *)
        args+=("$1")
        shift
        continue
        ;;
    esac
    shift 2
  done
  if ((resume == 1)); then
    ((${#args[@]} == 0)) || die "unknown argument: ${args[0]}"
    require_jq
    require_session "$dir"
  else
    start_session "${args[@]+"${args[@]}"}"
    dir="$SESSION_DIR"
  fi
  # --wait counts from the start of this call, so a first-use compile and the
  # page load cannot push it past the Bash tool's timeout.
  wait_answer "$dir" "$((wait > SECONDS ? wait - SECONDS : 0))"
}

# lock_inbound <dir> <pid> : take the session's send lock for the calling
# writer process and set INBOUND_LOCK; returns 1 if the viewer dies first.
# Pipe writes over PIPE_BUF are not atomic, so concurrent senders would
# interleave long lines. Locks are symlinks in.lock.N to the owner's pid and
# the highest N counts; N is free once in.lock.N.done exists or its owner
# died. No lock file is ever removed, so names are never reused and takers
# race on ln -s of N+1 with exactly one winner.
lock_inbound() {
  local dir="$1" me top n link
  # $BASHPID needs bash 4; the background writer must name itself.
  me="$(exec sh -c 'printf %s "$PPID"')"
  while :; do
    top=0
    for link in "$dir"/in.lock.*; do
      n="${link##*.}"
      if [[ "$n" =~ ^[1-9][0-9]*$ ]] && ((n > top)); then
        top="$n"
      fi
    done
    if ((top > 0)) && [[ ! -e "$dir/in.lock.$top.done" ]] &&
      pid_alive "$(readlink "$dir/in.lock.$top")"; then
      viewer_alive "$dir" "$2" || return 1
      sleep "$FIFO_POLL"
      continue
    fi
    INBOUND_LOCK="$dir/in.lock.$((top + 1))"
    ln -s "$me" "$INBOUND_LOCK" 2>/dev/null && return 0
  done
}

# send_line <dir> <pid> <line> : the background writer. It owns the send
# lock while it may write, so a killed wrapper cannot free the lock early.
send_line() {
  local rc=0
  lock_inbound "$1" "$2" || exit 1
  # Write-only, with the read-write open dropped once it served to open
  # without blocking: if the viewer dies, the write fails instead of hanging.
  exec 4<>"$1/in"
  exec 3>"$1/in" 4<&-
  # The leading newline ends any partial line a killed writer left behind,
  # so the viewer drops that fragment instead of this message.
  printf '\n%s\n' "$3" >&3 || rc=1
  : >"$INBOUND_LOCK.done"
  exit "$rc"
}

# write_inbound <dir> <line> [limit] : write one line to the session FIFO.
# A write larger than the pipe buffer blocks until the viewer reads it.
# Returns 1 if the viewer dies meanwhile, 2 when the optional limit
# (seconds) passes first.
write_inbound() {
  local dir="$1" line="$2" limit="${3:-}" pid writer rc=0
  pid="$(session_pid "$dir")"
  [[ -z "$limit" ]] || deadline_start "$limit"
  send_line "$dir" "$pid" "$line" &
  writer=$!
  while pid_alive "$writer"; do
    if ! viewer_alive "$dir" "$pid"; then
      rc=1
    elif [[ -n "$limit" ]] && deadline_passed; then
      rc=2
    else
      sleep "$FIFO_POLL"
      continue
    fi
    kill "$writer" 2>/dev/null || true
    break
  done
  if ((rc == 0)); then
    wait "$writer" || rc=1
  else
    wait "$writer" 2>/dev/null || true
  fi
  return "$rc"
}

# session_over <dir> : true when the window has closed or its viewer is gone.
session_over() {
  has_event "$1" closed || ! viewer_alive "$1" "$(session_pid "$1")"
}

cmd_live_send() {
  (($# == 2)) || die "usage: html-popup.sh live send DIR JSON"
  local dir="$1" line
  require_jq
  require_session "$dir"
  # Exactly one JSON value, compacted onto one line for the FIFO protocol.
  line="$(printf '%s' "$2" |
    jq -cs 'if length == 1 then .[0] else error("one value expected") end' \
      2>/dev/null)" || die "not a single JSON value: $2"
  session_over "$dir" && die "window is closed: $dir" 1
  [[ -p "$dir/in" ]] || die "session has no inbound FIFO: $dir" 1
  write_inbound "$dir" "$line" || die "window closed while sending: $dir" 1
}

cmd_live_wait() {
  local dir="${1:-}" wait="$DEFAULT_WAIT" cursor batch last pid
  (($# > 0)) && shift
  while (($# > 0)); do
    case "$1" in
      --wait)
        need_value "$@"
        wait="$(parse_wait "$2")"
        shift 2
        ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  require_jq
  require_session "$dir"
  pid="$(session_pid "$dir")"
  cursor="$(tr -d '[:space:]' 2>/dev/null <"$dir/cursor" || true)"
  [[ "$cursor" =~ ^[0-9]+$ ]] || cursor=0

  deadline_start "$wait"
  while :; do
    batch="$(new_events "$dir" "$cursor")"
    if [[ -n "$batch" ]]; then
      last="$(jq -s 'map(.seq) | max' <<<"$batch")"
      printf '%s\n' "$last" >"$dir/cursor.tmp.$$"
      mv -f "$dir/cursor.tmp.$$" "$dir/cursor"
      printf '%s\n' "$batch"
      if jq -e -n 'any(inputs; .type == "closed")' <<<"$batch" >/dev/null; then
        exit 1
      fi
      exit 0
    fi
    if has_event "$dir" closed || ! viewer_alive "$dir" "$pid"; then
      # The last events may have landed after the batch was read.
      [[ -n "$(new_events "$dir" "$cursor")" ]] && continue
      has_event "$dir" closed && exit 1
      die "viewer died without a closed event; see $dir/viewer.log" 5
    fi
    deadline_passed && exit 4
    sleep "$POLL"
  done
}

cmd_live_close() {
  (($# == 1)) || die "usage: html-popup.sh live close DIR"
  local dir="$1" pid rc=0
  require_jq
  require_session "$dir"
  session_over "$dir" && return 0
  pid="$(session_pid "$dir")"
  # Bounded: a viewer that stopped reading must not hang close.
  write_inbound "$dir" '{"htmlPopup":"close"}' "$CLOSE_WAIT" || rc=$?
  ((rc == 1)) && return 0
  deadline_start "$CLOSE_WAIT"
  until session_over "$dir"; do
    if ((rc == 2)) || deadline_passed; then
      printf 'html-popup: window did not close in %ss; terminating it\n' \
        "$CLOSE_WAIT" >&2
      terminate_viewer "$dir" "$pid" agent
      return 0
    fi
    sleep "$POLL"
  done
}

cmd_live() {
  local sub="${1:-}"
  (($# > 0)) && shift
  case "$sub" in
    start) cmd_show "$@" ;;
    send) cmd_live_send "$@" ;;
    wait) cmd_live_wait "$@" ;;
    close) cmd_live_close "$@" ;;
    *)
      printf 'html-popup: unknown live command: %s\n' "$sub" >&2
      usage
      exit 2
      ;;
  esac
}

main() {
  local cmd="${1:-}"
  (($# > 0)) && shift
  case "$cmd" in
    check) cmd_check "$@" ;;
    build) build_viewer "$@" ;;
    show) cmd_show "$@" ;;
    ask) cmd_ask "$@" ;;
    live) cmd_live "$@" ;;
    -h | --help | help) usage; exit 0 ;;
    "") usage; exit 2 ;;
    *) printf 'html-popup: unknown command: %s\n' "$cmd" >&2; usage; exit 2 ;;
  esac
}

main "$@"
