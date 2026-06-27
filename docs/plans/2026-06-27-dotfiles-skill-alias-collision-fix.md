# Fix dotfiles SKILL.md git-wrapper alias collision

## Overview
- **Bug**: `plugins/dotfiles/skills/dotfiles/SKILL.md` tells Claude to define a
  shell **function** named `dotfiles` to wrap git:
  `dotfiles() { git --git-dir="$git_dir" --work-tree="$work_tree" "$@"; }`
  (line 54). The plugin's own README instructs users to add an
  `alias dotfiles='git --git-dir=... --work-tree=...'` to their shell. In zsh,
  defining a function whose name is an existing alias is a hard parse error:
  `defining function based on alias 'dotfiles'` → `parse error near '()'`. So
  every recipe in the skill breaks on exactly the setup the plugin recommends.
- **Root cause**: putting *any* fixed name (`dotfiles`, `dfgit`, …) into the
  function/alias namespace risks colliding with a user alias of that name.
  Renaming the helper does not fix it — it only moves the collision.
- **Fix**: stop defining a wrapper function. Use a shell **array variable**
  holding the git command + flags, invoked as `"${dfgit[@]}" <args>`. A variable
  lives in a separate namespace from aliases, and `"${dfgit[@]}"` is a parameter
  expansion that the shell never alias-expands — so it cannot collide with any
  alias, in zsh or bash. Verified working in both shells with a colliding
  `dotfiles`/`df` alias defined.
- **Benefit**: the skill's recipes work regardless of the user's interactive
  aliases; the documented setup (with the `dotfiles` alias) no longer breaks the
  skill.

## Context (from discovery)
- File to change: `plugins/dotfiles/skills/dotfiles/SKILL.md` — the wrapper
  definition (line ~51-55) and every recipe that calls `dotfiles <args>` (the
  detection check and the add/commit/diff/log/checkout recipes).
- **No change needed** to `plugins/dotfiles/scripts/dotfiles-tracked.sh` — it
  already calls `git --git-dir=... --work-tree=...` directly (no function), so
  the hook path is unaffected.
- **No change needed** to `plugins/dotfiles/README.md` or the top-level
  `README.md` — neither defines a shell function; the README's user-facing
  `dotfiles` alias is correct and stays.
- Repo is **public** (`CLAUDE.md`): no personal data, placeholder paths only.
- Test convention: pure-bash suites under `tests/`, no framework, run via
  `tests/<name>_test.sh`; lint with `shellcheck`. Existing suite for this plugin:
  `tests/dotfiles_test.sh`.
- Verified facts (empirically, this session):
  - `dotfiles() {...}` with an active `dotfiles` alias → parse error in
    interactive zsh (alias expansion on).
  - `dfgit=(git --git-dir=... --work-tree=...)` then `"${dfgit[@]}" ...` → runs
    git directly, no alias fired, no parse error, in both `zsh -i` and `bash`,
    even when an alias of the same name exists.

## Development Approach
- **Testing approach**: Regular (apply the fix, then add a regression test).
- This is a small, well-understood bug fix — keep scope minimal (YAGNI).
- **CRITICAL: the code/content change MUST ship with a regression test** that
  would have caught the original bug.
- **CRITICAL: all tests must pass before the task is considered done.**
- **CRITICAL: update this plan file if scope changes.**
- Run `shellcheck` on any shell file touched/added and fix all findings.
- Keep everything machine-independent and free of personal data.

## Testing Strategy
- **Unit/regression tests** (extend `tests/dotfiles_test.sh`, pure bash):
  1. **Guard against reintroduction**: assert `SKILL.md` does **not** define a
     shell function for the wrapper — grep that no line matches a function
     definition of the wrapper name (e.g. `^[A-Za-z_][A-Za-z0-9_]*\(\) \{` near
     the git-dir/work-tree wrapper). The skill must use the array-variable form.
  2. **Positive behavior**: reproduce the failure mode and prove the fix —
     under `zsh -i` (alias expansion on) with `alias dotfiles='...'` defined,
     run the array-variable pattern
     (`dfgit=(git ...); "${dfgit[@]}" --version`) and assert it exits 0 with no
     `parse error` / `defining function based on alias` on stderr. Repeat under
     `bash` for portability.
  3. (Optional sanity) assert the literal anti-pattern
     `dotfiles() { ...` would still fail under the same `zsh -i` + alias setup,
     documenting *why* the function form is banned. Skip if it makes the test
     flaky across environments.
- **E2E tests**: none (CLI/agent plugin, no UI).
- Lint: `shellcheck tests/dotfiles_test.sh`.

