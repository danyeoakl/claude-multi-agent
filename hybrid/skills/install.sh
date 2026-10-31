#!/usr/bin/env bash
# Install the codex-review and x-research skills for this user.
# Usage: bash hybrid/skills/install.sh [--dry-run]
# Copies both skill folders into ~/.claude/skills/, replacing older copies of just these two. Safe to re-run. Works in
# Git Bash (Windows), macOS and Linux; no sudo. --dry-run prints the actions and changes nothing.
set -euo pipefail
DRY=
case "${1:-}" in
  "") ;;
  --dry-run) DRY=1 ;;
  *) echo "usage: $0 [--dry-run]" >&2; exit 2 ;;
esac
SRC=$(cd "$(dirname "$0")" && pwd)
SKILLS="${HOME:?}/.claude/skills"
pre=; [ -n "$DRY" ] && pre="[dry-run] would "

for skill in codex-review x-research; do
  [ -f "$SRC/$skill/SKILL.md" ] || { echo "missing $SRC/$skill/SKILL.md" >&2; exit 1; }
done
for skill in codex-review x-research; do
  if [ -e "$SKILLS/$skill" ]; then verb=replace; else verb=add; fi
  echo "${pre}${verb} $SKILLS/$skill"
  if [ -z "$DRY" ]; then
    mkdir -p "$SKILLS"
    rm -rf "${SKILLS:?}/${skill:?}"
    cp -R "$SRC/$skill" "$SKILLS/$skill"
  fi
done

export PATH="$HOME/.local/bin:$HOME/.grok/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
command -v codex >/dev/null 2>&1 || echo "note: codex is not on PATH here, so codex-review will report itself unavailable"
command -v grok >/dev/null 2>&1 || echo "note: grok is not on PATH here, so x-research will report itself unavailable"
if [ -n "$DRY" ]; then echo "dry run: nothing changed"; else echo "done; new Claude Code sessions pick up /codex-review and /x-research"; fi
