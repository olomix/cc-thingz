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

# The wrapper only trusts processes named like the viewer, so the stub
# re-execs itself with its own path as argv[0] (a plain script shows as bash).
# Long-lived bodies should use `exec -a "$0" sleep N` to keep that name.
cat >"$out" <<EOF
#!/bin/bash
if [[ -z "\${FAKE_VIEWER_NAMED:-}" ]]; then
  FAKE_VIEWER_NAMED=1 exec -a "\$0" /bin/bash "\$0" "\$@"
fi
${FAKE_SWIFTC_BODY:-exit 0}
EOF
chmod +x "$out"
