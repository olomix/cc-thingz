# Dotfiles Plugin

## Overview
- Add a new Claude Code plugin named **dotfiles** to the `olomix-cc-thingz`
  marketplace.
- The plugin does two things:
  1. **Teaches** Claude Code how to operate a **bare-repo dotfiles** setup
     (git-dir separate from a `$HOME` work-tree, managed via a `dotfiles` git
     wrapper) — adding, committing, diffing, rolling back, and keeping secrets
     out.
  2. **Prompts to commit** whenever Claude edits a file that is *tracked* in the
     dotfiles repo. After such an edit, Claude asks the user whether to commit
     and offers a commit message (it never commits without consent).
- **Machine-independent**: nothing hardcodes a username or absolute path. The
  repo location is resolved from environment variables with sensible defaults
  (`DOTFILES_GIT_DIR` → `$HOME/.dotfiles`, `DOTFILES_WORK_TREE` → `$HOME`). If no
  repo is present, every component no-ops silently, so the plugin is harmless to
  any user who installs it without a dotfiles setup.
- Ships a **README** explaining the bare-repo concept and the one-time setup the
  user must perform to benefit from the plugin.

## Context (from discovery)
- Repo: `~/src/github.com/olomix/cc-thingz` — a personal Claude Code plugin
  marketplace. Marketplace manifest: `.claude-plugin/marketplace.json`.
- Existing plugins to mirror for structure & style:
  - `plugins/gh-lookup/` → `.claude-plugin/plugin.json`, `scripts/*.sh`,
    `skills/<name>/SKILL.md`, `agents/*.md`.
  - `plugins/fsnotes/` → same shape; uses an env override (`FSNOTES_DIR`) for
    machine-independent path resolution and testability — the pattern this
    plugin reuses via `DOTFILES_GIT_DIR` / `DOTFILES_WORK_TREE`.
- **Repo is PUBLIC** (`CLAUDE.md`): no personal data — no real emails, no
  `/Users/<name>/...` paths, no private hostnames. Use placeholders
  (`/path/to/...`, `$HOME`). Author attribution in manifests is allowed.
- Tests: pure-bash, no framework, under `tests/`. Existing suites use env
  overrides to target temp fixtures and never touch real user data
  (`tests/fsnotes_test.sh`, `tests/gh-lookup_test.sh`). New plugin follows suit.
