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
- `woo-review install` — Verify local deps (`gh`, `jq`, `node`), pre-fetch `impeccable` + `react-doctor`, and register the post-session sidecar-write Stop hook in `.claude/settings.local.json` (run once per repo).
- `woo-review status` — Show the current PR's review status.

### PR-comment triggers (issue #19)

When the companion GitHub Action is installed, the following comment commands re-trigger the review without leaving the PR:

| Comment | Effect |
|---|---|
| `/woo-review` | Full re-review (sets `incremental=off`). Equivalent to `@review --full`. |
| `/woo-review recheck` | Incremental review of new commits since the last marker. Same path as a `synchronize` event. |
| `/woo-review force` | Bypass auto-skip (see *Auto-skip* below). Combinable: `/woo-review force recheck`. |

The legacy `@review` trigger phrase still works; `/woo-review` is an alias the example workflow's `issue_comment` `if:` recognizes.

### Auto-skip (bot PRs + release rollups)

`prefetch.sh` short-circuits the review with a single one-line PR comment when either condition holds (before fetching the diff, so token cost is ~zero):

- **PR author matches `authors_skip`.** Default list: `dependabot[bot]`, `renovate[bot]`, `github-actions[bot]`. Override with `authors_skip: [...]` in `.woo-review.yml`; explicit `authors_skip: []` opts out entirely.
- **PR title matches `release_rollup_pattern`** (Python regex). Default: `^(staging|release|chore\(release\))`. Override with any string; explicit empty string opts out.

The skip comment carries a `<!-- woo-review:skipped -->` marker; subsequent triggers on the same PR detect the marker and re-skip silently (no comment spam). To force a full review of a skipped PR, post `/woo-review force`.

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

## History Dedup & Rule Recommendations

After the adversarial validator produces `findings.json`, a second dedup pass runs against cross-PR history to suppress findings that have already been surfaced. Implementation lives in `scripts/dedup-against-history.sh`; the JSON schema and field contracts live in `prompts/_header.md`.

### What it does

**Pass 1 — Deterministic drop.** Each finding is identified by a `(file, code_anchor, semantic_key)` triple. Any finding whose triple matches an entry in `prior-findings.json` (open or resolved threads from prior reviews) or `sidecar-findings.json` (committed dismissals from past PRs) is dropped without an LLM call.

**Pass 2 — LLM tiebreak.** Ambiguous pairs — same file, `|Δline| ≤ 10`, exactly one of `(code_anchor, semantic_key)` matches — are sent to a fast-tier model call that decides whether the two findings refer to the same underlying issue. Deterministic drops always win over the LLM tiebreak.

**Output:** `findings.deduped.json` (the deduplicated set consumed by Stage 5) and `dedup-metrics.json` (counters: `det_drops`, `llm_drops`, `pair_count`, etc.).

### New required finding fields

