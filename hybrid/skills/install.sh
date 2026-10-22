#!/usr/bin/env bash
# Install the codex-review and x-research skills for this user, plus the CLAUDE.md block that turns them on.
# Usage: bash hybrid/skills/install.sh [--dry-run]
# Copies both skill folders into ~/.claude/skills/ (replacing older copies of just these two), and puts
# CLAUDE-snippet.md into ~/.claude/CLAUDE.md between the hybrid-cli-helpers marker lines: it creates the file if
# absent, replaces the block if present, and appends it otherwise. Safe to re-run. Works in Git Bash (Windows),
# macOS and Linux; no sudo. --dry-run prints the actions and changes nothing.
set -euo pipefail
DRY=
case "${1:-}" in
  "") ;;
  --dry-run) DRY=1 ;;
  *) echo "usage: $0 [--dry-run]" >&2; exit 2 ;;
esac
SRC=$(cd "$(dirname "$0")" && pwd)
SKILLS="${HOME:?}/.claude/skills"
MD="${HOME:?}/.claude/CLAUDE.md"
SNIPPET="$SRC/CLAUDE-snippet.md"
START='<!-- hybrid-cli-helpers:start -->'
END='<!-- hybrid-cli-helpers:end -->'
pre=; [ -n "$DRY" ] && pre="[dry-run] would "
block() { printf '%s\n' "$START"; awk 1 "$SNIPPET"; printf '%s\n' "$END"; }

[ -f "$SNIPPET" ] || { echo "missing $SNIPPET" >&2; exit 1; }
for skill in codex-review x-research; do
  [ -f "$SRC/$skill/SKILL.md" ] || { echo "missing $SRC/$skill/SKILL.md" >&2; exit 1; }
done
# Decide what to do with CLAUDE.md first, so bad markers stop the run before anything changes.
action=create
if [ -f "$MD" ]; then
  # Marker counts and order, ignoring CRLF line endings.
  read -r starts ends order < <(awk -v s="$START" -v e="$END" '
    { sub(/\r$/, "") }
    $0 == s { ns++; if (!fs) fs = NR }
    $0 == e { ne++; if (!fe) fe = NR }
    END { print ns + 0, ne + 0, (fs && fe && fs < fe) ? "ok" : "bad" }' "$MD")
  if [ "$starts" -eq 0 ] && [ "$ends" -eq 0 ]; then action=append
  elif [ "$starts" -eq 1 ] && [ "$ends" -eq 1 ] && [ "$order" = ok ]; then action=replace
  else
    echo "$MD has unmatched hybrid-cli-helpers markers ($starts start, $ends end); fix them by hand and re-run" >&2
    exit 1
  fi
fi

for skill in codex-review x-research; do
  if [ -e "$SKILLS/$skill" ]; then verb=replace; else verb=add; fi
  echo "${pre}${verb} $SKILLS/$skill"
  if [ -z "$DRY" ]; then
    mkdir -p "$SKILLS"
    rm -rf "${SKILLS:?}/${skill:?}"
    cp -R "$SRC/$skill" "$SKILLS/$skill"
  fi
done

case $action in
  create)
    echo "${pre}create $MD with the hybrid-cli-helpers block"
    [ -n "$DRY" ] || { mkdir -p "$(dirname "$MD")"; block > "$MD"; }
    ;;
  append)
    echo "${pre}append the hybrid-cli-helpers block to $MD"
    if [ -z "$DRY" ]; then
      { if [ -s "$MD" ]; then [ -z "$(tail -c1 "$MD")" ] || echo; echo; fi; block; } >> "$MD"
    fi
    ;;
  replace)
    echo "${pre}replace the hybrid-cli-helpers block in $MD"
    if [ -z "$DRY" ]; then
      tmp=$(mktemp "$MD.XXXXXX")
      awk -v s="$START" -v e="$END" -v f="$SNIPPET" '
        { line = $0; sub(/\r$/, "", line) }
        line == s { print s; while ((getline l < f) > 0) print l; print e; skip = 1; next }
        skip { if (line == e) skip = 0; next }
        { print }' "$MD" > "$tmp"
      cat "$tmp" > "$MD"   # keeps the file's own permissions
      rm -f "$tmp"
    fi
    ;;
esac

export PATH="$HOME/.local/bin:$HOME/.grok/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
command -v codex >/dev/null 2>&1 || echo "note: codex is not on PATH here, so codex-review will report itself unavailable"
command -v grok >/dev/null 2>&1 || echo "note: grok is not on PATH here, so x-research will report itself unavailable"
if [ -n "$DRY" ]; then echo "dry run: nothing changed"; else echo "done; new Claude Code sessions pick up /codex-review and /x-research"; fi
