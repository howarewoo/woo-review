---
name: woo-review
description: Managed agentic PR reviews with parallel matrix execution and skeptical validation.
install: npx skills add howarewoo/woo-review
requires:
  bins: [gh, jq, node]
recommends:
  skills: [pbakaus/impeccable, coreyhaines31/seo-audit, coreyhaines31/ai-seo, openai/security-best-practices]
---

# woo-review

Spawn a parallel swarm of review sub-agents against a pull request (or the local diff), validate their findings with a Skeptical Validator, and — when a PR is targeted — post a single batched GitHub Review.

This skill is **host-agnostic**: it works in any AI coding agent that supports sub-agent / task spawning (Claude Code, Cursor, Gemini CLI, opencode, etc.). Hosts without parallel sub-agents fall back to a sequential loop.

## Commands

- `/woo-review` — Auto-detect: if the current branch has an open PR (via `gh pr view --json number`), behave as `/woo-review <PR#>`. Otherwise review the local diff (no GitHub posting).
- `/woo-review <PR#>` — Fetch the PR via `gh`, run the swarm, and post a native batched GitHub Review.
- `woo-review install` — Verify local deps (`gh`, `jq`, `node`) and pre-fetch `impeccable` + `react-doctor`.
- `woo-review status` — Show the current PR's review status.

## Knowledge Aggregation

woo-review wires in domain skills as tool calls inside specific angles, not as a runtime dependency:

