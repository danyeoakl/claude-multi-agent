---
name: x-research
description: Find other people's projects, code, people or posts, mainly through X (Twitter), with the Grok CLI's built-in X search. It runs headless, read-only and in the background, and you reply with a short list whose links you have checked. Use whenever the user asks who has built something or to find projects, code, people or posts, even when they don't mention X, e.g. "who's built an MCP server for Airtable?", and on /x-research <query>. With --raw it also runs any research brief through Grok's web and X search.
argument-hint: "<what to find>"
---

# X research

Grok searches X server-side and confirms projects with web search; every local tool is removed, so it can't touch this machine. A run takes 1 to 4 minutes.

## 1. Start it in the background

Pick a slug of 3 to 6 words from the ask. Then use the Bash tool with `run_in_background: true`. On Windows this is Git Bash; the command is the same on every OS:

```bash
bash ~/.claude/skills/x-research/search.sh "<slug>" <<'ASK'
<the user's ask, verbatim, plus any constraints from the conversation: stack, language, how recent>
ASK
```

Tell the user in one line that the search is running, and keep working. Don't poll: you are notified when it exits.

For research that isn't finding projects or posts, pass `--raw` before the slug: Grok gets your brief exactly as written. Read the status block as below, then summarise Grok's answer instead of the list in step 4, with the report path.

## 2. Read the status block

- `status=ok`: go on.
- `x_search_calls=0`: tell the user that X search didn't run this time, so the finds come from web search only.
- `extra_tools=` anything but `none`: say so in one line (a newer Grok renamed a local tool past the deny list). The fix goes in the DENY list of `hybrid/skills/x-research/search.sh` in the repo the skill was installed from, followed by a re-run of install.sh; don't edit the installed copy.
- `cwd_files=` above 0: Grok wrote into its scratch folder. Mention it.
- `status=failed`: tell the user in one line, e.g. `X research unavailable: grok is not logged in`. The usual reasons are: grok not installed; not logged in; timed out (exit 124); turn cancelled (`stop=cancelled`). To check the login, the only command you may run is `grok models 2>&1 | head -n1`. Run it twice, because the first call sometimes says "not authenticated" by mistake. Never run `grok login`. Don't retry the search on your own.
- No `status=` line at all (for example exit 127, script missing): say `X research unavailable: search.sh not installed at ~/.claude/skills/x-research`.

## 3. Check the links

Check every link that isn't an X link:

- A GitHub repo: `gh api repos/<owner>/<repo> --jq '"\(.stargazers_count) stars, pushed \(.pushed_at[:10])\(if .archived then ", archived" else "" end)"'`. Without gh, use the curl line below and write `(checked: HTTP 200)`.
- Any other github.com link (PR, issue, file): curl the URL. If it's the find's main project link, also run gh api on its owner/repo for stars and pushed.
- Anything else: `curl -sIL -o /dev/null -w '%{http_code}' --max-time 15 '<url>'`. If you get 403 or 405, try again without `-I`, because some sites refuse HEAD requests.
- X links (x.com, twitter.com) can't be fetched without a login. Leave them as they are and mark them `X, unchecked`.

Drop a find whose project link is dead (404), unless the post itself is what the user wanted, and count the drops.

## 4. Reply with a short list

```
X research: <the ask in a few words> (Grok; X search ran, <n> calls)
1. **<name>** — <project URL> (checked: 120 stars, pushed 2026-10-01) [· <second link> (checked: ...)] · <X post URL> (X, unchecked) — @<handle>, <date> — <what it is>. Fits: <why>.
2. ...
<d> dropped (dead links). Full Grok report: <path>
```

Re-rank by fit to the ask rather than keeping Grok's order, up to 6; finds without public code or a usable product go last. Leave out the second link, handle or date when there is none. Don't paste the full report; give its path.
