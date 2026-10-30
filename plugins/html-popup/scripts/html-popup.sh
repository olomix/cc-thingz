#!/usr/bin/env bash
# html-popup.sh — show an HTML page in a native macOS window and exchange
# data with it. Builds and caches the Swift viewer on first use.
#
# Usage: html-popup.sh <command> [args...]
#   check   verify macOS, Swift compiler, jq, writable cache and GUI session
#   build   build the viewer if needed and print its path
#
# Exit codes: 0 ok, 2 usage error / missing dependency / build failure.
#
# Environment:
#   CLAUDE_PLUGIN_DATA  cache dir (default: ~/Library/Caches/html-popup)
#   HTML_POPUP_SWIFTC   compiler to use instead of swiftc (tests use a fake)
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VIEWER_SRC="$PLUGIN_ROOT/viewer/html-popup-viewer.swift"
CACHE_DIR="${CLAUDE_PLUGIN_DATA:-$HOME/Library/Caches/html-popup}"
SWIFTC="${HTML_POPUP_SWIFTC:-swiftc}"

usage() {
  cat >&2 <<'EOF'
usage: html-popup.sh <command> [args...]
  check   verify macOS, Swift compiler, jq, writable cache and GUI session
  build   build the viewer if needed and print its path
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

main() {
  local cmd="${1:-}"
  (($# > 0)) && shift
  case "$cmd" in
    check) cmd_check "$@" ;;
    build) build_viewer "$@" ;;
    -h | --help | help) usage; exit 0 ;;
    "") usage; exit 2 ;;
    *) printf 'html-popup: unknown command: %s\n' "$cmd" >&2; usage; exit 2 ;;
  esac
}

main "$@"
