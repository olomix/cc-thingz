#!/usr/bin/env bash
# Unit tests for the fsnotes plugin. Pure bash, no framework.
# Run: tests/fsnotes_test.sh  (exits non-zero on first failure)
set -euo pipefail

# Repo root is the parent of this tests/ directory, regardless of cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_DIR="$REPO_ROOT/plugins/fsnotes"

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

# valid_json <file> : true when the file parses as JSON.
valid_json() {
  jq -e . "$1" >/dev/null 2>&1
}

# json_has_key <file> <jq-path> : true when the key resolves to a non-null value.
json_has_key() {
  local file="$1" path="$2"
  [[ "$(jq -r "$path" "$file" 2>/dev/null)" != "null" ]]
}

# contains <needle> <haystack> : true when haystack contains needle.
contains() {
  case "$2" in
    *"$1"*) return 0 ;;
    *) return 1 ;;
  esac
}

# make_fixture : build a temp notes dir mirroring an FSNotes store and echo it.
# Layout: top-level notes, a "Work" notebook subfolder, reserved Trash/ & files/.
make_fixture() {
  local dir
  dir="$(mktemp -d)"
  mkdir -p "$dir/Work" "$dir/Trash" "$dir/files"

  printf '# Grocery list\n\nMilk and eggs. #shopping\n' \
    > "$dir/Grocery list.markdown"
  printf '# Meeting notes\n\nDiscussed roadmap. #work #planning\n' \
    > "$dir/Meeting notes.markdown"
  printf '# Project plan\n\nQ3 goals for the team. #work\n' \
    > "$dir/Work/Project plan.markdown"
  printf '# Deleted note\n\nOld content. #shopping\n' \
    > "$dir/Trash/Deleted note.markdown"

  printf '%s' "$dir"
}

# --- Tests: manifests --------------------------------------------------------

test_marketplace_manifest() {
  local f="$REPO_ROOT/.claude-plugin/marketplace.json"
  assert "marketplace.json exists" test -f "$f"
  assert "marketplace.json is valid JSON" valid_json "$f"
  assert_eq "marketplace name" "olomix-cc-thingz" \
    "$(jq -r '.name' "$f")"
  assert "marketplace has owner.name" json_has_key "$f" '.owner.name'
  assert_eq "marketplace lists fsnotes plugin" "fsnotes" \
    "$(jq -r '.plugins[0].name' "$f")"
  assert_eq "fsnotes plugin source" "./plugins/fsnotes" \
    "$(jq -r '.plugins[0].source' "$f")"
  assert "fsnotes plugin has description" \
    json_has_key "$f" '.plugins[0].description'
}

test_plugin_manifest() {
  local f="$PLUGIN_DIR/.claude-plugin/plugin.json"
  assert "plugin.json exists" test -f "$f"
  assert "plugin.json is valid JSON" valid_json "$f"
  assert_eq "plugin name" "fsnotes" "$(jq -r '.name' "$f")"
  assert_eq "plugin version" "0.1.0" "$(jq -r '.version' "$f")"
  assert "plugin has description" json_has_key "$f" '.description'
  assert "plugin has license" json_has_key "$f" '.license'
  assert "plugin has homepage" json_has_key "$f" '.homepage'
}

# --- Tests: fsnotes-lib.sh ---------------------------------------------------

# shellcheck source=plugins/fsnotes/scripts/fsnotes-lib.sh
source "$PLUGIN_DIR/scripts/fsnotes-lib.sh"

test_resolve_notes_dir() {
  local fixture
  fixture="$(make_fixture)"

  # FSNOTES_DIR override resolves to the given directory.
  assert_eq "resolve_notes_dir honors FSNOTES_DIR" "$fixture" \
    "$(FSNOTES_DIR="$fixture" resolve_notes_dir)"

  # FSNOTES_DIR set to a non-directory fails.
  assert "resolve_notes_dir rejects bad FSNOTES_DIR" \
    bash -c "source '$PLUGIN_DIR/scripts/fsnotes-lib.sh'; FSNOTES_DIR='$fixture/nope'; ! resolve_notes_dir 2>/dev/null"

  # Glob fallback: no primary, exactly one *fsnotes*/Documents under HOME.
  local home_one
  home_one="$(mktemp -d)"
  mkdir -p "$home_one/Library/Mobile Documents/co~fluder~fsnotes/Documents"
  assert_eq "resolve_notes_dir glob fallback (unique match)" \
    "$home_one/Library/Mobile Documents/co~fluder~fsnotes/Documents" \
    "$(unset FSNOTES_DIR; HOME="$home_one" resolve_notes_dir)"

  # Ambiguous: two matching directories → non-zero.
  local home_many
  home_many="$(mktemp -d)"
  mkdir -p "$home_many/Library/Mobile Documents/a-fsnotes/Documents" \
    "$home_many/Library/Mobile Documents/b-fsnotes/Documents"
  assert "resolve_notes_dir fails on ambiguous match" \
    bash -c "source '$PLUGIN_DIR/scripts/fsnotes-lib.sh'; unset FSNOTES_DIR; HOME='$home_many'; ! resolve_notes_dir 2>/dev/null"

  rm -rf "$fixture" "$home_one" "$home_many"
}

