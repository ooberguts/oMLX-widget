#!/usr/bin/env python3
"""Read and update Hermes Agent profiles so they point at oMLX.

Mirrors oMLX's own integrations/hermes.py: it writes a `providers.omlx` block
and points `model.provider` at it, taking a timestamped backup first.

  hermes.py list
  hermes.py apply --home <dir> --model <id> --base-url <url>
                  [--ctx N] [--max-tokens N] [--api-key K]
"""
from __future__ import annotations

import argparse
import json
import shutil
import sys
import time
from pathlib import Path

try:
    import yaml
except ImportError:
    print(json.dumps({"error": "PyYAML not available to this interpreter"}))
    sys.exit(1)

# Hermes refuses to launch below this; surfaced so the UI can warn early.
MIN_CONTEXT = 64_000


def profiles_root(home: Path) -> Path:
    return home / "profiles"


def discover(default_home: Path) -> list[dict]:
    """The root profile plus every named one (SOUL.md is the marker)."""
    out: list[dict] = []

    def describe(name: str, home: Path) -> dict:
        cfg = home / "config.yaml"
        d: dict = {}
        if cfg.is_file():
            try:
                d = yaml.safe_load(cfg.read_text(encoding="utf-8")) or {}
            except Exception:
                d = {}
        model = d.get("model") or {}
        providers = d.get("providers") or {}
        omlx = providers.get("omlx") or {}
        return {
            "name": name,
            "home": str(home),
            "config": str(cfg),
            "exists": cfg.is_file(),
            "provider": model.get("provider"),
            "model": model.get("default"),
            "base_url": omlx.get("base_url") or model.get("base_url"),
            "context_length": model.get("context_length"),
            "wired": model.get("provider") == "omlx" and bool(omlx),
        }

    if (default_home / "SOUL.md").exists() or (default_home / "config.yaml").exists():
        out.append(describe("default", default_home))

    root = profiles_root(default_home)
    if root.is_dir():
        for entry in sorted(root.iterdir()):
            if not entry.is_dir() or entry.name.startswith("."):
                continue
            if entry.name == "default":
                continue
            if not (entry / "SOUL.md").exists():
                continue
            out.append(describe(entry.name, entry))
    return out


def apply(home: Path, model: str, base_url: str,
          ctx: int | None, max_tokens: int | None, api_key: str) -> dict:
    cfg_path = home / "config.yaml"
    config: dict = {}
    if cfg_path.is_file():
        try:
            loaded = yaml.safe_load(cfg_path.read_text(encoding="utf-8"))
            if isinstance(loaded, dict):
                config = loaded
        except Exception as e:
            return {"ok": False, "error": f"could not parse {cfg_path}: {e}"}

    backup = ""
    if cfg_path.is_file():
        backup = str(cfg_path) + f".bak.{time.strftime('%Y%m%d-%H%M%S')}"
        try:
            shutil.copy2(cfg_path, backup)
        except OSError as e:
            return {"ok": False, "error": f"backup failed: {e}"}

    providers = config.setdefault("providers", {})
    if not isinstance(providers, dict):
        providers = {}
        config["providers"] = providers

    entry = providers.get("omlx")
    if not isinstance(entry, dict):
        entry = {}
    entry.update({
        "name": "oMLX",
        "base_url": base_url,
        "api_key": api_key,
        "api_mode": "chat_completions",
        "default_model": model,
    })
    providers["omlx"] = entry

    model_cfg = config.get("model")
    if not isinstance(model_cfg, dict):
        model_cfg = {}
    # Drop the keys a previous provider left behind — these confuse Hermes when
    # the provider changes (this is what oMLX's own integration does).
    for stale in ("base_url", "api_key", "api", "api_mode", "transport",
                  "lmstudio_load_mode"):
        model_cfg.pop(stale, None)
    model_cfg["provider"] = "omlx"
    model_cfg["default"] = model
    if ctx:
        model_cfg["context_length"] = ctx
    else:
        model_cfg.pop("context_length", None)
    if max_tokens:
        model_cfg["max_tokens"] = max_tokens
    else:
        model_cfg.pop("max_tokens", None)
    config["model"] = model_cfg

    try:
        cfg_path.parent.mkdir(parents=True, exist_ok=True)
        text = yaml.safe_dump(config, sort_keys=False, allow_unicode=True)
        cfg_path.write_text(text.rstrip() + "\n", encoding="utf-8")
    except OSError as e:
        return {"ok": False, "error": f"write failed: {e}"}

    warn = ""
    if ctx and ctx < MIN_CONTEXT:
        warn = f"Hermes wants >= {MIN_CONTEXT:,} context; this profile is set to {ctx:,}"
    return {"ok": True, "config": str(cfg_path), "backup": backup, "warning": warn}


def main() -> None:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    pl = sub.add_parser("list")
    pl.add_argument("--home", default=str(Path.home() / ".hermes"))

    pa = sub.add_parser("apply")
    pa.add_argument("--home", required=True)
    pa.add_argument("--model", required=True)
    pa.add_argument("--base-url", required=True)
    pa.add_argument("--ctx", type=int, default=0)
    pa.add_argument("--max-tokens", type=int, default=0)
    pa.add_argument("--api-key", default="local")

    a = ap.parse_args()
    if a.cmd == "list":
        print(json.dumps({"profiles": discover(Path(a.home))}))
    else:
        print(json.dumps(apply(Path(a.home), a.model, a.base_url,
                               a.ctx or None, a.max_tokens or None, a.api_key)))


if __name__ == "__main__":
    main()
