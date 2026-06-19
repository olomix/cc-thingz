---
name: gh-lookup
description: >-
  Look up exact `gh` CLI command and flag syntax — and discover whether a
  `gh` command exists for a task — from the locally installed reference
  instead of guessing flags from memory. Use when you need precise gh
  syntax or suspect a gh command exists ("what's the gh command for…",
  "which gh flag…", "is there a gh command to…"). Two modes: discover
  (keyword search) and show (`gh <command> --help`).
allowed-tools: Bash, Task, Read
---

You resolve exact `gh` CLI syntax from the manual installed on this machine.
`gh` flags and subcommands drift between versions, so guessing them from
memory is unreliable. This skill is an anti-hallucination guardrail: when
you need precise gh syntax, or suspect a gh command might exist for a task,
consult the installed manual rather than inventing flags.

## When to use

- You need the exact flags for a known command ("which gh flag squashes a
  merge?", "what's the flag to add a label?").
- You suspect a command exists but aren't sure ("is there a gh command to
  transfer an issue?", "what's the gh command for…").
- Before writing any non-trivial `gh` invocation whose flags you are not
  certain about for the installed version.

## Two modes

The work is done by a small deterministic script. Invoke it by its absolute
path under the plugin's scripts dir:

```
"${CLAUDE_PLUGIN_ROOT}/scripts/gh-lookup.sh" <mode> <args...>
```

- `discover <keywords...>` — keyword search across all command names and
  one-line descriptions in `gh reference`. Answers "is there a gh command
  for X?" Prints one `gh <cmd> — <description>` line per hit. Matching is
  case-insensitive and requires all keywords. Exit 1 means no matches.
- `show <command words...>` — print `gh <command> --help` verbatim (exact
  usage and flags for the installed gh version). Pass multi-word commands as
  separate words: `show pr merge`.

Typical flow: `discover` to find the command, then `show` to confirm flags.

## Operation playbook

For any "what's the gh command / which gh flag / is there a gh command"
request, dispatch the `gh-lookup-search` subagent via the Task tool rather
than calling the script yourself. It runs `gh-lookup.sh` and returns compact
hits for `discover` or the relevant excerpt for `show`, without dumping the
whole manual. Use its results to write the correct gh invocation — do not
fall back to guessing flags.

Run the script directly only when you specifically need its raw output in
the current context.
