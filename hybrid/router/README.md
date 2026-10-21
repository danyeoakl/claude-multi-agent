# Hybrid router

The `cma-claude` launchers point `ANTHROPIC_BASE_URL` at LiteLLM, so the whole session runs through the gateway,
and Claude Code's Remote Control, which expects the first-party address, needs the optional client patch. The
hybrid router keeps the session on `api.anthropic.com` instead and peels off only the requests meant for gateway
models. Claude Code reaches it as an ordinary `HTTPS_PROXY`, set in a Claude Code settings file, so any Claude
Code session works with it, including ones started by other apps. The CLI isn't patched and the base URL isn't
changed.

```text
Claude Code session (HTTPS_PROXY=http://127.0.0.1:4110, NODE_EXTRA_CA_CERTS=<router CA>)
   |
   |-- CONNECT api.anthropic.com:443 -> TLS terminated by the router
   |      |-- POST /v1/messages, model claude/<provider>/... -> LiteLLM gateway (127.0.0.1:4000)
   |      |      the client's Authorization / x-api-key are removed; the restricted gateway key is set
   |      |-- POST /v1/messages/count_tokens, same models  -> answered locally (bytes / 4)
   |      `-- everything else (Claude models, Remote Control, telemetry, upgrades) -> api.anthropic.com unchanged
   `-- CONNECT any other host -> plain TCP tunnel (bytes are never inspected)
```

## Routing rules

- **To the gateway:** `POST /v1/messages` whose JSON `model` starts with `claude/` and not with
  `claude/anthropic/`. Everything else, including `claude/anthropic/*` IDs, stays on the Anthropic leg;
  Anthropic doesn't know those IDs and answers with an error, so use native Claude IDs in a routed session.
- **Headers to the gateway:** all of the client's headers are kept (`anthropic-version`, `anthropic-beta`,
  `x-claude-code-*`, ...) except `Authorization`, `x-api-key` and hop-by-hop headers. The router adds
  `x-litellm-api-key: Bearer <key>` and `authorization: Bearer <key>`. The key comes from `gateway-key.json`
  (`cma up` and `cma sync-key` provision it) and is re-read whenever the file changes.
- **`count_tokens`** for gateway models is estimated as `ceil(body bytes / 4)`, because the gateway's
  OpenAI-backed routes may not implement it.
- **No silent fallback:** a gateway that can't be reached (refused, 10 s connect timeout, 960 s idle) yields a
  `502` with an Anthropic-style body, `{"type":"error","error":{"type":"api_error","message":"hybrid gateway
  unreachable: <code>"}}`. A gateway stream that breaks midway ends with an SSE `error` event. A gateway model
  is never retried against Anthropic.
- **Cancellation:** when the client goes away (Esc, a stopped subagent), the upstream request is closed too, so
  the gateway stops spending quota.

## Remote Control

Remote Control talks to `api.anthropic.com` (`/v1/code/sessions/...`: the bridge, worker GET/PUT, events, the
event stream and heartbeats). None of it is a gateway-model `/v1/messages` call, so the router relays it as is:
the request with its original headers and body, then the response streamed back without buffering. Upgrade
requests (WebSocket) are replayed to `api.anthropic.com` and piped both ways. The Claude login never leaves
the Anthropic leg.

## Security notes

- **The CA can vouch only for `api.anthropic.com`.** `make-ca.sh` gives it a critical X.509 name constraint
  (`permitted;DNS:api.anthropic.com`) and `pathlen:0`, so even its key can't produce a certificate any client
  would accept for another name. `NODE_EXTRA_CA_CERTS` adds that trust to Node processes only.
- **Keys stay private.** The CA folder is `0700`; `ca-key.pem`, `leaf-key.pem` and `leaf-cert.pem` are `0600`.
  Only `ca-cert.pem` is `0644`.
- **The gateway never receives the claude.ai token.** Gateway-bound requests lose `Authorization` and
  `x-api-key` before they leave the router and carry the restricted gateway key instead. Claude-model traffic
  goes to Anthropic only.
- **Loopback only.** The router binds `127.0.0.1`. Any local process that can connect to it can use the
  gateway through it, as with the gateway port itself; run it on a single-user machine or VM.
- **Logs carry no secrets.** One line per request: time, method, path without the query, model or `-`, route
  (`gateway`, `local`, `anthropic`, `tunnel`), status and time to first byte. Header values and bodies are never
  logged, and neither is the key.
- **Non-Node tools.** Programs run from a routed session inherit `HTTPS_PROXY`. Their traffic to other hosts is
  tunnelled untouched. A non-Node program that calls `api.anthropic.com` itself (Python's `anthropic` SDK,
  `curl`) sees the router's certificate and rejects it, because it doesn't read `NODE_EXTRA_CA_CERTS`. Run such
  a command with `NO_PROXY=api.anthropic.com`, or give it the CA explicitly.

## Install

Requirements: Node 22, python3 and openssl; systemd user units; the gateway from `scripts/cma` (`cma init`,
`cma up`).

```bash
hybrid/router/install.sh ~/.claude/settings.json          # every session of this user
hybrid/router/install.sh ~/src/project/.claude/settings.json   # or one project only
```

