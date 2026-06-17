#!/usr/bin/env bash
# fsnotes-trash.sh — move an FSNotes note into the store's Trash/ folder.
#
# Usage: fsnotes-trash.sh <note-path>
#   note-path — path to the note to trash; relative paths resolve against the
#               notes directory, absolute paths must resolve inside it.
#
# The note is always confined to the store: relative paths may not escape via
# "..", and absolute paths are canonicalized and refused unless they live
# under the notes directory. Never hard-deletes: the file is moved into
# <notes>/Trash/ (created on demand). On a name collision in Trash/, a numeric
# suffix is appended so the existing trashed note is preserved. Prints the new
# path on stdout.
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

  local notes_dir canon_notes
  notes_dir="$(resolve_notes_dir)" || return 1
  # Resolve symlinks once so the confinement check below compares like for
  # like (e.g. macOS /var -> /private/var).
  canon_notes="$(cd "$notes_dir" && pwd -P)" || return 1

  local src="$note"
  if [[ "$src" != /* ]]; then
    # Free-form note paths must not escape the store via "..".
    guard_notebook "$note" || return 1
    src="$notes_dir/$note"
  fi

  if [[ ! -f "$src" ]]; then
    printf 'fsnotes: no such note to trash: %s\n' "$src" >&2
    return 1
  fi

  # Refuse symlinks: the confinement check below canonicalizes only the parent
  # directory, so an in-store symlink whose target lives outside the store would
  # otherwise pass and have its target's contents hard-linked into Trash/.
  # Real FSNotes notes are never symlinks.
  if [[ -L "$src" ]]; then
    printf 'fsnotes: refusing to trash a symlink: %s\n' "$note" >&2
    return 1
  fi

  # Confine to the store: canonicalize the source and refuse anything that does
  # not live under the notes directory. Absolute inputs would otherwise let a
  # caller move an arbitrary readable file into Trash/.
  local src_real
  src_real="$(cd "$(dirname "$src")" && pwd -P)/$(basename "$src")" || return 1
  case "$src_real" in
    "$canon_notes"/*) ;;
    *)
      printf 'fsnotes: refusing to trash a path outside the notes store: %s\n' \
        "$note" >&2
      return 1
      ;;
  esac
  src="$src_real"

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

  # Atomically claim a Trash/ name: hard-link first (which fails if the name is
  # already taken) instead of test-then-mv, which could clobber a file FSNotes
  # sync created between the check and the move. Same filesystem is guaranteed
  # — Trash/ and the confined source both live under notes_dir.
  dest="$trash/$base"
  local n=1
  until ln "$src" "$dest" 2>/dev/null; do
    if [[ ! -e "$dest" ]]; then
      printf 'fsnotes: failed to move note into Trash: %s\n' "$src" >&2
      return 1
    fi
    dest="$trash/$name ($n)$ext"
    n=$((n + 1))
  done
  rm "$src"
  printf '%s\n' "$dest"
}

main "$@"
