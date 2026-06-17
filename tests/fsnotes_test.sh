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

# --- Runner ------------------------------------------------------------------

main() {
  test_marketplace_manifest
  test_plugin_manifest

  printf '\nAll %d assertions passed.\n' "$PASS_COUNT"
}

main "$@"
