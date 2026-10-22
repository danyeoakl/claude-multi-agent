---
name: codex-review
description: Have Codex review a code change you just finished. It runs Codex's built-in reviewer (gpt-6.1-sol at max effort, read-only) in the background, and you then fix only the findings that real use would hit. Use in the main conversation after finishing any non-trivial code change, and on /codex-review. Subagents and workflow steps don't run it unless their task asks for it.
argument-hint: "[--uncommitted | --base <branch> | --commit <sha>]"
---

# Codex review

Codex reviews; you triage and fix. Each review uses the user's ChatGPT plan quota, so run **one review per change** and never review your own fixes.

## 1. Decide whether to run

- **Run** when you finish a real code change: new behaviour, a bug fix, or a refactor that touches logic. Run it once the task's change is done, not after each edit. Also run whenever the user types /codex-review.
- **Skip** docs, comments, typos, formatting, renames, config or version one-liners, generated files and lockfiles, and anything outside a git repository.
- **Skip** when you are a subagent or a workflow step: the session that receives your result reviews the combined change. Run there only when your task explicitly asks for a Codex review.
- **Once per change.** Fixes from a review are not reviewed on their own. They ride along with the next change's review (leave them uncommitted with it, or cover both with `--base`). Never loop review, fix, review.

## 2. Pick the target

- Uncommitted work (staged, unstaged or untracked): `--uncommitted`. This is the default.
- A commit you just made: `--commit <sha>`, optionally with `--title "<subject>"`.
- Several commits on a branch: `--base <base branch>`.

Pass only a target flag, never a prompt: a prompt replaces the built-in reviewer. If /codex-review came with other text, ignore it and use `--uncommitted`.

## 3. Start it in the background

Use the Bash tool with `run_in_background: true`, from inside the repo. On Windows this is Git Bash; the command is the same on every OS:

```bash
bash ~/.claude/skills/codex-review/review.sh --uncommitted
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
