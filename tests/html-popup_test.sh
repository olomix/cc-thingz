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

# --- Runner --------------------------------------------------------------------

main() {
  test_manifest
  test_harness

  printf '\nAll %d assertions passed (%d skipped).\n' "$PASS_COUNT" "$SKIP_COUNT"
}

main "$@"
