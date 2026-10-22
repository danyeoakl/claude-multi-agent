import { expect, test } from 'claude-code/testing'

// The engine beneath the mod, kept minimal: Agent spawns as core would, steps record
// the model they were sent on, and the plugin's store is a plain object.
function engine($: any, on: any, store: Record<string, unknown> = {}) {
  const seen: { call?: any; spawn?: any; steps: string[] } = { steps: [] }
  on('store.get', (_: any, e: any) => ({ value: store[e.key] }))
  on('store.set', (_: any, e: any) => ({ value: void (store[e.key] = e.value) }))
  on('store.delete', (_: any, e: any) => ({ value: void delete store[e.key] }))
  on('store.keys', () => ({ value: Object.keys(store) }))
  on('agent.spawn', (_: any, e: any) => ({ model: e.model ?? e.parentModel, agentId: 'a-new' }))
  on('tool.call', { tool: 'Agent' }, async (_: any, e: any) => {
    seen.call = e
    seen.spawn = await $.agent.spawn({
      tool_use_id: e.tool_use_id, prompt: e.prompt, description: e.description, subagentType: 'general-purpose',
      provider: { plugin: 'engine', tier: 'core' }, model: e.model, parentModel: 'claude-opus-5-5', background: true, fork: false,
    })
    return { result: { status: 'async_launched', agentId: seen.spawn.agentId } }
  })
  on('turn.step', async function* (_: any, e: any) {
    seen.steps.push(e.model)
    return { turnId: e.turnId, index: e.index, answer: 'OK', toolUses: [], stopReason: 'end_turn', usage: null }
  })
  return seen
}

const agent = (args: object) => ({ tool: 'Agent', tool_use_id: `tu-${Math.random()}`, description: 'probe', prompt: 'Say OK', ...args }) as any
async function step($: any, model: string, agentId?: string) {
  const stream = $.turn.step({ turnId: 't', index: 0, model, messageCount: 1, ...(agentId && { agentId }) })
  for await (const _ of stream);
  return stream.result
}

test('a gateway model leaves the Agent call and reaches the spawn', async ($, on) => {
  const seen = engine($, on)
  await $.tool.call(agent({ model: 'claude/xai/grok-4.7', effort: 'xhigh' }))
  expect(seen.call.model).toBe(undefined)
  expect(seen.call.effort).toBe('xhigh')
  expect(seen.spawn.model).toBe('claude/xai/grok-4.7')
})

test('a gateway model without an effort gets its default', async ($, on) => {
  const seen = engine($, on)
  for (const [model, effort] of [['claude/chatgpt/gpt-6-astra', 'max'], ['claude/xai/grok-4.7', 'xhigh'],
                                 ['claude/xai/grok-4.5', 'high'], ['claude/xai/grok-4.7-build-fast', 'medium']]) {
    await $.tool.call(agent({ model }))
    expect(seen.call.effort).toBe(effort)
  }
  await $.tool.call(agent({ model: 'claude/chatgpt/gpt-6.1-sol', effort: 'low' }))
  expect(seen.call.effort).toBe('low')
})

test("Claude's own models and calls without a model pass untouched", async ($, on) => {
  const seen = engine($, on)
  await $.tool.call(agent({ model: 'haiku' }))
  expect(seen.call.model).toBe('haiku')
  await $.tool.call(agent({ subagent_type: 'Explore' }))
  expect(seen.spawn.model).toBe('claude-opus-5-5')
})

test('an unknown model and an effort the model lacks are refused', async ($, on) => {
  const seen = engine($, on)
  const unknown = await $.tool.call(agent({ model: 'claude/xai/grok-9' }))
  expect(JSON.stringify(unknown)).toContain('hybrid-route: unknown model claude/xai/grok-9. Gateway models: claude/chatgpt/gpt-6.1-sol')
  const effort = await $.tool.call(agent({ model: 'claude/xai/grok-4.5', effort: 'xhigh' }))
  expect(JSON.stringify(effort)).toContain('claude/xai/grok-4.5 supports effort low, medium, high, not xhigh')
  expect(seen.call).toBe(undefined)
})

test('a resumed subagent stays on its gateway model, kept in the store', async ($, on) => {
  const store: Record<string, unknown> = { 'agent:a-old': 'claude/chatgpt/gpt-6.1-sol' }
  for (let i = 0; i < 499; i++) store[`agent:fill-${i}`] = 'claude/xai/grok-4.6'
  const seen = engine($, on, store)
  await step($, 'claude-opus-5-5', 'a-old') // from an earlier session
  await step($, 'claude/xai/grok-4.7', 'a-new') // first step records it, dropping the oldest
  await step($, 'claude-opus-5-5', 'a-new') // resumed without the per-call model
  await step($, 'claude-opus-5-5', 'a-claude') // a Claude subagent is left alone
  await step($, 'claude-opus-5-5') // so is the main loop
  expect(seen.steps).toEqual(['claude/chatgpt/gpt-6.1-sol', 'claude/xai/grok-4.7', 'claude/xai/grok-4.7', 'claude-opus-5-5', 'claude-opus-5-5'])
  expect(store['agent:a-new']).toEqual({ model: 'claude/xai/grok-4.7', effort: undefined })
  expect(store['agent:a-old']).toBe(undefined)
  expect(Object.keys(store).length).toBe(500)
})
