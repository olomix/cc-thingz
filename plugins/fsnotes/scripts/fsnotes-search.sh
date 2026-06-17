#!/usr/bin/env bash
# fsnotes-search.sh — search the FSNotes store and print matching hits.
#
# Usage: fsnotes-search.sh <mode> <query> [notebook]
#   mode ∈ text | title | tag | folder
#     text   — match note bodies (the default for "find my note about X")
#     title  — match the first "# " heading and the filename
#     tag    — match inline #hashtags (a leading # in <query> is optional)
#     folder — like text, but restricted to the notebook named in <query>
#   notebook — optional 3rd arg: restrict any mode to that subfolder
#
# Output: one hit per line as `relative/path:line:text` (filename-only
# title matches print `relative/path`). Trash/ and files/ are always
# excluded. Errors and the ripgrep hint go to stderr; hits go to stdout.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugins/fsnotes/scripts/fsnotes-lib.sh
source "$SCRIPT_DIR/fsnotes-lib.sh"

usage() {
  printf 'usage: fsnotes-search.sh <text|title|tag|folder> <query> [notebook]\n' >&2
}

# search_backend : echo "rg" when ripgrep is available, else "grep" and emit a
# one-time hint to stderr that installing ripgrep improves search.
search_backend() {
  if command -v rg >/dev/null 2>&1; then
    printf 'rg\n'
  else
    printf 'fsnotes: ripgrep (rg) not found; falling back to grep. Install ripgrep for faster, more accurate search.\n' >&2
    printf 'grep\n'
  fi
}

# escape_ere <string> : escape regex metacharacters for an ERE pattern.
escape_ere() {
  printf '%s' "$1" | sed 's/[][(){}.^$*+?|\\]/\\&/g'
}

# run_search <pattern> <ere?> : search *.markdown bodies under $target for
# <pattern>, excluding Trash/ and files/. When <ere> is "ere" the pattern is
# treated as an extended regex; otherwise as a fixed string. Prints
# relative/path:line:text. Runs from $notes_dir so paths stay relative.
run_search() {
  local pattern="$1" kind="${2:-fixed}"
  (
    cd "$notes_dir"
    if [[ "$backend" == "rg" ]]; then
      # Exclude Trash/ and files/ at any depth (leading **/), matching grep's
      # --exclude-dir. A bare `Trash/**` is anchored to the rg root, so a
      # notebook-scoped search would leak a nested <notebook>/Trash/.
      local rg_args=(--line-number --no-heading --color=never -i
        -g '*.markdown' -g '!**/Trash/**' -g '!**/files/**')
      [[ "$kind" == "ere" ]] || rg_args+=(--fixed-strings)
      rg "${rg_args[@]}" -- "$pattern" "$target" 2>/dev/null || true
    else
      local grep_args=(-rn -i --include='*.markdown'
        --exclude-dir=Trash --exclude-dir=files)
      [[ "$kind" == "ere" ]] && grep_args+=(-E) || grep_args+=(-F)
      grep "${grep_args[@]}" -- "$pattern" "$target" 2>/dev/null || true
    fi
  ) | sed 's#^\./##'
}

# match_filenames <query> : print `path<TAB>path` for notes whose filename
# contains <query> (case-insensitive), excluding Trash/ and files/. The
# leading tab-delimited field is the dedup key; see the title-mode awk.
match_filenames() {
  local query="$1" lower_q rel base lower_b
  lower_q="$(printf '%s' "$query" | tr '[:upper:]' '[:lower:]')"
  (
    cd "$notes_dir"
    find "$target" -type f -name '*.markdown' \
      -not -path '*/Trash/*' -not -path '*/files/*' 2>/dev/null
  ) | while IFS= read -r rel; do
    rel="${rel#./}"
    base="$(basename "$rel" .markdown)"
    lower_b="$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')"
    if [[ "$lower_b" == *"$lower_q"* ]]; then
      printf '%s\t%s\n' "$rel" "$rel"
    fi
  done
}

# match_title_headings <query> : print `path<TAB>path:1:text` for notes whose
# FIRST line is a "# " heading containing <query> (case-insensitive), excluding
# Trash/ and files/. The note title is the first heading only — later body
# headings are not titles, so they must not produce title hits. The leading
# tab-delimited field is the dedup key; see the title-mode awk.
match_title_headings() {
  local query="$1" lower_q rel first lower_first
  lower_q="$(printf '%s' "$query" | tr '[:upper:]' '[:lower:]')"
  (
    cd "$notes_dir"
    find "$target" -type f -name '*.markdown' \
      -not -path '*/Trash/*' -not -path '*/files/*' 2>/dev/null
  ) | while IFS= read -r rel; do
    rel="${rel#./}"
    IFS= read -r first < "$notes_dir/$rel" || true
    case "$first" in
      '#'[[:space:]]*) ;;
      *) continue ;;
    esac
    lower_first="$(printf '%s' "$first" | tr '[:upper:]' '[:lower:]')"
    if [[ "$lower_first" == *"$lower_q"* ]]; then
      printf '%s\t%s:1:%s\n' "$rel" "$rel" "$first"
    fi
  done
}

main() {
  local mode="${1:-}" query="${2:-}" notebook="${3:-}"
  if [[ -z "$mode" || -z "$query" ]]; then
    usage
    return 2
  fi

  local notes_dir
  notes_dir="$(resolve_notes_dir)" || return 1

  # "folder" mode restricts a body search to the notebook named in <query>.
  if [[ "$mode" == "folder" ]]; then
    notebook="$query"
    query="${3:-}"
    if [[ -z "$query" ]]; then
      printf 'fsnotes: folder mode needs a query: fsnotes-search.sh folder <notebook> <query>\n' >&2
      return 2
    fi
  fi

  # Optional notebook scope: search target is the subfolder, else the whole store.
  local target='.'
  if [[ -n "$notebook" ]]; then
    guard_notebook "$notebook" || return 1
    if [[ ! -d "$notes_dir/$notebook" ]]; then
      printf 'fsnotes: notebook not found: %s\n' "$notebook" >&2
      return 1
    fi
    target="$notebook"
  fi

  local backend
  backend="$(search_backend)"

  case "$mode" in
    text | folder)
      run_search "$query"
      ;;
    title)
      # First-heading matches plus filename matches. A note whose heading and
      # filename both match would otherwise appear twice; dedupe on the path
      # and keep the richer `path:line:text` form. Both producers emit the
      # path as a leading tab-delimited key, so dedup is exact regardless of
      # colons or digits in the path (FSNotes permits them). Headings come
      # first, so the richer form wins; the key field is stripped before print.
      {
        match_title_headings "$query"
        match_filenames "$query"
      } | awk -F'\t' '!seen[$1]++ { sub(/^[^\t]*\t/, ""); print }'
      ;;
    tag)
      local tag="${query#\#}"
      run_search "(^|[^[:alnum:]_])#$(escape_ere "$tag")([^[:alnum:]_]|$)" ere
      ;;
    *)
      printf 'fsnotes: unknown mode: %s\n' "$mode" >&2
      usage
      return 2
      ;;
  esac
}

main "$@"
