#!/usr/bin/env bash
# fsnotes-newpath.sh — print the absolute path for a new FSNotes note.
#
# Usage: fsnotes-newpath.sh <title> [notebook]
#   title    — the note title; sanitized into a filesystem-safe base name
#   notebook — optional subfolder (created on demand by the caller, not here)
#
# Prints the absolute target `.markdown` path on stdout. Never overwrites:
# if the target already exists, prints a clear error to stderr and exits
# non-zero so the caller can pick a different title.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugins/fsnotes/scripts/fsnotes-lib.sh
source "$SCRIPT_DIR/fsnotes-lib.sh"

usage() {
  printf 'usage: fsnotes-newpath.sh <title> [notebook]\n' >&2
}

main() {
  local title="${1:-}" notebook="${2:-}"
  if [[ -z "$title" ]]; then
    usage
    return 2
  fi

  local notes_dir
  notes_dir="$(resolve_notes_dir)" || return 1

  local base
  base="$(sanitize_title "$title")" || return 1

  local dir="$notes_dir"
  if [[ -n "$notebook" ]]; then
    guard_notebook "$notebook" || return 1
    dir="$notes_dir/$notebook"
  fi

  local path="$dir/$base.markdown"
  if [[ -e "$path" ]]; then
    printf 'fsnotes: a note already exists at %s; choose another title\n' \
      "$path" >&2
    return 1
  fi

  printf '%s\n' "$path"
}

main "$@"
