#!/usr/bin/env node
// Hybrid router: the HTTPS_PROXY of Claude Code sessions that keeps the session itself on api.anthropic.com
// (so Remote Control keeps working) while gateway-model requests go to the local LiteLLM gateway.
// - CONNECT api.anthropic.com:443 is terminated with a leaf cert from a CA name-constrained to api.anthropic.com.
//   POST /v1/messages and /v1/messages/count_tokens whose model is claude/<provider>/... (but not
//   claude/anthropic/...) go to the gateway, with the client's credentials replaced by the restricted gateway key;
//   count_tokens for those models is estimated locally. Everything else, upgrades included, goes to the real
//   api.anthropic.com unchanged. A gateway model never falls back to Anthropic: gateway errors are a 502.
// - CONNECT to any other host is a plain TCP tunnel. GET /healthz is answered on the proxy port itself.
// Logs one line per request (method, path without query, model, route, status). Never header values or bodies.
// Usage: node router.mjs [--port 4110] [--ca-dir DIR] [--gateway http://127.0.0.1:4000] [--key gateway-key.json]
import { X509Certificate } from 'node:crypto'
import fs from 'node:fs'
import http from 'node:http'
import https from 'node:https'
import net from 'node:net'
import os from 'node:os'
import tls from 'node:tls'
import { parseArgs } from 'node:util'

const home = os.homedir()
const { values: opt } = parseArgs({ options: {
  port: { type: 'string', default: '4110' },
  'ca-dir': { type: 'string', default: `${home}/.config/tj-hybrid/router` },
  gateway: { type: 'string', default: 'http://127.0.0.1:4000' },
  key: { type: 'string', default: `${process.env.CMA_HOME || `${home}/.local/share/claude-multi-agent`}/gateway-key.json` },
} })
const PORT = Number(opt.port), DIR = opt['ca-dir'], KEY_FILE = opt.key
const GATEWAY = new URL(opt.gateway), BASE = GATEWAY.pathname.replace(/\/$/, '')
const ANTHROPIC = 'api.anthropic.com'
const MESSAGES = new Set(['/v1/messages', '/v1/messages/count_tokens'])
const DROP = new Set(['host', 'authorization', 'x-api-key', 'x-litellm-api-key', 'proxy-authorization',
  'connection', 'proxy-connection', 'keep-alive']) // client headers never sent to the gateway
const CONNECT_MS = 10_000, IDLE_MS = 960_000 // the gateway's own routes time out at 900 s
const agents = { 'https:': new https.Agent({ keepAlive: true }), 'http:': new http.Agent({ keepAlive: true }) }
const log = (...a) => console.log(new Date().toISOString(), ...a)
const pathOf = url => url.split('?')[0]
const failure = code => Object.assign(new Error(code), { code })
const apiError = message => ({ type: 'error', error: { type: 'api_error', message } })
const reply = (res, status, value) => {
  res.writeHead(status, { 'content-type': 'application/json' }); res.end(JSON.stringify(value))
}

// The leaf is re-read when make-ca.sh renews it; a half-written pair keeps the previous one until the next try
let leaf = {}
const loadLeaf = () => {
  try {
    const stamp = ['leaf-cert.pem', 'leaf-key.pem'].map(f => fs.statSync(`${DIR}/${f}`).mtimeMs).join()
    if (stamp !== leaf.stamp) {
      const cert = fs.readFileSync(`${DIR}/leaf-cert.pem`), key = fs.readFileSync(`${DIR}/leaf-key.pem`)
      leaf = { stamp, context: tls.createSecureContext({ cert, key }), until: Date.parse(new X509Certificate(cert).validTo) }
    }
  } catch (e) { log('leaf certificate unusable:', e.code ?? 'invalid') }
  return leaf
}
// The restricted gateway key is re-read when its file changes. Errors carry a code only, never file content.
let gatewayKey = {}
const loadKey = () => {
  const st = fs.statSync(KEY_FILE), stamp = `${st.mtimeMs}:${st.size}`
  if (stamp !== gatewayKey.stamp) {
    let key
    try { key = JSON.parse(fs.readFileSync(KEY_FILE, 'utf8')).key } catch (e) { throw failure(e.code ?? 'EBADKEY') }
    if (typeof key !== 'string' || !key) throw failure('EBADKEY')
    gatewayKey = { stamp, key }
  }
  return gatewayKey.key
}

