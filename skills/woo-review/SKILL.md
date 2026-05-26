---
name: woo-review
description: Managed agentic PR reviews with parallel matrix execution and skeptical validation.
install: npx skills add howarewoo/woo-review
requires:
  bins: [gh, jq, node]
recommends:
  skills: [pbakaus/impeccable, coreyhaines31/seo-audit, coreyhaines31/ai-seo, openai/security-best-practices, supabase/supabase-postgres-best-practices]
---

# woo-review

Spawn a parallel swarm of review sub-agents against a pull request (or the local diff), validate their findings with a Skeptical Validator, and — when a PR is targeted — post a single batched GitHub Review.

This skill is **host-agnostic**: it works in any AI coding agent that supports sub-agent / task spawning (Claude Code, Cursor, Gemini CLI, opencode, etc.). Hosts without parallel sub-agents fall back to a sequential loop.

## Commands

- `/woo-review` — Auto-detect: if the current branch has an open PR (via `gh pr view --json number`), behave as `/woo-review <PR#>`. Otherwise review the local diff (no GitHub posting).
- `/woo-review <PR#>` — Fetch the PR via `gh`, run the swarm, and post a native batched GitHub Review.
- `/woo-review --full` (or `@review --full` in a PR comment) — Force a complete re-review even when a prior SHA marker exists. Skips the incremental path described below.
- `woo-review install` — Verify local deps (`gh`, `jq`, `node`) and pre-fetch `impeccable` + `react-doctor`.
- `woo-review status` — Show the current PR's review status.

## Incremental Mode

By default (`incremental: auto` on the GitHub Action), every posted review carries a hidden watermark:

```
<!-- woo-review:sha=<headRefOid> -->
```

On the next run, `prefetch.sh` scans **bot-authored** prior review bodies (the same `BOT_NAME_PATTERN` used elsewhere) for the marker — non-bot reviewers cannot forge a marker to narrow the window. If found, prefetch diffs `<last_sha>...HEAD` via the GitHub compare API instead of the full PR diff — only the new commits since the last pass are reviewed. Unresolved prior review threads (any author) are dumped to `/tmp/pr-review/prior-findings.json` and consumed by the posting stage for two things only: (a) **event floor** — any non-empty priors list keeps the new review at minimum `REQUEST_CHANGES`, conservative gate so a stale open thread is never auto-resolved by a clean incremental pass; (b) **dedupe** — a new finding at the same `(file, line, title-stem)` as a prior unresolved thread is dropped (it would be a duplicate of an already-posted comment).

Override paths:
- Action input `incremental: off` (workflow-level opt-out).
- A trigger comment containing `--full` (e.g. `@review --full`) — fixed-string match, regex-injection safe.
- Force-push that drops `<last_sha>` from the branch history — the compare API returns 404; prefetch emits a `::warning::` and falls back to the full diff for that run.

When the incremental diff has no new commits (i.e. `LAST_SHA == HEAD_SHA`, e.g. someone re-triggers without pushing), prefetch emits `skip=true` with reason `no new commits since last review (<last_sha>)`. To force a re-review of the same SHA, pass `--full` (or set `incremental: off`).

Marker semantics are state-light: the marker IS the state. There is no DB or workflow artifact retention beyond what GitHub already keeps in review history.

## Knowledge Aggregation

woo-review wires in domain skills as tool calls inside specific angles, not as a runtime dependency:

