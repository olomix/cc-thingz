# dotfiles

A Claude Code plugin that teaches Claude to operate a **bare-repo dotfiles**
setup and prompts to commit whenever you edit a tracked dotfile.

## What is a bare-repo dotfiles setup?

A dotfiles bare repo keeps the **git directory** separate from the **work
tree**. The git-dir holds only repository data (it has no work-tree of its
own); the work-tree is your `$HOME`, where the actual config files live in
place. This version-controls `$HOME` without a `.git` folder sitting at the top
of your home directory and without nesting other repos inside one giant repo.

Because there is no enclosing `.git`, every git command must be told where the
repo and work-tree are. That is the `dotfiles` wrapper:

```sh
git --git-dir="$HOME/.dotfiles" --work-tree="$HOME" <args>
```

## What the plugin provides

- A **`dotfiles` skill** that teaches Claude the bare-repo model and the
  add/commit/diff/log/rollback recipes, how to detect whether a file is
  tracked, and the secrets caution.
- A **PostToolUse hook** that, after Claude edits a file tracked in your
  dotfiles repo, surfaces a prompt to commit — Claude asks whether to commit
  and offers a proposed message. It never commits without your consent.

If no dotfiles repo is present, the hook is a silent no-op, so the plugin is
harmless to install even without a dotfiles setup.

## Install

```
/plugin marketplace add olomix/cc-thingz
/plugin install dotfiles
```

## One-time setup

Create the bare repo, silence untracked-file noise, and add the shell alias:

```sh
# 1. Initialize the bare repo (git-dir at ~/.dotfiles, work-tree at $HOME)
git init --bare "$HOME/.dotfiles"

# 2. Report only tracked files in `status` (otherwise all of $HOME shows up)
git --git-dir="$HOME/.dotfiles" --work-tree="$HOME" \
  config status.showUntrackedFiles no

# 3. Add a shell alias (in ~/.bashrc, ~/.zshrc, etc.)
alias dotfiles='git --git-dir="$HOME/.dotfiles" --work-tree="$HOME"'
```

After that, manage files with the alias:

```sh
dotfiles add -- ~/.zshrc
dotfiles commit -m "Add zshrc"
dotfiles status
dotfiles log --oneline
```

## Repo resolution

The plugin resolves the two locations from environment variables, with safe
defaults — nothing hardcodes a username or absolute path:

| Variable             | Default          | Meaning                          |
| -------------------- | ---------------- | -------------------------------- |
| `DOTFILES_GIT_DIR`   | `$HOME/.dotfiles`| The bare repo's git directory.   |
| `DOTFILES_WORK_TREE` | `$HOME`          | The work-tree (your home dir).   |

Set these only if your repo lives somewhere other than `$HOME/.dotfiles`. If
`DOTFILES_GIT_DIR` does not point at a directory, the plugin assumes there is no
dotfiles setup on this machine and stays silent.

## Secrets caution

`$HOME` is full of sensitive material. Never add to the dotfiles repo:

- private keys and credentials (`~/.ssh/id_*`, `*.pem`, `*.key`,
  `~/.aws/credentials`, `~/.netrc`, token/cookie files);
- shell/REPL **history** files (`.bash_history`, `.zsh_history`,
  `.python_history`) — they leak commands and secrets;
- caches, state, and large binaries.

This repo is for configuration, not secrets.