test_sanitize_title() {
  assert_eq "sanitize_title passes plain text" "Grocery list" \
    "$(sanitize_title 'Grocery list')"
  assert_eq "sanitize_title replaces slashes" "a-b-c" \
    "$(sanitize_title 'a/b/c')"
  assert_eq "sanitize_title strips leading dots" "hidden" \
    "$(sanitize_title '...hidden')"
  assert_eq "sanitize_title collapses whitespace" "a b" \
    "$(sanitize_title '  a    b  ')"
  assert_eq "sanitize_title removes shell-hostile chars" "weird name" \
    "$(sanitize_title 'weird:*?"<>|name')"
  assert "sanitize_title rejects empty result" \
    bash -c "source '$PLUGIN_DIR/scripts/fsnotes-lib.sh'; ! sanitize_title '...' 2>/dev/null"
}

# --- Tests: fsnotes-search.sh ------------------------------------------------

SEARCH="$PLUGIN_DIR/scripts/fsnotes-search.sh"

test_search() {
  local fixture out
  fixture="$(make_fixture)"

  # text: body match finds the note, no match yields empty output.
  out="$(FSNOTES_DIR="$fixture" "$SEARCH" text Milk)"
  assert "text mode finds body match" contains "Grocery list.markdown" "$out"
  out="$(FSNOTES_DIR="$fixture" "$SEARCH" text nonexistentxyz)"
  assert_eq "text mode no-match is empty" "" "$out"

  # title: matches the # heading and the filename.
  out="$(FSNOTES_DIR="$fixture" "$SEARCH" title Meeting)"
  assert "title mode matches filename/heading" \
    contains "Meeting notes.markdown" "$out"
  out="$(FSNOTES_DIR="$fixture" "$SEARCH" title nonexistentxyz)"
  assert_eq "title mode no-match is empty" "" "$out"

  # tag: matches inline hashtag (leading # optional).
  out="$(FSNOTES_DIR="$fixture" "$SEARCH" tag work)"
  assert "tag mode finds #work" contains "Meeting notes.markdown" "$out"
  out="$(FSNOTES_DIR="$fixture" "$SEARCH" tag '#work')"
  assert "tag mode accepts leading #" contains "Meeting notes.markdown" "$out"
  out="$(FSNOTES_DIR="$fixture" "$SEARCH" tag nosuchtag)"
  assert_eq "tag mode no-match is empty" "" "$out"

  # Exclusions: Trash/ and files/ are never searched.
  out="$(FSNOTES_DIR="$fixture" "$SEARCH" tag shopping)"
  assert "tag mode finds top-level #shopping" \
    contains "Grocery list.markdown" "$out"
  assert "tag mode excludes Trash/" bash -c \
    "! FSNOTES_DIR='$fixture' '$SEARCH' tag shopping | grep -q Trash"
  out="$(FSNOTES_DIR="$fixture" "$SEARCH" text 'Old content')"
  assert_eq "text mode excludes Trash/ body" "" "$out"

  # Notebook scoping via the optional 3rd argument.
  out="$(FSNOTES_DIR="$fixture" "$SEARCH" text goals Work)"
  assert "notebook scope finds in-folder match" \
    contains "Work/Project plan.markdown" "$out"
  out="$(FSNOTES_DIR="$fixture" "$SEARCH" text Milk Work)"
  assert_eq "notebook scope excludes out-of-folder match" "" "$out"
  assert "unknown notebook fails" bash -c \
    "! FSNOTES_DIR='$fixture' '$SEARCH' text goals NoSuchBook 2>/dev/null"

  # folder mode: <query> is the notebook, restricting a body search to it.
  out="$(FSNOTES_DIR="$fixture" "$SEARCH" folder Work goals)"
  assert "folder mode restricts to notebook" \
    contains "Work/Project plan.markdown" "$out"

  # Usage / unknown mode error out non-zero.
  assert "missing args is an error" bash -c \
    "! FSNOTES_DIR='$fixture' '$SEARCH' text 2>/dev/null"
  assert "unknown mode is an error" bash -c \
    "! FSNOTES_DIR='$fixture' '$SEARCH' bogus query 2>/dev/null"

  rm -rf "$fixture"
}

test_search_grep_fallback() {
  local fixture out err
  fixture="$(make_fixture)"
  err="$(mktemp)"

  # Shadow rg by restricting PATH to the system dirs (ripgrep lives elsewhere,
  # e.g. /opt/homebrew/bin), forcing the grep fallback path.
  out="$(PATH=/usr/bin:/bin FSNOTES_DIR="$fixture" \
    bash "$SEARCH" text Milk 2>"$err")"
  assert "grep fallback returns same hit" \
    contains "Grocery list.markdown" "$out"
  assert "grep fallback emits ripgrep hint" \
    contains "ripgrep" "$(cat "$err")"

  rm -rf "$fixture"
  rm -f "$err"
}

