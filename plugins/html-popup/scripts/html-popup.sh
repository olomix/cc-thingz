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
# Exit codes: 0 ok / answered; 1 window closed (no answer, session over);
# 2 usage error, missing dependency, build failure; 3 page or data invalid,
# page failed to load; 4 wait expired (window still open) or window
# --timeout reached; 5 viewer died without a closed event.
#
# Environment:
#   CLAUDE_PLUGIN_DATA      cache dir (default: ~/Library/Caches/html-popup)
#   HTML_POPUP_SWIFTC       compiler to use instead of swiftc (tests use a fake)
#   HTML_POPUP_TEST_SCRIPT  JS file run after page load; headless test mode
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VIEWER_SRC="$PLUGIN_ROOT/viewer/html-popup-viewer.swift"
CACHE_DIR="${CLAUDE_PLUGIN_DATA:-$HOME/Library/Caches/html-popup}"
SWIFTC="${HTML_POPUP_SWIFTC:-swiftc}"

usage() {
  cat >&2 <<'EOF'
usage: html-popup.sh <command> [args...]
  check                          verify macOS, swiftc, jq, cache, GUI session
  build                          build the viewer if needed, print its path
  show PAGE [opts]               open a window, return at once, print DIR
  ask PAGE [opts] [--wait SEC]   wait for the answer, print it as JSON
  ask --resume DIR [--wait SEC]  keep waiting on an earlier ask
  live start PAGE [opts]         open, wait until ready, print DIR
  live send DIR JSON             deliver one JSON value to the page
  live wait DIR [--wait SEC]     print new events as JSON lines
  live close DIR                 close the window (ok if already gone)
opts: --data FILE  --title TEXT  --size WxH  --timeout SEC (window lifetime)
--wait SEC: how long this call blocks (default 100)
EOF
}

die() {
  printf 'html-popup: %s\n' "$1" >&2
  exit "${2:-2}"
}

# missing_* print one message per missing piece and return non-zero.
missing_macos() {
  [[ "$(uname -s)" == "Darwin" ]] && return 1
  printf 'html-popup: macOS is required\n' >&2
}

# /usr/bin/swiftc is a shim that exists even without the Command Line Tools,
# so ask xcrun whether a real compiler is installed.
missing_compiler() {
  if [[ -n "${HTML_POPUP_SWIFTC:-}" ]]; then
    command -v "$SWIFTC" >/dev/null 2>&1 && return 1
    printf 'html-popup: HTML_POPUP_SWIFTC not found: %s\n' "$SWIFTC" >&2
    return 0
  fi
  xcrun --find swiftc >/dev/null 2>&1 && return 1
  printf 'html-popup: swiftc not found; install the Xcode Command Line Tools: xcode-select --install\n' >&2
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
  printf 'html-popup: no GUI login session (launchctl managername is not Aqua)\n' >&2
}

cmd_check() {
  local failed=0
  missing_macos && failed=1
  missing_compiler && failed=1
  missing_jq && failed=1
  missing_cache_dir && failed=1
  missing_gui && failed=1
  ((failed == 0)) || exit 2
  printf 'html-popup: all checks passed\n'
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
  local failed=0 bin tmp
  missing_macos && failed=1
  missing_compiler && failed=1
  missing_cache_dir && failed=1
  ((failed == 0)) || exit 2
  [[ -r "$VIEWER_SRC" ]] || die "viewer source not found: $VIEWER_SRC"

  bin="$(viewer_path)"
  if [[ ! -x "$bin" ]]; then
    # A per-process temp name plus an atomic mv keeps concurrent first uses
    # from running a half-written binary.
    tmp="$bin.tmp.$$"
    if ! "$SWIFTC" -O -o "$tmp" "$VIEWER_SRC" >&2; then
      rm -f "$tmp"
      die "failed to compile the viewer"
    fi
    mv -f "$tmp" "$bin"
  fi
  printf '%s\n' "$bin"
}

# --- Sessions -------------------------------------------------------------------

DEFAULT_WAIT=100
READY_WAIT=10
CLOSE_WAIT=5
POLL=0.2

TMP_ROOT="${TMPDIR:-/tmp}"
TMP_ROOT="${TMP_ROOT%/}"

require_jq() {
  missing_jq && exit 2
  return 0
}

# parse_wait <value> : validate a --wait value (whole seconds).
parse_wait() {
  [[ "$1" =~ ^[0-9]+$ ]] || die "bad --wait: $1 (whole seconds)"
  printf '%s' "$1"
}

