import type { EngineInterface, Register } from 'claude-code'

// hybrid-route: per-call gateway models on Agent calls, without patching Claude Code.
// - tool.call: Agent(model: <gateway model>) is taken off the call before the schema
//   check (its enum is sonnet/opus/haiku/fable) and remembered by tool_use_id. An unknown
//   model, or an explicit effort the model lacks, is refused; effort is never lowered.
//   The same effort check covers the named workers (codex, grok, grok-fast in hybrid/agents).
// - agent.spawn: names the remembered model for that call's subagent; a fork, which ignores it, is refused.
// - turn.step: a resumed subagent (SendMessage to a finished agent, or after a restart)
//   stays on the gateway model and effort it first stepped with; kept across sessions in $.store.
// Sending claude/... requests to the gateway is the router's job, not this mod's.

// The gateway's models and the effort each accepts. Keep in step with the gateway's
// roster and with CLAUDE_CODE_MODEL_CAPABILITIES (see README.md).
const EFFORT = ['low', 'medium', 'high', 'xhigh', 'max']
const MODELS = new Map<string, string[]>([
  ['claude/chatgpt/gpt-6.1-sol', EFFORT],
  ['claude/chatgpt/gpt-6-astra', EFFORT],
  ['claude/xai/grok-4.7', EFFORT.slice(0, 4)],
  ['claude/xai/grok-4.7-build-fast', EFFORT.slice(0, 4)],
  ['claude/xai/grok-4.6', EFFORT.slice(0, 4)],
  ['claude/xai/grok-4.5', EFFORT.slice(0, 3)],
])
// The named workers' models (hybrid/agents/*.md), for the effort check on Agent(subagent_type: ...)
const WORKERS = new Map<string, string>([
  ['codex', 'claude/chatgpt/gpt-6.1-sol'],
  ['grok', 'claude/xai/grok-4.7'],
  ['grok-fast', 'claude/xai/grok-4.7-build-fast'],
])
const CLAUDE = new Set(['sonnet', 'opus', 'haiku', 'fable'])
const KEEP = 500 // subagents remembered in $.store; the oldest go first

type Kept = { model: string; effort?: string | number }
const wanted = new Map<string, string>() // Agent tool_use_id -> gateway model, until its spawn
const known = new Map<string, Kept | null>() // agentId -> gateway model and effort (null: none); cache of $.store

const isGateway = (model: unknown): model is string => typeof model === 'string' && MODELS.has(model)
const refuseEffort = (model: string, effort: unknown) => {
  const levels = MODELS.get(model)!
  return effort !== undefined && !levels.includes(effort as string)
    ? { deny: `hybrid-route: ${model} supports effort ${levels.join(', ')}, not ${effort}; retry with one of those.` }
    : undefined
}

async function recall($: EngineInterface, agentId: string) {
  if (!known.has(agentId)) {
    const stored = (await $.store.get(`agent:${agentId}`)) as unknown
    // entries written before effort was kept are plain model strings
    const kept = typeof stored === 'string' ? { model: stored } : (stored as Kept | undefined)
    known.set(agentId, kept && isGateway(kept.model) ? kept : null)
  }
  return known.get(agentId)
}

async function remember($: EngineInterface, agentId: string, kept: Kept) {
  known.set(agentId, kept)
  await $.store.set(`agent:${agentId}`, kept)
  const keys = await $.store.keys()
  for (const key of keys.slice(0, Math.max(0, keys.length - KEEP))) await $.store.delete(key)
}

export const register: Register = on => {
  on('tool.call', { tool: 'Agent' }, ($, e, next) => {
    const { model, effort, subagent_type } = e as { model?: unknown; effort?: unknown; subagent_type?: unknown }
    if (model === undefined && typeof subagent_type === 'string' && WORKERS.has(subagent_type))
      return refuseEffort(WORKERS.get(subagent_type)!, effort) ?? next(e)
    if (typeof model !== 'string' || CLAUDE.has(model)) return next(e)
    if (!MODELS.has(model))
      return { deny: `hybrid-route: unknown model ${model}. Gateway models: ${[...MODELS.keys()].join(', ')}. Claude models: ${[...CLAUDE].join(', ')}.` }
    const refused = refuseEffort(model, effort)
    if (refused) return refused
    wanted.set(e.tool_use_id, model)
    const { model: _, ...rest } = e
    return next(rest)
  }).catch(($, e, next) => next(e)) // passes the call as it came; an off-enum model then fails the schema loudly

  on('agent.spawn', ($, e, next) => {
    const model = wanted.get(e.tool_use_id)
    if (!model) return next(e)
    wanted.delete(e.tool_use_id)
    // A fork always runs on its parent's model and ignores this one: refuse rather than run on Claude.
    if (e.fork) return { deny: `hybrid-route: a fork runs on its parent's model, not ${model}; use another subagent_type (general-purpose, say).` }
    return next({ ...e, model })
  }).catch(($, e, next) => next(e))

  on('turn.step', async function* ($, e, next) {
    if (!e.agentId) return yield* next(e)
    let kept: Kept | null | undefined
    try {
      kept = await recall($, e.agentId)
      if (!kept && isGateway(e.model)) await remember($, e.agentId, { model: e.model, effort: e.effort })
    } catch {} // the store is a convenience: a failure leaves the step as it came
    if (!kept || kept.model === e.model) return yield* next(e)
    return yield* next({ ...e, model: kept.model, ...(kept.effort !== undefined ? { effort: kept.effort } : {}) })
  })
}