// One upstream request; the response is relayed as is. Before a response, errors are an Anthropic-style 502;
// a gateway stream that breaks midway ends with an SSE error event, so a subagent never ends silently.
function send(req, res, { body, model, route, done, options, message }) {
  let gone = false
  const up = (options.protocol === 'https:' ? https : http).request(options, upRes => {
    done(model, route, upRes.statusCode)
    res.writeHead(upRes.statusCode, upRes.statusMessage, upRes.rawHeaders)
    upRes.pipe(res)
    upRes.on('error', e => {
      if (route === 'gateway' && !gone && !res.writableEnded && /event-stream/.test(upRes.headers['content-type'] ?? ''))
        res.end(`event: error\ndata: ${JSON.stringify(apiError(`hybrid gateway stream interrupted: ${e.code ?? 'aborted'}`))}\n\n`)
      else res.destroy()
    })
  })
  const timer = setTimeout(() => up.destroy(failure('ETIMEDOUT')), CONNECT_MS)
  up.on('socket', s => s.connecting ? s.once('connect', () => clearTimeout(timer)) : clearTimeout(timer))
  up.on('close', () => clearTimeout(timer))
  up.on('timeout', () => up.destroy(failure('ETIMEDOUT')))
  up.on('error', e => {
    if (res.headersSent) return
    done(model, route, gone ? 499 : 502)
    if (!gone) reply(res, 502, apiError(`${message}: ${e.code ?? 'error'}`))
  })
  res.on('close', () => { if (!res.writableFinished) { gone = true; up.destroy() } }) // client left: stop upstream work
  req.on('error', () => up.destroy())
  body ? up.end(body) : req.pipe(up)
}

// The inner HTTP server sees the decrypted api.anthropic.com traffic
const inner = http.createServer((req, res) => {
  const t0 = Date.now(), path = pathOf(req.url)
  const done = (model, route, status) => log(req.method, path, model ?? '-', route, status, `${Date.now() - t0}ms`)
  const anthropic = (body, model) => send(req, res, { body, model, route: 'anthropic', done,
    message: 'hybrid router: api.anthropic.com unreachable', options: { protocol: 'https:', host: ANTHROPIC, port: 443,
      servername: ANTHROPIC, agent: agents['https:'], method: req.method, path: req.url, headers: req.rawHeaders } })
  if (req.method !== 'POST' || !MESSAGES.has(path)) return anthropic()
  const chunks = []
  req.on('data', c => chunks.push(c))
  req.on('end', () => {
    const body = Buffer.concat(chunks)
    let model
    try { model = JSON.parse(body.toString('utf8')).model } catch {}
    if (typeof model !== 'string' || !model.startsWith('claude/') || model.startsWith('claude/anthropic/')) return anthropic(body, model)
    if (path.endsWith('/count_tokens')) { done(model, 'local', 200); return reply(res, 200, { input_tokens: Math.ceil(body.length / 4) }) }
    let key
    try { key = loadKey() } catch (e) { done(model, 'gateway', 502); return reply(res, 502, apiError(`hybrid gateway key unavailable: ${e.code}`)) }
    const headers = ['Host', GATEWAY.host]
    for (let i = 0; i < req.rawHeaders.length; i += 2)
      if (!DROP.has(req.rawHeaders[i].toLowerCase())) headers.push(req.rawHeaders[i], req.rawHeaders[i + 1])
    headers.push('x-litellm-api-key', `Bearer ${key}`, 'authorization', `Bearer ${key}`)
    send(req, res, { body, model, route: 'gateway', done, message: 'hybrid gateway unreachable', options: {
      protocol: GATEWAY.protocol, hostname: GATEWAY.hostname, port: GATEWAY.port, path: BASE + req.url, method: 'POST',
      headers, agent: agents[GATEWAY.protocol], timeout: IDLE_MS } })
  })
})
inner.keepAliveTimeout = 120_000
inner.on('clientError', (e, sock) => sock.destroy())
// WebSocket and other upgrades go to api.anthropic.com: replay the request head, then pipe both ways
inner.on('upgrade', (req, sock, head) => {
  const t0 = Date.now(), path = pathOf(req.url)
  let open = false
  const up = tls.connect({ host: ANTHROPIC, port: 443, servername: ANTHROPIC, ALPNProtocols: ['http/1.1'] }, () => {
    open = true
    const lines = [`${req.method} ${req.url} HTTP/1.1`]
    for (let i = 0; i < req.rawHeaders.length; i += 2) lines.push(`${req.rawHeaders[i]}: ${req.rawHeaders[i + 1]}`)
    up.write(lines.join('\r\n') + '\r\n\r\n')
    if (head?.length) up.write(head)
    up.pipe(sock); sock.pipe(up)
    up.once('data', c => log(req.method, path, '-', 'anthropic',
      c.toString('latin1', 0, 12).match(/^HTTP\/1\.[01] (\d{3})/)?.[1] ?? '?', `${Date.now() - t0}ms`))
  })
  up.on('error', e => {
    if (open) return sock.destroy()
    log(req.method, path, '-', 'anthropic', 502, e.code ?? 'error')
    sock.end('HTTP/1.1 502 Bad Gateway\r\n\r\n')
  })
  up.on('close', () => { if (open) sock.destroy() })
  sock.on('error', () => up.destroy())
  sock.on('close', () => up.destroy())
})