pid_alive() {
  [[ -n "$1" ]] && kill -0 "$1" 2>/dev/null
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

# has_event <dir> <type> : true when a complete event of that type exists.
has_event() {
  complete_events "$1" | jq -e --arg t "$2" -n 'any(inputs; .type == $t)' \
    >/dev/null 2>&1
}

# Wall-clock deadline in whole seconds plus a sleep budget: SECONDS truncates,
# so either alone could end a short wait early or let a long one drift.
deadline_start() {
  WAIT_START=$SECONDS
  WAIT_TRIES=$(($1 * 5))
  WAIT_SECS=$1
}

deadline_passed() {
  ((WAIT_TRIES-- <= 0)) || ((SECONDS - WAIT_START > WAIT_SECS))
}

# remove_stale_sessions : drop session dirs older than a day whose viewer is
# gone. Windows without --timeout may live long, so a live pid is kept.
remove_stale_sessions() {
  local dir
  while IFS= read -r dir; do
    pid_alive "$(session_pid "$dir")" || rm -rf "$dir"
  done < <(find "$TMP_ROOT" -maxdepth 1 -type d -name 'html-popup.*' \
    -mtime +0 2>/dev/null)
}

# start_session <page> [opts...] : validate, build, start a detached viewer,
# wait for its ready event and set SESSION_DIR. Sets ASK_WAIT from --wait
# when ALLOW_WAIT=1.
start_session() {
  local page="" data="" bin pid rc arg
  local -a viewer_args=()
  while (($# > 0)); do
    arg="$1"
    case "$arg" in
      --data | --title | --size | --timeout | --wait)
        (($# >= 2)) || die "missing value for $arg"
        case "$arg" in
          --data) data="$2" ;;
          --wait)
            [[ "${ALLOW_WAIT:-0}" == 1 ]] || die "unknown option: $arg"
            ASK_WAIT="$(parse_wait "$2")"
            ;;
        esac
        [[ "$arg" == --wait ]] || viewer_args+=("$arg" "$2")
        shift 2
        ;;
      -*) die "unknown option: $arg" ;;
      *)
        [[ -z "$page" ]] || die "only one PAGE allowed"
        page="$arg"
        shift
        ;;
    esac
  done
  [[ -n "$page" ]] || die "missing PAGE"
  require_jq

  remove_stale_sessions

  # A detached viewer cannot report errors to the caller, so check first.
  [[ -f "$page" && -r "$page" ]] || die "page not found or not readable: $page" 3
  if [[ -n "$data" ]]; then
    [[ -f "$data" && -r "$data" ]] || die "data not found or not readable: $data" 3
    jq empty "$data" >/dev/null 2>&1 || die "data is not valid JSON: $data" 3
  fi
  if [[ -n "${HTML_POPUP_TEST_SCRIPT:-}" ]]; then
    viewer_args+=(--test-script "$HTML_POPUP_TEST_SCRIPT")
  fi

  bin="$(build_viewer)" || exit 2
  SESSION_DIR="$(mktemp -d "$TMP_ROOT/html-popup.XXXXXX")"

  "$bin" "$page" --session "$SESSION_DIR" "${viewer_args[@]+"${viewer_args[@]}"}" \
    </dev/null >>"$SESSION_DIR/viewer.log" 2>&1 &
  pid=$!
  # The viewer writes the same pid itself; writing it now closes the window
  # in which a fast follow-up call would find no pid file.
  printf '%s\n' "$pid" >"$SESSION_DIR/pid"

  deadline_start "$READY_WAIT"
  while ! has_event "$SESSION_DIR" ready; do
    if ! pid_alive "$pid"; then
      has_event "$SESSION_DIR" ready && break
      # Still our child, so wait reports its exit code.
      rc=0
      wait "$pid" || rc=$?
      printf 'html-popup: viewer exited before the page was ready; log:\n' >&2
      tail -n 5 "$SESSION_DIR/viewer.log" >&2 || true
      case "$rc" in
        0) exit 1 ;;
        2 | 3 | 4) exit "$rc" ;;
        *) exit 5 ;;
      esac
    fi
    if deadline_passed; then
      kill "$pid" 2>/dev/null || true
      die "page not ready after ${READY_WAIT}s; see $SESSION_DIR/viewer.log" 3
    fi
    sleep "$POLL"
  done
  disown "$pid" 2>/dev/null || true
}

