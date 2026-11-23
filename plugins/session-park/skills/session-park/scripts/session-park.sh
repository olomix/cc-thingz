#!/usr/bin/env bash
# session-park.sh — record a Claude Code session in a note so it can be
# resumed later.
#
# Usage:
#   session-park.sh info [--session-id ID] [--dir DIR]
#       Print `id=<session id>`, `dir=<session start directory>` and
#       `config_dir=<Claude config directory>`.
#   session-park.sh newest <note-path>...
#       Print the absolute path of the most recently modified note.
#   session-park.sh add [--session-id ID] [--dir DIR] <note-path> <title>
#       Put a resume entry for the session at the top of the note, unless the
#       note already holds the session ID. Prints `parked: <title>` or
#       `already parked: <existing heading>`.
#
# The session ID defaults to $CLAUDE_CODE_SESSION_ID. The directory defaults
# to the first working directory in the session transcript, so the resumed
# session starts where the original one did, whatever `cd` ran since.
#
# A relative <note-path> is resolved against the FSNotes store only
# ($FSNOTES_DIR, else the iCloud path), never against the current directory.
#
# `add` holds an exclusive flock(2) lock on the note for the whole check and
# write, so concurrent runs on one note cannot drop each other's entries. The
# lock comes from lockf(1) (macOS), else flock(1); $SESSION_PARK_LOCK_TIMEOUT
# is the wait in seconds (default 10). FSNotes itself does not take the lock.
#
# Exit codes: 0 ok, 1 runtime error, 2 usage error.
set -euo pipefail

# Exit status of lockf(1) when it gives up waiting (EX_TEMPFAIL).
LOCK_TIMEOUT_STATUS=75

# Set by cmd_add; read by the EXIT trap.
WORK_DIR=""
NOTE_BACKUP=""

usage() {
  printf 'usage: session-park.sh info [--session-id ID] [--dir DIR]\n' >&2
  printf '       session-park.sh newest <note-path>...\n' >&2
  printf '       session-park.sh add [--session-id ID] [--dir DIR] <note-path> <title>\n' >&2
}

fail() {
  printf 'session-park: %s\n' "$1" >&2
  return 1
}

# A backup that still exists at exit means the note write did not finish.
cleanup() {
  [[ -z "$WORK_DIR" ]] || rm -rf "$WORK_DIR"
  if [[ -n "$NOTE_BACKUP" && -e "$NOTE_BACKUP" ]]; then
    printf 'session-park: the note may be incomplete; its previous content is in %s\n' \
      "$NOTE_BACKUP" >&2
  fi
}

# shell_quote <string> : print the string as one shell word. Not `printf %q`:
# Bash 3.2 escapes UTF-8 bytes one at a time and emits invalid UTF-8.
shell_quote() {
  local string="$1" escaped_quote="'\\''"
  local LC_ALL=C
  case "$string" in
    '' | *[!A-Za-z0-9_./@%+=:,-]*)
      printf "'%s'" "${string//\'/$escaped_quote}"
      ;;
    *)
      printf '%s' "$string"
      ;;
  esac
}