## Progress Tracking
- Mark completed items with `[x]` immediately when done.
- Add newly discovered tasks with ➕ prefix.
- Document issues/blockers with ⚠️ prefix.
- Keep the plan in sync with actual work done.

## What Goes Where
- **Implementation Steps** (`[ ]`): edits to `SKILL.md` and `tests/dotfiles_test.sh`.
- **Post-Completion** (no checkboxes): reinstall/update the installed plugin so a
  live session picks up the fix; manual verification in a real Claude Code
  session; commit & push the public repo.

## Implementation Steps

### Task 1: Replace the wrapper function with an array variable in SKILL.md
- [x] In `plugins/dotfiles/skills/dotfiles/SKILL.md`, replace the wrapper
      definition block (the `git_dir`/`work_tree` setup that ends with
      `dotfiles() { ... }`) with the array form:
      `dfgit=(git --git-dir="$git_dir" --work-tree="$work_tree")`, and add a
      one-line note explaining the helper must NOT be a function/alias (collides
      with the user's `dotfiles` alias in zsh) and that `"${dfgit[@]}"` is
      alias-proof.
- [x] Update every recipe that calls `dotfiles <args>` to `"${dfgit[@]}" <args>`:
      the tracked-file detection (`ls-files --error-unmatch`), `add`,
      `commit --only`, `diff` / `diff --staged`, `status`, `log --oneline`,
      `checkout` (discard + restore), and the commit-prompt-rule snippet.
- [x] Keep the user-facing `alias dotfiles='...'` example (it documents the
      human shorthand) and the `status.showUntrackedFiles no` prose intact;
      ensure that prose no longer implies Claude should redefine `dotfiles` as a
      function.
- [x] Re-read the file: confirm no remaining `() {` wrapper definition, no
      personal data, placeholder paths only.
- [x] (Tested in Task 2 — this task changes skill content, the regression test
      lands next.)

### Task 2: Add regression tests for the alias-collision fix
- [x] Extend `tests/dotfiles_test.sh` with a test asserting `SKILL.md` contains
      no wrapper **function** definition (grep guard against reintroduction).
- [x] Add a test that, under `zsh -i` with `alias dotfiles='git ...'` active,
      the array-variable pattern runs git and exits 0 with no `parse error` /
      `defining function based on alias` on stderr; repeat under `bash`.
- [x] Guard the zsh test so it skips cleanly (not fails) if `zsh` is unavailable
      on the runner, to keep the suite portable.
- [x] Run `shellcheck tests/dotfiles_test.sh` and fix all findings.
- [x] Run `tests/dotfiles_test.sh` — all tests (existing + new) must pass.

### Task 3: Verify acceptance criteria
- [ ] Confirm `SKILL.md` uses only the array-variable wrapper and every recipe
      calls `"${dfgit[@]}"` (no `dotfiles <args>` executable recipe remains).
- [ ] Confirm `scripts/dotfiles-tracked.sh`, both READMEs, and `hooks.json` are
      unchanged and still correct.
- [ ] Run the full `tests/dotfiles_test.sh` suite and `shellcheck` on all shell
      files — everything passes.
- [ ] Re-scan all changed content for personal data — none present.

## Technical Details
- **Canonical wrapper (new)**:
  ```sh
  git_dir="${DOTFILES_GIT_DIR:-$HOME/.dotfiles}"
  work_tree="${DOTFILES_WORK_TREE:-$HOME}"
  dfgit=(git --git-dir="$git_dir" --work-tree="$work_tree")   # call: "${dfgit[@]}" <args>
  ```
- **Why it is alias-proof**: variable assignment is never alias-expanded;
  `"${dfgit[@]}"` is a parameter expansion, not a command word in the alias
  namespace, so no alias of any name can intercept it. Works identically in zsh
  and bash; array syntax is supported by both.
- **Anti-pattern to avoid (banned)**: `dotfiles() { ... }` or any
  `name() { git ... }` wrapper — collides with a user alias of that name in zsh.
- **Recipe rewrite map**: `dotfiles X -- "$file"` → `"${dfgit[@]}" X -- "$file"`.

## Post-Completion
*Items requiring manual intervention or external systems - informational only*

**Manual verification**:
- Update/reinstall the installed `dotfiles` plugin (the marketplace cache copy)
  so a running Claude Code session picks up the fixed skill.
- In a shell that has the `dotfiles` alias defined, ask Claude to run a dotfiles
  recipe (e.g. check tracked status / show status) and confirm no
  `parse error` / `defining function based on alias` occurs and the command
  succeeds.

**External system updates**:
- Commit and push the public `olomix/cc-thingz` repo (commit message without AI
  attribution, per repo/global rules).
