#!/usr/bin/env bash
# gh-lookup.sh — look up exact `gh` CLI syntax from the locally installed
# reference instead of guessing flags from memory.
#
# Usage: gh-lookup.sh <mode> <args...>
#   discover <keywords...> — keyword search across command names + one-line
#     descriptions in `gh reference`; prints `gh <cmd> — <description>` per hit.
#
# All gh calls go through GH_BIN ("${GH_BIN:-gh}") so tests can point at a fake.
set -euo pipefail

GH_BIN="${GH_BIN:-gh}"

# parse_reference : read a `gh reference` stream on stdin and emit one record
# per command as `<cmd>\t<description>`. Command headers are Markdown ATX
# headings that start with `gh `; the command name is the leading `gh <word>...`
# tokens up to the first usage placeholder (a token beginning with [, {, or <),
# and the description is the first non-blank line after the heading.
parse_reference() {
  awk '
    /^#+[ \t]+gh / {
      heading = $0
      sub(/^#+[ \t]+/, "", heading)
      n = split(heading, toks, /[ \t]+/)
      cmd = ""
      for (i = 1; i <= n; i++) {
        c = substr(toks[i], 1, 1)
        if (c == "[" || c == "{" || c == "<") break
        cmd = (cmd == "" ? toks[i] : cmd " " toks[i])
      }
      pending = cmd
      want_desc = 1
      next
    }
    want_desc && /[^ \t]/ {
      desc = $0
      sub(/^[ \t]+/, "", desc)
      print pending "\t" desc
      want_desc = 0
    }
  '
}

# discover <keywords...> : print each command whose name or description contains
# all of the (case-insensitive) keywords, as `gh <cmd> — <description>`.
# Exit 1 when nothing matches.
discover() {
  if (( $# == 0 )); then
    return 2
  fi
  local -a keywords=("$@")

  local records
  records="$("$GH_BIN" reference | parse_reference)"

  local found=0 cmd desc hay kw lkw match
  while IFS=$'\t' read -r cmd desc; do
    [[ -n "$cmd" ]] || continue
    hay="$(printf '%s %s' "$cmd" "$desc" | tr '[:upper:]' '[:lower:]')"
    match=1
    for kw in "${keywords[@]}"; do
      lkw="$(printf '%s' "$kw" | tr '[:upper:]' '[:lower:]')"
      if [[ "$hay" != *"$lkw"* ]]; then
        match=0
        break
      fi
    done
    if (( match )); then
      printf '%s — %s\n' "$cmd" "$desc"
      found=1
    fi
  done <<< "$records"

  (( found )) || return 1
}

main() {
  local mode="${1:-}"
  case "$mode" in
    discover)
      shift
      discover "$@"
      ;;
    *)
      printf 'gh-lookup: unknown mode: %s\n' "$mode" >&2
      return 2
      ;;
  esac
}

main "$@"
