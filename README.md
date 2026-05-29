# woo-review

A portable AI **skill** that turns any coding agent into a parallel PR review swarm. One slash command spawns specialized sub-agents (bugs, security, SEO, design, React, database), runs a skeptical validator, and — if you point it at a GitHub PR — posts a single batched review.

The companion GitHub Action is an **extension** of the skill: same prompts, same angles, same validator, just packaged for CI.

**Idempotent across runs.** Re-running on the same PR will not re-post findings that already match an open or resolved thread or a line-shifted version of a prior finding.

---

## Features

- **Parallel angle swarm** — one sub-agent per detected angle (`bugs`, `security`, `seo`, `aeo`, `design`, `react`, `database`) runs concurrently against the same diff.
- **Skeptical Validator** — adversarial prosecutor + defender pass, deterministic intersect, severity downgrade only (never upgrade). Merges duplicate findings from different angles before posting.
- **Cross-PR memory** — a plain-markdown file at `.woo-review/memory.md` that the team curates with gotchas and intentionally-accepted issues. The review reads it as context and drops any finding the memory already records as known/accepted. Humans can edit it freely; the local skill may append to it after a review.
- **High-priority-only by default** — `severity_floor` defaults to `high` so only critical findings surface out of the box. Set `severity_floor: low` or `medium` in `.woo-review/config.yml` to widen the net.
- **Host-agnostic** — the skill runs under Claude Code, Cursor, Gemini CLI, opencode, or any host that can spawn sub-agents.
- **Multi-provider** — Anthropic, OpenAI, Google, and OpenRouter all work with the same prompts; provider auto-detected from the secret you supply.
- **CI extension** — same prompts, same angles, same validator, packaged as a reusable GitHub Actions workflow.
- **Batched native review** — one `pulls/<N>/reviews` POST per run; no comment spam, no PR title/description/label mutations.
- **Knowledge aggregation** — calls established tools (`impeccable`, `react-doctor`, `openai/security-best-practices`, `supabase-postgres-best-practices`, `coreyhaines31` SEO/AEO rubrics) instead of re-implementing them.

---

## Install (skill)

```bash
npx skills add howarewoo/woo-review
```

Requires `gh`, `jq`, `node` on PATH. Optional power-ups: `pbakaus/impeccable`, `coreyhaines31/seo-audit`.

## Use (skill)

```text
/woo-review            # Auto-detect: if current branch has an open PR, behave as /woo-review <PR#>; else review local diff against origin/main
/woo-review 123        # Fetch PR #123, run the swarm, post a native GitHub Review
woo-review install     # Verify deps + warm npx caches
woo-review status      # Show current PR review state
```

When you invoke `/woo-review` the host agent:

1. **Prefetches** diff + metadata + rules + prior review threads (open + resolved) + cross-PR memory into `/tmp/pr-review/`.
2. **Detects** which angles apply (always-on: `bugs`, `security`; conditional: `seo`, `aeo`, `design`, `react`, `database`).
3. **Spawns one sub-agent per angle in parallel** (Claude Code Task, Cursor subagents, Gemini CLI sequential loop fallback — host-agnostic).
4. **Validates** all findings through a Skeptical Validator pass (merges duplicate findings from different angles, defense-attorney audit, severity downgrade only).
5. **Filters against memory** — drops findings already recorded as known/accepted in `.woo-review/memory.md`.
6. **Reports** locally OR posts one batched GitHub Review when a PR# was given.

```mermaid
flowchart TD
    A["/woo-review [PR#?]"] --> B[Prefetch<br/>diff + metadata + rules + memory<br/>→ /tmp/pr-review/]
    B --> C{Detect angles}
    C -->|always-on| D1[bugs]
    C -->|always-on| D2[security]
    C -->|*.html, meta, og:, sitemap| D3[seo]
    C -->|llms.txt, pricing.md, AI crawler tokens, JSON-LD| D3a[aeo]
    C -->|*.tsx/css/vue/svelte| D4[design]
    C -->|*.tsx/jsx + react dep| D6[react]
    C -->|*.sql, migrations/, SQL DDL/RLS tokens| D7[database]
    D1 --> E[Parallel sub-agents<br/>one per angle]
    D2 --> E
    D3 --> E
    D3a --> E
    D4 --> E
    D6 --> E
    D7 --> E
    E --> F[Skeptical Validator<br/>merge duplicate findings · defense-attorney · severity downgrade only]
    F --> F2[Memory filter<br/>drop findings already recorded as<br/>known/accepted in .woo-review/memory.md]
    F2 --> G{PR# given?}
    G -->|no| H[Local report]
    G -->|yes| I[Batched GitHub Review<br/>event=REQUEST_CHANGES when blocking]
```