# --- Tests: fsnotes-newpath.sh -----------------------------------------------

NEWPATH="$PLUGIN_DIR/scripts/fsnotes-newpath.sh"

test_newpath() {
  local fixture out
  fixture="$(make_fixture)"

  # Fresh title → sanitized absolute path at the store root.
  out="$(FSNOTES_DIR="$fixture" "$NEWPATH" 'Fresh idea')"
  assert_eq "newpath builds path for fresh title" \
    "$fixture/Fresh idea.markdown" "$out"

  # Title is sanitized (slashes replaced) before forming the path.
  out="$(FSNOTES_DIR="$fixture" "$NEWPATH" 'a/b')"
  assert_eq "newpath sanitizes the title" "$fixture/a-b.markdown" "$out"

  # Existing title → non-zero and no path printed (never overwrite).
  assert "newpath refuses existing note" bash -c \
    "! FSNOTES_DIR='$fixture' '$NEWPATH' 'Grocery list' 2>/dev/null"
  out="$(FSNOTES_DIR="$fixture" "$NEWPATH" 'Grocery list' 2>/dev/null || true)"
  assert_eq "newpath prints nothing for existing note" "" "$out"

  # Notebook subfolder placement.
  out="$(FSNOTES_DIR="$fixture" "$NEWPATH" 'Sprint review' Work)"
  assert_eq "newpath places note in notebook" \
    "$fixture/Work/Sprint review.markdown" "$out"

  # Missing title is an error.
  assert "newpath requires a title" bash -c \
    "! FSNOTES_DIR='$fixture' '$NEWPATH' 2>/dev/null"

  rm -rf "$fixture"
}

# --- Tests: fsnotes-trash.sh -------------------------------------------------

TRASH="$PLUGIN_DIR/scripts/fsnotes-trash.sh"

test_trash() {
  local fixture out

  # Move succeeds: file lands in Trash/ and the source no longer exists.
  fixture="$(make_fixture)"
  out="$(FSNOTES_DIR="$fixture" "$TRASH" 'Grocery list.markdown')"
  assert_eq "trash moves note into Trash/" \
    "$fixture/Trash/Grocery list.markdown" "$out"
  assert "trash removes the source" test ! -e "$fixture/Grocery list.markdown"
  assert "trashed note exists in Trash/" \
    test -f "$fixture/Trash/Grocery list.markdown"

  # Trash/ is created on demand when absent.
  rmdir "$fixture/files" 2>/dev/null || true
  rm -rf "$fixture/Trash"
  out="$(FSNOTES_DIR="$fixture" "$TRASH" 'Meeting notes.markdown')"
  assert_eq "trash creates Trash/ when absent" \
    "$fixture/Trash/Meeting notes.markdown" "$out"
  rm -rf "$fixture"

  # Collision in Trash/ preserves both files via a numeric suffix.
  fixture="$(make_fixture)"
  printf '# Other grocery\n\nNew list.\n' > "$fixture/Grocery list.markdown"
  printf '# Trashed grocery\n\nOld list.\n' \
    > "$fixture/Trash/Grocery list.markdown"
  out="$(FSNOTES_DIR="$fixture" "$TRASH" 'Grocery list.markdown')"
  assert_eq "trash disambiguates on collision" \
    "$fixture/Trash/Grocery list (1).markdown" "$out"
  assert "trash keeps the pre-existing trashed note" \
    test -f "$fixture/Trash/Grocery list.markdown"
  assert "trash keeps the newly trashed note" \
    test -f "$fixture/Trash/Grocery list (1).markdown"
  assert "collision did not clobber original trashed content" bash -c \
    "grep -q 'Old list' '$fixture/Trash/Grocery list.markdown'"
  assert "newly trashed note retains its content" bash -c \
    "grep -q 'New list' '$fixture/Trash/Grocery list (1).markdown'"

  # Absolute paths and notebook-relative paths both resolve.
  out="$(FSNOTES_DIR="$fixture" "$TRASH" 'Work/Project plan.markdown')"
  assert_eq "trash accepts notebook-relative path" \
    "$fixture/Trash/Project plan.markdown" "$out"
  assert "trash removes notebook source" \
    test ! -e "$fixture/Work/Project plan.markdown"

  # Missing source → non-zero, nothing printed.
  assert "trash fails on missing source" bash -c \
    "! FSNOTES_DIR='$fixture' '$TRASH' 'No such note.markdown' 2>/dev/null"
  # Missing argument → non-zero.
  assert "trash requires a note path" bash -c \
    "! FSNOTES_DIR='$fixture' '$TRASH' 2>/dev/null"

  rm -rf "$fixture"
}

# --- Runner ------------------------------------------------------------------

main() {
  test_marketplace_manifest
  test_plugin_manifest
  test_resolve_notes_dir
  test_sanitize_title
  test_search
  test_search_grep_fallback
  test_newpath
  test_trash

  printf '\nAll %d assertions passed.\n' "$PASS_COUNT"
}

main "$@"
