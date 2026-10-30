---
name: html-popup
description: >-
  Show a generated HTML page — report, chart, table, form or dialog — in a
  native macOS window (WebKit, no browser) and get data back from it. Use
  when the user wants to see results visually ("show it in a window", "pop
  up a report", "chart this"), when you need the user to pick or fill in
  something ("ask me which month", "let me choose"), or for a live
  interactive page that exchanges messages with you. Three modes: show,
  ask, live.
allowed-tools: Bash, Read, Write
---

You show HTML pages in a native macOS window through one wrapper script.
The window runs detached: a Bash call that times out or is killed never
closes it.

`R` is the plugin root: `${CLAUDE_PLUGIN_ROOT}` when installed as a plugin,
otherwise two levels above this skill's base directory (e.g. a skill
symlinked into `~/.claude/skills/`).

```sh
R="${CLAUDE_PLUGIN_ROOT:-<this skill's base directory>/../..}"
P="$R/scripts/html-popup.sh"
```

## Writing the page (token-saving rules)

- Copy `$R/assets/template.html` into a scratch/temp dir
  and edit only `<title>`, the header and the `#body` slot. Delete the
  `#details` panel and Details button unless you use live mode.
- Put data in a JSON file and pass `--data FILE`; the page reads it as
  `htmlPopup.data`. Do not inline data into the HTML.
- Keep everything local: inline CSS/JS/SVG, files next to the page (the
  window can read only the page's directory). No CDN scripts, no remote
  fonts. `http(s)` links open in the default browser.
- Look native: system font, follow light/dark with the template's CSS
  variables, keep its 44px top padding (traffic lights). No dimming
  backdrops or modal overlays, no thick colored accent strips at the top.
- Read `$R/examples/solar-2025/` (`report.html`,
  `data.json`, `run.sh`) only when you need a full live pattern.

## Page API (`window.htmlPopup`, injected; no script include)

- `htmlPopup.data` — the `--data` JSON, or `null`.
- `htmlPopup.answer(value)` — finish with a result; window closes.
- `htmlPopup.cancel()` — finish without a result; window closes.
- `htmlPopup.send(value)` — event to the agent; window stays open.
- `htmlPopup.onMessage(fn)` — receive values sent with `live send`.
- `htmlPopup.closeOnEscape` — default `true`: Esc closes the window unless
  focus is in an input/textarea/select/contenteditable or the page called
  `preventDefault()` on the keydown.

Values cross the bridge as JSON, so numbers, nesting and scalars survive.
Only the top-level page can use the bridge; messages from iframes are ignored.
The template's Return key answers `{"ok":true}`, except in inputs, buttons
or contenteditable elements, or when a page listener calls
`preventDefault()` on the keydown.

## Commands

```
"$P" show PAGE [opts]                # open, wait until loaded, print DIR
"$P" ask PAGE [opts] [--wait SEC]    # print the answer as one JSON line
"$P" ask --resume DIR [--wait SEC]   # keep waiting on an earlier ask
"$P" live start PAGE [opts]          # open, wait for ready, print DIR
"$P" live send DIR 'JSON'            # deliver one JSON value to the page
"$P" live wait DIR [--wait SEC]      # print new events as JSON lines
"$P" live close DIR                  # close (ok if already gone)
"$P" check                           # diagnose setup problems
```

`opts`: `--data FILE`, `--title TEXT` (default: page `<title>`),
`--size WxH` (default 980x640), `--timeout SEC` (window lifetime; default:
open until closed). `--wait` = how long this call blocks, counted from its
start (page load included; exit 4 may come while the page still loads),
whole seconds, default 100 (below the Bash tool's 120 s timeout). The
first-use compile is not bounded by it: run `"$P" build` once up front. Concurrent `live send` calls to
one window are serialized.

## Flows

```sh
# show
"$P" show "$dir/report.html" --data "$dir/data.json"

# ask; exit 4 = window still open, stderr says: still waiting; resume with: ...
ans=$("$P" ask "$dir/pick.html" --data "$dir/data.json"); jq -r .month <<<"$ans"
"$P" ask --resume "$session"     # session DIR is in that stderr line

# live
s=$("$P" live start "$dir/page.html" --data "$dir/data.json")
"$P" live wait "$s"     # first call also returns {"seq":1,"type":"ready"}
"$P" live send "$s" '{"details":{"Total":"43,929 GWh"}}'
"$P" live close "$s"
```

Events (`DIR/events.jsonl`, one per line, `seq` from 1):
`ready`; `message` with `data`; `answer` with `data`; then exactly one
`closed` with `reason`: `answer`, `cancel`, `user` (close button, Cmd-W,
Cmd-Q, Esc), `agent`, `timeout` or `error` (+ `message`). `live wait` remembers
what it already printed (`DIR/cursor`).

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | ok / answered / new events |
| 1 | window closed (no answer for `ask`, also on window `--timeout`; session over for `wait`/`send`) |
| 2 | usage error (incl. bad `--size`/`--timeout`, `live send` text that is not exactly one JSON value), missing dependency, build failure, not a session DIR |
| 3 | page or data invalid, page failed to load or not ready in 10 s |
| 4 | `--wait` expired; the window is still open: call again |
| 5 | viewer died without a `closed` event (see `DIR/viewer.log`) |

## Waiting for a human

- Exit 4 from `ask`/`live wait` is normal and always means the window is
  still open: call again. A window `--timeout` is not exit 4: `ask` exits 1
  (`window timed out without an answer`), `live wait` prints a `closed`
  event with `reason` `timeout` and exits 1.
- For long think time, watch `DIR/events.jsonl` with the Monitor tool, or
  run `live wait`/`ask --resume` with the Bash tool's `run_in_background`,
  instead of polling in a loop.
- Talk to the page only through `live send`. Never type into or send
  input to your own terminal pane.

## Requirements and errors

- macOS with a GUI session, Xcode Command Line Tools (`swiftc`) and `jq`.
  First use compiles the viewer (several seconds; `"$P" build` does it
  ahead of time) into
  `${CLAUDE_PLUGIN_DATA:-~/Library/Caches/html-popup}`; later uses reuse it.
- On any exit 2, or a window that never appears, run `"$P" check` first.
- Sandboxed Bash may block the cache dir, the window server or the
  LaunchServices launch (`open`); if so, rerun outside the sandbox.
- A page or `--data` under `~/Documents`, `~/Desktop` or `~/Downloads`
  triggers a macOS access prompt (once per viewer build) and startup may
  exit 3 while it is open: keep pages in a temp/scratch dir.
