#!/bin/zsh
# Check for and apply oMLX server updates.
#
#   omlx-update.sh check          -> JSON {installed, latest, available, ...}
#   omlx-update.sh apply <tag>    -> checkout, reinstall, restart
#
# AI_ROOT defaults to ~/AI. Applying restarts the server.
set -uo pipefail

AI_ROOT="${AI_ROOT:-$HOME/AI}"
SRC="$AI_ROOT/omlx/src"
VENV="$AI_ROOT/omlx/.venv"
CTL="$AI_ROOT/omlx/bin/omlxctl"
REPO="jundot/omlx"

installed_version() {
  "$VENV/bin/omlx" --version 2>/dev/null | tr -d '[:space:]'
}

# Newest release GitHub does not mark as a prerelease, plus the newest overall.
latest_tags() {
  curl -fsSL "https://api.github.com/repos/$REPO/releases?per_page=30" 2>/dev/null \
  | /usr/bin/python3 -c '
import sys, json
try:
    rs = json.load(sys.stdin)
except Exception:
    print("|"); raise SystemExit
stable = next((r["tag_name"] for r in rs if not r.get("prerelease")), "")
newest = rs[0]["tag_name"] if rs else ""
print(f"{stable}|{newest}")
'
}

case "${1:-}" in
  check)
    inst="$(installed_version)"
    IFS='|' read -r stable newest <<< "$(latest_tags)"
    /usr/bin/python3 -c '
import sys, json
inst, stable, newest = sys.argv[1], sys.argv[2], sys.argv[3]
def norm(t): return t.lstrip("v")
avail = bool(stable) and norm(stable) != inst
print(json.dumps({
    "installed": inst or "unknown",
    "latest": norm(stable) if stable else "",
    "latest_tag": stable,
    "newest_tag": newest,
    "available": avail,
}))
' "$inst" "$stable" "$newest"
    ;;

  apply)
    tag="${2:-}"
    [[ -n "$tag" ]] || { echo '{"ok":false,"error":"no tag given"}'; exit 1; }
    [[ -d "$SRC/.git" ]] || { echo '{"ok":false,"error":"no oMLX source checkout"}'; exit 1; }

    # The install may be a shallow clone; deepen it so tags resolve.
    git -C "$SRC" fetch --tags --unshallow >/dev/null 2>&1 \
      || git -C "$SRC" fetch --tags >/dev/null 2>&1

    if ! git -C "$SRC" rev-parse "$tag" >/dev/null 2>&1; then
      echo "{\"ok\":false,\"error\":\"tag $tag not found after fetch\"}"; exit 1
    fi

    prev="$(git -C "$SRC" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    [[ "$prev" == "HEAD" ]] && prev="$(git -C "$SRC" rev-parse HEAD)"

    if ! git -C "$SRC" checkout --quiet "$tag" 2>/dev/null; then
      echo '{"ok":false,"error":"checkout failed (local changes?)"}'; exit 1
    fi

    export PATH="$HOME/.local/bin:$PATH"
    if ! VIRTUAL_ENV="$VENV" uv pip install --quiet -e "$SRC" >/dev/null 2>&1; then
      # Put the previous revision back so the server still starts.
      git -C "$SRC" checkout --quiet "$prev" 2>/dev/null
      VIRTUAL_ENV="$VENV" uv pip install --quiet -e "$SRC" >/dev/null 2>&1
      echo '{"ok":false,"error":"install failed — rolled back"}'; exit 1
    fi

    "$CTL" restart >/dev/null 2>&1
    for i in {1..40}; do
      [[ "$("$CTL" status 2>/dev/null)" == "running" ]] && break
      sleep 1
    done
    now="$(installed_version)"
    up="$("$CTL" status 2>/dev/null)"
    echo "{\"ok\":true,\"installed\":\"$now\",\"server\":\"$up\"}"
    ;;

  *) echo '{"ok":false,"error":"usage: check | apply <tag>"}'; exit 2 ;;
esac
