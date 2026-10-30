#!/usr/bin/env bash
# fake-open.sh — stands in for open(1) in html-popup tests with fake viewers.
#
# Accepts what the wrapper passes (-n, -g, -a BUNDLE, --stdout F, --stderr F,
# --args ...) and starts BUNDLE/Contents/MacOS/* detached, like
# LaunchServices: cwd /, parent launchd. A bash stub launched through real
# open would bounce in the Dock. Knobs:
#   FAKE_OPEN_ARGS=FILE  append each received argument to FILE, one per line
#   FAKE_OPEN_FAIL=MSG   print MSG on stderr and exit 1 without launching
set -euo pipefail

if [[ -n "${FAKE_OPEN_ARGS:-}" ]]; then
  printf '%s\n' "$@" >>"$FAKE_OPEN_ARGS"
fi
if [[ -n "${FAKE_OPEN_FAIL:-}" ]]; then
  printf '%s\n' "$FAKE_OPEN_FAIL" >&2
  exit 1
fi

bundle="" out=/dev/null err=/dev/null
while (($# > 0)); do
  case "$1" in
    -n | -g) shift ;;
    -a) bundle="$2"; shift 2 ;;
    --stdout) out="$2"; shift 2 ;;
    --stderr) err="$2"; shift 2 ;;
    --args) shift; break ;;
    *) printf 'fake-open: unexpected argument: %s\n' "$1" >&2; exit 1 ;;
  esac
done
exe=("$bundle"/Contents/MacOS/*)
[[ -x "${exe[0]}" ]] || {
  printf 'fake-open: no executable in %s\n' "$bundle" >&2
  exit 1
}

# Double fork, so the viewer's parent is launchd as with real open.
cd /
(
  "${exe[0]}" "$@" </dev/null >>"$out" 2>>"$err" &
)
