#!/usr/bin/env bash
# Ask the Grok CLI, headless and read-only, to find projects, code, people or posts on X with its server-side X search.
# Usage: search.sh <slug> < ask.txt        (the user's ask on stdin)
# Saves Grok's full answer to ~/x-research/<YYYY-MM-DD>-<slug>.md, then prints a status block and the answer.
# Works in Git Bash (Windows), macOS and Linux. Needs python3 (python on Windows).
set -o pipefail
export PATH="$HOME/.local/bin:$HOME/.grok/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
ASK=$(cat)
[ -n "$ASK" ] || { echo "status=failed reason=no ask on stdin"; exit 2; }
command -v grok >/dev/null 2>&1 || { echo "status=failed reason=grok CLI not found on PATH"; exit 3; }
WIN=; command -v cygpath >/dev/null 2>&1 && WIN=1
PY=python3; [ -n "$WIN" ] && PY=python   # in Git Bash, python3 can be the Microsoft Store stub
SLUG=$(printf '%s' "${1:-search}" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9' '-' | sed 's/--*/-/g; s/^-//; s/-$//' | cut -c1-60)
mkdir -p "$HOME/x-research" || exit 3
DEST="$HOME/x-research/$(date +%Y-%m-%d)-${SLUG:-search}.md"
[ -e "$DEST" ] && DEST="${DEST%.md}-$(date +%H%M%S).md"

S=$(mktemp -d) || exit 3
trap 'cd "$HOME" 2>/dev/null || cd /; rm -rf "${S:?}"' EXIT
mkdir "$S/cwd" || exit 3
GCWD="$S/cwd"; [ -n "$WIN" ] && GCWD=$(cygpath -w "$GCWD")
printf '%s\n' "$ASK" > "$S/ask.txt"
{ printf 'Today is %s. Find on X (Twitter):\n\n%s\n\n' "$(date -u +%Y-%m-%d)" "$ASK"
  cat <<'EOF'
How to search:
- Use your X search tools first (keyword search, semantic search, thread fetch) to find the posts.
- Then use web search to confirm each project: open its GitHub repo or project page.
- Prefer recent posts and real projects with public code or a working product over announcements, waitlists and reposts.
- Only give URLs you actually saw in results. Never guess a URL.

Return up to 6 finds, best first. For each find give:
- Name
- Project or GitHub URL
- X post URL
- Author handle
- Post date
- One line on what it is
- One line on why it fits the ask

End with one line naming the search tools you used.
EOF
} > "$S/brief.md"

# Remove every client tool; Grok's server-side X search and web search stay. Never use --tools here: an allowlist
# also drops X search. web_fetch goes too, because a tool call that needs approval can cancel the whole headless turn.
DENY=run_terminal_cmd,search_replace,write,read_file,grep,list_dir,web_fetch,task,Agent,todo_write,scheduler_create,scheduler_delete,scheduler_list,monitor,workflow,image_gen,image_edit,image_to_video,reference_to_video,send_feedback,use_tool,search_tool,enter_plan_mode,exit_plan_mode,ask_user_question,kill_task,get_task_output,wait_tasks
# Don't let Grok load Claude Code or Cursor MCP servers, hooks, skills, rules or agents.
for v in CLAUDE CURSOR; do for k in MCPS HOOKS SKILLS RULES AGENTS; do export "GROK_${v}_${k}_ENABLED=false"; done; done
with_timeout() { if command -v timeout >/dev/null 2>&1; then timeout 600 "$@"; else "$@"; fi; }
cd "$S/cwd" || exit 3
# MSYS_NO_PATHCONV: Git Bash must not rewrite the prompt or the (already Windows) cwd as paths. No effect elsewhere.
MSYS_NO_PATHCONV=1 with_timeout grok -p "$(cat "$S/brief.md")" -m grok-4.7 --reasoning-effort xhigh --cwd "$GCWD" \
  --output-format streaming-messages-json --disallowed-tools "$DENY" --no-subagents --no-plan \
  >"$S/out.ndjson" 2>"$S/err.txt" </dev/null
rc=$?
cd "$HOME" || cd /

"$PY" -X utf8 - "$S/out.ndjson" "$S/err.txt" "$S/ask.txt" "$S/cwd" "$DEST" "$rc" <<'PY'
import collections, json, os, re, sys
out, err, askf, cwd, dest, rc = sys.argv[1:7]
ask = open(askf, encoding="utf-8").read().strip()
raw = open(out, encoding="utf-8", errors="replace").read() if os.path.exists(out) else ""
init = res = None
x_calls = web_calls = 0
names = collections.Counter()

def walk(node):
    # Count tool calls in assistant/user events only, never in answer text (which names the tools too).
    global x_calls, web_calls
    if isinstance(node, dict):
        kind = node.get("type")
        if kind == "tool_use":
            inp = node.get("input") if isinstance(node.get("input"), dict) else {}
            if inp.get("variant") == "XSearch":
                x_calls += 1
            elif inp.get("variant") == "WebSearch":
                web_calls += 1
        elif kind == "server_tool_use":
            web_calls += 1
        elif kind == "tool_result":
            names.update(re.findall(r"x_(?:keyword|semantic|user)_search|x_thread_fetch", json.dumps(node.get("content"))))
            return
        for value in node.values():
            walk(value)
    elif isinstance(node, list):
        for value in node:
            walk(value)

for line in raw.splitlines():
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if not isinstance(event, dict):
        continue
    if event.get("type") == "system" and event.get("subtype") == "init" and init is None:
        init = event
    elif event.get("type") == "result":
        res = event
    else:
        walk(event)

res = res or {}
text = (res.get("result") or "").strip()
stop, subtype = res.get("stop_reason"), res.get("subtype")
ok = subtype == "success" and stop == "end_turn" and bool(text)
toolset = (init or {}).get("tools")
extra = [t for t in (toolset or []) if t != "web_search"]
cwd_files = len(os.listdir(cwd)) if os.path.isdir(cwd) else 0
used = ", ".join(f"{k} x{v}" for k, v in sorted(names.items())) or "none"
saved = False
if text:
    title = ask.splitlines()[0][:120]
    with open(dest, "w", encoding="utf-8", newline="\n") as f:
        f.write(f"# X research: {title}\n\n")
        f.write(f"- Model: grok-4.7, effort xhigh. Run: {'complete' if ok else f'INCOMPLETE ({subtype}, {stop})'}\n")
        f.write(f"- X search calls: {x_calls} ({used}). Web search calls: {web_calls}.\n\n")
        f.write("## Ask\n\n" + "\n".join("> " + l for l in ask.splitlines()) + "\n\n## Grok's answer\n\n" + text + "\n")
    saved = True

if ok:
    print("status=ok")
else:
    if rc == "124":
        why = "timed out after 10 min"
    elif not res:
        why = f"grok produced no result (exit {rc})"
    elif not text:
        why = f"empty answer ({subtype}, {stop})"
    else:
        why = f"turn did not finish ({subtype}, {stop})"
    print(f"status=failed reason={why}")
print(f"grok_exit={rc} subtype={subtype} stop={stop}")
print(f"x_search_calls={x_calls} tools_seen={used} web_search_calls={web_calls}")
print(f"toolset={toolset} extra_tools={', '.join(extra) or 'none'}")
print(f"cwd_files={cwd_files}")
print(f"report={dest if saved else 'not saved (no answer)'}")
if os.path.exists(err):
    tail = [l.rstrip()[:300] for l in open(err, encoding="utf-8", errors="replace").read().splitlines() if l.strip()][-8:]
    if tail:
        print("stderr:")
        print("\n".join(tail))
print("----- answer -----")
print(text)
sys.exit(0 if ok else 1)
PY
