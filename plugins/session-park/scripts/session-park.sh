#!/usr/bin/env bash
# session-park.sh — record a Claude Code session in a note so it can be
# resumed later.
#
# Usage:
#   session-park.sh info [--session-id ID] [--dir DIR]
#       Print `id=<session id>` and `dir=<session start directory>`.
#   session-park.sh add [--session-id ID] [--dir DIR] <note-path> <title>
#       Put a resume entry for the session at the top of the note, unless the
#       note already holds the session ID. Prints `parked: <title>` or
#       `already parked: <existing heading>`.
#
# The session ID defaults to $CLAUDE_CODE_SESSION_ID. The directory defaults
# to the first working directory in the session transcript, because
# `claude --resume` finds a session only from the directory it started in.
#
# A relative <note-path> is resolved against the current directory, then
# against the FSNotes store ($FSNOTES_DIR, else the iCloud path).
#
# Exit codes: 0 ok, 1 runtime error, 2 usage error.
set -euo pipefail

usage() {
  printf 'usage: session-park.sh info [--session-id ID] [--dir DIR]\n' >&2
  printf '       session-park.sh add [--session-id ID] [--dir DIR] <note-path> <title>\n' >&2
}

fail() {
  printf 'session-park: %s\n' "$1" >&2
  return 1
}

