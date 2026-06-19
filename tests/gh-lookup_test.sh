#!/usr/bin/env bash
# Unit tests for the gh-lookup plugin. Pure bash, no framework.
# Run: tests/gh-lookup_test.sh  (exits non-zero on first failure)
#
# No network, no auth, no real gh: every test points GH_BIN at the fake gh
# stub (tests/fixtures/fake-gh.sh), which serves canned reference/--help
# output from synthetic fixtures.
set -euo pipefail

# Locate fixtures relative to this tests/ directory, regardless of cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURE_DIR="$SCRIPT_DIR/fixtures"
FAKE_GH="$FIXTURE_DIR/fake-gh.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GH_LOOKUP="$REPO_ROOT/plugins/gh-lookup/scripts/gh-lookup.sh"

PASS_COUNT=0

# assert <description> <command...> : runs command, fails the suite if it exits
# non-zero. The command is evaluated as-is so callers can pass test expressions.
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

# --- Tests: test harness (fake gh + fixtures) --------------------------------

test_harness() {
  local out

  assert "fake gh stub exists" test -f "$FAKE_GH"
  assert "fake gh stub is executable" test -x "$FAKE_GH"
  assert "reference fixture exists" test -f "$FIXTURE_DIR/gh-reference-sample.txt"

  # `reference` dumps the synthetic manual; it must carry the header shape the
  # discover parser relies on (### gh <cmd> ... + a following description line).
  out="$(GH_BIN="$FAKE_GH" "$FAKE_GH" reference)"
  assert "fake gh reference emits command headers" \
    contains "### gh pr merge" "$out"
  assert "fake gh reference emits descriptions" \
    contains "Merge a pull request" "$out"

  # `<cmd words> --help` is keyed by the command words joined with hyphens.
  out="$(GH_BIN="$FAKE_GH" "$FAKE_GH" pr merge --help)"
  assert "fake gh serves multi-word help" contains "USAGE" "$out"
  assert "fake gh help matches the command" \
    contains "gh pr merge" "$out"
  out="$(GH_BIN="$FAKE_GH" "$FAKE_GH" issue create --help)"
  assert "fake gh serves a second help fixture" \
    contains "Create a new issue" "$out"

  # Unknown help target and unsupported invocations fail loudly.
  assert "fake gh fails on unknown help fixture" bash -c \
    "! '$FAKE_GH' no such cmd --help 2>/dev/null"
  assert "fake gh fails on unsupported invocation" bash -c \
    "! '$FAKE_GH' status 2>/dev/null"
}

# --- Tests: discover mode ----------------------------------------------------

test_discover() {
  local out rc

  assert "gh-lookup script exists" test -f "$GH_LOOKUP"
  assert "gh-lookup script is executable" test -x "$GH_LOOKUP"

  # Single keyword → one compact `gh <cmd> — <description>` hit.
  out="$(GH_BIN="$FAKE_GH" "$GH_LOOKUP" discover merge)"
  assert_eq "discover single keyword → one hit" \
    "gh pr merge — Merge a pull request" "$out"

  # Keyword shared by several commands → multiple hits.
  out="$(GH_BIN="$FAKE_GH" "$GH_LOOKUP" discover create)"
  assert "discover lists gh pr create" \
    contains "gh pr create — Create a pull request" "$out"
  assert "discover lists gh issue create" \
    contains "gh issue create — Create a new issue" "$out"

  # Case-insensitive match.
  out="$(GH_BIN="$FAKE_GH" "$GH_LOOKUP" discover MERGE)"
  assert "discover is case-insensitive" \
    contains "gh pr merge — Merge a pull request" "$out"

  # Multi-word query: all words must be present (AND over cmd + description).
  out="$(GH_BIN="$FAKE_GH" "$GH_LOOKUP" discover merge a pull request)"
  assert_eq "discover multi-word query → single hit" \
    "gh pr merge — Merge a pull request" "$out"

  # No match → non-zero exit (1) and nothing on stdout.
  set +e
  out="$(GH_BIN="$FAKE_GH" "$GH_LOOKUP" discover zzznotacommand 2>/dev/null)"
  rc=$?
  set -e
  assert_eq "discover no-match exits 1" "1" "$rc"
  assert_eq "discover no-match prints nothing" "" "$out"
}

# --- Runner ------------------------------------------------------------------

main() {
  test_harness
  test_discover

  printf '\nAll %d assertions passed.\n' "$PASS_COUNT"
}

main "$@"
