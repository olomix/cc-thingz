#!/usr/bin/env bash
# fsnotes-lib.sh — shared helpers for the fsnotes plugin scripts.
#
# Source this file; it defines functions and has no top-level side effects:
#     source "$(dirname "$0")/fsnotes-lib.sh"
#
# All callers honor the FSNOTES_DIR environment override (used by tests to
# target a fixture). When unset, the real iCloud FSNotes store is located.

# resolve_notes_dir : print the absolute notes directory on stdout.
# Resolution order:
#   1. FSNOTES_DIR, when set and an existing directory.
#   2. The iCloud primary path, when it exists.
#   3. A glob of ~/Library/Mobile Documents/*fsnotes*/Documents — used only
#      when it matches exactly one directory.
# On zero or multiple matches, print a clear error to stderr and return 1.
resolve_notes_dir() {
  if [[ -n "${FSNOTES_DIR:-}" ]]; then
    if [[ -d "$FSNOTES_DIR" ]]; then
      printf '%s\n' "$FSNOTES_DIR"
      return 0
    fi
    printf 'fsnotes: FSNOTES_DIR is set but not a directory: %s\n' \
      "$FSNOTES_DIR" >&2
    return 1
  fi

  local primary="$HOME/Library/Mobile Documents/iCloud~co~fluder~fsnotes/Documents"
  if [[ -d "$primary" ]]; then
    printf '%s\n' "$primary"
    return 0
  fi

  local matches=()
  local candidate
  for candidate in "$HOME/Library/Mobile Documents/"*fsnotes*/Documents; do
    [[ -d "$candidate" ]] && matches+=("$candidate")
  done

  if [[ "${#matches[@]}" -eq 1 ]]; then
    printf '%s\n' "${matches[0]}"
    return 0
  fi

  if [[ "${#matches[@]}" -eq 0 ]]; then
    printf 'fsnotes: could not locate the FSNotes notes directory. Set FSNOTES_DIR to override.\n' >&2
  else
    printf 'fsnotes: multiple candidate notes directories found; set FSNOTES_DIR to pick one:\n' >&2
    printf '  %s\n' "${matches[@]}" >&2
  fi
  return 1
}

# sanitize_title <title> : print a filesystem-safe base name (no extension).
# Strips control characters, replaces path separators, drops leading dots so
# the result is never a hidden/parent reference, and collapses whitespace.
sanitize_title() {
  local title="$1"
  # Drop control characters (including newlines/tabs).
  title="$(printf '%s' "$title" | tr -d '[:cntrl:]')"
  # Replace path separators and other shell-hostile characters with a space.
  title="${title//\//-}"
  title="$(printf '%s' "$title" | tr '\\:*?"<>|' '        ')"
  # Collapse runs of whitespace into a single space and trim ends.
  title="$(printf '%s' "$title" | tr -s '[:space:]' ' ')"
  title="${title#"${title%%[![:space:]]*}"}"
  title="${title%"${title##*[![:space:]]}"}"
  # Strip leading dots to avoid hidden files / "." / "..".
  title="${title#"${title%%[!.]*}"}"
  title="${title#"${title%%[![:space:]]*}"}"

  if [[ -z "$title" ]]; then
    printf 'fsnotes: title is empty after sanitizing\n' >&2
    return 1
  fi
  printf '%s\n' "$title"
}
