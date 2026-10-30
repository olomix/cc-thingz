#!/usr/bin/env bash
# fake-swiftc.sh — a stub standing in for swiftc in html-popup build tests.
#
# Writes an executable stub to the path given with -o and appends one line
# per call to $FAKE_SWIFTC_CALLS (if set). Knobs:
#   FAKE_SWIFTC_DELAY=SEC  sleep before writing, to force concurrent builds
#                          to overlap
#   FAKE_SWIFTC_FAIL=1     write a partial output, then exit 1
#   FAKE_SWIFTC_BODY=SH    bash code for the stub (default: exit 0), so
#                          wrapper tests can run a scripted fake viewer
#   FAKE_SWIFTC_EXEC_DELAY=SEC  stub sleeps before taking the viewer name,
#                          like a viewer slow to exec
set -euo pipefail

out=""
while (($# > 0)); do
  if [[ "$1" == "-o" && $# -ge 2 ]]; then
    out="$2"
    shift
  fi
  shift
done
[[ -n "$out" ]] || { printf 'fake-swiftc: missing -o\n' >&2; exit 1; }

if [[ -n "${FAKE_SWIFTC_CALLS:-}" ]]; then
  printf 'call\n' >>"$FAKE_SWIFTC_CALLS"
fi
if [[ -n "${FAKE_SWIFTC_DELAY:-}" ]]; then
  sleep "$FAKE_SWIFTC_DELAY"
fi

if [[ -n "${FAKE_SWIFTC_FAIL:-}" ]]; then
  printf 'partial' >"$out"
  printf 'fake-swiftc: error: simulated compile failure\n' >&2
  exit 1
fi

# The wrapper only trusts a process named like the viewer whose arguments
# hold --session DIR, so the stub re-execs itself with its own path as argv[0]
# (a plain script shows as bash) and keeps its arguments. Long-lived bodies
# call `idle N`: short sleeps leave no orphan behind when the stub is killed.
cat >"$out" <<EOF
#!/bin/bash
if [[ -z "\${FAKE_VIEWER_NAMED:-}" ]]; then
  sleep ${FAKE_SWIFTC_EXEC_DELAY:-0}
  FAKE_VIEWER_NAMED=1 exec -a "\$0" /bin/bash "\$0" "\$@"
fi
idle() { local i; for ((i = 0; i < \$1 * 5; i++)); do sleep 0.2; done; }
${FAKE_SWIFTC_BODY:-exit 0}
EOF
chmod +x "$out"
