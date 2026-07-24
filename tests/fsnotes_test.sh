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

# frontmatter <file> : echo the YAML frontmatter block (between the first two
# "---" fences). Empty when the file has no frontmatter.
frontmatter() {
  awk 'NR==1 && $0!="---"{exit} NR==1{next} $0=="---"{exit} {print}' "$1"
}

# frontmatter_has_key <file> <key> : true when the frontmatter has a top-level
# "<key>:" entry.
frontmatter_has_key() {
  frontmatter "$1" | grep -Eq "^$2:"
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
  printf '# Workshop ideas\n\nPlanning a #workshop next month.\n' \
    > "$dir/Workshop ideas.markdown"
  # First line is the title; a later "# " line is a body heading, not a title.
  printf '# Alpha note\n\n# Buried heading\n\nBody. #misc\n' \
    > "$dir/Alpha note.markdown"
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

test_urlencode() {
  # Unreserved characters (RFC 3986) pass through untouched.
  assert_eq "urlencode passes unreserved chars" \
    "AZaz09.~_-" "$(urlencode 'AZaz09.~_-')"
  # Space becomes %20, not '+'.
  assert_eq "urlencode encodes space as %20" "a%20b" "$(urlencode 'a b')"
  # Reserved/query characters are percent-encoded.
  assert_eq "urlencode escapes ampersand" "a%26b" "$(urlencode 'a&b')"
  assert_eq "urlencode escapes question mark" "a%3Fb" "$(urlencode 'a?b')"
  assert_eq "urlencode escapes hash" "a%23b" "$(urlencode 'a#b')"
  assert_eq "urlencode escapes slash" "a%2Fb" "$(urlencode 'a/b')"
  assert_eq "urlencode escapes percent" "a%25b" "$(urlencode 'a%b')"
  # Multi-byte UTF-8 is encoded per byte (Cyrillic "Заметка").
  assert_eq "urlencode encodes UTF-8 per byte" \
    "%D0%97%D0%B0%D0%BC%D0%B5%D1%82%D0%BA%D0%B0" \
    "$(urlencode 'Заметка')"
  # Empty input yields empty output.
  assert_eq "urlencode handles empty input" "" "$(urlencode '')"
}

# --- Tests: fsnotes-link.sh --------------------------------------------------

LINK="$PLUGIN_DIR/scripts/fsnotes-link.sh"

test_link() {
  # find: markdown link, title encoded in the URL but raw in the link text.
  assert_eq "link find markdown" \
    "[Grocery list](fsnotes://find?id=Grocery%20list)" \
    "$("$LINK" find 'Grocery list')"

  # open: open-or-create by title.
  assert_eq "link open markdown" \
    "[My note](fsnotes://open/?title=My%20note)" \
    "$("$LINK" open 'My note')"

  # open with --txt appends the text query.
  assert_eq "link open with txt" \
    "[My note](fsnotes://open/?title=My%20note&txt=Hello%20there)" \
    "$("$LINK" open 'My note' --txt 'Hello there')"

  # tag: select a tag in the sidebar.
  assert_eq "link tag markdown" \
    "[work](fsnotes://open/?tag=work)" \
    "$("$LINK" tag work)"

  # new: create a note.
  assert_eq "link new markdown" \
    "[Fresh idea](fsnotes://new/?title=Fresh%20idea)" \
    "$("$LINK" new 'Fresh idea')"

  # new with --txt and --folder.
  assert_eq "link new with txt and folder" \
    "[Fresh idea](fsnotes://new/?title=Fresh%20idea&txt=Body%20text&folder=Work)" \
    "$("$LINK" new 'Fresh idea' --txt 'Body text' --folder Work)"

  # A space and an ampersand encode inside the URL but stay raw in link text.
  assert_eq "link encodes ampersand in url, raw in text" \
    "[Tom & Jerry](fsnotes://find?id=Tom%20%26%20Jerry)" \
    "$("$LINK" find 'Tom & Jerry')"

  # --osc8: exact escape framing. ST is ESC "\"; the payload is ASCII because
  # the URL is fully percent-encoded.
  local esc expected
  esc=$'\033'
  expected="${esc}]8;;fsnotes://find?id=Grocery%20list${esc}\\Grocery list${esc}]8;;${esc}\\"
  assert_eq "link osc8 framing" "$expected" \
    "$("$LINK" --osc8 find 'Grocery list')"

  # Error cases (all exit non-zero, message on stderr).
  assert "link no args errors" bash -c "! '$LINK' 2>/dev/null"
  assert "link unknown route errors" bash -c "! '$LINK' bogus x 2>/dev/null"
  assert "link empty title errors" bash -c "! '$LINK' find '' 2>/dev/null"
  assert "link reserved folder errors" bash -c \
    "! '$LINK' new Note --folder Trash 2>/dev/null"
  assert "link unknown flag errors" bash -c \
    "! '$LINK' find Note --bogus 2>/dev/null"
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
  # A note whose heading and filename both match must appear only once.
  out="$(FSNOTES_DIR="$fixture" "$SEARCH" title Meeting | wc -l | tr -d ' ')"
  assert_eq "title mode dedupes heading+filename match" "1" "$out"
  # title matches the first heading, not a later body "# " heading.
  out="$(FSNOTES_DIR="$fixture" "$SEARCH" title Alpha)"
  assert "title mode matches the first heading" \
    contains "Alpha note.markdown" "$out"
  out="$(FSNOTES_DIR="$fixture" "$SEARCH" title Buried)"
  assert_eq "title mode ignores body headings" "" "$out"
  # Distinct notes whose filenames share a colon-prefix must not collapse:
  # dedupe keys on the path, not the substring before the first colon.
  printf '# Re Sync one\n' > "$fixture/Re: Sync one.markdown"
  printf '# Re Sync two\n' > "$fixture/Re: Sync two.markdown"
  out="$(FSNOTES_DIR="$fixture" "$SEARCH" title Sync | wc -l | tr -d ' ')"
  assert_eq "title mode keeps colon-prefixed distinct notes" "2" "$out"
  rm -f "$fixture/Re: Sync one.markdown" "$fixture/Re: Sync two.markdown"
  # The dedup key must not treat a `:<digits>:` substring in the filename as a
  # `:line:` suffix, or distinct notes sharing that substring would collapse.
  printf '# Re 12 one SyncDigit\n' > "$fixture/Re:12:one SyncDigit.markdown"
  printf '# Re 12 two SyncDigit\n' > "$fixture/Re:12:two SyncDigit.markdown"
  out="$(FSNOTES_DIR="$fixture" "$SEARCH" title SyncDigit | wc -l | tr -d ' ')"
  assert_eq "title mode keeps colon-digit distinct notes" "2" "$out"
  rm -f "$fixture/Re:12:one SyncDigit.markdown" \
    "$fixture/Re:12:two SyncDigit.markdown"

  # tag: matches inline hashtag (leading # optional).
  out="$(FSNOTES_DIR="$fixture" "$SEARCH" tag work)"
  assert "tag mode finds #work" contains "Meeting notes.markdown" "$out"
  out="$(FSNOTES_DIR="$fixture" "$SEARCH" tag '#work')"
  assert "tag mode accepts leading #" contains "Meeting notes.markdown" "$out"
  out="$(FSNOTES_DIR="$fixture" "$SEARCH" tag nosuchtag)"
  assert_eq "tag mode no-match is empty" "" "$out"
  # Word boundary: #work must not match the longer #workshop tag.
  out="$(FSNOTES_DIR="$fixture" "$SEARCH" tag work)"
  assert "tag mode respects word boundary (not #workshop)" bash -c \
    "! printf '%s' \"\$1\" | grep -q Workshop" _ "$out"

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
  # A notebook escaping the store via ".." is rejected before any search.
  assert "notebook traversal is rejected" bash -c \
    "! FSNOTES_DIR='$fixture' '$SEARCH' text goals '../../etc' 2>/dev/null"
  # Reserved folders must not be searchable as notebooks (Trash/ exists here).
  assert "reserved notebook Trash is rejected" bash -c \
    "! FSNOTES_DIR='$fixture' '$SEARCH' text shopping Trash 2>/dev/null"
  assert "reserved notebook files is rejected" bash -c \
    "! FSNOTES_DIR='$fixture' '$SEARCH' text shopping files 2>/dev/null"

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

  # A notebook escaping the store via ".." is rejected, printing no path.
  assert "newpath rejects traversal notebook" bash -c \
    "! FSNOTES_DIR='$fixture' '$NEWPATH' 'escape' '../../../tmp' 2>/dev/null"
  out="$(FSNOTES_DIR="$fixture" "$NEWPATH" 'escape' '../../../tmp' \
    2>/dev/null || true)"
  assert_eq "newpath prints nothing for traversal notebook" "" "$out"

  # Reserved folders must not be usable as notebooks for new notes.
  assert "newpath rejects reserved notebook Trash" bash -c \
    "! FSNOTES_DIR='$fixture' '$NEWPATH' 'sneaky' 'Trash' 2>/dev/null"
  assert "newpath rejects reserved notebook files" bash -c \
    "! FSNOTES_DIR='$fixture' '$NEWPATH' 'sneaky' 'files' 2>/dev/null"

  # A "." prefix must not slip a reserved folder past the guard.
  assert "newpath rejects ./Trash notebook" bash -c \
    "! FSNOTES_DIR='$fixture' '$NEWPATH' 'sneaky' './Trash' 2>/dev/null"
  assert "newpath rejects ./files notebook" bash -c \
    "! FSNOTES_DIR='$fixture' '$NEWPATH' 'sneaky' './files' 2>/dev/null"

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

  # Absolute in-store paths and notebook-relative paths both resolve.
  out="$(FSNOTES_DIR="$fixture" "$TRASH" 'Work/Project plan.markdown')"
  assert_eq "trash accepts notebook-relative path" \
    "$fixture/Trash/Project plan.markdown" "$out"
  assert "trash removes notebook source" \
    test ! -e "$fixture/Work/Project plan.markdown"
  out="$(FSNOTES_DIR="$fixture" "$TRASH" "$fixture/Workshop ideas.markdown")"
  assert "trash accepts an absolute in-store path" \
    test -f "$fixture/Trash/Workshop ideas.markdown"
  assert "trash removes the absolute in-store source" \
    test ! -e "$fixture/Workshop ideas.markdown"

  # Missing source → non-zero, nothing printed.
  assert "trash fails on missing source" bash -c \
    "! FSNOTES_DIR='$fixture' '$TRASH' 'No such note.markdown' 2>/dev/null"
  # Missing argument → non-zero.
  assert "trash requires a note path" bash -c \
    "! FSNOTES_DIR='$fixture' '$TRASH' 2>/dev/null"

  # A relative path with ".." must be rejected, not allowed to escape the store.
  printf 'victim\n' >"$fixture/../trash_victim.markdown"
  assert "trash rejects traversal in relative path" bash -c \
    "! FSNOTES_DIR='$fixture' '$TRASH' '../trash_victim.markdown' 2>/dev/null"
  assert "trash leaves the out-of-store file in place" \
    test -e "$fixture/../trash_victim.markdown"
  rm -f "$fixture/../trash_victim.markdown"

  # An absolute path outside the store is canonicalized and refused.
  local outside
  outside="$(mktemp)"
  printf 'outside\n' >"$outside"
  assert "trash rejects an absolute path outside the store" bash -c \
    "! FSNOTES_DIR='$fixture' '$TRASH' '$outside' 2>/dev/null"
  assert "trash leaves the outside file in place" test -e "$outside"
  rm -f "$outside"

  # An in-store symlink pointing outside must be refused, not dereferenced into
  # Trash/ (which would hard-link the outside target's contents into the store).
  outside="$(mktemp)"
  printf 'secret\n' >"$outside"
  ln -s "$outside" "$fixture/Leak.markdown"
  assert "trash rejects an in-store symlink" bash -c \
    "! FSNOTES_DIR='$fixture' '$TRASH' 'Leak.markdown' 2>/dev/null"
  assert "trash leaves the symlink in place" test -L "$fixture/Leak.markdown"
  assert "trash does not pull the symlink target into Trash/" \
    test ! -e "$fixture/Trash/Leak.markdown"
  rm -f "$fixture/Leak.markdown" "$outside"

  rm -rf "$fixture"
}

# --- Tests: fsnotes-search agent ---------------------------------------------

test_search_agent() {
  local f="$PLUGIN_DIR/agents/fsnotes-search.md"
  assert "search agent exists" test -f "$f"
  assert "search agent has name key" frontmatter_has_key "$f" name
  assert "search agent has description key" frontmatter_has_key "$f" description
  assert "search agent has tools key" frontmatter_has_key "$f" tools
  assert_eq "search agent name is fsnotes-search" "fsnotes-search" \
    "$(frontmatter "$f" | awk -F': *' '/^name:/{print $2}')"
  assert "search agent references the search script" bash -c \
    "grep -q 'fsnotes-search.sh' '$f'"

  # Output guidance must point at the link builder and the find route so hits
  # come back as clickable fsnotes://find links.
  assert "search agent references the link script" bash -c \
    "grep -q 'fsnotes-link.sh' '$f'"
  assert "search agent mentions fsnotes://find" bash -c \
    "grep -qF -- 'fsnotes://find' '$f'"

  local fm mode
  fm="$(frontmatter "$f")"
  for mode in text title tag folder; do
    assert "search agent description mentions $mode mode" \
      contains "$mode" "$fm"
  done
}

# --- Tests: fsnotes SKILL.md -------------------------------------------------

test_skill() {
  local f="$PLUGIN_DIR/skills/fsnotes/SKILL.md"
  assert "skill exists" test -f "$f"
  assert "skill has name key" frontmatter_has_key "$f" name
  assert "skill has description key" frontmatter_has_key "$f" description
  assert "skill has allowed-tools key" frontmatter_has_key "$f" allowed-tools
  assert_eq "skill name is fsnotes" "fsnotes" \
    "$(frontmatter "$f" | awk -F': *' '/^name:/{print $2}')"

  # The skill must reference each of the five scripts.
  local script
  for script in fsnotes-search.sh fsnotes-newpath.sh fsnotes-trash.sh \
    fsnotes-link.sh fsnotes-lib.sh; do
    assert "skill mentions $script" bash -c "grep -q '$script' '$f'"
  done

  # The deep-links section must document the routes and the --osc8 flag.
  local token
  for token in 'fsnotes://find' 'fsnotes://new' '--osc8'; do
    assert "skill mentions $token" bash -c "grep -qF -- '$token' '$f'"
  done

  # No real-world local notebook names may be hardcoded anywhere in the
  # plugin tree. Notebooks are discovered at runtime; the only folder names
  # that may appear are the reserved Trash/ and files/.
  assert "no real notebook names hardcoded in plugins/" \
    no_local_notebooks "$PLUGIN_DIR"
}

# no_local_notebooks <dir> : fail if any non-test file under <dir> references
# a notebook name pulled from the user's actual store. Allowlist covers the
# generic example names used in docs and the reserved folders.
no_local_notebooks() {
  local dir="$1"
  # Personal notebook names that must never leak into the shipped plugin.
  local forbidden='Inbox|Journal|Personal|Daily'
  ! grep -rEl "($forbidden)" "$dir" >/dev/null 2>&1
}

# --- Runner ------------------------------------------------------------------

main() {
  test_marketplace_manifest
  test_plugin_manifest
  test_resolve_notes_dir
  test_sanitize_title
  test_urlencode
  test_link
  test_search
  test_search_grep_fallback
  test_newpath
  test_trash
  test_search_agent
  test_skill

  printf '\nAll %d assertions passed.\n' "$PASS_COUNT"
}

main "$@"
