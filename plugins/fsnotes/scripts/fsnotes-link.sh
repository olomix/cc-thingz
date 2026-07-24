#!/usr/bin/env bash
# fsnotes-link.sh — build a clickable fsnotes:// deep link.
#
# Usage: fsnotes-link.sh [--osc8] <route> <args…>
#
# Routes:
#   find <title>                      → fsnotes://find?id=<enc>
#   open <title> [--txt <text>]       → fsnotes://open/?title=<enc>[&txt=<enc>]
#   tag  <tag>                        → fsnotes://open/?tag=<enc>
#   new  <title> [--txt <text>] [--folder <notebook>]
#                                     → fsnotes://new/?title=<enc>[&txt=<enc>][&folder=<enc>]
#
# Default output is a markdown link `[<title>](<url>)`; the link text is the
# raw title/tag, only the query values are percent-encoded. With --osc8 the
# visible text is wrapped in OSC 8 hyperlink escapes so terminals that
# hyperlink arbitrary schemes (e.g. kitty) make it clickable. Links are
# title-based, so no notes-directory resolution happens; --folder is validated
# with guard_notebook.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugins/fsnotes/scripts/fsnotes-lib.sh
source "$SCRIPT_DIR/fsnotes-lib.sh"

OSC8=0

usage() {
  printf 'usage: fsnotes-link.sh [--osc8] <find|open|tag|new> <args…>\n' >&2
}

die() {
  printf 'fsnotes: %s\n' "$1" >&2
  return 1
}

# emit <text> <url> : print the link in the selected output format.
emit() {
  local text="$1" url="$2"
  if [[ "$OSC8" -eq 1 ]]; then
    # OSC 8 hyperlink: ESC ] 8 ; ; URI  ST  <text>  ESC ] 8 ; ;  ST
    # ST is ESC "\". The URI is fully percent-encoded, so the payload is ASCII.
    printf '\033]8;;%s\033\\%s\033]8;;\033\\\n' "$url" "$text"
  else
    # Backslash-escape markdown link-text metacharacters so a title with
    # unbalanced brackets (e.g. "Draft [WIP") still parses as a link.
    local safe="${text//\\/\\\\}"
    safe="${safe//\[/\\[}"
    safe="${safe//]/\\]}"
    printf '[%s](%s)\n' "$safe" "$url"
  fi
}

main() {
  if [[ "${1:-}" == "--osc8" ]]; then
    OSC8=1
    shift
  fi

  local route="${1:-}"
  if [[ -z "$route" ]]; then
    usage
    return 1
  fi
  shift

  local title txt folder url
  case "$route" in
    find)
      title="${1:-}"
      shift || true
      [[ -n "$title" ]] || die "find requires a non-empty title" || return 1
      (($# == 0)) || die "unexpected argument: $1" || return 1
      emit "$title" "fsnotes://find?id=$(urlencode "$title")"
      ;;
    tag)
      title="${1:-}"
      shift || true
      [[ -n "$title" ]] || die "tag requires a non-empty tag" || return 1
      (($# == 0)) || die "unexpected argument: $1" || return 1
      emit "$title" "fsnotes://open/?tag=$(urlencode "$title")"
      ;;
    open)
      title="${1:-}"
      shift || true
      [[ -n "$title" ]] || die "open requires a non-empty title" || return 1
      txt=""
      while (($# > 0)); do
        case "$1" in
          --txt)
            txt="${2:-}"
            shift 2 || die "--txt requires a value" || return 1
            ;;
          *) die "unexpected argument: $1" || return 1 ;;
        esac
      done
      url="fsnotes://open/?title=$(urlencode "$title")"
      if [[ -n "$txt" ]]; then url+="&txt=$(urlencode "$txt")"; fi
      emit "$title" "$url"
      ;;
    new)
      title="${1:-}"
      shift || true
      [[ -n "$title" ]] || die "new requires a non-empty title" || return 1
      txt="" folder=""
      while (($# > 0)); do
        case "$1" in
          --txt)
            txt="${2:-}"
            shift 2 || die "--txt requires a value" || return 1
            ;;
          --folder)
            folder="${2:-}"
            shift 2 || die "--folder requires a value" || return 1
            ;;
          *) die "unexpected argument: $1" || return 1 ;;
        esac
      done
      url="fsnotes://new/?title=$(urlencode "$title")"
      if [[ -n "$txt" ]]; then url+="&txt=$(urlencode "$txt")"; fi
      if [[ -n "$folder" ]]; then
        guard_notebook "$folder" || return 1
        url+="&folder=$(urlencode "$folder")"
      fi
      emit "$title" "$url"
      ;;
    *)
      die "unknown route: $route" || return 1
      ;;
  esac
}

main "$@"
