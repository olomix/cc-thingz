#!/usr/bin/env bash
# Show the 2025 US solar report in a live html-popup window. Each month the
# user chooses gets a details panel in the page and a summary on stdout.
# Runs until the user presses Done or closes the window.
#
# Usage: run.sh [--timeout SEC] [other html-popup window opts]
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
popup="$here/../../scripts/html-popup.sh"
data="$here/data.json"

# Figures for month $m (1-12), shared by the page and terminal outputs.
# shellcheck disable=SC2016 # jq program; $names are jq variables.
STATS='
  def pct(a; b): (a / b * 1000 | round) / 10
    | tostring | if test("\\.") then . else . + ".0" end;
  def num: tostring | [scan("\\d{1,3}(?=(?:\\d{3})*$)")] | join(",");
  .months as $all
  | ($all | map(.total) | add) as $year
  | $all[$m - 1] as $mo
  | pct($mo.total - $mo.total2024; $mo.total2024) as $yoy
  | {
      m: $mo, unit, source, year: $year,
      rank: ($all | map(.total) | sort | reverse | index($mo.total) + 1),
      yoy: ((if $yoy | startswith("-") then "" else "+" end) + $yoy),
      share: pct($mo.total; $year),
      split: {utility: pct($mo.utility; $mo.total),
              small: pct($mo.small; $mo.total),
              thermal: pct($mo.thermal; $mo.total)},
      ratio: (($mo.total / $mo.wind * 100 | round) / 100)
    }
'

details_message() {
  jq -c --argjson m "$1" "$STATS"'
    | .m as $mo
    | {month: $m, details: {
        "Total solar": "\($mo.total | num) \(.unit)",
        "Utility-scale PV": "\($mo.utility | num) \(.unit) · \(.split.utility)%",
        "Small-scale PV": "\($mo.small | num) \(.unit) · \(.split.small)%",
        "Solar thermal": "\($mo.thermal | num) \(.unit) · \(.split.thermal)%",
        "vs \($mo.name) 2024": "\(.yoy)%",
        "Rank in 2025": "#\(.rank) of 12",
        "Share of the year": "\(.share)%",
        "Solar vs wind": "\(.ratio)× wind"
      }}' "$data"
}

print_details() {
  jq -r --argjson m "$1" "$STATS"'
    | def pad(n): tostring | (" " * ([n - length, 0] | max)) + .;
      def rpad(n): tostring | . + (" " * ([n - length, 0] | max));
      .m as $mo
    | "",
      "  \($mo.name) 2025 — US solar generation",
      "  ─────────────────────────────────────────────",
      "  Total solar        \($mo.total | num | pad(7)) \(.unit)   (\($mo.total / 100 | round / 10) TWh)",
      "    Utility-scale PV \($mo.utility | num | pad(7)) \(.unit)   \(.split.utility | pad(4))%",
      "    Small-scale PV   \($mo.small | num | pad(7)) \(.unit)   \(.split.small | pad(4))%",
      "    Solar thermal    \($mo.thermal | num | pad(7)) \(.unit)   \(.split.thermal | pad(4))%",
      "",
      "  \("\($mo.name) 2024" | rpad(19))\($mo.total2024 | num | pad(7)) \(.unit)   \(.yoy)% year over year",
      "  Rank in 2025       #\(.rank) of 12",
      "  Share of the year  \(.share)% of \(.year | num) \(.unit)",
      "  Wind, same month   \($mo.wind | num | pad(7)) \(.unit)   solar = \(.ratio)× wind",
      "",
      "  Source: \(.source)"' "$data"
}

session="$("$popup" live start "$here/report.html" --data "$data" "$@")"

while :; do
  rc=0
  events="$("$popup" live wait "$session")" || rc=$?
  case "$rc" in
    0 | 1) ;;
    4) continue ;;
    *) exit "$rc" ;;
  esac
  # Only {"month": 1-12} messages are requests; ignore anything else.
  while read -r month; do
    "$popup" live send "$session" "$(details_message "$month")" || true
    print_details "$month"
  done < <(jq -r 'select(.type == "message") | .data | objects | .month
    | numbers | select(. >= 1 and . <= 12 and . == floor)' <<<"$events")
  ((rc == 0)) || break
done
