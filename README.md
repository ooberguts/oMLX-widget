# oMLX Widget

A small macOS panel for running and watching [oMLX](https://omlx.ai) — the
Apple-Silicon LLM inference server. Start and stop the server, watch GPU and
throughput, manage models, and copy client connection settings, from a window
that fits in a corner of the screen.

Built with AppKit + WKWebView. No Xcode, no Electron, no dependencies — one
`swiftc` call against the Command Line Tools.

## Install

```bash
git clone https://github.com/ooberguts/oMLX-widget.git
cd oMLX-widget
./build.sh
open "$HOME/AI/apps/oMLX Widget.app"
```

Build somewhere else with `OMLX_WIDGET_APP=/Applications/"oMLX Widget.app" ./build.sh`.

The app updates itself: it stamps the commit it was built from into its bundle,
compares that against `main`, and can download, rebuild and hot-swap in place.
Click the version chip in the footer to check.

## Layout it expects

| Path | What |
|---|---|
| `~/AI` | root — override with `OMLX_HOME` |
| `~/AI/omlx/bin/omlxctl` | server control script (`start`/`stop`/`status`/`serve`) |
| `~/AI/omlx/data/` | oMLX settings, and the widget's `widget-tps.json` |
| `~/AI/logs/` | server logs |
| `http://127.0.0.1:8000` | oMLX — override with `OMLX_URL` |

## Tabs

**Monitor** — memory pressure against the guard ceiling, rolling 90-second GPU
and tokens/sec graphs, request counts, and per-model lifetime tokens, request
count, average/peak/low tok/s plus tokens generated since the model was loaded.

**Models** — everything on disk with sizes, two-click delete, and downloads by
exact repo id or Hugging Face search. **Serve** moves the `local` alias onto a
model so clients can switch models without touching their own config.

**Connect** — base URLs, API key and model ids with copy buttons, plus
ready-to-paste config for [Hermes](https://github.com/ooberguts).

## Notes

GPU utilisation comes from the IOKit accelerator's `Device Utilization %`,
read directly rather than shelling out to `ioreg`, so no `sudo` and no process
spawn per poll.

Tokens/sec is summed from each in-flight request's live decode rate. oMLX's
cumulative counters only move when a request finishes, which would flatline the
graph and then spike it.

oMLX persists per-model averages but not extremes, so the widget samples the
decode rate itself and keeps peak/low in `~/AI/omlx/data/widget-tps.json`.

The admin API is read through `skip_api_key_verification`, which is safe only
because oMLX binds to loopback. If you bind to `0.0.0.0`, set an API key and
turn that off.

## Licence

MIT