claude_config_dir() {
  local dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  case "$dir" in
    *$'\n'*)
      fail 'CLAUDE_CONFIG_DIR contains a newline'
      return 1
      ;;
  esac
  printf '%s\n' "$dir"
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
# recorded in the session transcript. When it cannot, print nothing and say
# why on stderr.
transcript_start_dir() {
  local id="$1" config_dir transcript dir
  config_dir="$(claude_config_dir)" || return 1
  if ! command -v jq >/dev/null 2>&1; then
    printf 'session-park: jq is not installed, so the session transcript cannot be read\n' >&2
    return 0
  fi
  for transcript in "$config_dir"/projects/*/"$id".jsonl; do
    [[ -f "$transcript" ]] || continue
    # The transcript is still being written; ignore a torn last line.
    dir="$(jq -rn 'first(inputs | .cwd? // empty)' "$transcript" 2>/dev/null || true)"
    if [[ -z "$dir" ]]; then
      printf 'session-park: the transcript of session %s records no working directory\n' \
        "$id" >&2
      return 0
    fi
    printf '%s\n' "$dir"
    return 0
  done
  printf 'session-park: no transcript for session %s under %s\n' \
    "$id" "$config_dir" >&2
}

# resolve_session_dir <override> <session-id> : print the directory to `cd`
# into before `claude --resume`.
resolve_session_dir() {
  local dir="${1:-}" id="$2"
  [[ -n "$dir" ]] || dir="$(transcript_start_dir "$id")" || return 1
  if [[ -z "$dir" ]]; then
    printf 'session-park: using the current directory; pass --dir if the session started elsewhere\n' >&2
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

# resolve_notes_dir : print the FSNotes store directory. Same resolution
# order as the fsnotes plugin's fsnotes-lib.sh; plugins are installed
# separately, so that file cannot be sourced from here.
resolve_notes_dir() {
  if [[ -n "${FSNOTES_DIR:-}" ]]; then
    if [[ -d "$FSNOTES_DIR" ]]; then
      printf '%s\n' "$FSNOTES_DIR"
      return 0
    fi
    fail "FSNOTES_DIR is set but not a directory: $FSNOTES_DIR"
    return 1
  fi

  local primary="$HOME/Library/Mobile Documents/iCloud~co~fluder~fsnotes/Documents"
  if [[ -d "$primary" ]]; then
    printf '%s\n' "$primary"
    return 0
  fi

  local matches=() candidate
  for candidate in "$HOME/Library/Mobile Documents/"*fsnotes*/Documents; do
    [[ -d "$candidate" ]] && matches+=("$candidate")
  done
  if [[ "${#matches[@]}" -eq 1 ]]; then
    printf '%s\n' "${matches[0]}"
    return 0
  fi
  fail 'could not locate the FSNotes notes directory; set FSNOTES_DIR'
}

