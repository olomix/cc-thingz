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

# version_set <plugin.json> : true when the manifest has a version.
version_set() {
  [[ "$(jq -r .version "$1")" != null ]]
}

# has_description <SKILL.md> : true when the frontmatter has a description.
has_description() {
  frontmatter "$1" | grep -q '^description:'
}

# no_backup_files <dir> : true when the script left no note backup in <dir>.
no_backup_files() {
  local file
  for file in "$1"/session-park-backup.*; do
    [[ -e "$file" ]] && return 1
  done
  return 0
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
  assert "plugin has a version" version_set "$f"

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
  assert "skill has a description" has_description "$f"
  assert "skill mentions the script" grep -q 'session-park.sh' "$f"
  assert "skill delegates the note lookup to fsnotes" \
    grep -q 'fsnotes:fsnotes' "$f"
  # shellcheck disable=SC2016
  assert "skill picks the newest note with the script" \
    grep -qF '"$P" newest' "$f"
  assert "skill says how to write an apostrophe in a path" \
    grep -qF "'Team'\''s sessions.markdown'" "$f"
  assert "skill single-quotes the title" \
    grep -qF "\"\$P\" add '<note-path>' '<title>'" "$f"
  assert "script is executable" test -x "$SESSION_PARK"
}

# --- Tests: info --------------------------------------------------------------

test_info() {
  local out err rc
  make_sandbox

  out="$(park info --session-id "$SESSION_ID")"
  assert_eq "info prints the ID, the start dir and the config dir" \
    "id=$SESSION_ID"$'\n'"dir=/work/project"$'\n'"config_dir=$SANDBOX/claude" \
    "$out"

  out="$(CLAUDE_CODE_SESSION_ID="$SESSION_ID" \
    CLAUDE_CONFIG_DIR="$SANDBOX/claude" "$SESSION_PARK" info)"
  assert "info reads the ID from CLAUDE_CODE_SESSION_ID" \
    contains "id=$SESSION_ID" "$out"

  out="$(park info --session-id "$SESSION_ID" --dir /elsewhere)"
  assert "--dir overrides the transcript" contains "dir=/elsewhere" "$out"

  out="$(cd "$SANDBOX" && park info --session-id unknown-id 2>/dev/null)"
  assert "an unknown session falls back to the current directory" \
    contains "dir=$(cd "$SANDBOX" && pwd)" "$out"
  err="$(park info --session-id unknown-id 2>&1 >/dev/null)"
  assert "the fallback warning names the missing transcript" \
    contains "no transcript for session unknown-id" "$err"

  printf '{"type":"summary"}\n' \
    > "$SANDBOX/claude/projects/-work-project/no-cwd.jsonl"
  err="$(park info --session-id no-cwd 2>&1 >/dev/null)"
  assert "the fallback warning names a transcript without a directory" \
    contains "records no working directory" "$err"

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
    printf '## new work\n```bash\n'
    printf '# CLAUDE_CONFIG_DIR=%s\n' "$SANDBOX/claude"
    printf 'cd /work/project\n'
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

  # A same-named file in the current directory must not be picked up.
  mkdir "$SANDBOX/cwd"
  printf 'project file\n' > "$SANDBOX/cwd/Sessions.markdown"
  out="$(cd "$SANDBOX/cwd" &&
    park add --session-id "$SESSION_ID" Sessions.markdown 'relative')"
  assert_eq "a relative path resolves against the notes store" \
    "parked: relative" "$out"
  assert_eq "a same-named file in the current directory is untouched" \
    "project file" "$(cat "$SANDBOX/cwd/Sessions.markdown")"
  assert "the store note got the entry" grep -qx '## relative' "$note"

  out="$(park add --session-id s1 --dir '/with space/dir' "$note" \
    $'  ## messy\n  title  ')"
  assert_eq "the title is cleaned to one line" "parked: messy title" "$out"
  assert "the heading has no extra #" grep -qx '## messy title' "$note"
  assert "a directory with a space is shell-quoted" \
    grep -qxF "cd '/with space/dir'" "$note"

  park add --session-id s5 --dir "/it's/here" "$note" quote >/dev/null
  assert "a single quote in the directory is escaped" \
    grep -qxF "cd '/it'\''s/here'" "$note"

  # Bash 3.2 (macOS /bin/bash) must not mangle UTF-8 in the directory.
  local shell
  for shell in bash /bin/bash; do
    command -v "$shell" >/dev/null 2>&1 || continue
    printf '# U\n' > "$SANDBOX/notes/utf8.markdown"
    env -u CLAUDE_CODE_SESSION_ID CLAUDE_CONFIG_DIR="$SANDBOX/claude" \
      "$shell" "$SESSION_PARK" add --session-id s6 --dir '/work/проєкт' \
      "$SANDBOX/notes/utf8.markdown" t >/dev/null
    assert "$shell keeps a non-ASCII directory as valid UTF-8" \
      grep -qxF "cd '/work/проєкт'" "$SANDBOX/notes/utf8.markdown"
  done

  # awk would read this operand as a variable assignment, not as a file.
  printf '# Assign\n\nkeep me\n' > "$SANDBOX/notes/a=b.markdown"
  (cd "$SANDBOX/notes" &&
    park add --session-id s7 --dir /p 'a=b.markdown' t >/dev/null)
  assert "a note named like name=value keeps its content" \
    grep -qx 'keep me' "$SANDBOX/notes/a=b.markdown"
  assert "a note named like name=value gets the entry" \
    grep -qx 'claude --resume s7' "$SANDBOX/notes/a=b.markdown"

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
    "# Only a title"$'\n\n## t\n```bash\n'"# CLAUDE_CONFIG_DIR=$SANDBOX/claude"$'\ncd /p\nclaude --resume s3\n```' \
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

