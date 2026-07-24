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
  # Strip control characters from the display text. A raw ESC/BEL/CR/newline
  # would terminate the OSC 8 hyperlink early or inject unrelated terminal
  # control sequences; a newline would also split the markdown link across
  # lines. The URL side is unaffected — it is already fully percent-encoded.
  #
  # Byte-level and locale-independent so a C/POSIX-only system with no UTF-8
  # locale installed can't silently disable the sanitization:
  #   1. iconv -c normalizes to valid UTF-8, dropping invalid byte sequences —
  #      including raw lone C1 bytes (e.g. a bare 0x9D not preceded by 0xC2).
  #   2. tr removes C0 controls (0x00-0x1F) and DEL (0x7F): single ASCII bytes.
  #   3. sed removes the well-formed C1 controls (U+0080-U+009F = the two-byte
  #      sequences 0xC2 0x80..0x9F). A 0xC2 lead byte in valid UTF-8 is only
  #      ever followed by 0x80-0xBF, and 0xC2 0xA0..0xBF are printable
  #      (U+00A0..U+00BF), so this touches only C1 controls and never corrupts
  #      other multi-byte characters. $'…' passes literal bytes to sed so no
  #      octal-escape interpretation (differs between BSD and GNU sed) is
  #      relied on.
  text="$(printf '%s' "$text" \
    | iconv -c -f UTF-8 -t UTF-8 2>/dev/null \
    | LC_ALL=C tr -d '\000-\037\177' \
    | LC_ALL=C sed $'s/\302[\200-\237]//g')"
  # Reject titles that leave no visible character: a control-only title strips
  # to empty and a whitespace-only title has no printable glyph, so either would
  # render as an invisible link ([](url) or blank OSC 8 text) while still
  # exiting 0. Test emptiness after stripping ASCII/Unicode whitespace AND
  # default-ignorable code points (zero-width, format, and other glyphless
  # characters), byte-for-byte under LC_ALL=C, so the check does not depend on a
  # UTF-8 locale being installed — otherwise a title of only Unicode whitespace
  # (e.g. U+2003 EM SPACE, bytes E2 80 83) or a zero-width character (e.g. U+200B
  # ZERO WIDTH SPACE / U+FEFF BOM) would slip through as an invisible link.
  #
  # First sed pass removes the White_Space characters (C0/C1 whitespace such as
  # tab/NEL is already gone from the control strip above): ASCII space plus the
  # multi-byte U+00A0, U+1680, U+2000-200A, U+2028, U+2029, U+202F, U+205F,
  # U+3000. Second sed pass removes the Unicode Default_Ignorable_Code_Point set
  # not already covered by whitespace: U+00AD, U+034F, U+061C, U+115F-1160,
  # U+17B4-17B5, U+180B-180F, U+200B-200F, U+202A-202E, U+2060-206F, U+3164,
  # U+FE00-FE0F, U+FEFF, U+FFA0, U+FFF0-FFF8, U+1BCA0-1BCA3, U+1D173-1D17A, and
  # the whole Plane-14 U+E0000-E0FFF block (tags + variation selectors
  # supplement). Only the probe copy is stripped; the emitted text keeps these
  # bytes, so a legitimate mixed title like "a<ZWSP>b" still renders and passes.
  local visible
  visible="$(printf '%s' "$text" | LC_ALL=C sed \
    $'s/ //g; s/\302\240//g; s/\341\232\200//g; s/\342\200[\200-\212]//g; s/\342\200\250//g; s/\342\200\251//g; s/\342\200\257//g; s/\342\201\237//g; s/\343\200\200//g' \
    | LC_ALL=C sed \
    $'s/\302\255//g; s/\315\217//g; s/\330\234//g; s/\341\205[\237\240]//g; s/\341\236[\264\265]//g; s/\341\240[\213-\217]//g; s/\342\200[\213-\217]//g; s/\342\200[\252-\256]//g; s/\342\201[\240-\257]//g; s/\343\205\244//g; s/\357\270[\200-\217]//g; s/\357\273\277//g; s/\357\276\240//g; s/\357\277[\260-\270]//g; s/\363\240[\200-\277][\200-\277]//g; s/\360\233\262[\240-\243]//g; s/\360\235\205[\263-\272]//g')"
  if [[ -z "$visible" ]]; then
    die "title has no visible characters" || return 1
  fi
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
