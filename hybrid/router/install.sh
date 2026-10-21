#!/bin/bash
# Run the hybrid router as systemd --user units, then point one Claude Code settings file at it.
# Usage: install.sh <settings.json>     e.g. ~/.claude/settings.json or <project>/.claude/settings.json
# Optional env: PORT (4110), CA_DIR (~/.config/tj-hybrid/router), GATEWAY (http://127.0.0.1:4000),
#   KEY_FILE (${CMA_HOME:-~/.local/share/claude-multi-agent}/gateway-key.json).
# The settings file changes only once the router answers /healthz. Re-running updates the units and restarts
# the router, which cuts requests in flight.
set -euo pipefail
[ $# -eq 1 ] || { echo "usage: $0 <settings.json>" >&2; exit 2; }
DIR=$(cd "$(dirname "$0")" && pwd)
SETTINGS=$(realpath -ms "$1")
PORT=${PORT:-4110}
CA_DIR=$(realpath -ms "${CA_DIR:-$HOME/.config/tj-hybrid/router}")
GATEWAY=${GATEWAY:-http://127.0.0.1:4000}
KEY_FILE=$(realpath -ms "${KEY_FILE:-${CMA_HOME:-$HOME/.local/share/claude-multi-agent}/gateway-key.json}")
NODE=$(command -v node) || { echo "node (22) is required" >&2; exit 1; }
PYTHON=$(command -v python3) || { echo "python3 is required" >&2; exit 1; }
UNITS=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user

[ -f "$KEY_FILE" ] || echo "note: no gateway key at $KEY_FILE yet; gateway models get a 502 until it exists" >&2
"$DIR/make-ca.sh" "$CA_DIR"
render() { # fill the @NAME@ placeholders; % is doubled for systemd
  local text name value
  text=$(<"$DIR/systemd/$1")
  for name in NODE PYTHON DIR PORT CA_DIR GATEWAY KEY_FILE SETTINGS; do
    value=${!name}; text=${text//@$name@/"${value//\%/%%}"}
  done
  printf '%s\n' "$text" > "$UNITS/$1"
}
mkdir -p "$UNITS"
for unit in tj-hybrid-router.service tj-hybrid-watchdog.service tj-hybrid-watchdog.timer; do render "$unit"; done
systemctl --user daemon-reload
systemctl --user enable tj-hybrid-router.service
systemctl --user restart tj-hybrid-router.service
ok=
for _ in $(seq 20); do "$PYTHON" "$DIR/watchdog.py" health --port "$PORT" && { ok=1; break; }; sleep 0.5; done
[ -n "$ok" ] || { echo "router not healthy on 127.0.0.1:$PORT; $SETTINGS left unchanged (journalctl --user -u tj-hybrid-router)" >&2; exit 1; }
systemctl --user enable --now tj-hybrid-watchdog.timer
"$PYTHON" "$DIR/watchdog.py" enable --settings "$SETTINGS" --port "$PORT" --ca-dir "$CA_DIR"
loginctl show-user "$(id -un)" -p Linger 2>/dev/null | grep -q '=yes' ||
  echo "note: user units stop when the last login session ends; as root: loginctl enable-linger $(id -un)"
echo "router on 127.0.0.1:$PORT, watchdog every 15 s on $SETTINGS; new Claude Code sessions route through it"