- Hook mechanics (verified against official Claude Code docs):
  - Plugin hooks live at `hooks/hooks.json` (auto-discovered).
  - Schema: `{ "hooks": { "PostToolUse": [ { "matcher": "Write|Edit|MultiEdit",
    "hooks": [ { "type": "command", "command": "..." } ] } ] } }`.
  - Reference the bundled script via `"${CLAUDE_PLUGIN_ROOT}"/scripts/...`.
  - PostToolUse hook reads a JSON payload **on stdin**; edited path is at
    `.tool_input.file_path`; `.cwd` is also available.
  - To surface a message back: print JSON on stdout with `systemMessage`
    (user-visible) and `hookSpecificOutput.additionalContext` (injected into
    Claude's context), then `exit 0`. No output + `exit 0` = silent no-op.

## Development Approach
- **Testing approach**: Regular (implement the deterministic script, then cover
  it with bash tests) — matches the repo's existing convention.
- Complete each task fully before moving to the next.
- Make small, focused changes.
- **CRITICAL: every task with code changes MUST include new/updated tests.**
  - The testable unit is `scripts/dotfiles-tracked.sh`; tests drive it through a
    temporary bare repo + work-tree via `DOTFILES_GIT_DIR`/`DOTFILES_WORK_TREE`.
  - Cover success (tracked file → message) and error/edge cases (untracked file,
    no repo, file outside work-tree, missing `jq`).
- **CRITICAL: all tests must pass before starting the next task.**
- **CRITICAL: update this plan file when scope changes during implementation.**
- Run `shellcheck` on every shell file and fix all findings (per global rule:
  shell scripts must pass `shellcheck`).
- Keep all content machine-independent and free of personal data.

## Testing Strategy
- **Unit tests**: `tests/dotfiles_test.sh`, pure bash, no framework. Builds a
  throwaway bare repo + work-tree in a temp dir, points the script at them via
  the env overrides, and asserts stdout/exit behavior. Never touches the real
  `~/.dotfiles` or `$HOME`.
- **E2E tests**: none — this is a CLI/agent plugin with no UI.
- Lint: `shellcheck` on `scripts/dotfiles-tracked.sh` and `tests/dotfiles_test.sh`.

## Progress Tracking
- Mark completed items with `[x]` immediately when done.
- Add newly discovered tasks with ➕ prefix.
- Document issues/blockers with ⚠️ prefix.
- Keep the plan in sync with actual work done.

## What Goes Where
- **Implementation Steps** (`[ ]`): all files in this repo — plugin manifest,
  script, hook, skill, READMEs, marketplace registration, tests.
- **Post-Completion** (no checkboxes): installing/enabling the plugin locally and
  verifying the live commit-prompt behavior in a real Claude Code session, plus
  committing & pushing the public repo — manual, outside the plan.

## Implementation Steps

### Task 1: Scaffold the plugin and register it in the marketplace
- [x] Create `plugins/dotfiles/.claude-plugin/plugin.json` mirroring
      `plugins/gh-lookup/.claude-plugin/plugin.json` (fields: `name` `dotfiles`,
      `description`, `version` `0.1.0`, `author.name` `Oleg Lomaka`, `homepage`
      & `repository` `https://github.com/olomix/cc-thingz`, `license` `MIT`).
- [x] Add a `dotfiles` entry to `.claude-plugin/marketplace.json` `plugins`
      array (`name`, `source` `./plugins/dotfiles`, one-line `description`),
      keeping JSON valid and consistent with existing entries.
- [x] Verify both JSON files parse (e.g. `jq . <file>` exits 0).
- [x] No test needed for static manifests; the JSON-parse check above is the
      verification for this task.

### Task 2: Tracked-file detection script
- [x] Create `plugins/dotfiles/scripts/dotfiles-tracked.sh` (executable,
      `#!/usr/bin/env bash`, `set -euo pipefail`).
- [x] Resolve config machine-independently: `git_dir=${DOTFILES_GIT_DIR:-$HOME/.dotfiles}`,
      `work_tree=${DOTFILES_WORK_TREE:-$HOME}`. If `git_dir` is not a directory,
      `exit 0` (silent no-op).
- [x] Read the hook payload from **stdin**; extract `.tool_input.file_path` via
      `jq` (guard: if `jq` missing or path empty, `exit 0`).
- [x] Determine tracked status with
      `git --git-dir="$git_dir" --work-tree="$work_tree" ls-files
      --error-unmatch -- "$file_path"` (suppress output; non-zero = not tracked
      or outside work-tree → `exit 0`).
- [x] When tracked, print stdout JSON via `jq -n` containing both `systemMessage`
      and `hookSpecificOutput.{hookEventName:"PostToolUse", additionalContext}`.
      The message states the file is a tracked dotfile, instructs Claude to ask
      the user whether to commit **and to offer a commit message**, and shows the
      exact `git --git-dir=... --work-tree=... add/commit` invocation. `exit 0`.
- [x] Make the script robust to paths with spaces (quote everything; use `--`).
- [x] Write `tests/dotfiles_test.sh`: build temp `work_tree` + `git init --bare`
      `git_dir`; add & commit one file. Assert: (a) tracked file path on stdin →
      stdout is valid JSON containing the commit prompt; (b) untracked file → no
      output, exit 0; (c) `DOTFILES_GIT_DIR` pointing at a non-existent dir → no
      output, exit 0; (d) file path outside `work_tree` → no output, exit 0.
- [x] Run `shellcheck plugins/dotfiles/scripts/dotfiles-tracked.sh
      tests/dotfiles_test.sh` and fix all findings.
- [x] Run `tests/dotfiles_test.sh` — must pass before next task.

### Task 3: PostToolUse hook configuration
- [x] Create `plugins/dotfiles/hooks/hooks.json` with a `PostToolUse` entry,
      `matcher` `"Write|Edit|MultiEdit"`, one command hook invoking
      `"${CLAUDE_PLUGIN_ROOT}"/scripts/dotfiles-tracked.sh`.
- [x] Verify the file parses (`jq . hooks/hooks.json`).
- [x] Add a test assertion (extend `tests/dotfiles_test.sh`) that `hooks.json`
      is valid JSON and the referenced script path exists & is executable.
- [x] Run `tests/dotfiles_test.sh` — must pass before next task.

### Task 4: Skill that teaches the dotfiles workflow
- [x] Create `plugins/dotfiles/skills/dotfiles/SKILL.md` with YAML frontmatter
      (`name: dotfiles`, a trigger-rich `description` covering "work with my
      dotfiles / bare repo / track a config file / commit dotfile changes",
      `allowed-tools: Bash`).
- [x] Body teaches: the bare-repo model and the `dotfiles` wrapper
      (`git --git-dir="$DOTFILES_GIT_DIR" --work-tree="$DOTFILES_WORK_TREE"`,
      defaults `$HOME/.dotfiles` / `$HOME`); how to discover the repo and detect
      whether a file is tracked; add/commit/diff/log/rollback recipes;
      `status.showUntrackedFiles no` rationale; secrets caution (never add
      private keys / credentials / history files).
- [x] Body states the **commit-prompt rule** as durable instruction: after
      editing any file tracked in the dotfiles repo, ask the user whether to
      commit and **offer a proposed commit message**; commit only on consent.
      This backs up the hook (hook = trigger, skill = instruction).
- [x] Use only placeholder paths / `$HOME` — no personal data.
- [x] No automated test for prose; verification is the self-review in Task 6.

### Task 5: Plugin README (setup guide)
- [ ] Create `plugins/dotfiles/README.md` explaining: what a bare-repo dotfiles
      setup is and why; the one-time user setup (`git init --bare`,
      `config status.showUntrackedFiles no`, the shell `dotfiles` alias);
      the optional `DOTFILES_GIT_DIR` / `DOTFILES_WORK_TREE` overrides for
      non-default locations; how installing the plugin enables the teaching skill
      and the commit-prompt hook; and the secrets caution.
- [ ] Use placeholder paths only (public repo).

### Task 6: Verify acceptance criteria
- [ ] Verify all Overview requirements are met: skill teaches the workflow; hook
      prompts to commit on edits to tracked files and offers a message;
      everything is env-var configurable with safe no-op defaults; READMEs
      present.
- [ ] Re-read every new file for placeholders/personal data; confirm no
      `/Users/<name>` paths, emails, or hostnames leaked in.
- [ ] Run `shellcheck` on all shell files — all issues fixed.
- [ ] Run `tests/dotfiles_test.sh` — full suite passes.
- [ ] Confirm all new JSON parses (`plugin.json`, `marketplace.json`,
      `hooks/hooks.json`).

### Task 7: Update repository documentation
- [ ] Add a `## dotfiles` section to the top-level `README.md` describing the
      plugin (mirroring the fsnotes / gh-lookup sections), including an
      **Install** snippet (`/plugin install dotfiles`) and a
      **Repo resolution** note documenting `DOTFILES_GIT_DIR` /
      `DOTFILES_WORK_TREE` and their defaults.
- [ ] Update the intro line ("currently ships two plugins…") to reflect three.
- [ ] Add the new shellcheck/test commands to the **Development** section.

## Technical Details
- **Config resolution** (script & skill identical):
  - `git_dir = ${DOTFILES_GIT_DIR:-$HOME/.dotfiles}`
  - `work_tree = ${DOTFILES_WORK_TREE:-$HOME}`
- **Tracked check**: `git --git-dir="$git_dir" --work-tree="$work_tree"
  ls-files --error-unmatch -- "$file_path"` → exit 0 means tracked.
- **Hook payload (stdin)**: `.tool_input.file_path`, `.cwd`, `.tool_name`.
- **Hook stdout (only when tracked)**:
  ```json
  {
    "systemMessage": "<file> is tracked in your dotfiles repo …",
    "hookSpecificOutput": {
      "hookEventName": "PostToolUse",
      "additionalContext": "Ask the user whether to commit; offer a message. Commit with: git --git-dir=… --work-tree=… add -- <file> && … commit -m \"<msg>\"."
    }
  }
  ```
- **No-op contract**: missing repo, missing `jq`, empty/external path, or
  untracked file → no stdout, `exit 0`. Never blocks the edit (never `exit 2`).
- **Test isolation**: `DOTFILES_GIT_DIR`/`DOTFILES_WORK_TREE` point at a
  `mktemp -d` sandbox; real `$HOME` is never read or written.

## Post-Completion
*Items requiring manual intervention or external systems - informational only*

**Manual verification**:
- Install/enable the plugin locally (`/plugin marketplace add` the local repo or
  `olomix/cc-thingz`, then `/plugin install dotfiles`), set up a throwaway bare
  repo, edit a tracked file via Claude, and confirm Claude surfaces the
  commit prompt with a proposed message and commits only on consent.
- Confirm the plugin stays silent when no dotfiles repo exists.

**External system updates**:
- Commit and push the public `olomix/cc-thingz` repo (commit message without AI
  attribution, per repo/global rules).
