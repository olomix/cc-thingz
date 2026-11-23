#!/usr/bin/env bash
# Unit tests for the session-park plugin. Pure bash, no framework.
# Run: tests/session-park_test.sh  (exits non-zero on first failure)
#
# Every test works in a temp dir: notes are fixture files, and transcripts
# live under a fake CLAUDE_CONFIG_DIR, so the real notes store and the real
# ~/.claude are never read or written.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_DIR="$REPO_ROOT/plugins/session-park"
SESSION_PARK="$PLUGIN_DIR/scripts/session-park.sh"
MARKETPLACE="$REPO_ROOT/.claude-plugin/marketplace.json"

SESSION_ID="11111111-2222-3333-4444-555555555555"

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

# frontmatter <file> : echo the YAML frontmatter block (between the first two
# "---" fences). Empty when the file has no frontmatter.
frontmatter() {
  awk 'NR==1 && $0!="---"{exit} NR==1{next} $0=="---"{exit} {print}' "$1"
}

# park <args...> : run the script with a sandboxed environment. $SANDBOX holds
# the fake Claude config dir and the fixture notes store.
park() {
  env -u CLAUDE_CODE_SESSION_ID \
    CLAUDE_CONFIG_DIR="$SANDBOX/claude" \
    FSNOTES_DIR="$SANDBOX/notes" \
    "$SESSION_PARK" "$@"
}

# make_sandbox : build $SANDBOX with a transcript for $SESSION_ID that started
# in /work/project, and a notes store holding one list note.
make_sandbox() {
  SANDBOX="$(mktemp -d)"
  mkdir -p "$SANDBOX/claude/projects/-work-project" "$SANDBOX/notes"
  {
    printf '{"type":"summary"}\n'
    printf '{"type":"user","cwd":"/work/project"}\n'
    printf '{"type":"user","cwd":"/work/project/sub"}\n'
    printf '{"type":"user","cwd":"/torn'
  } > "$SANDBOX/claude/projects/-work-project/$SESSION_ID.jsonl"
  {
    printf '# Sessions\n\n'
    printf '## older work\n```bash\ncd /work/older\n'
    printf 'claude --resume aaaaaaaa-0000-0000-0000-000000000000\n```\n'
  } > "$SANDBOX/notes/Sessions.markdown"
}

# --- Tests: manifests and skill ---------------------------------------------

test_manifests() {
  local f="$PLUGIN_DIR/.claude-plugin/plugin.json"
  assert "plugin.json parses" jq empty "$f"
  assert_eq "plugin name" "session-park" "$(jq -r .name "$f")"
  assert "plugin has a version" bash -c \
    "[[ \"\$(jq -r .version '$f')\" != null ]]"

  assert_eq "marketplace lists session-park once" "1" \
    "$(jq '[.plugins[] | select(.name == "session-park")] | length' \
      "$MARKETPLACE")"
  assert_eq "marketplace source points at the plugin" \
    "./plugins/session-park" \
    "$(jq -r '.plugins[] | select(.name == "session-park") | .source' \
      "$MARKETPLACE")"
}

test_skill() {
  local f="$PLUGIN_DIR/skills/session-park/SKILL.md"
  assert "skill exists" test -f "$f"
  assert_eq "skill name is session-park" "session-park" \
    "$(frontmatter "$f" | awk -F': *' '/^name:/{print $2}')"
  assert "skill has a description" bash -c \
    "grep -q '^description:' <(awk 'NR>1 && /^---\$/{exit} {print}' '$f')"
  assert "skill mentions the script" grep -q 'session-park.sh' "$f"
  assert "skill delegates the note lookup to fsnotes" \
    grep -q 'fsnotes:fsnotes' "$f"
  assert "script is executable" test -x "$SESSION_PARK"
}

# --- Tests: info --------------------------------------------------------------

test_info() {
  local out err rc
  make_sandbox

  out="$(park info --session-id "$SESSION_ID")"
  assert_eq "info prints the ID and the transcript start dir" \
    "id=$SESSION_ID"$'\n'"dir=/work/project" "$out"

  out="$(CLAUDE_CODE_SESSION_ID="$SESSION_ID" \
    CLAUDE_CONFIG_DIR="$SANDBOX/claude" "$SESSION_PARK" info)"
  assert "info reads the ID from CLAUDE_CODE_SESSION_ID" \
    contains "id=$SESSION_ID" "$out"

  out="$(park info --session-id "$SESSION_ID" --dir /elsewhere)"
  assert "--dir overrides the transcript" contains "dir=/elsewhere" "$out"

  out="$(cd "$SANDBOX" && park info --session-id unknown-id 2>/dev/null)"
  assert "an unknown session falls back to the current directory" \
    contains "dir=$(cd "$SANDBOX" && pwd)" "$out"

  set +e
  err="$(park info 2>&1 >/dev/null)"
  rc=$?
  set -e
  assert_eq "missing session ID exits 1" "1" "$rc"
  assert "missing session ID names the variable" \
    contains "CLAUDE_CODE_SESSION_ID" "$err"

  set +e
  park info --session-id 'bad id' >/dev/null 2>&1
  rc=$?
  set -e
  assert_eq "invalid session ID exits 1" "1" "$rc"

  rm -rf "$SANDBOX"
}

