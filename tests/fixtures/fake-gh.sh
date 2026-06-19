#!/usr/bin/env bash
# fake-gh.sh — a stub standing in for the real `gh` binary in tests.
#
# It serves canned output from fixtures so the suite runs offline with no auth:
#   reference            → cats gh-reference-sample.txt (the synthetic manual)
#   <cmd words...> --help → cats gh-help-<cmd-words-joined-by-hyphen>.txt
#
# Tests point the gh-lookup script at this file via GH_BIN so no real gh,
# network, or GitHub auth is ever touched.
set -euo pipefail

FIXTURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${1:-}" == "reference" ]]; then
  cat "$FIXTURE_DIR/gh-reference-sample.txt"
  exit 0
fi

# `<command words...> --help`: the last argument is --help; the rest name the
# command. Join the command words with hyphens to key the help fixture file.
args=("$@")
last=$(( ${#args[@]} - 1 ))
if (( last >= 0 )) && [[ "${args[last]}" == "--help" ]]; then
  unset 'args[last]'
  key="$(IFS=-; printf '%s' "${args[*]}")"
  fixture="$FIXTURE_DIR/gh-help-$key.txt"
  if [[ -f "$fixture" ]]; then
    cat "$fixture"
    exit 0
  fi
  printf 'fake-gh: no help fixture for: %s\n' "${args[*]}" >&2
  exit 1
fi

printf 'fake-gh: unsupported invocation: %s\n' "$*" >&2
exit 1
