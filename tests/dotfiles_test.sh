#!/usr/bin/env bash
# Unit tests for the dotfiles plugin. Pure bash, no framework.
# Run: tests/dotfiles_test.sh  (exits non-zero on first failure)
set -euo pipefail

# Repo root is the parent of this tests/ directory, regardless of cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_DIR="$REPO_ROOT/plugins/dotfiles"
TRACKED="$PLUGIN_DIR/scripts/dotfiles-tracked.sh"
HOOKS_JSON="$PLUGIN_DIR/hooks/hooks.json"
SKILL_MD="$PLUGIN_DIR/skills/dotfiles/SKILL.md"

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

# not_contains <needle> <haystack> : true when haystack lacks needle.
not_contains() {
  case "$2" in
    *"$1"*) return 1 ;;
    *) return 0 ;;
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

# make_fixture [tracked_name] : build a temp bare repo + work-tree with one
# tracked file (default name "tracked.conf"). Sets globals FX_GIT_DIR and
# FX_WORK_TREE rather than echoing a space-joined string, so paths and file
# names containing spaces survive intact.
make_fixture() {
  local tracked_name="${1:-tracked.conf}"
  FX_WORK_TREE="$(mktemp -d)"
  FX_GIT_DIR="$(mktemp -d)/dotfiles.git"
  git init --bare --quiet "$FX_GIT_DIR"

  printf 'alias ll="ls -l"\n' > "$FX_WORK_TREE/$tracked_name"
  git --git-dir="$FX_GIT_DIR" --work-tree="$FX_WORK_TREE" \
    -c user.name="Test" -c user.email="test@example.com" \
    add -- "$FX_WORK_TREE/$tracked_name"
  git --git-dir="$FX_GIT_DIR" --work-tree="$FX_WORK_TREE" \
    -c user.name="Test" -c user.email="test@example.com" \
    commit --quiet -m "add $tracked_name"
}

# --- Tests: dotfiles-tracked.sh ----------------------------------------------

test_tracked_file_prompts_commit() {
  local git_dir work_tree out ctx
  make_fixture
  git_dir="$FX_GIT_DIR"
  work_tree="$FX_WORK_TREE"

  out="$(payload "$work_tree/tracked.conf" | \
    DOTFILES_GIT_DIR="$git_dir" DOTFILES_WORK_TREE="$work_tree" "$TRACKED")"
  ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')"

  assert "tracked file yields valid JSON" is_json "$out"
  assert "tracked output has systemMessage" \
    contains "tracked" "$(printf '%s' "$out" | jq -r '.systemMessage')"
  assert "tracked output names the file" \
    contains "tracked.conf" "$(printf '%s' "$out" | jq -r '.systemMessage')"
  assert_eq "tracked output sets hookEventName" "PostToolUse" \
    "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName')"
  # The commit command is load-bearing output: assert it names the actual file
  # and uses a path-scoped commit, not just the substrings.
  assert "tracked output references the edited file path" \
    contains "$work_tree/tracked.conf" "$ctx"
  assert "tracked output has a path-scoped commit command" \
    contains "commit --only -m" "$ctx"
  assert "tracked output ends the commit with the file pathspec" \
    contains "-- $work_tree/tracked.conf" "$ctx"

  rm -rf "$work_tree" "${git_dir%/*}"
}

# A tracked filename containing shell metacharacters must be %q-escaped in the
# suggested command, so copying it into Bash cannot trigger command
# substitution (e.g. a file literally named with a '$(...)' fragment).
test_commit_command_escapes_shell_metacharacters() {
  local git_dir work_tree out cmd
  # The single-quoted name is an intentional literal, not an expansion.
  # shellcheck disable=SC2016
  make_fixture 'evil$(touch PWNED).conf'
  git_dir="$FX_GIT_DIR"
  work_tree="$FX_WORK_TREE"

  out="$(payload "$work_tree/evil\$(touch PWNED).conf" | \
    DOTFILES_GIT_DIR="$git_dir" DOTFILES_WORK_TREE="$work_tree" "$TRACKED")"
  # Isolate just the suggested command (after "run: "); the descriptive prose
  # naturally names the raw file, but only the command would be executed.
  cmd="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext' \
    | sed 's/.*run: //')"

  assert "suggested command escapes the substitution metacharacters" \
    contains 'evil\$\(touch\ PWNED\).conf' "$cmd"
  # Literal needle, not an expansion.
  # shellcheck disable=SC2016
  assert "suggested command holds no runnable substitution" \
    not_contains '$(touch PWNED)' "$cmd"

  rm -rf "$work_tree" "${git_dir%/*}"
}

