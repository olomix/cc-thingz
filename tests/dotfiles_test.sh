#!/usr/bin/env bash
# Unit tests for the dotfiles plugin. Pure bash, no framework.
# Run: tests/dotfiles_test.sh  (exits non-zero on first failure)
set -euo pipefail

# Repo root is the parent of this tests/ directory, regardless of cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_DIR="$REPO_ROOT/plugins/dotfiles"
TRACKED="$PLUGIN_DIR/scripts/dotfiles-tracked.sh"

PASS_COUNT=0

# assert <description> <command...> : runs command, fails the suite if it exits
# non-zero.
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

# is_json <string> : true when the string parses as JSON.
is_json() {
  printf '%s' "$1" | jq -e . >/dev/null 2>&1
}

# payload <file_path> : echo a PostToolUse hook payload referencing the path.
payload() {
  jq -n --arg p "$1" '{tool_name: "Edit", tool_input: {file_path: $p}}'
}

# make_fixture : build a temp bare repo + work-tree with one tracked file.
# Echoes "<git_dir> <work_tree>". The tracked file is "tracked.conf".
make_fixture() {
  local work_tree git_dir
  work_tree="$(mktemp -d)"
  git_dir="$(mktemp -d)/dotfiles.git"
  git init --bare --quiet "$git_dir"

  printf 'alias ll="ls -l"\n' > "$work_tree/tracked.conf"
  git --git-dir="$git_dir" --work-tree="$work_tree" \
    -c user.name="Test" -c user.email="test@example.com" \
    add -- "$work_tree/tracked.conf"
  git --git-dir="$git_dir" --work-tree="$work_tree" \
    -c user.name="Test" -c user.email="test@example.com" \
    commit --quiet -m "add tracked.conf"

  printf '%s %s' "$git_dir" "$work_tree"
}

# --- Tests: dotfiles-tracked.sh ----------------------------------------------

test_tracked_file_prompts_commit() {
  local fx git_dir work_tree out
  fx="$(make_fixture)"
  git_dir="${fx% *}"
  work_tree="${fx#* }"

  out="$(payload "$work_tree/tracked.conf" | \
    DOTFILES_GIT_DIR="$git_dir" DOTFILES_WORK_TREE="$work_tree" "$TRACKED")"

  assert "tracked file yields valid JSON" is_json "$out"
  assert "tracked output has systemMessage" \
    contains "tracked" "$(printf '%s' "$out" | jq -r '.systemMessage')"
  assert "tracked output names the file" \
    contains "tracked.conf" "$(printf '%s' "$out" | jq -r '.systemMessage')"
  assert_eq "tracked output sets hookEventName" "PostToolUse" \
    "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName')"
  assert "tracked output instructs to commit" contains "commit" \
    "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')"
  assert "tracked output shows the git command" contains "git --git-dir" \
    "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')"

  rm -rf "$work_tree" "${git_dir%/*}"
}

test_untracked_file_is_silent() {
  local fx git_dir work_tree out
  fx="$(make_fixture)"
  git_dir="${fx% *}"
  work_tree="${fx#* }"

  printf 'untracked\n' > "$work_tree/other.conf"
  out="$(payload "$work_tree/other.conf" | \
    DOTFILES_GIT_DIR="$git_dir" DOTFILES_WORK_TREE="$work_tree" "$TRACKED")"
  assert_eq "untracked file produces no output" "" "$out"

  rm -rf "$work_tree" "${git_dir%/*}"
}

test_missing_repo_is_silent() {
  local work_tree out
  work_tree="$(mktemp -d)"
  printf 'x\n' > "$work_tree/tracked.conf"

  out="$(payload "$work_tree/tracked.conf" | \
    DOTFILES_GIT_DIR="$work_tree/nope.git" DOTFILES_WORK_TREE="$work_tree" \
    "$TRACKED")"
  assert_eq "missing git_dir produces no output" "" "$out"

  rm -rf "$work_tree"
}

test_file_outside_work_tree_is_silent() {
  local fx git_dir work_tree outside out
  fx="$(make_fixture)"
  git_dir="${fx% *}"
  work_tree="${fx#* }"

  outside="$(mktemp -d)"
  printf 'x\n' > "$outside/tracked.conf"
  out="$(payload "$outside/tracked.conf" | \
    DOTFILES_GIT_DIR="$git_dir" DOTFILES_WORK_TREE="$work_tree" "$TRACKED")"
  assert_eq "file outside work-tree produces no output" "" "$out"

  rm -rf "$work_tree" "${git_dir%/*}" "$outside"
}

test_empty_path_is_silent() {
  local fx git_dir work_tree out
  fx="$(make_fixture)"
  git_dir="${fx% *}"
  work_tree="${fx#* }"

  out="$(jq -n '{tool_input: {}}' | \
    DOTFILES_GIT_DIR="$git_dir" DOTFILES_WORK_TREE="$work_tree" "$TRACKED")"
  assert_eq "empty file_path produces no output" "" "$out"

  rm -rf "$work_tree" "${git_dir%/*}"
}

# --- Runner ------------------------------------------------------------------

main() {
  test_tracked_file_prompts_commit
  test_untracked_file_is_silent
  test_missing_repo_is_silent
  test_file_outside_work_tree_is_silent
  test_empty_path_is_silent

  printf '\nAll %d assertions passed.\n' "$PASS_COUNT"
}

main "$@"
