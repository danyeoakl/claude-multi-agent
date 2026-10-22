#!/usr/bin/env bash
# Run Codex's built-in reviewer on one change: read-only sandbox, gpt-6.1-sol at max effort, no custom prompt
# (a prompt would replace the built-in review request, so only target flags are accepted).
# Usage, from inside the repo: review.sh [--uncommitted | --base <branch> | --commit <sha> [--title <subject>]]
# The default target is --uncommitted. The report goes to <main git dir>/codex-reviews/<UTC stamp>.md (shared by all
# worktrees) with the --json log beside it, so git status stays clean and --uncommitted never reviews its own output.
# CODEX_REVIEW_BIN names another codex launcher to use (default: codex on PATH).
# The last lines are status=done findings=<n> report=<path>, or status=failed reason=<why> log=<path> plus the
# log's tail. Works in Git Bash (Windows), macOS and Linux.
set -o pipefail
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
CODEX="${CODEX_REVIEW_BIN:-codex}"
[ $# -gt 0 ] || set -- --uncommitted
want=
for a in "$@"; do
  if [ -n "$want" ]; then want=; continue; fi
  case $a in
    --uncommitted|--base=?*|--commit=?*|--title=?*) ;;
    --base|--commit|--title) want=$a ;;
    *) echo "status=failed reason=unexpected argument $a (targets only)"; exit 2 ;;
  esac
done
[ -z "$want" ] || { echo "status=failed reason=$want needs a value"; exit 2; }
command -v "$CODEX" >/dev/null 2>&1 || { echo "status=failed reason=codex CLI not found ($CODEX)"; exit 3; }
REPO=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "status=failed reason=not inside a git repository"; exit 3; }
# The common dir, not --absolute-git-dir: a linked worktree's own git dir is deleted with the worktree.
DIR="$(git rev-parse --path-format=absolute --git-common-dir)/codex-reviews"
mkdir -p "$DIR" || { echo "status=failed reason=cannot create $DIR"; exit 3; }
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
REPORT="$DIR/$STAMP.md"
LOG="$DIR/$STAMP.log"
echo "target=$* report=$REPORT"
with_timeout() { if command -v timeout >/dev/null 2>&1; then timeout 1800 "$@"; else "$@"; fi; }
cd "$REPO" || exit 3
# Exec-level options (-s, -C) must come before the word "review".
with_timeout "$CODEX" exec -s read-only -C "$REPO" review "$@" \
  -m gpt-6.1-sol -c model_reasoning_effort=max -c review_model=gpt-6.1-sol \
  -o "$REPORT" --json </dev/null >"$LOG" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && [ -s "$REPORT" ]; then
  echo "status=done findings=$(grep -cE '^- \[P[0-9]\]' "$REPORT") report=$REPORT"
  exit 0
fi
case $rc in
  0) why="codex wrote no report" ;;
  124) why="timed out after 30 min" ;;
  *) why="codex exited $rc" ;;
esac
echo "status=failed reason=$why log=$LOG"
tail -n 8 "$LOG" | cut -c1-400
exit 1
