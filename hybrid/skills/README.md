# CLI helper skills

Two Claude Code user skills that call another vendor's CLI from a Claude session. Claude stays the planner and builder; these add a reviewer and an X search.

| Skill | What it does | Needs |
| --- | --- | --- |
| `codex-review` | When Claude finishes a task with a non-trivial code change in the main conversation (subagents and workflow steps leave it to the session they report to), it runs Codex's built-in reviewer in the background (`codex exec review`, gpt-6.1-sol at max effort, read-only sandbox). Claude then fixes only the findings that real use would hit and reports one line per fix, the count of dropped findings, and the path of the saved report (`.git/codex-reviews/`). Also available as `/codex-review [--base <branch> \| --commit <sha>]`. | Codex CLI, logged in (`codex login status`) |
| `x-research` | Finds other people's projects, code, people or posts, mainly on X, with the Grok CLI's server-side X search, run headless with every local tool removed. It also takes "who has built…?" asks that don't mention X. Claude checks the non-X links and replies with a short list; Grok's full answer is saved under `~/x-research/`. Also available as `/x-research <what to find>`. | Grok CLI, logged in (`grok models` says so) |

Each skill runs a small bash script in its own folder: in Git Bash on Windows, and in the system bash on macOS and Linux. x-research also needs `python3` (`python` on Windows) to read Grok's output, and `curl` or `gh` to check links.

## Install

```sh
bash hybrid/skills/install.sh --dry-run   # shows what it would do
bash hybrid/skills/install.sh
```

This copies both folders into `~/.claude/skills/`, replacing older copies of these two only. It also adds `CLAUDE-snippet.md` to `~/.claude/CLAUDE.md` between `<!-- hybrid-cli-helpers:start -->` and `<!-- hybrid-cli-helpers:end -->`. That block makes the review run after each real change and sends X-finding asks to x-research. Re-run the installer after pulling to update both. New sessions pick the skills up.

## Optional: Codex that is not on PATH

If `codex` is installed only inside another tool's private Node folder, expose it with a wrapper rather than a second install:

```sh
mkdir -p ~/.local/bin
cat > ~/.local/bin/codex <<'EOF'
#!/bin/sh
exec "<prefix>/bin/node" "<prefix>/lib/node_modules/@openai/codex/bin/codex.js" "$@"
EOF
chmod 755 ~/.local/bin/codex
```

Here `<prefix>` is that Node folder. The wrapper goes through `codex.js` rather than the native binary so Codex's own launcher logic still applies, and it uses whatever version the other tool installs. Don't run Codex self-updates through it: they would install into the other tool's folder. The skills put `~/.local/bin` on PATH themselves. The wrapper is part of the install on such a machine: codex-review finds Codex only through it, so don't remove it in a cleanup.

## Remove

```sh
rm -rf ~/.claude/skills/codex-review ~/.claude/skills/x-research
```

Then delete the lines from `<!-- hybrid-cli-helpers:start -->` to `<!-- hybrid-cli-helpers:end -->` in `~/.claude/CLAUDE.md`. Reports stay where they are: in each repo's `.git/codex-reviews/` and in `~/x-research/`.

## Notes

- **Codex quota.** Codex reviews use the ChatGPT plan's quota, so the skill runs once per change and never re-reviews fixes. A usage limit is reported, not retried.
- **Explicit Codex flags.** The review passes `-s read-only`, the model and the effort explicitly, because user configs can default to full access, to `ultra` effort or to another model. It passes no prompt: a prompt replaces the built-in review request, so `review.sh` accepts only target flags.
- **Another Codex launcher.** To review through a different launcher (for example one that sets its own `CODEX_HOME`), set `CODEX_REVIEW_BIN` to its path under `env` in `~/.claude/settings.json`. It must pass `exec … review …` through unchanged.
- **No `--tools` for Grok.** The Grok run never uses `--tools`, because an allowlist drops the server-side X search. It removes local tools with `--disallowed-tools` instead. It also sets `GROK_CLAUDE_*_ENABLED=false` and `GROK_CURSOR_*_ENABLED=false`, so Grok doesn't load Claude Code or Cursor MCP servers, hooks, skills or rules. If a newer Grok renames a tool, the run reports it under `extra_tools`: add the new name to `DENY` in `x-research/search.sh` here and re-run the installer.
- **Versions.** The flags follow probes of Codex CLI 0.160 to 0.163 and Grok CLI 1.0.46 to 1.0.67.
