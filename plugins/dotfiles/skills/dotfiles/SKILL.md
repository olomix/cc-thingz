---
name: dotfiles
description: >-
  Operate a bare-repo dotfiles setup (a git-dir separate from a `$HOME`
  work-tree, driven through a `dotfiles` git wrapper). Use whenever the user
  wants to work with their dotfiles, track a config file, add/commit/diff/log
  or roll back a dotfile, or check whether a file is tracked ("manage my
  dotfiles", "is this file in my dotfiles repo?", "commit my dotfile change",
  "track this config file"). Resolves the repo from `DOTFILES_GIT_DIR` /
  `DOTFILES_WORK_TREE` (defaults `$HOME/.dotfiles` / `$HOME`).
allowed-tools: Bash
---

You operate the user's **bare-repo dotfiles** setup.

## The bare-repo model

A dotfiles bare repo keeps the **git directory** separate from the **work
tree**. The git-dir holds only repository data (it has no work-tree of its
own); the work-tree is the user's `$HOME`, where the actual config files live
in place. This lets `$HOME` be version-controlled without a `.git` folder
sitting at the top of the home directory and without nesting other repos
inside one giant repo.

Because there is no enclosing `.git`, every git command must be told where the
repo and work-tree are. That is the `dotfiles` wrapper:

```sh
git --git-dir="$DOTFILES_GIT_DIR" --work-tree="$DOTFILES_WORK_TREE" <args>
```

Users typically alias this as `dotfiles` in their shell:

```sh
alias dotfiles='git --git-dir="$HOME/.dotfiles" --work-tree="$HOME"'
```

## Resolving the repo

Resolve the two locations machine-independently — never hardcode a username or
absolute path:

- `git_dir = ${DOTFILES_GIT_DIR:-$HOME/.dotfiles}`
- `work_tree = ${DOTFILES_WORK_TREE:-$HOME}`

If `git_dir` is not a directory, there is no dotfiles setup on this machine —
say so and do nothing rather than guessing.

In the recipes below, set these once so every command is consistent:

```sh
git_dir="${DOTFILES_GIT_DIR:-$HOME/.dotfiles}"
work_tree="${DOTFILES_WORK_TREE:-$HOME}"
dotfiles() { git --git-dir="$git_dir" --work-tree="$work_tree" "$@"; }
```

## Detecting whether a file is tracked

Before adding or committing, check that the file is actually tracked. The
authoritative test is `ls-files --error-unmatch`: it exits 0 when the path is
tracked and non-zero when it is untracked or lies outside the work-tree.

```sh
if dotfiles ls-files --error-unmatch -- "$file" >/dev/null 2>&1; then
  echo "tracked"
else
  echo "not tracked"
fi
```

Always pass paths after `--` and quote them so names with spaces work.

## Recipes

Add a new file under version control (then commit):

```sh
dotfiles add -- "$file"
dotfiles commit -m "Add <file>"
```

Stage and commit an existing tracked file's change:

```sh
dotfiles add -- "$file"
dotfiles commit -m "<message>"
```

See what changed (working tree vs. last commit), or only staged changes:

```sh
dotfiles diff -- "$file"
dotfiles diff --staged -- "$file"
```

Inspect history:

```sh
dotfiles status
dotfiles log --oneline -- "$file"
```

Roll back: discard an uncommitted change, or restore a file to an earlier
commit:

```sh
dotfiles checkout -- "$file"            # discard working-tree change
dotfiles checkout <commit> -- "$file"   # restore from a past commit
```

## `status.showUntrackedFiles no`

The setup sets `dotfiles config status.showUntrackedFiles no` once at init.
Without it, every untracked file in `$HOME` (the entire home directory) would
flood `dotfiles status`, making it useless. With it, `status` reports only
tracked files — exactly the dotfiles you manage. Keep this setting; do not
suggest removing it.

## Secrets caution

`$HOME` is full of sensitive material. Never add to the dotfiles repo:

- private keys and credentials (`~/.ssh/id_*`, `*.pem`, `*.key`,
  `~/.aws/credentials`, `~/.netrc`, token/cookie files);
- shell/REPL **history** files (`.bash_history`, `.zsh_history`,
  `.python_history`) — they leak commands and secrets;
- caches, state, and large binaries.

When the user asks to track something that may contain secrets, flag it and
confirm before adding. This repo is for configuration, not secrets.

## Commit-prompt rule (durable instruction)

After you edit **any file that is tracked in the dotfiles repo**, ask the user
whether to commit the change and **offer a proposed commit message** describing
it. Commit only with their explicit consent — never commit automatically.

This is the same behavior the plugin's PostToolUse hook triggers (the hook is
the trigger; this instruction is the rule that backs it up, so the prompt
happens even if the hook output is missed). Propose a concise, descriptive
message, then on consent run:

```sh
dotfiles add -- "$file" && dotfiles commit -m "<message>"
```
