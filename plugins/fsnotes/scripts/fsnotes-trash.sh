#!/usr/bin/env bash
# fsnotes-trash.sh — move an FSNotes note into the store's Trash/ folder.
#
# Usage: fsnotes-trash.sh <note-path>
#   note-path — path to the note to trash; relative paths resolve against the
#               notes directory, absolute paths are used as-is.
#
# Never hard-deletes: the file is moved into <notes>/Trash/ (created on
# demand). On a name collision in Trash/, a numeric suffix is appended so the
# existing trashed note is preserved. Prints the new path on stdout.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugins/fsnotes/scripts/fsnotes-lib.sh
source "$SCRIPT_DIR/fsnotes-lib.sh"

usage() {
  printf 'usage: fsnotes-trash.sh <note-path>\n' >&2
}

main() {
  local note="${1:-}"
  if [[ -z "$note" ]]; then
    usage
    return 2
  fi

  local notes_dir
  notes_dir="$(resolve_notes_dir)" || return 1

  local src="$note"
  [[ "$src" != /* ]] && src="$notes_dir/$note"

  if [[ ! -f "$src" ]]; then
    printf 'fsnotes: no such note to trash: %s\n' "$src" >&2
    return 1
  fi

  local trash="$notes_dir/Trash"
  mkdir -p "$trash"

  local base name ext dest
  base="$(basename "$src")"
  # Disambiguate against the .markdown extension so suffixes land before it.
  if [[ "$base" == *.* ]]; then
    name="${base%.*}"
    ext=".${base##*.}"
  else
    name="$base"
    ext=""
  fi

  dest="$trash/$base"
  local n=1
  while [[ -e "$dest" ]]; do
    dest="$trash/$name ($n)$ext"
    n=$((n + 1))
  done

  mv "$src" "$dest"
  printf '%s\n' "$dest"
}

main "$@"
