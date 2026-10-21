#!/bin/bash
# Undo install.sh: take the three proxy keys out of the settings file first, so new sessions go straight to
# Anthropic, then stop and remove the units. The CA folder is kept; delete it to drop the CA key as well.
# Usage: uninstall.sh <settings.json>   (the file given to install.sh, with the same PORT / CA_DIR if overridden)
set -euo pipefail
[ $# -eq 1 ] || { echo "usage: $0 <settings.json>" >&2; exit 2; }
DIR=$(cd "$(dirname "$0")" && pwd)
SETTINGS=$(realpath -ms "$1")
PORT=${PORT:-4110}
CA_DIR=$(realpath -ms "${CA_DIR:-$HOME/.config/tj-hybrid/router}")
UNITS=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user

python3 "$DIR/watchdog.py" disable --settings "$SETTINGS" --port "$PORT" --ca-dir "$CA_DIR"
systemctl --user disable --now tj-hybrid-watchdog.timer tj-hybrid-router.service 2>/dev/null || true
systemctl --user stop tj-hybrid-watchdog.service 2>/dev/null || true
rm -f "$UNITS/tj-hybrid-router.service" "$UNITS/tj-hybrid-watchdog.service" "$UNITS/tj-hybrid-watchdog.timer"
systemctl --user daemon-reload
systemctl --user reset-failed tj-hybrid-router.service tj-hybrid-watchdog.service 2>/dev/null || true
echo "router removed; restart Claude Code sessions that were using it. CA kept in $CA_DIR"
