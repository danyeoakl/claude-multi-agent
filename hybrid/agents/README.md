# Named gateway workers

Three Claude Code agent files that run a subagent on a gateway model. Each one carries its own model and effort, so they work without the `hybrid-route` mod. Use them as the smoke test for a new setup, and as the fallback where the mod is not installed.

| Agent | Model | Effort | Tools |
| --- | --- | --- | --- |
| `codex` | `claude/chatgpt/gpt-6.1-sol` | xhigh | all (inherited) |
| `grok` | `claude/xai/grok-4.7` | xhigh | Read, Write, Edit, Glob, Grep, Bash, TodoWrite, SubagentHandback |
| `grok-fast` | `claude/xai/grok-4.7-build-fast` | medium | same as `grok` |

## Enable

Copy the files into one of these folders:

- `~/.claude/agents/`: every project;
- `<project>/.claude/agents/`: one project.

```sh
mkdir -p ~/.claude/agents && cp hybrid/agents/codex.md hybrid/agents/grok.md hybrid/agents/grok-fast.md ~/.claude/agents/
```

Leave this README out of the copy. The coordinator then calls `Agent(subagent_type: "codex", ...)`, `"grok"` or `"grok-fast"`.

## What they need

- **The gateway** serving these model names, with its ChatGPT and xAI logins done (see the top-level README and OPS.md).
- **The router** (`hybrid/router`), which sends `claude/...` requests to the gateway. Without it, a worker fails at once with a 404 `model_not_found` from the Anthropic API. Nothing falls back to Claude silently.
- **`CLAUDE_CODE_MODEL_CAPABILITIES`** in `~/.claude/settings.json`, so Claude Code sends effort to these models. The value is in `../mod/README.md`.

## Why the Grok tool list is short

- **WebSearch and WebFetch are left out.** Claude Code's web search reaches the Responses API as a `web_search_preview` tool, which xAI is expected to reject.
- **A short list keeps requests small.** Without `tools:`, a subagent inherits every tool in the session, MCP tools included.
- **SubagentHandback is listed** because in auto mode a subagent reports back through it. An allowlist without it may leave the worker unable to report.
- **Glob and Grep** are not registered by the native Linux and macOS builds. There the worker searches with Bash.

The body of each file is a short worker contract, adapted from `skills/codex-fallback/references/worker-preamble.md`.

**Also required:** `CLAUDE_CODE_TETHER_LIVE=false` and `CLAUDE_CODE_SLEEPY_SNOWFLAKE=off` in the user
settings' `env`, or gateway subagents lose their history after the first turn. See
`hybrid/router/README.md`, "Required Claude Code settings".