| Source | Used by | How |
|---|---|---|
| [pbakaus/impeccable](https://github.com/pbakaus/impeccable) | `design` | `npx -y impeccable detect --json` (run once; feeds both quant + qual passes inside the angle prompt) |
| [millionco/react-doctor](https://github.com/millionco/react-doctor) | `react` | `npx -y react-doctor --diff <base> --offline` |
| [coreyhaines31/seo-audit](https://www.skills.sh/coreyhaines31/marketingskills/seo-audit) framework | `seo` | Embedded as the audit rubric in `prompts/angles/seo.md` |
| [openai/security-best-practices](https://www.skills.sh/openai/skills/security-best-practices) | `security` | Referenced from `prompts/angles/security.md`; fetch `references/<language>-<framework>-<stack>-security.md` via `gh api` |
| [coreyhaines31/ai-seo](https://www.skills.sh/coreyhaines31/marketingskills/ai-seo) | `aeo` | Embedded as the rubric in `prompts/angles/aeo.md`; deeper `references/` (platform-ranking-factors, content-patterns, content-types) fetched on demand via `gh api` |

The audit frameworks themselves are embedded in `prompts/` (inside this skill bundle) so the skill is self-sufficient. Installing the recommended skills only enhances your host agent's general vocabulary.

## `/woo-review` Workflow

When the user invokes `/woo-review [PR#]`, the host agent MUST perform the following stages. **All file paths below are relative to `$WOO_REVIEW_ACTION_PATH`**.

### Stage 0 — Resolve skill path

Set `WOO_REVIEW_ACTION_PATH` to the directory containing this `SKILL.md` (the installed skill bundle). All `prompts/` and `scripts/` assets ship inside that directory.

```bash
export WOO_REVIEW_ACTION_PATH="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# Or however your host exposes the skill's install dir (e.g. $SKILL_DIR).
```

### Stage 1 — Prefetch

Build the same `/tmp/pr-review/` artifact tree the GitHub Action builds.

**If no PR number was supplied**, first try to resolve one from the current branch:

```bash
PR_NUMBER="$(gh pr view --json number --jq .number 2>/dev/null || true)"
```

If `PR_NUMBER` is non-empty, proceed as if it had been passed in. If empty (no open PR for this branch, or no GitHub remote), fall back to local-diff mode.

**If a PR number is set (supplied or auto-detected):**

```bash
mkdir -p /tmp/pr-review
gh pr diff "$PR_NUMBER" > /tmp/pr-review/diff.txt
gh pr view "$PR_NUMBER" --json headRefOid,baseRefName,title,body,files \
  > /tmp/pr-review/meta.json
```

**If no PR number resolved (local mode):**

```bash
mkdir -p /tmp/pr-review
BASE="$(git merge-base HEAD origin/main 2>/dev/null || git merge-base HEAD main)"
git diff "$BASE"...HEAD > /tmp/pr-review/diff.txt
# Synthesize meta.json from git for downstream scripts.
git diff --name-only "$BASE"...HEAD \
  | jq -R . | jq -s '{
      headRefOid: "'"$(git rev-parse HEAD)"'",
      baseRefName: "'"$(git rev-parse --abbrev-ref "$BASE@{upstream}" 2>/dev/null || echo main)"'",
      title: "(local diff)",
      body: "",
      files: [.[] | {path: .}]
    }' > /tmp/pr-review/meta.json
```

Compose rules: copy every `CLAUDE.md` reachable from changed files into `/tmp/pr-review/rules.md`.

### Stage 2 — Detect Angles

```bash
bash "$WOO_REVIEW_ACTION_PATH/scripts/detect-angles.sh"
```

Read the result from `/tmp/pr-review/angles.txt` (one angle per line). Always-on angles: `bugs`, `security`. Conditional: `seo`, `aeo`, `design`, `react`.

### Stage 3 — Spawn Parallel Sub-Agents (one per angle)

**This is the swarm step.** For each detected angle, spawn a sub-agent in parallel using your host's primitive:

- Claude Code: `Task` tool, one call per angle in a single message.
- Cursor / Composer: parallel subagent dispatch.
- Gemini CLI / opencode: sequential loop (no native subagents — still launch them one at a time inside this stage).

Each sub-agent receives the same brief:

```
You are the <angle> reviewer for this PR. Read:
- $WOO_REVIEW_ACTION_PATH/prompts/_header.md   (shared contract)
- $WOO_REVIEW_ACTION_PATH/prompts/angles/<angle>.md   (your scope)
- /tmp/pr-review/diff.txt, /tmp/pr-review/rules.md, /tmp/pr-review/meta.json

Execute any shell commands the angle prompt specifies (e.g. impeccable detect,
react-doctor). Write your findings as a JSON array to
/tmp/pr-review/findings.<angle>.json per the schema in _header.md. EXIT.
```

Sub-agents MUST NOT post comments, edit the PR, or touch other angles' files.

**Model routing (token optimization, host-agnostic).** Each angle prompt and the validator declare a `tier:` in frontmatter — `fast`, `standard`, or `deep`. The host resolves the tier to a concrete model via the table in `prompts/_header.md`. Tier assignments:

| Stage | Tier | Why |
|---|---|---|
| Context+summary subagent | `fast` | Mechanical summarization. |
| `bugs`, `security` workers | `standard` | Reasoning-heavy: correctness + threat model. |
| `design`, `react` workers | `standard` | Heuristic + Rules-of-Hooks judgment after deterministic tools. |
| `seo`, `aeo` workers | `fast` | Rubric checklists; no novel reasoning. |
| Skeptical Validator | `deep` | Highest-leverage step — strictest false-positive filter pays for itself. |

Per-provider resolution (full table in `_header.md`):

| Tier | Anthropic | OpenAI | Google | OpenRouter |
|---|---|---|---|---|
| `fast` | `claude-haiku-4-5` | `gpt-5-mini` | `gemini-3-5-flash` | `openrouter/deepseek/deepseek-v4-flash` |
| `standard` | `claude-sonnet-4-6` | `gpt-5` | `gemini-3-5-flash` | `openrouter/deepseek/deepseek-v4-pro` |
| `deep` | `claude-opus-4-7` | `gpt-5` + `reasoning_effort: high` | `gemini-3-5-flash` | `openrouter/deepseek/deepseek-v4-pro` + `reasoning_effort: xhigh` |

- **Google** currently exposes only `gemini-3-5-flash` — tier routing is a no-op on Gemini until a larger 3.5 model ships.
- **OpenAI** GPT-5 reasoning is a `reasoning_effort` parameter (`minimal`/`low`/`medium`/`high`), not a slug suffix. There is no `gpt-5-pro`. Newer `gpt-5.5` family exists; upgrade once the Codex Action supports it.
- **OpenRouter** exposes only `deepseek/deepseek-v4-flash` and `deepseek/deepseek-v4-pro`; reasoning is the `reasoning_effort` parameter (`high`/`xhigh`). Do not route to `deepseek-r1` — V4 supersedes it.

**Host capability:**

- **Per-call routing** (Claude Code `Task`, opencode `@subagent`): honor each prompt's `tier:` verbatim. Maximum savings.
- **Single model per session** (Codex Action, Gemini CLI): pin the run to the `standard` tier — covers every angle safely. `tier:` becomes informational. Split into multiple jobs if you want fast-tier savings on rubric angles or deep-tier validation.

### Stage 4 — Merge + Skeptical Validation

After every sub-agent has finished:

```bash
bash "$WOO_REVIEW_ACTION_PATH/scripts/merge-findings.sh"
# Produces /tmp/pr-review/raw_findings.json
```

Now act as the **Skeptical Validator** by following `prompts/validator.md`:

1. Dedupe across angles (keep the most actionable description; preserve the winner's `title` / `description` / `fix`).
2. Defense-attorney audit: try to prove each finding wrong. Drop pedantic / style-only / lint-catchable / "maybe" findings.
3. Severity check: you MAY downgrade (HIGH → MEDIUM, blocking true → false). You MAY NOT upgrade.
4. Comment-shape check: every surviving finding has `title` (bold headline ≤60 chars), `description` (issue only, no fix), and `fix` (recommended change in prose). Split overloaded `description` fields when an angle collapsed them.
5. Write the surviving array to `/tmp/pr-review/findings.json`.

### Stage 5 — Report

**If invoked with a PR number** — post a single native batched GitHub Review per the procedure in `prompts/_header.md`:

- Build the STATUS_LINE (`APPROVED` / `APPROVED WITH SUGGESTIONS` / `CHANGES REQUESTED`).
- Submit one `gh api repos/<repo>/pulls/<PR>/reviews` POST containing all inline comments + the summary + status line. The review `event` (`APPROVE` / `COMMENT` / `REQUEST_CHANGES`) is the native gate — any blocking finding triggers `REQUEST_CHANGES`.
- DO NOT modify the PR title or body. DO NOT mutate PR labels.

**If invoked locally (no PR#)** — print the validated findings to the terminal grouped by severity, then stop. Do not touch any remote.

## Architecture

```
detect ─► fan-out (parallel sub-agents, one per angle) ─► merge ─► skeptical validator ─► post
```

This mirrors the cloud GitHub Action exactly (`.github/workflows/reusable-review.yml`), just with sub-agents standing in for GHA matrix jobs.

## Companion GitHub Action

For a fully-managed CI flow, drop this into the consumer repo at `.github/workflows/ai-review.yml`:

```yaml
name: AI PR Review
on:
  pull_request:
    types: [opened, reopened, ready_for_review]
  issue_comment:
    types: [created]

jobs:
  review:
    uses: howarewoo/woo-review/.github/workflows/reusable-review.yml@v0.1.0
    with:
      provider: anthropic
    secrets:
      anthropic_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

Zero local setup required in the consumer repo — the action ships its own prompts, scripts, and Node tools.

## Best Practices

- Always parallelize Stage 3 when the host supports it; the validator pass is calibrated for ~5 angles' worth of input.
- Trust the Skeptical Validator. Disabling it produces noisy reviews.
- Honor angle-prompt tiers (`fast`/`standard`/`deep`) when the host supports per-call model routing. Hosts that run one model per session should pin the `standard` tier model (table above) — this matches the May 2026 flagship recommendation.
- Pass `disable_angles` to skip optional angles when scope is narrow (e.g. backend-only PR → `disable_angles: "seo,design,react"`).

## Troubleshooting

- **Missing artifacts** in cloud mode — verify the `detect` job uploaded `review-artifacts`.
- **Empty validator output** — inspect `/tmp/pr-review/raw_findings.json`. If empty, no angle wrote findings; check each `findings.<angle>.json`.
- **Sub-agents posting prematurely** — re-read the Stage 3 brief; workers must write JSON only.
