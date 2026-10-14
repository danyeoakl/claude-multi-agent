# Driving external CLI workers

## Why a cheap driver

An interactive external CLI is useful when a task needs that worker's reasoning,
search or tooling, but the coordinator cannot call it through its Agent API.
A low-cost driver model spends most of its time blocked, handles narrow steering
and reports independently checked evidence. Keep design decisions and permission
changes with the coordinator; use the worker for implementation, not the driver.
This is an operational pattern, not a guarantee of lower total cost or access.

## Supervisor architecture

```text
coordinator -> driver -> short ext-agent.py control commands
                                |
                       private run directory
                                |
                  detached Python supervisor -> tmux pane -> CLI worker
                                |
                 transcript, state, retries, first-idle final snapshot
```

The supervisor is a stdlib Python process detached from the driver's session.
Tmux provides persistent terminal input, screen capture and pipe-pane transcripts.
Adapters infer idle/busy/asking/error from current terminal output, with a quiet
window to prevent a visible-but-streaming prompt from looking finished. Metadata
updates are locked and atomically replaced. Linux process identities and owned
process trees protect cleanup against PID reuse; do not substitute broad process
name searches. A stopped coordinator can adopt a live run without launching again.
This does not survive a host reboot or external termination of tmux/supervisor.

Run roots and executable paths are environment-configurable; preambles and briefs
are explicit file arguments. No project deployment configuration, model roster or
login state ships with the skill. Approval bypass is an explicit opt-in. The
supervisor does not sandbox a worker or grant permission to use one.

## Lessons learned

- **Foreground waits:** a background wait ends the driver's turn; in an agent
  harness, that can wake the coordinator on every turn. Use a bounded foreground
  wait with progress-return events so the driver remains cheaply blocked and
  receives steering between waits. Progress output alone does not wake it.
- **Edge-triggered context:** a level-triggered wake returns immediately on every
  wait while context remains above its threshold and spins. Arm below the
  threshold and wake on a fresh crossing; starting above it must still block.
- **Visible prompt is not idle:** Grok can display its input prompt while a
  background command runs. Treat `N commands still running`, spinners and queued
  input as busy, and debounce streaming output before declaring idle.
- **No process-name polling:** `pgrep -f` can match its own wrapper's command line
  and deadlock a wait. Use recorded PID/start identity, owned process state and
  the supervisor's existing wait command instead of inventing another watcher.
- **Crash-safe test isolation:** a suite killed before cleanup can leave its tmux
  server alive with fake executable overrides, a temporary run root and a test
  socket directory in its environment. A coordinator restarted inside that server
  inherits those settings and can silently launch a stub. Tests must never use the
  default tmux server. Drivers should check `events.jsonl` launch commands against
  the intended real CLI executable before trusting a newly adopted or started run.
- **Interrupt and queue behavior:** observed Grok turns ignore Escape; Ctrl+C is
  the interrupt key. Queued messages can flush one per Enter, so inspect the
  queue and deliver additional Enter keys deliberately rather than duplicating
  text. Antigravity's adapter uses Escape. These are version-sensitive UI rules.
- **Verify claims:** rerun authorized tests, grep citations in actual files and
  compare timestamps/artifact contents. A confident worker summary, an available
  prompt or a `final.md` snapshot is not proof of completed work. The snapshot
  records the first idle answer only, not every later steering result.
- **Measure wall time:** use supervisor start/submission timestamps and the
  timestamp of independent validation, not a worker's self-report. Observed
  self-reported durations can overstate elapsed time by roughly 2-4x. Separate
  backoff, resource waits, worker time and driver verification overhead.
- **Retry cautiously:** automatic 503 recovery is bounded, but replay may repeat
  side effects and relaunch loses conversation context. Inspect worktree and
  external jobs before resuming; do not equate successful retry with safe replay.

## Scorecard approach

The coordinator keeps one short entry per evaluated task; do not ship a private
project's historical entries. Score the work against independent evidence, with
1 = poor, 3 = acceptable with intervention, 5 = strong with little intervention.
Use unknown for unfinished or unsupported ratings:

| Dimension | Evidence |
| --- | --- |
| Correct | Gates/review pass, no demonstrated regressions, claims match files/results |
| Judgement | Respects scope/timebox/stop bar, escalates permissions and ambiguity |
| Quality | Maintainable code and reasoning; amount of reviewer rework needed |
| Creative | Useful new approach or root cause, not novelty for its own sake |
| Wall time | Timestamp-derived time to validated result, relative to task difficulty |

Record task category, worker/driver identity, ratings, elapsed time, steering
count, retry count, peak context and verification limits. Keep raw elapsed time
rather than inventing a speed rating for incomparable tasks. Periodically compact
about ten entries into a small summary: best uses, strengths, weaknesses and
number/type of independently verified tasks. Retain source evidence privately.
Do not generalize one good task into a universal model ranking.

## Verified versus untested

The repository's unit suite runs a fake raw-terminal CLI inside real tmux, with
private temporary state and its own socket namespace. It tests both adapters,
multiline paste, busy sends, interrupts, descendant cleanup, transcript cursors,
retry/relaunch/exhaustion, restart adoption, archive pruning, output debounce,
context/progress/quiet wakes and the first-idle backstop. It performs no login,
provider inference or paid API calls.

Real Grok/Antigravity versions, current CLI flag compatibility, authentication,
entitlement, actual remote 503 behavior, vendor acceptance and real queue flushing
are not established by fake-CLI tests. The UI lessons above motivate the adapters
but are not newly live-verified by this port. Ask the owner for an explicitly
authorized live smoke test before relying on a changed CLI version. Never publish
private transcripts or authentication state as verification evidence.