# --- Tests: add ---------------------------------------------------------------

test_add() {
  local out note expected
  make_sandbox
  note="$SANDBOX/notes/Sessions.markdown"

  out="$(park add --session-id "$SESSION_ID" "$note" 'new work')"
  assert_eq "add reports the parked title" "parked: new work" "$out"

  expected="$(
    printf '# Sessions\n\n'
    printf '## new work\n```bash\ncd /work/project\n'
    printf 'claude --resume %s\n```\n\n' "$SESSION_ID"
    printf '## older work\n```bash\ncd /work/older\n'
    printf 'claude --resume aaaaaaaa-0000-0000-0000-000000000000\n```\n'
  )"
  assert_eq "entry goes below the title, above older entries" \
    "$expected" "$(cat "$note")"

  out="$(park add --session-id "$SESSION_ID" "$note" 'another title')"
  assert_eq "a second add reports the existing heading" \
    "already parked: new work" "$out"
  assert_eq "a second add leaves the note unchanged" \
    "$expected" "$(cat "$note")"

  rm -rf "$SANDBOX"
}

test_add_edge_cases() {
  local out note rc
  make_sandbox
  note="$SANDBOX/notes/Sessions.markdown"

  # An ID that is only a prefix of a parked ID is a different session.
  out="$(park add --session-id aaaaaaaa --dir /p "$note" 'prefix')"
  assert_eq "a prefix of a parked ID is not a match" "parked: prefix" "$out"

  out="$(park add --session-id "$SESSION_ID" Sessions.markdown 'relative')"
  assert_eq "a relative path resolves against the notes store" \
    "parked: relative" "$out"

  out="$(park add --session-id s1 --dir '/with space/dir' "$note" \
    $'  ## messy\n  title  ')"
  assert_eq "the title is cleaned to one line" "parked: messy title" "$out"
  assert "the heading has no extra #" grep -qx '## messy title' "$note"
  assert "a directory with a space is shell-quoted" \
    grep -qxF 'cd /with\ space/dir' "$note"

  printf 'plain first line\n' > "$SANDBOX/notes/untitled.markdown"
  park add --session-id s2 --dir /p "$SANDBOX/notes/untitled.markdown" t \
    >/dev/null
  assert_eq "a note without a title gets the entry at the top" "## t" \
    "$(head -1 "$SANDBOX/notes/untitled.markdown")"
  assert_eq "the old content is kept after a blank line" \
    $'\nplain first line' "$(tail -2 "$SANDBOX/notes/untitled.markdown")"

  printf '# Only a title' > "$SANDBOX/notes/fresh.markdown"
  park add --session-id s3 --dir /p "$SANDBOX/notes/fresh.markdown" t \
    >/dev/null
  assert_eq "a title-only note gets the entry below the title" \
    $'# Only a title\n\n## t\n```bash\ncd /p\nclaude --resume s3\n```' \
    "$(cat "$SANDBOX/notes/fresh.markdown")"

  set +e
  park add --session-id s4 "$SANDBOX/notes/missing.markdown" t \
    >/dev/null 2>&1
  rc=$?
  set -e
  assert_eq "a missing note exits 1" "1" "$rc"

  set +e
  park add --session-id s4 "$note" '   ' >/dev/null 2>&1
  rc=$?
  set -e
  assert_eq "an empty title exits 1" "1" "$rc"

  set +e
  park add --session-id s4 "$note" >/dev/null 2>&1
  rc=$?
  set -e
  assert_eq "a missing title exits 2" "2" "$rc"

  set +e
  park >/dev/null 2>&1
  rc=$?
  set -e
  assert_eq "no command exits 2" "2" "$rc"

  rm -rf "$SANDBOX"
}

# --- Runner -------------------------------------------------------------------

main() {
  test_manifests
  test_skill
  test_info
  test_add
  test_add_edge_cases

  printf '\nAll %d assertions passed.\n' "$PASS_COUNT"
}

main "$@"