test_untracked_file_is_silent() {
  local git_dir work_tree out
  make_fixture
  git_dir="$FX_GIT_DIR"
  work_tree="$FX_WORK_TREE"

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
  local git_dir work_tree outside out
  make_fixture
  git_dir="$FX_GIT_DIR"
  work_tree="$FX_WORK_TREE"

  outside="$(mktemp -d)"
  printf 'x\n' > "$outside/tracked.conf"
  out="$(payload "$outside/tracked.conf" | \
    DOTFILES_GIT_DIR="$git_dir" DOTFILES_WORK_TREE="$work_tree" "$TRACKED")"
  assert_eq "file outside work-tree produces no output" "" "$out"

  rm -rf "$work_tree" "${git_dir%/*}" "$outside"
}

test_empty_path_is_silent() {
  local git_dir work_tree out
  make_fixture
  git_dir="$FX_GIT_DIR"
  work_tree="$FX_WORK_TREE"

  out="$(jq -n '{tool_input: {}}' | \
    DOTFILES_GIT_DIR="$git_dir" DOTFILES_WORK_TREE="$work_tree" "$TRACKED")"
  assert_eq "empty file_path produces no output" "" "$out"

  rm -rf "$work_tree" "${git_dir%/*}"
}

# A non-JSON payload must not make the hook exit non-zero or print anything —
# otherwise a malformed harness payload would surface a hook error on every edit.
test_malformed_payload_is_silent() {
  local git_dir work_tree out status
  make_fixture
  git_dir="$FX_GIT_DIR"
  work_tree="$FX_WORK_TREE"

  set +e
  out="$(printf 'not json at all' | \
    DOTFILES_GIT_DIR="$git_dir" DOTFILES_WORK_TREE="$work_tree" "$TRACKED" 2>/dev/null)"
  status=$?
  set -e
  assert_eq "malformed payload exits 0" "0" "$status"
  assert_eq "malformed payload produces no output" "" "$out"

  rm -rf "$work_tree" "${git_dir%/*}"
}

# The plan requires tracked-file detection to be robust to paths with spaces.
test_tracked_file_with_spaces() {
  local git_dir work_tree out
  make_fixture "my config.conf"
  git_dir="$FX_GIT_DIR"
  work_tree="$FX_WORK_TREE"

  out="$(payload "$work_tree/my config.conf" | \
    DOTFILES_GIT_DIR="$git_dir" DOTFILES_WORK_TREE="$work_tree" "$TRACKED")"
  assert "spaced tracked file yields valid JSON" is_json "$out"
  assert "spaced tracked output names the file" \
    contains "my config.conf" "$(printf '%s' "$out" | jq -r '.systemMessage')"

  rm -rf "$work_tree" "${git_dir%/*}"
}

# --- Tests: hooks.json -------------------------------------------------------

test_hooks_json_is_valid_and_wired() {
  assert "hooks.json is valid JSON" is_json "$(cat "$HOOKS_JSON")"

  local matcher cmd
  matcher="$(jq -r '.hooks.PostToolUse[0].matcher' "$HOOKS_JSON")"
  assert_eq "hooks.json matches Write|Edit|MultiEdit" \
    "Write|Edit|MultiEdit" "$matcher"

  cmd="$(jq -r '.hooks.PostToolUse[0].hooks[0].command' "$HOOKS_JSON")"
  assert "hook command references the bundled script" \
    contains "dotfiles-tracked.sh" "$cmd"
  assert "hook command uses CLAUDE_PLUGIN_ROOT" \
    contains 'CLAUDE_PLUGIN_ROOT' "$cmd"

  assert "referenced script exists and is executable" test -x "$TRACKED"
}

