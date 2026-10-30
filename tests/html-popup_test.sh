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
  local cache bin rc=0
  new_tmpdir cache
  run_capture env CLAUDE_PLUGIN_DATA="$cache" \
    "$PLUGIN_DIR/scripts/html-popup.sh" build
  assert_eq "real build exits 0" "0" "$RC"
  bin="$OUT"
  assert "real build produces an executable" test -x "$bin"
  "$bin" >/dev/null 2>&1 || rc=$?
  assert_eq "viewer without arguments exits 2" "2" "$rc"
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

  printf '\nAll %d assertions passed (%d skipped).\n' "$PASS_COUNT" "$SKIP_COUNT"
}

main "$@"
