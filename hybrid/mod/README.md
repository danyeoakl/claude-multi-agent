# hybrid-route

A Claude Code mod (a plugin of function hooks) that lets any Agent call name a gateway model, TJ-style, without patching Claude Code:

```
Agent(subagent_type: "Explore", model: "claude/xai/grok-4.7", effort: "high", prompt: "...")
```

The Agent tool's own `model` parameter only takes `sonnet`, `opus`, `haiku` and `fable`. The mod handles any other value before that check.

## What it does

All three hooks are in `hooks/register.ts`:

- **`tool.call` (Agent):**
  - It sees the call's raw input before the schema check.
  - When `model` is a gateway model, the mod takes it off the call and remembers it by the call's `tool_use_id`.
  - It refuses an unknown model, listing the gateway models and Claude's own.
  - It refuses an explicit `effort` the model does not support, naming that model's levels. Effort is never lowered silently.
  - Claude's own models, and calls without a model, pass through untouched.
- **`agent.spawn`:** names the remembered model for that call's subagent. A fork always runs on its parent's model, so a gateway model on a fork is refused rather than run on Claude.
- **`turn.step`:**
  - It records each subagent's gateway model by agent id, keeping the newest 500 in the plugin's own store (`$.store`), so the record survives a restart.
  - A resumed subagent (a SendMessage to a finished agent, in the same session or after a restart) may step without the per-call model. The mod then puts it back on the gateway model it started on.

**When a hook fails,** the call goes on as it came. An off-list model then fails the Agent schema check loudly, rather than running on the wrong model.

## Gateway models

The table is `MODELS` in `hooks/register.ts`. The mod engine loads only script files, so the table can't be a JSON file.

| Model | Effort levels |
| --- | --- |
| `claude/chatgpt/gpt-6.1-sol` | low, medium, high, xhigh, max |
| `claude/chatgpt/gpt-6-astra` | low, medium, high, xhigh, max |
| `claude/xai/grok-4.7` | low, medium, high, xhigh |
| `claude/xai/grok-4.7-build-fast` | low, medium, high, xhigh |
| `claude/xai/grok-4.6` | low, medium, high, xhigh |
| `claude/xai/grok-4.5` | low, medium, high |

When the gateway's roster changes, change this table and `CLAUDE_CODE_MODEL_CAPABILITIES` (below) together.

## What it does not do

**It doesn't route anything.** A subagent on `claude/xai/grok-4.7` still sends its request to the session's API address. Getting `claude/...` requests to the LiteLLM gateway is the router's job (`hybrid/router`). Without the router, such a subagent fails at once with a 404 `model_not_found`, and nothing falls back to Claude silently.

**It doesn't name workers.** The named workers (`hybrid/agents`) carry their model in the agent file and work without this mod.

## Install

Run these with the Claude Code CLI on the machine where the sessions run:

```sh
claude plugin marketplace add /path/to/claude-multi-agent
claude plugin install hybrid-route@tpurtell-agent-tools --scope user
```

**About the marketplace:**
- The marketplace is this repository's `.claude-plugin/marketplace.json`.
- Installing copies the mod into Claude Code's plugin cache, one folder per version. Sessions run that copy, not the checkout.
- After changing the mod, bump `version` in `hybrid/mod/.claude-plugin/plugin.json` and in its marketplace entry. Then run `claude plugin marketplace update tpurtell-agent-tools` and `claude plugin update hybrid-route@tpurtell-agent-tools --scope user`, and start a new session.

**Set the effort capabilities.** Add this to `~/.claude/settings.json`:

```json
{
  "env": {
    "CLAUDE_CODE_MODEL_CAPABILITIES": "claude/chatgpt/*=effort,xhigh_effort,max_effort;claude/xai/*=effort,xhigh_effort,-max_effort;claude/xai/grok-4.5=-xhigh_effort"
  }
}
```

- **What it does:** it tells Claude Code which effort levels each gateway model takes, so effort is sent to them at all.
- **Its syntax:** entries are separated by `;`, a trailing `*` matches a prefix, and later entries win.
- **Where it goes:** user settings or the launch environment. A project's `.claude/settings.json` cannot set this key.

## Check

```sh
claude plugin validate hybrid/mod
claude plugin test hybrid/mod
```

The tests in `tests/route.test.ts` run the hooks against the engine's own test kit. They cover:
- the per-call route;
- the refusals;
- pass-through for Claude models;
- the resume rewrite, with the bounded store.

**Also required:** `CLAUDE_CODE_TETHER_LIVE=false` and `CLAUDE_CODE_SLEEPY_SNOWFLAKE=off` in the user
settings' `env`, or gateway subagents lose their history after the first turn. See
`hybrid/router/README.md`, "Required Claude Code settings".