See [`skills/woo-review/SKILL.md`](./skills/woo-review/SKILL.md) for the full workflow contract.

---

## Knowledge aggregation

The skill calls into established domain tools instead of re-implementing them:

| Source | Used by angle | Mechanism |
|---|---|---|
| [coreyhaines31/ai-seo](https://www.skills.sh/coreyhaines31/marketingskills/ai-seo) | `aeo` | Embedded as the rubric in `skills/woo-review/prompts/angles/aeo.md`; deeper `references/` fetched on demand via `gh api` |
| [coreyhaines31/seo-audit](https://www.skills.sh/coreyhaines31/marketingskills/seo-audit) | `seo` | Embedded as the rubric in `skills/woo-review/prompts/angles/seo.md` |
| [millionco/react-doctor](https://github.com/millionco/react-doctor) | `react` | `npx -y react-doctor --diff <base> --offline` |
| [openai/security-best-practices](https://www.skills.sh/openai/skills/security-best-practices) | `security` | Language/framework-specific rubric loaded from `openai/skills` `references/`; fetched on demand via `gh api` if not installed locally |
| [pbakaus/impeccable](https://github.com/pbakaus/impeccable) | `design` | `npx -y impeccable detect --json` (one run, drives quant + qual passes) |
| [supabase/supabase-postgres-best-practices](https://www.skills.sh/supabase/agent-skills/supabase-postgres-best-practices) | `database` | Referenced from `skills/woo-review/prompts/angles/database.md`; rule families (`security-*`, `query-*`, `schema-*`, `conn-*`, `lock-*`, `data-*`) fetched on demand via `gh api` |

The audit rubrics live in `skills/woo-review/prompts/` so the skill is self-sufficient — recommended skills only enrich the host agent's general vocabulary.

---

## Angles

| Angle | Always-on | Detection trigger | Tooling |
|---|---|---|---|
| `bugs` | yes | — | LLM only |
| `security` | yes | — | LLM + `openai/security-best-practices` rubric |
| `seo` | no | `*.html`, `head.{ts,tsx}`, `layout.{ts,tsx}`, `robots.txt`, `sitemap.{xml,ts}`, `next.config.*`, `app/manifest.*`, or `<meta>`/`og:`/`canonical` tokens in diff | LLM + `coreyhaines31/seo-audit` rubric (embedded in `skills/woo-review/prompts/angles/seo.md`) |
| `aeo` | no | `robots.txt`, `llms.txt`, `pricing.{md,txt}`, `*.{md,mdx,html}`, or diff body contains AI-crawler tokens (`GPTBot`, `PerplexityBot`, `ClaudeBot`, `Google-Extended`, `anthropic-ai`) or JSON-LD `FAQPage`/`HowTo`/`Article`/`Product`/`ItemList`/`Review` types | LLM + `coreyhaines31/ai-seo` rubric (embedded in `skills/woo-review/prompts/angles/aeo.md`) |
| `design` | no | `*.{tsx,jsx,vue,svelte,html,css,scss,sass,less,styl,astro}` | LLM + `impeccable detect` (one run; quantitative pass from JSON, qualitative critique scoped to flagged files) |
| `react` | no | `*.{tsx,jsx}` AND `react` in `package.json` | `react-doctor` + LLM |
| `database` | no | `*.sql`, `(db\|supabase\|prisma)/migrations/`, `prisma/schema.prisma`, `drizzle.config.*`, `drizzle/`, `knexfile.*`, `supabase/(config.toml\|seed.sql)`, OR SQL DDL / RLS tokens / Supabase client / ORM raw-SQL call sites in diff | LLM + `supabase/supabase-postgres-best-practices` rubric (fetched via `gh api`) |

---

## CI extension: the GitHub Action

The same skill, packaged as a GHA reusable workflow for repos that want reviews on every PR without anyone running a slash command.

```yaml
# .github/workflows/ai-review.yml
name: AI PR Review
on:
  pull_request:
    types: [opened, reopened, ready_for_review]
  issue_comment:
    types: [created]

jobs:
  review:
    # Pinned to the v0.1.0 tag. Production: replace with the full commit SHA (see Security section).
    uses: howarewoo/woo-review/.github/workflows/reusable-review.yml@v0.1.0
    with:
      provider: anthropic
    secrets:
      anthropic_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

Zero local setup in the consumer repo — the action ships its own Node tools and prompts. Full template at [`examples/workflows/ai-review.yml`](./examples/workflows/ai-review.yml).

The CI pipeline mirrors the skill's swarm 1:1 — detection job → matrix of angle workers → validator → batched review.

### Provider matrix (May 2026 defaults)

| Provider | Worker model | Validator model | Secret |
|---|---|---|---|
| `anthropic` | `claude-sonnet-4-6` | `claude-opus-4-7` | `anthropic_token` |
| `openai` | `gpt-5-5-instant` | `gpt-5-5` | `openai_api_key` |
| `google` | `gemini-3-5-flash` | `gemini-3-1-pro` | `google_api_key` |
| `openrouter` | `deepseek/deepseek-v4-flash` | `deepseek/deepseek-v4-pro` | `openrouter_api_key` |

### Inputs

| Name | Default | Notes |
|---|---|---|
| `provider` | `""` | `anthropic`, `openai`, `google`, `openrouter`. Auto-detected from supplied secret. |
| `mode` | `full` | `full`, `detect`, `review`, `validate`. Reusable workflow handles wiring. |
| `disable_angles` | `""` | CSV of optional angles to skip (e.g. `seo,aeo,design,react,database`). `bugs` and `security` are non-negotiable. |
| `max_turns` | `30` | Agent loop cap (Anthropic; other providers use their equivalent). |

> Review tuning that is **not** an action input — `severity_floor`, `angles.force`/`skip`, `ignore`, `authors_skip`, `disable_adversarial`, `chunking`, per-tier `models` — lives in the consumer repo's `.woo-review/config.yml`, not here. See the [Per-repo Configuration](skills/woo-review/SKILL.md#per-repo-configuration-woo-reviewconfigyml) section of the skill for the full schema.

---

## Output

Whether triggered locally or via CI:

1. **Inline review comments** — one batched `gh api ... /pulls/<N>/reviews` POST with `suggestion` blocks where applicable. Findings already recorded as known/accepted in `.woo-review/memory.md` are dropped before posting.
2. **Status line** in the review body: `**Status: APPROVED** / APPROVED WITH SUGGESTIONS / CHANGES REQUESTED — counts.`
3. **Native review event** — `REQUEST_CHANGES` when any validated finding is blocking OR when any prior thread is still `status: open`; `COMMENT` when only non-blocking findings exist; `APPROVE` when none and no open prior threads. Wire branch protection to "Require approval of the most recent reviewable push" or the `pull-request-review` required check to gate merges.

The action never modifies the PR title, description, or labels.

### Cross-PR memory

`.woo-review/memory.md` is the skill's home for cross-PR knowledge — a plain-markdown list of gotchas, known false positives, and intentionally-accepted issues that the team curates over time. There is no database, no sharded JSONL, no hooks: just a file.

- **Read as context.** Prefetch loads it into the review; every angle and both validator passes drop any finding the memory already records as known/accepted/wontfix. That is what keeps re-reviews quiet.
- **Written inline (local).** When you run `/woo-review` locally and dismiss a finding, the skill records the *learning* in `.woo-review/memory.md` — but first checks no existing entry already covers it, so the file stays a small deduplicated set of reusable rules, not a log of every dismissal. Direct write access, no post-session hook.
- **Curated by humans.** Edit it freely; it is meant to be read.

See [`skills/woo-review/SKILL.md`](./skills/woo-review/SKILL.md) for the full workflow contract.

---

## Security

When wiring the action behind `pull_request_target` (write-scope), always pin to a full commit SHA to defend against supply-chain attacks. See [GitHub's hardening guide](https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions).

## Project docs

- Skill contract: [`skills/woo-review/SKILL.md`](./skills/woo-review/SKILL.md)
- Agent mandates: [`AGENTS.md`](./AGENTS.md)

## License

MIT.
