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

In the recipes below, set these once so every command is consistent. Hold the
git invocation in an **array variable** and call it as `"${dfgit[@]}"` — do
**not** define a shell function or alias for it. A function/alias named
`dotfiles` collides with the user's `dotfiles` alias (in zsh, `dotfiles() {...}`
with that alias active is a hard parse error). A variable lives in a separate
namespace and `"${dfgit[@]}"` is a parameter expansion the shell never
alias-expands, so it is alias-proof in both zsh and bash:

```sh
git_dir="${DOTFILES_GIT_DIR:-$HOME/.dotfiles}"
work_tree="${DOTFILES_WORK_TREE:-$HOME}"
dfgit=(git --git-dir="$git_dir" --work-tree="$work_tree")   # call: "${dfgit[@]}" <args>
```

## Detecting whether a file is tracked

Before adding or committing, check that the file is actually tracked. The
authoritative test is `ls-files --error-unmatch`: it exits 0 when the path is
tracked and non-zero when it is untracked or lies outside the work-tree.

```sh
if "${dfgit[@]}" ls-files --error-unmatch -- "$file" >/dev/null 2>&1; then
  echo "tracked"
else
  echo "not tracked"
fi
```

Always pass paths after `--` and quote them so names with spaces work.

## Recipes

Add a new file under version control (then commit). Pass the path to
`commit --only` so only this file is committed, even if the shared dotfiles
index already holds unrelated staged changes:

```sh
"${dfgit[@]}" add -- "$file"
"${dfgit[@]}" commit --only -m "Add <file>" -- "$file"
```

Stage and commit an existing tracked file's change. `commit --only` takes the
working-tree content of the named path directly — no separate `add`, and other
staged paths are left untouched:

```sh
"${dfgit[@]}" commit --only -m "<message>" -- "$file"
```

See what changed (working tree vs. last commit), or only staged changes:

```sh
"${dfgit[@]}" diff -- "$file"
"${dfgit[@]}" diff --staged -- "$file"
```

Inspect history:

```sh
"${dfgit[@]}" status
"${dfgit[@]}" log --oneline -- "$file"
```

Roll back: discard an uncommitted change, or restore a file to an earlier
commit:

```sh
"${dfgit[@]}" checkout -- "$file"            # discard working-tree change
"${dfgit[@]}" checkout <commit> -- "$file"   # restore from a past commit
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
message, then on consent commit only this file (so unrelated staged changes in
the shared dotfiles index are not swept in):

```sh
"${dfgit[@]}" commit --only -m "<message>" -- "$file"
```