# --- Tests: SKILL.md alias-collision fix -------------------------------------

# Regression guard: the skill must NOT tell Claude to define a shell function
# (or alias) to wrap git. A function/alias named `dotfiles` collides with the
# user's `dotfiles` alias and is a hard parse error in zsh. Grep for any
# function-definition line (`name() {`) inside the SKILL's code fences.
test_skill_has_no_wrapper_function() {
  local hits
  # A wrapper function would look like `dotfiles() {`, `dfgit() {`, etc.
  # Match an identifier immediately followed by `()` and an opening brace.
  hits="$(grep -nE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{' \
    "$SKILL_MD" || true)"
  assert_eq "SKILL.md defines no wrapper function" "" "$hits"
}

# The skill must use the alias-proof array-variable form.
test_skill_uses_array_variable() {
  assert "SKILL.md defines the dfgit array variable" \
    contains 'dfgit=(git --git-dir=' "$(cat "$SKILL_MD")"
  # Literal needle: we are searching for this exact text in the skill, not
  # expanding it.
  # shellcheck disable=SC2016
  assert "SKILL.md invokes the wrapper as a parameter expansion" \
    contains '"${dfgit[@]}"' "$(cat "$SKILL_MD")"
}

# Positive behavior under a shell: with a colliding `dotfiles` alias active,
# the array-variable pattern must run git and exit 0 with no parse error /
# "defining function based on alias" on stderr. <shell> <extra-args...> lets
# the caller turn on interactive alias expansion (zsh -i).
assert_array_pattern_runs() {
  local shell="$1"
  shift
  local script err status
  # Define a colliding alias, then exercise the documented pattern. `--version`
  # avoids needing a real repo while still proving git was invoked. The script
  # is a literal run by the target shell; nothing here should expand now.
  # shellcheck disable=SC2016
  script='alias dotfiles="git --git-dir=/x --work-tree=/y"
alias df="git --git-dir=/x --work-tree=/y"
git_dir="/tmp/x"; work_tree="/tmp/y"
dfgit=(git --git-dir="$git_dir" --work-tree="$work_tree")
"${dfgit[@]}" --version >/dev/null'
  set +e
  err="$("$shell" "$@" -c "$script" 2>&1 >/dev/null)"
  status=$?
  set -e
  assert_eq "$shell: array pattern with colliding alias exits 0" "0" "$status"
  assert "$shell: array pattern emits no parse error" \
    not_contains "parse error" "$err"
  assert "$shell: array pattern does not collide with the alias" \
    not_contains "defining function based on alias" "$err"
}

test_array_pattern_runs_in_bash() {
  assert_array_pattern_runs bash
}

# Run the same check under interactive zsh (alias expansion on), which is where
# the original `dotfiles() {...}` bug surfaced. Skip cleanly when zsh is absent
# so the suite stays portable across runners.
test_array_pattern_runs_in_zsh() {
  if ! command -v zsh >/dev/null 2>&1; then
    printf 'skip - zsh not installed; skipping interactive-zsh check\n'
    return 0
  fi
  assert_array_pattern_runs zsh -i
}

# --- Runner ------------------------------------------------------------------

main() {
  test_tracked_file_prompts_commit
  test_commit_command_escapes_shell_metacharacters
  test_untracked_file_is_silent
  test_missing_repo_is_silent
  test_file_outside_work_tree_is_silent
  test_empty_path_is_silent
  test_malformed_payload_is_silent
  test_tracked_file_with_spaces
  test_hooks_json_is_valid_and_wired
  test_skill_has_no_wrapper_function
  test_skill_uses_array_variable
  test_array_pattern_runs_in_bash
  test_array_pattern_runs_in_zsh

  printf '\nAll %d assertions passed.\n' "$PASS_COUNT"
}

main "$@"