| Source | Used by | How |
|---|---|---|
| [pbakaus/impeccable](https://github.com/pbakaus/impeccable) | `design` | `npx -y impeccable detect --json` (run once; feeds both quant + qual passes inside the angle prompt) |
| [millionco/react-doctor](https://github.com/millionco/react-doctor) | `react` | `npx -y react-doctor --diff <base> --offline` |
| [coreyhaines31/seo-audit](https://www.skills.sh/coreyhaines31/marketingskills/seo-audit) framework | `seo` | Embedded as the audit rubric in `prompts/angles/seo.md` |
| [openai/security-best-practices](https://www.skills.sh/openai/skills/security-best-practices) | `security` | Referenced from `prompts/angles/security.md`; fetch `references/<language>-<framework>-<stack>-security.md` via `gh api` |
| [coreyhaines31/ai-seo](https://www.skills.sh/coreyhaines31/marketingskills/ai-seo) | `aeo` | Embedded as the rubric in `prompts/angles/aeo.md`; deeper `references/` (platform-ranking-factors, content-patterns, content-types) fetched on demand via `gh api` |
| [supabase/supabase-postgres-best-practices](https://www.skills.sh/supabase/agent-skills/supabase-postgres-best-practices) | `database` | Referenced from `prompts/angles/database.md`; fetch `references/<family>-<topic>.md` (`security-*`, `query-*`, `schema-*`, `conn-*`, `lock-*`, `data-*`) on demand via `gh api repos/supabase/agent-skills/contents/skills/supabase-postgres-best-practices/references/<file>` |

The audit frameworks themselves are embedded in `prompts/` (inside this skill bundle) so the skill is self-sufficient. Installing the recommended skills only enhances your host agent's general vocabulary.

## Project Rules

Prefetch auto-discovers project rule files (`AGENTS.md`, `CLAUDE.md`, `.cursorrules`, `.windsurfrules`, `GEMINI.md`) at the repo root, and additionally walks up from each changed file path to collect any `AGENTS.md` / `CLAUDE.md` along the way. The discovered content is concatenated (each section prefixed by a `## SOURCE: <path>` header, 100KB cap) into `/tmp/pr-review/rules.md` and surfaced to every angle as additional rubric. When that file is present, an extra `conventions` angle fires; the validator drops any finding that claims a rule violation but cannot quote the rule verbatim. Repos without rule files run unchanged.

## Per-repo Configuration (`.woo-review.yml`)

Drop an optional `.woo-review.yml` at the consumer repo root to tune the review without forking the skill. Prefetch parses it into `/tmp/pr-review/config.json`; downstream stages read from there. Missing file = current behaviour. Invalid YAML or unknown keys → loud `::error file=.woo-review.yml,line=N::<msg>` annotation and the workflow fails (no silent fallback).

```yaml
# .woo-review.yml — all keys optional
angles:
  force: [database]            # always run, even if not auto-detected
  skip:  [seo]                 # never run (bugs/security cannot be skipped)
severity_floor: medium         # one of: low | medium | high; drops findings below the floor
ignore:                        # fnmatch globs; ignored paths skip angle triggers + diff body
  - "**/*.generated.ts"
  - "migrations/*.sql"
project_rules:                 # appended to auto-discovered rules.md
  - constitution.md
  - "docs/standards/*.md"
authors_skip:                  # PR author logins that short-circuit the entire review
  - "dependabot[bot]"
  - "renovate[bot]"
models:                        # per-tier overrides; inputs.model still wins
  fast:     anthropic/claude-haiku-4-5
  standard: openai/gpt-5
  deep:     anthropic/claude-opus-4-7
fix_commands:                  # reserved for --loop mode (issue #15)
  - pnpm lint:fix
  - pnpm format
disable_adversarial: false     # cost-sensitive opt-out for the prosecutor+
                               # defender validator (issue #13). When true,
                               # only the defender pass runs and its output
                               # becomes findings.json directly.
```

**Precedence**: for the angle set, `angles.force` beats `angles.skip` when the same angle is listed in both. For model resolution, the action input `inputs.model` beats `models.<tier>` which beats the table default in `prompts/_header.md`. `ignore` is applied to both file paths and the per-file diff sections before angle gates evaluate.

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
gh pr view "$PR_NUMBER" --json headRefOid,baseRefName,title,body,files,author \
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

### Stage 2 — Detect Angles

```bash
bash "$WOO_REVIEW_ACTION_PATH/scripts/load-config.sh"   # parses .woo-review.yml (no-op if absent)
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
- /tmp/pr-review/diff.txt, /tmp/pr-review/meta.json

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
| `database` worker | `standard` | Postgres correctness, RLS reasoning, plan/index judgment. |
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

### Stage 4 — Merge + Adversarial Validation

After every sub-agent has finished:

```bash
bash "$WOO_REVIEW_ACTION_PATH/scripts/merge-findings.sh"
# Produces /tmp/pr-review/raw_findings.json
```

Validation runs as an **adversarial pipeline** (issue #13): two opposing-bias `deep`-tier validator passes followed by a deterministic intersection. The intersection (findings BOTH passes agree to keep) is what authors see — this trades 2× validator cost for materially higher signal-to-noise.

Read `disable_adversarial` from `/tmp/pr-review/config.json`:

```bash
DISABLE_ADV="$(jq -r '.disable_adversarial // false' /tmp/pr-review/config.json 2>/dev/null || echo false)"
```

**Stage 4a — Prosecutor pass** (skip if `DISABLE_ADV == true`):

Run `prompts/validator-prosecutor.md`. Bias: assume each finding is real; drop only the clearly wrong. Writes `/tmp/pr-review/findings.prosecutor.json` and exits.

**Stage 4b — Defender pass** (`prompts/validator.md`):

1. Dedupe across angles (keep the most actionable description; preserve the winner's `title` / `description` / `fix`).
2. Defense-attorney audit: try to prove each finding wrong. Drop pedantic / style-only / lint-catchable / "maybe" findings.
3. Severity check: you MAY downgrade (HIGH → MEDIUM, blocking true → false). You MAY NOT upgrade.
4. Comment-shape check: every surviving finding has `title` (bold headline ≤60 chars), `description` (issue only, no fix), and `fix` (recommended change in prose). Split overloaded `description` fields when an angle collapsed them.
5. `fix_type` enforcement: every surviving finding MUST carry `fix_type` (`"suggestion"` or `"prose"`). Downgrade any `fix_type: "suggestion"` that violates the ≤10-line / single-file / self-contained / no-placeholder / no-fence-break rules — set `fix_type: "prose"` and `suggestion: null`. Full rule list lives in `prompts/validator.md` step 7.
6. Writes `/tmp/pr-review/findings.defender.json`.

**Stage 4c — Intersect**:

```bash
bash "$WOO_REVIEW_ACTION_PATH/scripts/intersect-findings.sh"
```

Produces `/tmp/pr-review/findings.json` — the final validated set — and `/tmp/pr-review/validator-metrics.json` with `prosecutor_count`, `defender_count`, `kept_count`, `disagreement_count`. Intersection key is `(file, line, title-stem)` (same stem as prior-thread dedupe in `_header.md`). When `disable_adversarial: true` is set or `findings.prosecutor.json` is absent, the script copies defender output verbatim and tags metrics `mode: defender-only`. Severity = `min(prosecutor, defender)`, blocking = `prosecutor.blocking AND defender.blocking`, other fields take the defender's copy.

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
