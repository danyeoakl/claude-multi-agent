---
name: codex-review
description: Run Codex's built-in code reviewer (gpt-6.1-sol at max effort, read-only) in the background on finished work, then fix only what real use would hit. Use when a big chunk of your own code work is done, such as a branch before its PR, and on /codex-review.
argument-hint: "[--base <branch> | --uncommitted | --commit <sha>]"
---

# Codex review

Each review uses the user's ChatGPT plan quota: one per big chunk of work, never on your own fixes.

## 1. When to run

- When a big chunk of your own code work is done (say, a branch before its PR), not after each change; and whenever the user types /codex-review.
- In a subagent or workflow step, only when its brief asks.
- Fixes from a review go in without another review.

## 2. Pick the target

- A branch (the usual case): `--base <base branch>`, after committing; it doesn't see files that were never committed.
- Uncommitted work: `--uncommitted`.
- One commit: `--commit <sha>`, optionally with `--title "<subject>"`.

Pass only a target flag, never a prompt: a prompt replaces the built-in reviewer. If /codex-review came with other text, ignore it and pick the target as above.

## 3. Start it in the background

Use the Bash tool with `run_in_background: true`, from inside the repo. On Windows this is Git Bash; the command is the same on every OS:

```bash
bash ~/.claude/skills/codex-review/review.sh --base main
```

review.sh runs Codex's built-in reviewer (`codex exec review`) read-only on gpt-6.1-sol at max and saves the report in the repo's `.git/codex-reviews/`.

Keep working while it runs; a review takes from about a minute to ten. Avoid rewriting the files under review in the meantime, because the reviewer reads the live working tree. In a main session, don't poll: you are notified when it exits. In a subagent or scripted run with nothing else to do, wait for it to exit before your final reply; ending the turn loses the result.

## 4. Read the outcome

The output ends with `status=done findings=<n> report=<path>` or `status=failed reason=<why> log=<path>` plus the log's last lines.

- **No `status=` line** (for example exit 127, script missing): say `Codex review unavailable: review.sh not installed at ~/.claude/skills/codex-review` and move on.
- **Failed:** tell the user in one line, e.g. `Codex review unavailable: not logged in (log: <path>)`, and move on. The usual reasons are: codex not installed; not logged in (`codex login status` is the only check you may run; never run a login); usage limit reached; timed out (exit 124). Don't retry.
- **Done:** read the report. It starts with a summary paragraph. Each finding is a bullet, `- [P1] <title> — <absolute path>:<start>-<end>`, followed by an indented paragraph. No bullets means no findings.

## 5. Triage: does it happen in real life?

Read the code each finding points at. If you kept working, the lines may have moved.

- **Keep** a finding only when a concrete, realistic input or state, one that real use will hit, reaches a wrong result, a crash, data loss or a security hole, and this change introduced it.
- **Drop** speculative edge cases (inputs that can't occur here, contrived timing), hardening and defensive checks, style and naming, requests for tests, problems that predate the change, and anything you can't tie to a real scenario.

## 6. Fix what you kept

Make the smallest fix, in the code's existing style. Add no tests or hardening beyond the fix itself. Don't run the review again. If a kept finding needs a design decision rather than a fix, don't fix it; list it as `Not fixed: <what> (needs your call)`.

## 7. Report, in exactly this shape

```
Codex review: <k> fixed, <d> dropped as unrealistic. Report: <report path>
- Fixed <what was wrong> (<repo-relative path>:<start line>)
- Fixed <what was wrong> (<repo-relative path>:<start line>)
```

Paths are repo-relative with the start line only, e.g. `(src/trials.py:36)`. With nothing dropped: `Codex review: <k> fixed. Report: <path>`. With no findings: `Codex review: no findings. Report: <path>`. With nothing kept: `Codex review: nothing to fix (<d> dropped as unrealistic). Report: <path>`. Never list the dropped findings; the count is enough, and the user can open the report.
