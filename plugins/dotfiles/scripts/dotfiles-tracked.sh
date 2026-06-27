#!/usr/bin/env bash
# PostToolUse hook: when Claude edits a file tracked in a bare-repo dotfiles
# setup, print a JSON message prompting a commit. Otherwise stay silent.
#
# Reads the hook payload from stdin (JSON with .tool_input.file_path). The repo
# location is resolved machine-independently from env vars with HOME-based
# defaults, so the hook is a harmless no-op for users without a dotfiles repo.
#
# No-op contract: missing repo, missing jq, empty/external path, or an untracked
# file all yield no stdout and exit 0. The hook never blocks an edit.
set -euo pipefail

git_dir="${DOTFILES_GIT_DIR:-$HOME/.dotfiles}"
work_tree="${DOTFILES_WORK_TREE:-$HOME}"

# No dotfiles repo present → nothing to do.
[[ -d "$git_dir" ]] || exit 0

# jq parses the stdin payload and renders the stdout message; without it we
# cannot safely do either, so no-op.
command -v jq >/dev/null 2>&1 || exit 0

payload="$(cat)"
file_path="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty')"
[[ -n "$file_path" ]] || exit 0

# Tracked check. Non-zero means untracked or outside the work-tree → no-op.
# Redirect both streams: ls-files prints the path on match and an error on miss.
if ! git --git-dir="$git_dir" --work-tree="$work_tree" \
  ls-files --error-unmatch -- "$file_path" >/dev/null 2>&1; then
  exit 0
fi

commit_cmd="git --git-dir=\"$git_dir\" --work-tree=\"$work_tree\" add -- \"$file_path\" && git --git-dir=\"$git_dir\" --work-tree=\"$work_tree\" commit -m \"<message>\""

system_message="$file_path is tracked in your dotfiles repo. Ask the user whether to commit this change, and offer a proposed commit message. Commit only with their consent."

additional_context="The edited file \"$file_path\" is tracked in the user's bare-repo dotfiles ($git_dir). Ask the user whether to commit the change and propose a concise commit message describing it. Do not commit without explicit consent. When the user agrees, run: $commit_cmd"

jq -n \
  --arg msg "$system_message" \
  --arg ctx "$additional_context" \
  '{
     systemMessage: $msg,
     hookSpecificOutput: {
       hookEventName: "PostToolUse",
       additionalContext: $ctx
     }
   }'

exit 0