`install.sh`:
1. runs `make-ca.sh` (it creates the CA and leaf in `~/.config/tj-hybrid/router` if missing, and renews them
   within 30 days of expiry);
2. renders the units in `systemd/` with absolute paths into `~/.config/systemd/user`, then reloads systemd and
   enables and (re)starts `tj-hybrid-router.service`;
3. waits for `/healthz`, and stops there, leaving the settings untouched, if the router doesn't come up;
4. enables `tj-hybrid-watchdog.timer`;
5. sets three `env` keys in the settings file: `HTTPS_PROXY=http://127.0.0.1:4110`,
   `NO_PROXY=localhost,127.0.0.1,::1` and `NODE_EXTRA_CA_CERTS=<ca dir>/ca-cert.pem`. It refuses if the file
   already points those keys elsewhere: the router doesn't chain to another proxy.

Optional environment: `PORT`, `CA_DIR`, `GATEWAY` and `KEY_FILE` (the default is
`${CMA_HOME:-~/.local/share/claude-multi-agent}/gateway-key.json`). One install serves one settings file;
uninstall before switching to another.

**Keep it running without a login.** User units stop when the user's last login session ends. To keep the
router and the watchdog up regardless, enable lingering once, as root:

```bash
loginctl enable-linger <user>
```

New Claude Code sessions pick up the settings. Whether a running session picks up a change to them is not
established, so restart sessions after installing, uninstalling or a watchdog switch.

## Uninstall

```bash
hybrid/router/uninstall.sh ~/.claude/settings.json
```

It removes the three keys first, so new sessions go straight to Anthropic, then disables and deletes the units.
The CA folder stays; `rm -r ~/.config/tj-hybrid/router` removes it. Restart sessions that were using the router.

## Watchdog

A session whose proxy is down can't reach Anthropic at all. The CLI fails with `ECONNREFUSED`. The router
restarts itself (`Restart=always`, `RestartSec=2`, no start limit), and the watchdog covers the time it can't:

- `tj-hybrid-watchdog.timer` runs `watchdog.py check` every 15 s.
- If `GET /healthz` fails twice in a row (4 s apart, longer than a crash restart takes), and the settings file
  routes through this router, the watchdog removes the three keys and saves their values in
  `~/.config/tj-hybrid/router/disabled-by-watchdog` (`0600`).
- When `/healthz` answers again, it puts the keys back and deletes the marker.
- It never touches other keys. If the router was never enabled in that file, it does nothing.
- The file is rewritten atomically with `indent=2`, keeping its mode.

`/healthz` returns `200 {"ok":true,"gateway":"up"|"down"}`. Only the router matters to the watchdog: the
gateway status (`GET <gateway>/health/liveliness`, 2 s timeout) is informational, since a down gateway already
fails loudly per request. `ok` turns false (`503`) when the leaf certificate has expired.

The watchdog also works by hand: `watchdog.py check|enable|disable|health --settings <file> --port <port>`.
`TJ_HYBRID_SETTINGS` and `TJ_HYBRID_ROUTER_PORT` are accepted in place of the flags.

## Operating

```bash
curl -s http://127.0.0.1:4110/healthz
journalctl --user -u tj-hybrid-router -f        # one line per request
journalctl --user -u tj-hybrid-watchdog         # only when it removes or restores the keys
systemctl --user restart tj-hybrid-router       # after updating router.mjs
```

The router reloads a renewed leaf on its own. A renewed CA needs running sessions restarted, because Node
reads `NODE_EXTRA_CA_CERTS` at start-up.

## Required Claude Code settings: no message threads

Behind this router the session stays first party, so Claude Code (2.1.30x) uses its
server-side **message threads**: after a subagent's first request it sends
`thread: {type: "continue", previous_message_id}` with only the newest messages and
relies on api.anthropic.com to hold the rest of the conversation. LiteLLM has no threads,
so a gateway worker then sees tool results without its task or its own tool calls
(Codex: "No tool call found for function call output"; Grok: "what should I do next?").
Claude Code also adds mid-conversation `system` reminders after the task.

Turn both off in the **user** settings of the machine that runs the sessions
(`~/.claude/settings.json`; project settings may not set these keys):

```json
{ "env": { "CLAUDE_CODE_TETHER_LIVE": "false", "CLAUDE_CODE_SLEEPY_SNOWFLAKE": "off",
           "CLAUDE_CODE_DISABLE_NONSTREAMING_FALLBACK": "1" } }
```

`CLAUDE_CODE_DISABLE_NONSTREAMING_FALLBACK=1` matters too: when a stream stalls, Claude Code
retries the same request without streaming, and the ChatGPT backend only streams, so a Codex
worker would fail on the retry instead of reporting the stalled stream.

Requests then carry the full history, as they always do at a custom `ANTHROPIC_BASE_URL`
(TJ's launcher setup), where Claude Code never uses threads. Restart sessions after the change.

## Debugging: dump gateway-bound requests

`TJ_HYBRID_ROUTER_DUMP=<private dir>` in the router's environment (a systemd drop-in) writes
each gateway-bound request body there (0600). Bodies hold conversation content but no
credentials (those travel in headers). Turn it off and delete the files after debugging.