// GET /healthz: 200 while the router can serve (the leaf is valid); reports whether the gateway answers
function health(res) {
  const ok = !!loadLeaf().context && leaf.until > Date.now()
  let sent = false
  const answer = gateway => {
    if (sent) return
    sent = true
    reply(res, ok ? 200 : 503, { ok, gateway: gateway ? 'up' : 'down', ...(ok ? {} : { error: 'leaf certificate expired or unusable' }) })
  }
  const g = (GATEWAY.protocol === 'https:' ? https : http).get(`${GATEWAY.origin}${BASE}/health/liveliness`, { timeout: 2000, agent: false },
    r => { r.resume(); answer(r.statusCode >= 200 && r.statusCode < 300) })
  g.on('timeout', () => g.destroy(failure('ETIMEDOUT')))
  g.on('error', () => answer(false))
}

const proxy = http.createServer((req, res) => {
  if (req.method === 'GET' && pathOf(req.url).replace(/^http:\/\/[^/]+/, '') === '/healthz') return health(res)
  // plain-HTTP proxying isn't offered: only HTTPS_PROXY points here. An absolute URL's user:password@ is never logged
  log(req.method, pathOf(req.url).replace(/^(\w+:\/\/)[^/]*@/, '$1'), '-', 'refused', 501)
  res.writeHead(501); res.end()
})
proxy.on('clientError', (e, sock) => sock.destroy())
proxy.on('connect', (req, client, head) => {
  const t0 = Date.now(), m = req.url.match(/^(?:\[([^\]]+)\]|([^:]+)):(\d+)$/)
  client.on('error', () => {})
  if (!m) { log('CONNECT', req.url.slice(0, 80), '-', 'tunnel', 400); return client.end('HTTP/1.1 400 Bad Request\r\n\r\n') }
  const host = m[1] ?? m[2], port = Number(m[3])
  if (host === ANTHROPIC && port === 443) {
    const { context } = loadLeaf()
    client.write('HTTP/1.1 200 Connection Established\r\n\r\n')
    if (head?.length) client.unshift(head)
    const sec = new tls.TLSSocket(client, { isServer: true, secureContext: context, ALPNProtocols: ['http/1.1'] })
    sec.on('error', e => log('CONNECT', `${ANTHROPIC}:443`, '-', 'tls', e.code ?? 'error'))
    return inner.emit('connection', sec)
  }
  let open = false
  const up = net.connect(port, host, () => {
    open = true
    client.write('HTTP/1.1 200 Connection Established\r\n\r\n')
    if (head?.length) up.write(head)
    up.pipe(client); client.pipe(up)
    log('CONNECT', `${host}:${port}`, '-', 'tunnel', 200, `${Date.now() - t0}ms`)
  })
  up.on('error', e => {
    if (open) return client.destroy()
    log('CONNECT', `${host}:${port}`, '-', 'tunnel', 502, e.code ?? 'error')
    client.end('HTTP/1.1 502 Bad Gateway\r\n\r\n')
  })
  up.on('close', () => { if (open) client.destroy() })
  client.on('close', () => up.destroy())
})

if (!loadLeaf().context) { log(`no usable leaf certificate in ${DIR}; run make-ca.sh`); process.exit(1) }
proxy.on('error', e => { log(`cannot listen on 127.0.0.1:${PORT}:`, e.code ?? e.message); process.exit(1) })
proxy.listen(PORT, '127.0.0.1', () =>
  log(`router on 127.0.0.1:${PORT}; gateway ${GATEWAY.origin}${BASE}; leaf valid until ${new Date(leaf.until).toISOString()}`))
