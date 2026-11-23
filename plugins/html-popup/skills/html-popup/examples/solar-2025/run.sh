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
stats='
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
  jq -c --argjson m "$1" "$stats"'
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
  jq -r --argjson m "$1" "$stats"'
    | def pad(n): tostring | (" " * ([n - length, 0] | max)) + .;
      def rpad(n): tostring | . + (" " * ([n - length, 0] | max));
      .unit as $unit
    | def amount(x): "\(x | num | pad(7)) \($unit)   ";
      def row(name; text): "  " + (name | rpad(19)) + text;
      def part(name; x; p): row("  " + name; amount(x) + "\(p | pad(4))%");
      .m as $mo
    | ($mo.total / 100 | round / 10) as $twh
    | "",
      "  \($mo.name) 2025 — US solar generation",
      "  ─────────────────────────────────────────────",
      row("Total solar"; amount($mo.total) + "(\($twh) TWh)"),
      part("Utility-scale PV"; $mo.utility; .split.utility),
      part("Small-scale PV"; $mo.small; .split.small),
      part("Solar thermal"; $mo.thermal; .split.thermal),
      "",
      row("\($mo.name) 2024";
        amount($mo.total2024) + "\(.yoy)% year over year"),
      row("Rank in 2025"; "#\(.rank) of 12"),
      row("Share of the year"; "\(.share)% of \(.year | num) \(.unit)"),
      row("Wind, same month"; amount($mo.wind) + "solar = \(.ratio)× wind"),
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