# resolve_session_id <override> : print the session ID, or fail when none is
# known or it holds characters that could break out of the note's code block.
resolve_session_id() {
  local id="${1:-${CLAUDE_CODE_SESSION_ID:-}}"
  if [[ -z "$id" ]]; then
    fail 'no session ID: CLAUDE_CODE_SESSION_ID is unset; pass --session-id'
    return 1
  fi
  if [[ ! "$id" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]; then
    fail "invalid session ID: $id"
    return 1
  fi
  printf '%s\n' "$id"
}

# transcript_start_dir <session-id> : print the first working directory
# recorded in the session transcript. Prints nothing when the transcript or
# jq is missing.
transcript_start_dir() {
  local id="$1" config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}" transcript
  command -v jq >/dev/null 2>&1 || return 0
  for transcript in "$config_dir"/projects/*/"$id".jsonl; do
    [[ -f "$transcript" ]] || continue
    # The transcript is still being written; ignore a torn last line.
    jq -rn 'first(inputs | .cwd? // empty)' "$transcript" 2>/dev/null || true
    return 0
  done
}

# resolve_session_dir <override> <session-id> : print the directory to `cd`
# into before `claude --resume`.
resolve_session_dir() {
  local dir="${1:-}" id="$2"
  [[ -n "$dir" ]] || dir="$(transcript_start_dir "$id")"
  if [[ -z "$dir" ]]; then
    printf 'session-park: no transcript for session %s; using the current directory\n' \
      "$id" >&2
    dir="$PWD"
  fi
  case "$dir" in
    *$'\n'*)
      fail 'session directory contains a newline'
      return 1
      ;;
  esac
  printf '%s\n' "$dir"
}

# resolve_note_path <path> : print the path of an existing note file.
resolve_note_path() {
  local path="$1" store
  if [[ -f "$path" ]]; then
    printf '%s\n' "$path"
    return 0
  fi
  if [[ "$path" != /* ]]; then
    store="${FSNOTES_DIR:-$HOME/Library/Mobile Documents/iCloud~co~fluder~fsnotes/Documents}"
    if [[ -f "$store/$path" ]]; then
      printf '%s\n' "$store/$path"
      return 0
    fi
  fi
  fail "note not found: $path"
}

# clean_title <title> : print the title as one trimmed line.
clean_title() {
  local title
  title="$(printf '%s' "$1" | tr '[:cntrl:]' ' ' | tr -s ' ')"
  title="${title#"${title%%[! ]*}"}"
  title="${title%"${title##*[! ]}"}"
  # A leading "#" would change the heading level of the entry.
  title="${title#"${title%%[!# ]*}"}"
  if [[ -z "$title" ]]; then
    fail 'title is empty'
    return 1
  fi
  printf '%s\n' "$title"
}

# parked_heading <note> <session-id> : print the `## ` heading of the entry
# that holds the session ID. Returns 1 when the note does not hold it.
parked_heading() {
  awk -v id="$2" '
    function is_id_char(c) { return c ~ /[A-Za-z0-9_-]/ }
    /^## / { heading = substr($0, 4) }
    {
      rest = $0
      while ((at = index(rest, id)) > 0) {
        before = at > 1 ? substr(rest, at - 1, 1) : ""
        after = substr(rest, at + length(id), 1)
        if (!is_id_char(before) && !is_id_char(after)) {
          print heading
          found = 1
          exit
        }
        rest = substr(rest, at + length(id))
      }
    }
    END { exit found ? 0 : 1 }
  ' "$1"
}

# insert_entry <note> <entry-file> : write the note with the entry placed
# below the `# Title` line, or at the very top when there is no title line.
insert_entry() {
  awk -v entry_file="$2" '
    function print_entry(   line) {
      while ((getline line < entry_file) > 0) print line
      close(entry_file)
    }
    NR == 1 && /^# / { print; print ""; print_entry(); titled = 1; next }
    NR == 1 { print_entry(); pending_gap = 1 }
    titled && !body_started && /^[[:space:]]*$/ { next }
    titled && !body_started { print ""; body_started = 1 }
    pending_gap { print ""; pending_gap = 0 }
    { print }
    END { if (NR == 0) print_entry() }
  ' "$1"
}

cmd_info() {
  local id dir
  id="$(resolve_session_id "$opt_session_id")" || return 1
  dir="$(resolve_session_dir "$opt_dir" "$id")" || return 1
  printf 'id=%s\ndir=%s\n' "$id" "$dir"
}

cmd_add() {
  if [[ $# -ne 2 ]]; then
    usage
    return 2
  fi
  local note title id dir heading work
  note="$(resolve_note_path "$1")" || return 1
  title="$(clean_title "$2")" || return 1
  id="$(resolve_session_id "$opt_session_id")" || return 1

  if heading="$(parked_heading "$note" "$id")"; then
    printf 'already parked: %s\n' "${heading:-<no heading>}"
    return 0
  fi

  dir="$(resolve_session_dir "$opt_dir" "$id")" || return 1

  work="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$work'" EXIT
  {
    printf '## %s\n' "$title"
    printf '```bash\n'
    printf 'cd %q\n' "$dir"
    printf 'claude --resume %s\n' "$id"
    printf '```\n'
  } > "$work/entry"
  insert_entry "$note" "$work/entry" > "$work/note"
  # Write in place: a rename would drop the extended attributes that FSNotes
  # and iCloud keep on the note file.
  cat "$work/note" > "$note"
  printf 'parked: %s\n' "$title"
}

main() {
  local command="${1:-}"
  [[ $# -gt 0 ]] && shift
  opt_session_id=""
  opt_dir=""
  local positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --session-id | --dir)
        if [[ $# -lt 2 || -z "$2" ]]; then
          printf 'session-park: %s needs a value\n' "$1" >&2
          usage
          return 2
        fi
        if [[ "$1" == --dir ]]; then opt_dir="$2"; else opt_session_id="$2"; fi
        shift 2
        ;;
      --)
        shift
        positional+=("$@")
        break
        ;;
      *)
        positional+=("$1")
        shift
        ;;
    esac
  done

  case "$command" in
    info)
      if [[ ${#positional[@]} -ne 0 ]]; then
        usage
        return 2
      fi
      cmd_info
      ;;
    add)
      cmd_add ${positional[@]+"${positional[@]}"}
      ;;
    *)
      usage
      return 2
      ;;
  esac
}

main "$@"
