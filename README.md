# oMLX Widget

A small macOS panel for running and watching [oMLX](https://omlx.ai) — the
Apple-Silicon LLM inference server. Start and stop the server, watch GPU and
throughput, manage models, and wire up clients, from a window that fits in a
corner of the screen.

Built with AppKit + WKWebView. No Xcode, no Electron, no dependencies — one
`swiftc` call against the Command Line Tools.

## Quick start

Paste this into Terminal. It sets up everything and leaves you with a working
server and app:

```sh
curl -fsSL https://raw.githubusercontent.com/ooberguts/oMLX-widget/main/install.sh | zsh
```

Then:

```sh
open ~/AI/apps/"oMLX Widget.app"
```

That is the whole install. It needs only the Command Line Tools
(`xcode-select --install`) — no Homebrew, and nothing touches system Python.

Everything lands under `~/AI`, with models in their own directory:

```
~/AI/
├── models/                 downloaded weights, nothing else
├── omlx/                   oMLX source, private venv, settings, omlxctl
├── cache/kv/               paged SSD KV cache
├── logs/                   server logs
└── apps/oMLX Widget.app
```

The widget has no models to start with — use its **Models** tab to download one.

## Install options

The installer is idempotent — re-run it to update oMLX and rebuild the widget.

| Variable | Effect |
|---|---|
| `AI_ROOT=/elsewhere` | install somewhere other than `~/AI` |
| `OMLX_REF=v0.7.0.dev4` | pin an oMLX version (default: latest tag) |
| `WITH_KERNELS=0` | skip the Metal kernel build (faster install, slower inference) |
| `WIDGET_ONLY=1` | just rebuild the widget |
| `SKIP_SERVICE=1` | do not install the LaunchAgent or start the server |

What it does: installs `uv` and a private Python 3.12, clones and builds oMLX
with its Metal kernels, writes `omlxctl` and a LaunchAgent, builds the widget,
and starts the server. The memory guard is sized from your installed RAM.

It will not overwrite a LaunchAgent belonging to an install under a different
root — it warns and skips instead.

### Metal kernels need full Xcode

oMLX ships optional Metal kernels (Bonsai ternary decode, Qwen3.5 prefill and
others) that are opt-in behind `OMLX_WITH_CUSTOM_KERNEL=1`. Building them needs
the `metal` shader compiler, which comes with **full Xcode** — the Command Line
Tools do not include it.

The installer checks for it and skips the kernels when it is missing, rather
than failing. If a kernel build fails for any other reason it retries without
them, so you always end up with a working install.

Everything works without them; ternary/Bonsai models and Qwen prefill just fall
back to slower generic paths. To add them later:

```sh
# after installing Xcode from the App Store
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
WITH_KERNELS=1 curl -fsSL https://raw.githubusercontent.com/ooberguts/oMLX-widget/main/install.sh | zsh
```

Widget only, from a clone:

```sh
git clone https://github.com/ooberguts/oMLX-widget.git
cd oMLX-widget && ./build.sh
```

Build elsewhere with `OMLX_WIDGET_APP=/Applications/"oMLX Widget.app" ./build.sh`.

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

A **Server** row at the bottom shows the running oMLX version and whether a
newer release exists. Updating checks out that tag, reinstalls into the private
venv and restarts the server — so it asks twice, since a restart drops
in-flight requests. If the reinstall fails it rolls back to the previous
revision so the server still starts.

The check treats GitHub's own prerelease flag as authoritative rather than
guessing from the tag name: `v0.7.0rc1` is published as a normal release even
though it reads like a candidate.

**Models** — everything on disk with sizes, two-click delete, and downloads by
exact repo id or Hugging Face search. **Serve** moves the `local` alias onto a
model so clients can switch models without touching their own config.

**Connect** — base URLs, API key and model ids with copy buttons, plus a
**Hermes Agent** panel behind a toggle.

The Hermes panel lists every profile it finds — the root profile plus each
`~/.hermes/profiles/<name>/` carrying a `SOUL.md` — and shows which provider
and model each is on. Pick a profile and a model, and it writes a proper
`providers.omlx` block and points `model.provider` at it, taking a timestamped
backup first. **Test** sends a real completion and reports oMLX's own error
text rather than a generic failure.

The provider is `omlx`, not `lmstudio`. Hermes resolves named providers out of
`providers:`, which is what oMLX's own `omlx launch hermes` writes. Pointing
`model.provider` at a different provider without clearing the previous one's
keys (`base_url`, `api_mode`, `lmstudio_load_mode`) is what produces HTTP 409s;
writing the profile here clears them.

`default` is never preselected, and overwriting it takes two clicks — on most
installs that is the primary cloud profile.

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