cmd_show() {
  start_session "$@"
  printf '%s\n' "$SESSION_DIR"
}

# wait_answer <dir> <wait> : print the answer and exit per the ask contract.
wait_answer() {
  local dir="$1" event type pid
  pid="$(session_pid "$dir")"
  deadline_start "$2"
  while :; do
    event="$(complete_events "$dir" |
      jq -c 'select(.type == "answer" or .type == "closed")' 2>/dev/null |
      head -n 1)"
    if [[ -n "$event" ]]; then
      type="$(jq -r .type <<<"$event")"
      if [[ "$type" == answer ]]; then
        jq -c .data <<<"$event"
        exit 0
      fi
      case "$(jq -r .reason <<<"$event")" in
        timeout) die "window timed out without an answer" 4 ;;
        error) die "window closed with an error: $(jq -r '.message // ""' <<<"$event")" 3 ;;
        *) die "window closed without an answer" 1 ;;
      esac
    fi
    if ! pid_alive "$pid"; then
      # Recheck: the viewer may have written its last events just now.
      if has_event "$dir" closed || has_event "$dir" answer; then
        continue
      fi
      die "viewer died without a closed event; see $dir/viewer.log" 5
    fi
    if deadline_passed; then
      printf 'html-popup: still waiting; resume with: html-popup.sh ask --resume %s\n' \
        "$dir" >&2
      exit 4
    fi
    sleep "$POLL"
  done
}

cmd_ask() {
  local dir=""
  ASK_WAIT="$DEFAULT_WAIT"
  if [[ "${1:-}" == --resume ]]; then
    (($# >= 2)) || die "missing DIR for --resume"
    dir="$2"
    shift 2
    while (($# > 0)); do
      case "$1" in
        --wait)
          (($# >= 2)) || die "missing value for --wait"
          ASK_WAIT="$(parse_wait "$2")"
          shift 2
          ;;
        *) die "unknown argument: $1" ;;
      esac
    done
    require_jq
    require_session "$dir"
  else
    ALLOW_WAIT=1 start_session "$@"
    dir="$SESSION_DIR"
  fi
  wait_answer "$dir" "$ASK_WAIT"
}

# write_inbound <dir> <line> : write one line to the session FIFO. The
# read-write open never blocks, but a write larger than the pipe buffer does
# until the viewer reads it, so give up if the viewer dies meanwhile.
write_inbound() {
  local dir="$1" line="$2" pid writer rc=0
  pid="$(session_pid "$dir")"
  (
    exec 3<>"$dir/in"
    printf '%s\n' "$line" >&3
  ) &
  writer=$!
  while pid_alive "$writer"; do
    if ! pid_alive "$pid"; then
      kill "$writer" 2>/dev/null || true
      wait "$writer" 2>/dev/null || true
      return 1
    fi
    sleep 0.05
  done
  wait "$writer" || rc=$?
  return "$rc"
}

# session_over <dir> : true when the window has closed or its viewer is gone.
session_over() {
  has_event "$1" closed || ! pid_alive "$(session_pid "$1")"
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
        (($# >= 2)) || die "missing value for --wait"
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
    batch="$(complete_events "$dir" |
      jq -c --argjson c "$cursor" 'select(.seq > $c)' 2>/dev/null || true)"
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
    has_event "$dir" closed && exit 1
    if ! pid_alive "$pid"; then
      # Recheck: the viewer may have written its last events just now.
      batch="$(complete_events "$dir" |
        jq -c --argjson c "$cursor" 'select(.seq > $c)' 2>/dev/null || true)"
      [[ -n "$batch" ]] && continue
      die "viewer died without a closed event; see $dir/viewer.log" 5
    fi
    deadline_passed && exit 4
    sleep "$POLL"
  done
}

cmd_live_close() {
  (($# == 1)) || die "usage: html-popup.sh live close DIR"
  local dir="$1" pid
  require_jq
  require_session "$dir"
  session_over "$dir" && return 0
  pid="$(session_pid "$dir")"
  write_inbound "$dir" '{"htmlPopup":"close"}' || return 0
  deadline_start "$CLOSE_WAIT"
  until session_over "$dir"; do
    if deadline_passed; then
      printf 'html-popup: window did not close in %ss; terminating it\n' \
        "$CLOSE_WAIT" >&2
      kill "$pid" 2>/dev/null || true
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
    *) printf 'html-popup: unknown live command: %s\n' "$sub" >&2; usage; exit 2 ;;
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