# resolve_note_path <path> : print the absolute path of an existing note.
resolve_note_path() {
  local path="$1" store
  if [[ "$path" != /* ]]; then
    store="$(resolve_notes_dir)" || return 1
    path="$store/${path#./}"
  fi
  if [[ ! -f "$path" ]]; then
    fail "note not found: $path"
    return 1
  fi
  printf '%s\n' "$path"
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
  # The note goes in on stdin: awk reads an operand like `a=b.markdown` as a
  # variable assignment, not as a file.
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
  ' < "$1"
}

# insert_entry <note> <entry-file> : print the note with the entry placed
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
  ' < "$1"
}

# replace_note_content <note> <new-content-file> : overwrite the note in place
# and keep its previous content in $NOTE_BACKUP until the write is verified.
# Every step is checked by hand: callers use `|| return`, and Bash turns
# `set -e` off inside a function called that way.
replace_note_content() {
  local note="$1" new="$2" backup
  if ! backup="$(mktemp "${TMPDIR:-/tmp}/session-park-backup.XXXXXX")"; then
    fail "could not create a backup file; $note is unchanged"
    return 1
  fi
  # The note is not touched until a complete copy of it exists.
  if ! cp "$note" "$backup" || ! cmp -s "$note" "$backup"; then
    rm -f "$backup"
    fail "could not back up $note; it is unchanged"
    return 1
  fi
  NOTE_BACKUP="$backup"

  # Write in place: a rename would drop the extended attributes that FSNotes
  # and iCloud keep on the note file.
  if cat "$new" > "$note" && cmp -s "$new" "$note"; then
    rm -f "$NOTE_BACKUP"
    NOTE_BACKUP=""
    return 0
  fi
  if cmp -s "$NOTE_BACKUP" "$note" ||
    { cat "$NOTE_BACKUP" > "$note" && cmp -s "$NOTE_BACKUP" "$note"; }; then
    rm -f "$NOTE_BACKUP"
    NOTE_BACKUP=""
    fail "could not write $note; it is unchanged"
    return 1
  fi
  # cleanup reports where the previous content is.
  fail "could not write $note"
  return 1
}

# run_locked <note> <command...> : run the command while holding an exclusive
# lock on the note. The lock is on the note file itself, so every run agrees
# on it whatever its TMPDIR, and it ends with the process that holds it.
run_locked() {
  local note="$1" timeout="${SESSION_PARK_LOCK_TIMEOUT:-10}" status=0
  shift
  if command -v lockf >/dev/null 2>&1; then
    lockf -k -s -t "$timeout" "$note" "$@" || status=$?
  elif command -v flock >/dev/null 2>&1; then
    flock -w "$timeout" -E "$LOCK_TIMEOUT_STATUS" "$note" "$@" || status=$?
  else
    printf 'session-park: no lockf or flock; writing without a lock\n' >&2
    "$@" || status=$?
  fi
  if [[ "$status" -eq "$LOCK_TIMEOUT_STATUS" ]]; then
    fail "another session-park run holds $note; try again"
    return 1
  fi
  return "$status"
}

cmd_info() {
  local id dir config_dir
  id="$(resolve_session_id "$opt_session_id")" || return 1
  dir="$(resolve_session_dir "$opt_dir" "$id")" || return 1
  config_dir="$(claude_config_dir)" || return 1
  printf 'id=%s\ndir=%s\nconfig_dir=%s\n' "$id" "$dir" "$config_dir"
}

cmd_newest() {
  if [[ $# -eq 0 ]]; then
    usage
    return 2
  fi
  local candidate path newest=""
  for candidate in "$@"; do
    path="$(resolve_note_path "$candidate")" || return 1
    if [[ -z "$newest" || "$path" -nt "$newest" ]]; then
      newest="$path"
    fi
  done
  printf '%s\n' "$newest"
}

cmd_add() {
  if [[ $# -ne 2 ]]; then
    usage
    return 2
  fi
  local note title id dir config_dir heading
  note="$(resolve_note_path "$1")" || return 1
  title="$(clean_title "$2")" || return 1
  id="$(resolve_session_id "$opt_session_id")" || return 1

  if heading="$(parked_heading "$note" "$id")"; then
    printf 'already parked: %s\n' "${heading:-<no heading>}"
    return 0
  fi

  dir="$(resolve_session_dir "$opt_dir" "$id")" || return 1
  config_dir="$(claude_config_dir)" || return 1

  WORK_DIR="$(mktemp -d)"
  {
    printf '## %s\n' "$title"
    printf '```bash\n'
    printf '# CLAUDE_CONFIG_DIR=%s\n' "$(shell_quote "$config_dir")"
    printf 'cd %s\n' "$(shell_quote "$dir")"
    printf 'claude --resume %s\n' "$id"
    printf '```\n'
  } > "$WORK_DIR/entry"
  insert_entry "$note" "$WORK_DIR/entry" > "$WORK_DIR/note"
  if ! parked_heading "$WORK_DIR/note" "$id" >/dev/null; then
    fail "could not build the new content of $note; it is unchanged"
    return 1
  fi
  replace_note_content "$note" "$WORK_DIR/note" || return 1
  printf 'parked: %s\n' "$title"
}

main() {
  trap cleanup EXIT
  # Exit through the EXIT trap, so an interrupted write is reported.
  trap 'exit 130' INT
  trap 'exit 143' TERM

  local original_args=("$@")
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
    newest)
      cmd_newest ${positional[@]+"${positional[@]}"}
      ;;
    add)
      if [[ ${#positional[@]} -ne 2 ]]; then
        usage
        return 2
      fi
      if [[ -n "${SESSION_PARK_LOCK_HELD:-}" ]]; then
        cmd_add "${positional[@]}"
        return
      fi
      # Run the same command again under the lock: a shell script cannot
      # take a flock(2) lock on its own on macOS.
      local note
      note="$(resolve_note_path "${positional[0]}")" || return 1
      run_locked "$note" env SESSION_PARK_LOCK_HELD=1 \
        "$BASH" "${BASH_SOURCE[0]}" "${original_args[@]}"
      ;;
    *)
      usage
      return 2
      ;;
  esac
}

main "$@"