Workers MUST emit two additional fields on every finding (defined in the angle prompt's `semantic_key` enum and the `_header.md` schema):

- **`semantic_key`** — kebab-case `<angle>/<issue-type>` string, ≤ 40 chars (e.g. `bugs/null-deref`, `security/sql-injection`). Sourced from the angle prompt's enum; workers must not free-form it.
- **`code_anchor`** — first 12 hex chars of `shasum -a 1` of the ±3 source lines around the finding. Computed by the worker before writing `findings.<angle>.json`. Together with `semantic_key`, these form the dedup identity that persists across PR runs.

### Sidecar lifecycle

`prefetch.sh` loads the sidecar from the consumer repo into `/tmp/pr-review/sidecar-findings.json` at the start of each run. This file accumulates resolved threads that authors have explicitly dismissed — it prevents re-surfacing issues the team has consciously accepted.

After the review POST, `sidecar-write.sh` reads any threads that became
resolved on the PR and appends them — one JSON object per line — to one of
16 hash-sharded files at `.woo-review/dismissed-<0-f>.jsonl`, where the
shard is the first hex char of `sha1(file path)`. Sharding cuts merge-conflict
surface ~16× for concurrent PRs; a `merge=union` rule in `.gitattributes`
(installed automatically on first write) makes the remaining same-shard
collisions resolve line-by-line without conflict. Entries older than
`sidecar_ttl_days` (default 180) are pruned opportunistically — only on
shards the current write touches. On first run after upgrade, any pre-existing
`.woo-review/dismissed.json` is migrated into the shards and removed atomically
in the same commit; the migration runs even when there are zero newly-resolved
threads, so dormant repos still convert.

This write is gated on the `enable_sidecar_write` config flag (default `true`). In the CI extension the script runs in a *separate, permission-isolated* job that holds `contents: write` — the validator job (which runs the LLM against untrusted PR content) only holds `contents: read`, so an LLM compromise cannot pivot to repo-write capability. On local hosts the same isolation holds: the skill session never calls `sidecar-write.sh` itself. Instead it drops a `sidecar-pending` sentinel after the review POST, and a host-level **post-session hook** — registered in `.claude/settings.local.json` by `woo-review install` — runs the script once the session ends. The hook no-ops unless the sentinel is present and the current repo matches the reviewed one (`review-context.json:repo_path`).

#### Host-specific hook setup

`woo-review install` auto-registers the post-session hook only on **Claude Code** (it writes a `Stop` hook to `.claude/settings.local.json`). On other hosts it prints the command to wire manually instead of registering it. To complete local-sidecar setup on a non-Claude host, register this command as a **post-session / post-task hook** using your host's mechanism:

```bash
bash "$WOO_REVIEW_ACTION_PATH/scripts/sidecar-write.sh"
```

| Host | Where to register |
|---|---|
| **Claude Code** | Automatic — `Stop` hook in `.claude/settings.local.json` (run `woo-review install` once per repo). |
| **Cursor** | A background-agent post-task hook; the exact mechanism depends on Cursor's extension/agent API. |
| **opencode** | A session-end hook in the OpenCode runtime's hook configuration. |
| **Gemini CLI** | A post-run shell step (Gemini CLI has no native session-end hook today — wire it into your invoking wrapper/script). |

The hook is safe to run after every session: it no-ops unless the `sidecar-pending` sentinel is present **and** the current repo matches `review-context.json:repo_path`. Running the LLM step never touches repo-write — only this out-of-band hook does (PR #33 contract).

### Event-floor rule change

The posting stage now uses `prior-findings.json` differently from earlier releases:

- **Open** prior threads remain a gate signal — a non-empty set of open priors keeps the new review at minimum `REQUEST_CHANGES`.
- **Resolved** prior threads are dedup signal only. They no longer force `REQUEST_CHANGES`; a clean incremental pass can `APPROVE` even when resolved threads exist in history.

### Rule recommendations for AGENT.md / CLAUDE.md

When `findings.deduped.json ∪ sidecar-findings.json` contains ≥ `WOO_REVIEW_RULES_THRESHOLD` entries sharing the same `semantic_key`, one short Sonnet (`fast`-tier) call drafts a markdown bullet list of project rules that would have prevented the cluster. The output is appended to the PR review body under the heading `### Suggested rules for AGENT.md / CLAUDE.md`. Authors can copy the bullets directly into their repo's `AGENTS.md` or `CLAUDE.md`; on the next PR the `conventions` angle will enforce them.

### Config flags

| Flag | Type | Default | Effect |
|---|---|---|---|
| `enable_history_dedup` | `.woo-review.yml` boolean | `true` | Gates `dedup-against-history.sh`. When `false`, Stage 5 consumes `findings.json` directly (legacy path). |
| `enable_sidecar_write` | `.woo-review.yml` boolean | `true` | Gates `sidecar-write.sh`. |
| `sidecar_ttl_days` | `.woo-review.yml` integer | `180` | Age cap for sidecar entries. Pruned opportunistically on touched shards. Set `0` to disable pruning. |
| `WOO_REVIEW_RULES_THRESHOLD` | env integer | `2` | Cluster size at which rule recommendations are drafted. Set to `0` to disable rule recs entirely. |

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
sidecar_ttl_days: 180          # age cap in days for sidecar entries; set 0 to disable pruning
ignore:                        # fnmatch globs; ignored paths skip angle triggers + diff body
  - "**/*.generated.ts"
  - "migrations/*.sql"
project_rules:                 # appended to auto-discovered rules.md
  - constitution.md
  - "docs/standards/*.md"
authors_skip:                  # PR author logins that short-circuit the entire review.
  - "dependabot[bot]"          # Defaults: dependabot[bot], renovate[bot],
  - "renovate[bot]"            # github-actions[bot]. Set to [] to opt out.
release_rollup_pattern: '^(staging|release|chore\(release\))'  # Python regex on PR
                               # title. Default shown. Empty string opts out.
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
chunking:
  max_loc: 4000                # diff-chunking threshold (issue #14). When the
                               # post-ignore diff exceeds this many changed
                               # lines, prefetch splits it into chunks honoring
                               # workspace package roots > top-level dirs >
                               # file-LOC balanced groups. Each angle fans out
                               # as angles × chunks parallel sub-agents.
                               # `0` disables chunking entirely. Missing => 4000.
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

> **Atomic state.** `prefetch.sh` wipes `$OUTDIR` (defaults to `/tmp/pr-review`) before recreating it. Hosts that invoke individual stages directly (skipping `prefetch.sh`) MUST do the same — stale `findings.<angle>.json` from a prior run will otherwise re-enter the merge step and contaminate the review.
>
> **OUTDIR override.** All scripts (`prefetch.sh`, `load-config.sh`, `detect-angles.sh`, `merge-findings.sh`, `intersect-findings.sh`, `chunk-diff.sh`, `resolve-diff-line.sh`) honor the `OUTDIR` environment variable. Hosts that cannot use `/tmp/pr-review/` (e.g. sandboxed runtimes with workspace-scoped temp dirs) MUST export `OUTDIR=<their_dir>` to **every** sub-agent. Without that, sub-agents will write findings to a different directory than the merge step reads, silently dropping them.

**If a PR number was supplied** — export it and invoke `prefetch.sh` directly. The script handles diff fetch, meta fetch, project-rule discovery, auto-skip checks, and prior-findings extraction. Hosts whose tool gating blocks caller-side `$(...)` substitution (notably Gemini CLI) MUST use this path — `prefetch.sh` self-resolves the PR number from the current branch when none is exported and `GITHUB_ACTIONS != "true"`, so callers never need their own subshell.

```bash
export PR_NUMBER=<n>   # optional; prefetch.sh derives it from the branch when unset
bash "$WOO_REVIEW_ACTION_PATH/scripts/prefetch.sh"
```

When prefetch resolves a PR number AND finds an open PR, it produces the full artifact tree (`diff.txt`, `meta.json`, `last_sha.txt`, `prior-findings.json`, `rules.md` when applicable, `sidecar-findings.json` when any `.woo-review/dismissed-*.jsonl` shards or the legacy `dismissed.json` exist in the consumer repo). When no PR resolves, it emits `skip=true` — the host then falls back to local-diff mode below.

**Artifact reference.** All paths are under `$OUTDIR` (default `/tmp/pr-review/`):

| Artifact | Written by | Consumed by | Notes |
|---|---|---|---|
| `diff.txt` | `prefetch.sh` | angle workers, `merge-findings.sh` | Full or incremental diff |
| `meta.json` | `prefetch.sh` | all stages | PR metadata (title, files, SHA, author) |
| `last_sha.txt` | `prefetch.sh` | Stage 5 watermark | Present only when a prior watermark was found |
| `prior-findings.json` | `prefetch.sh` | dedup, event-floor gate | Unresolved + resolved prior review threads |
| `rules.md` | `prefetch.sh` | `conventions` angle, validator | Concatenated project rule files; triggers `conventions` angle when present |
| `angles.txt` | `detect-angles.sh` | Stage 3 orchestrator | One angle name per line |
| `findings.<angle>.json` | angle workers | `merge-findings.sh` | Raw per-angle output |
| `raw_findings.json` | `merge-findings.sh` | validator passes | Merged, chunk-collapsed findings |
| `findings.json` | `intersect-findings.sh` | Stage 5, dedup script | Final validated set |
| `sidecar-findings.json` | `prefetch.sh` (from `.woo-review/dismissed-*.jsonl` + legacy `dismissed.json` fallback) | dedup Pass 1 | array of `{file, line, title, semantic_key, code_anchor, resolved_at, pr_number}`; merged across all 16 shards. |
| `review-context.json` | `prefetch.sh` | `sidecar-write.sh` (local Stop hook) | PR handoff: `{pr_number, head_sha, repo, repo_path}`; read by the post-session hook to re-hydrate state when session env is absent. Local hosts only. |
| `findings.deduped.json` | `dedup-against-history.sh` | Stage 5 posting | `findings.json` with history-matched entries removed |
| `dedup-metrics.json` | `dedup-against-history.sh` | observability | `det_drops`, `llm_drops`, `pair_count` counters |
| `rule-recommendations.md` | `dedup-against-history.sh` (Sonnet call) | Stage 5 posting | Markdown bullets appended to review body when emitted; see *Rule Recommendations* above |
| `validator-metrics.json` | `intersect-findings.sh` | observability | `prosecutor_count`, `defender_count`, `kept_count`, `disagreement_count` |

**If no PR number resolved (local mode):**

```bash
OUTDIR="${OUTDIR:-/tmp/pr-review}"
rm -rf "$OUTDIR"
mkdir -p "$OUTDIR"
BASE="$(git merge-base HEAD origin/main 2>/dev/null || git merge-base HEAD main)"
git diff "$BASE"...HEAD > "$OUTDIR/diff.txt"
# Synthesize meta.json from git for downstream scripts.
git diff --name-only "$BASE"...HEAD \
  | jq -R . | jq -s '{
      headRefOid: "'"$(git rev-parse HEAD)"'",
      baseRefName: "'"$(git rev-parse --abbrev-ref "$BASE@{upstream}" 2>/dev/null || echo main)"'",
      title: "(local diff)",
      body: "",
      files: [.[] | {path: .}]
    }' > "$OUTDIR/meta.json"
```

### Stage 2 — Detect Angles

```bash
bash "$WOO_REVIEW_ACTION_PATH/scripts/load-config.sh"   # parses .woo-review.yml (no-op if absent)
bash "$WOO_REVIEW_ACTION_PATH/scripts/detect-angles.sh"
```

Read the result from `/tmp/pr-review/angles.txt` (one angle per line). Always-on angles: `bugs`, `security`. Conditional (auto-detected from changed paths + diff body): `conventions` (when `rules.md` is present), `seo`, `aeo`, `design`, `react`, `database`, `tests`, `api`, `infra`, `observability`, `types`, `i18n`, `docs`, `deps`. See `scripts/detect-angles.sh` for per-angle gating heuristics.

Prefetch also produces optional chunking artifacts when the post-ignore diff exceeds `chunking.max_loc` (default 4000 LOC). When present, the host MUST fan out one sub-agent per `(angle, chunk)` pair in Stage 3:

- `/tmp/pr-review/chunks.txt` — chunk IDs, one per line (`chunk-0`, `chunk-1`, …).
- `/tmp/pr-review/chunks.json` — manifest: `[{id, files, loc, diff_path, boundary}]`.
- `/tmp/pr-review/diff.chunk-<id>.txt` — per-chunk diff (a valid `diff --git` stream).

Boundary precedence: workspace packages (`packages/<name>/`, `apps/<name>/`, `services/<name>/`, `libs/<name>/`) → top-level directories → file-LOC-balanced split. When `chunks.txt` is absent the diff is under threshold and chunking is a no-op.

### Stage 3 — Spawn Parallel Sub-Agents (one per angle, × chunk if chunked)

**This is the swarm step.** For each detected angle, spawn a sub-agent in parallel using your host's primitive:

- Claude Code: `Task` tool, one call per angle in a single message.
- Cursor / Composer: parallel subagent dispatch.
- Gemini CLI: built-in `@generalist` subagent, one `@generalist` per angle in the same response (see `prompts/google.md`). Parallel-vs-sequential dispatch of multiple `@<agent>` calls in a single turn is not formally documented today; treat as best-effort parallel — the isolation pattern still buys token economy even if Gemini serializes internally.
- opencode: parallel subagent dispatch via the OpenCode runtime's primitive (see `prompts/opencode.md`); falls back to a sequential loop when the build does not support it.

Each sub-agent receives the same brief:

```
You are the <angle> reviewer for this PR. Read:
- $WOO_REVIEW_ACTION_PATH/prompts/_header.md   (shared contract)
- $WOO_REVIEW_ACTION_PATH/prompts/angles/<angle>.md   (your scope)
- $OUTDIR/diff.txt, $OUTDIR/meta.json   (OUTDIR defaults to /tmp/pr-review)

Execute any shell commands the angle prompt specifies (e.g. impeccable detect,
react-doctor). Write your findings as a JSON array to
$OUTDIR/findings.<angle>.json per the schema in _header.md. The file MUST
start with `[` and end with `]` — no preamble, no commentary, no markdown
fences. Before writing each finding's `line` field, validate it via
`bash $WOO_REVIEW_ACTION_PATH/scripts/resolve-diff-line.sh --file <path> --line <N>`
and drop the finding when the helper prints `null` (the line is not anchorable
on the diff's RIGHT side and the GitHub API will reject the comment). EXIT.
```

**Chunked fan-out.** When `/tmp/pr-review/chunks.txt` exists, spawn one sub-agent per `(angle, chunk_id)` instead of one per angle. Pass the chunk ID in the brief, and tell the sub-agent to read `/tmp/pr-review/diff.chunk-<id>.txt` and write `/tmp/pr-review/findings.<angle>.chunk-<id>.json`. The validator pass still runs **once globally** — `merge-findings.sh` collapses any within-angle duplicates across chunks before validation, and the validator handles cross-angle dedup as today.

Sub-agents MUST NOT post comments, edit the PR, or touch other angles' files.

**Model routing (token optimization, host-agnostic).** Each angle prompt and the validator declare a `tier:` in frontmatter — `fast`, `standard`, or `deep`. The host resolves the tier to a concrete model via the table in `prompts/_header.md`. Tier assignments:

| Stage | Tier | Why |
|---|---|---|
| Context+summary subagent | `fast` | Mechanical summarization. |
| `bugs`, `security` workers | `standard` | Reasoning-heavy: correctness + threat model. |
| `design`, `react` workers | `standard` | Heuristic + Rules-of-Hooks judgment after deterministic tools. |
| `database` worker | `standard` | Postgres correctness, RLS reasoning, plan/index judgment. |
| `tests`, `api`, `infra` workers | `standard` | Coverage/contract/IaC reasoning. |
| `seo`, `aeo` workers | `fast` | Rubric checklists; no novel reasoning. |
| `observability`, `types`, `i18n`, `docs`, `deps` workers | `fast` | Pattern matching + diff-anchored hygiene checks. |
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
- Pass `disable_angles` to skip optional angles when scope is narrow (e.g. backend-only PR → `disable_angles: "seo,aeo,design,react,i18n"`).

## Troubleshooting

- **Missing artifacts** in cloud mode — verify the `detect` job uploaded `review-artifacts`.
- **Empty validator output** — inspect `$OUTDIR/raw_findings.json`. If empty, no angle wrote findings; check each `findings.<angle>.json`.
- **Sub-agents posting prematurely** — re-read the Stage 3 brief; workers must write JSON only.
- **`gh api ... /reviews` returns HTTP 422 "Line could not be resolved"** — a finding's `line` field did not map to a `+` or context line on the diff's RIGHT side. The merge step now drops these via `resolve-diff-line.sh`, but mismatches outside the helper's reach can still slip through. Re-run with the resolver enabled (it runs by default in `merge-findings.sh`) and inspect `$OUTDIR/diff-line-cache.json` to see which lookups returned `null`.
- **Stale findings from a prior run** — `prefetch.sh` now wipes `$OUTDIR` before recreating it. Hosts that skip `prefetch.sh` MUST `rm -rf "$OUTDIR"` themselves; otherwise files like `findings.bugs.json` from an earlier session leak into the merge step.
- **`detect-angles.sh` crashes outside GitHub Actions** — fixed: the script now emits `angles=` / `chunks_json=` lines to stdout and writes `$OUTDIR/angles.json` + `$OUTDIR/chunks-matrix.json` when `$GITHUB_OUTPUT` is unset. Inspect those files when running locally.
- **Sub-agent writes findings to the wrong path** — caused by host workspace drift (the sub-agent's CWD differs from the orchestrator's). Export `OUTDIR` to every sub-agent — see Stage 1.
- **Adversarial validators dropped a finding both passes agreed on** — the intersection now applies a fuzzy second pass (`±10` lines, prefix-20 title-stem match). Check `$OUTDIR/validator-metrics.json` for `disagreement_count`; surprises usually mean title-stem prefix mismatch, not line drift.
- **Caller-side `PR_NUMBER="$(gh pr view ...)"` blocked by host sandbox** — some hosts (Gemini CLI, sandboxed runtimes) reject inline `$(...)` substitutions on tool calls. Skip the caller-side resolution: `bash $WOO_REVIEW_ACTION_PATH/scripts/prefetch.sh` derives the PR number itself from the current branch when `PR_NUMBER` is unset and `GITHUB_ACTIONS != "true"`.
- **`prefetch.sh` skipped with "bot already commented and trigger is not explicit" on a local run** — fixed: that re-run guard now only applies inside GitHub Actions (`GITHUB_ACTIONS=true`). Local `/woo-review` invocations are explicit by definition and no longer trip the gate.
- **GitHub API rejects `REQUEST_CHANGES` / `APPROVE` on a self-authored PR** — fixed in `_header.md`: the payload-builder compares `gh api user --jq .login` against `meta.json .author.login` and downgrades the event to `COMMENT` when they match. The STATUS_LINE in the review body still carries the accurate verdict; a small note is appended explaining the downgrade.
- **Sub-agent died mid-run and left no `findings.<angle>.json`** — orchestrator prompts now write `[]` to the findings path on entry (so a crash leaves an empty array, not a missing file) and re-launch any angle whose file is missing or non-array after the swarm completes (one retry per `(angle, chunk)` pair). If the retry also fails, that angle simply contributes no findings — the rest of the review still posts.
- **`merge-findings.sh` failed on bad JSON escapes from a worker** — the recovery path now tries `json.loads(strict=False)` and a fallback that strips bare control bytes + invalid `\<char>` escapes inside strings. Workers that emit raw tabs/newlines or Windows paths inside `description` fields no longer sink the whole merge. The Output Discipline section of `_header.md` documents the escape rules workers should follow up-front.