# --- Tests: newest ------------------------------------------------------------

test_newest() {
  local out rc
  make_sandbox
  printf '# Old\n' > "$SANDBOX/notes/Old.markdown"
  touch -t 202001010000 "$SANDBOX/notes/Old.markdown"
  mkdir "$SANDBOX/notes/Work"
  printf '# Older\n' > "$SANDBOX/notes/Work/Older.markdown"
  touch -t 201901010000 "$SANDBOX/notes/Work/Older.markdown"

  # Run from another directory: the paths are relative to the store.
  out="$(cd "$SANDBOX" &&
    park newest Old.markdown Sessions.markdown Work/Older.markdown)"
  assert_eq "newest prints the absolute path of the latest note" \
    "$SANDBOX/notes/Sessions.markdown" "$out"

  out="$(park newest Work/Older.markdown "$SANDBOX/notes/Old.markdown")"
  assert_eq "newest accepts absolute paths" \
    "$SANDBOX/notes/Old.markdown" "$out"

  set +e
  park newest Old.markdown missing.markdown >/dev/null 2>&1
  rc=$?
  set -e
  assert_eq "newest fails on a missing candidate" "1" "$rc"

  set +e
  park newest >/dev/null 2>&1
  rc=$?
  set -e
  assert_eq "newest without paths exits 2" "2" "$rc"

  rm -rf "$SANDBOX"
}

# --- Tests: failed note writes ------------------------------------------------

test_failed_write() {
  local note original err rc backup
  make_sandbox
  note="$SANDBOX/notes/Sessions.markdown"
  original="$(cat "$note")"

  # A fake cmp that fails whenever it checks what was written to the note
  # makes the script treat every write as unverified: the path taken when a
  # write breaks after truncating the note. The backup check still passes.
  mkdir "$SANDBOX/bin" "$SANDBOX/tmp" "$SANDBOX/nocp"
  {
    printf '#!/bin/sh\n'
    printf 'for last; do :; done\n'
    # shellcheck disable=SC2016
    printf '[ "$last" = "$FAKE_CMP_NOTE" ] && exit 1\n'
    printf 'exec "%s" "$@"\n' "$(command -v cmp)"
  } > "$SANDBOX/bin/cmp"
  printf '#!/bin/sh\nexit 1\n' > "$SANDBOX/nocp/cp"
  chmod +x "$SANDBOX/bin/cmp" "$SANDBOX/nocp/cp"

  # No backup, no write: the note must not be touched.
  set +e
  err="$(PATH="$SANDBOX/nocp:$PATH" TMPDIR="$SANDBOX/tmp" \
    park add --session-id "$SESSION_ID" "$note" t 2>&1 >/dev/null)"
  rc=$?
  set -e
  assert_eq "a failed backup exits 1" "1" "$rc"
  assert "a failed backup is reported" contains "could not back up" "$err"
  assert_eq "a failed backup leaves the note untouched" \
    "$original" "$(cat "$note")"
  assert "a failed backup leaves no backup file" \
    no_backup_files "$SANDBOX/tmp"

  set +e
  err="$(PATH="$SANDBOX/nocp:$PATH" TMPDIR="$SANDBOX/missing" \
    park add --session-id "$SESSION_ID" "$note" t 2>&1 >/dev/null)"
  rc=$?
  set -e
  assert_eq "a failed mktemp exits 1" "1" "$rc"
  assert_eq "a failed mktemp leaves the note untouched" \
    "$original" "$(cat "$note")"

  set +e
  err="$(PATH="$SANDBOX/bin:$PATH" TMPDIR="$SANDBOX/tmp" \
    FAKE_CMP_NOTE="$note" park add --session-id "$SESSION_ID" "$note" t 2>&1 >/dev/null)"
  rc=$?
  set -e
  assert_eq "an unverified write exits 1" "1" "$rc"
  assert "an unverified write reports the backup" \
    contains "its previous content is in $SANDBOX/tmp/session-park-backup." \
    "$err"
  backup="$(printf '%s\n' "$SANDBOX"/tmp/session-park-backup.*)"
  assert_eq "the backup holds the previous content" \
    "$original" "$(cat "$backup")"

  if [[ "$(id -u)" -ne 0 ]]; then
    printf '%s\n' "$original" > "$note"
    chmod 444 "$note"
    set +e
    err="$(TMPDIR="$SANDBOX/tmp" \
      park add --session-id "$SESSION_ID" "$note" t 2>&1 >/dev/null)"
    rc=$?
    set -e
    chmod 644 "$note"
    assert_eq "a read-only note exits 1" "1" "$rc"
    assert "a read-only note is reported as unchanged" \
      contains "it is unchanged" "$err"
    assert_eq "a read-only note keeps its content" \
      "$original" "$(cat "$note")"
    assert_eq "no second backup is left behind" "$backup" \
      "$(printf '%s\n' "$SANDBOX"/tmp/session-park-backup.*)"
  else
    printf 'skip - read-only note test needs a non-root user\n'
  fi

  rm -rf "$SANDBOX"
}

# --- Runner -------------------------------------------------------------------

main() {
  test_manifests
  test_skill
  test_info
  test_add
  test_add_edge_cases
  test_newest
  test_failed_write

  printf '\nAll %d assertions passed.\n' "$PASS_COUNT"
}

main "$@"
