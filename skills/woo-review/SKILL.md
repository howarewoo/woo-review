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
- `woo-review install` — Verify local deps (`gh`, `jq`, `node`) and pre-fetch `impeccable` + `react-doctor` (run once per repo).
- `woo-review status` — Show the current PR's review status.
- `woo-review address <PR#>` — Autonomously address the PR's unresolved review threads (fix or push back, reply, resolve) and record accept-by-design dismissals to `.woo-review/memory.md`. Local hosts only. See *Addressing Reviews* below.

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

- **PR author matches `authors_skip`.** Default list: `dependabot[bot]`, `renovate[bot]`, `github-actions[bot]`. Override with `"authors_skip": [...]` in `.woo-review/config.json`; explicit `"authors_skip": []` opts out entirely.
- **PR title matches `release_rollup_pattern`** (Python regex). Default: `^(staging|release|chore\(release\))`. Override with any string; explicit empty string opts out.

The skip comment carries a `<!-- woo-review:skipped -->` marker; subsequent triggers on the same PR detect the marker and re-skip silently (no comment spam). To force a full review of a skipped PR, post `/woo-review force`.

## Incremental Mode

By default (`incremental: auto` on the GitHub Action), every posted review carries a hidden watermark:

```
<!-- woo-review:sha=<headRefOid> -->
```

On the next run, `prefetch.sh` scans **bot-authored** prior review bodies (the same `BOT_NAME_PATTERN` used elsewhere) for the marker — non-bot reviewers cannot forge a marker to narrow the window. If found, prefetch diffs `<last_sha>...HEAD` via the GitHub compare API instead of the full PR diff — only the new commits since the last pass are reviewed. Unresolved prior review threads (any author) are dumped to `$OUTDIR/prior-findings.json` and consumed by the posting stage as an **event floor**: any non-empty priors list keeps the new review at minimum `REQUEST_CHANGES`, a conservative gate so a stale open thread is never auto-resolved by a clean incremental pass.

Override paths:
- Action input `incremental: off` (workflow-level opt-out).
- A trigger comment containing `--full` (e.g. `@review --full`) — fixed-string match, regex-injection safe.
- Force-push that drops `<last_sha>` from the branch history — the compare API returns 404; prefetch emits a `::warning::` and falls back to the full diff for that run.

When the incremental diff has no new commits (i.e. `LAST_SHA == HEAD_SHA`, e.g. someone re-triggers without pushing), prefetch emits `skip=true` with reason `no new commits since last review (<last_sha>)`. To force a re-review of the same SHA, pass `--full` (or set `incremental: off`).

Marker semantics are state-light: the marker IS the state. There is no DB or workflow artifact retention beyond what GitHub already keeps in review history.

## Cross-PR Memory (`.woo-review/memory.md`)

Reviews stay useful across PRs through a single plain-markdown file in the consumer repo: **`.woo-review/memory.md`**. It is the team's running list of gotchas, intentional design choices, and issues a prior review already surfaced and the team consciously accepted. There is no database, no sharded JSONL, no hooks — just a file you can read and edit by hand.

### How it's used

- **Read as context.** `prefetch.sh` copies `.woo-review/memory.md` (if present, 100KB cap) into `$OUTDIR/memory.md`. Every angle worker and both validator passes treat it as additional rubric and **drop any finding the memory already records as known/accepted/wontfix**. This is what keeps re-reviews quiet: an issue the team has consciously accepted is not re-flagged on the next PR.
- **Written inline (local).** When you run `/woo-review` locally and dismiss a finding (or note a gotcha worth remembering), the skill records the **learning** in `.woo-review/memory.md` — first checking that no existing entry already covers it, so the file stays a small deduplicated set of reusable rules rather than a log of every dismissal. The local skill has direct write access — no post-session hook, no permission-isolated job. See Stage 6 below.
- **Curated by humans.** The file is meant to be edited directly. Add a bullet, delete a stale one, group entries under headings — whatever keeps it readable.

### Event-floor rule (prior threads)

`prior-findings.json` (unresolved + resolved threads on the *current* PR) is still produced for incremental mode, but it is used for one thing only: **open** prior threads are an event floor — a non-empty set keeps the new review at minimum `REQUEST_CHANGES`. Resolved threads do not gate the event; a clean incremental pass can `APPROVE`.

### Noise control (`severity_floor`)

`severity_floor` **defaults to `high`** — by default only high-priority findings surface. Widen it per-repo in `.woo-review/config.json` (`"severity_floor": "low"` or `"medium"`). The validator applies the floor after its own severity check.

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

Prefetch auto-discovers project rule files (`AGENTS.md`, `CLAUDE.md`, `.cursorrules`, `.windsurfrules`, `GEMINI.md`) at the repo root, and additionally walks up from each changed file path to collect any `AGENTS.md` / `CLAUDE.md` along the way. The discovered content is concatenated (each section prefixed by a `## SOURCE: <path>` header, 100KB cap) into `$OUTDIR/rules.md` and surfaced to every angle as additional rubric. When that file is present, an extra `conventions` angle fires; the validator drops any finding that claims a rule violation but cannot quote the rule verbatim. Repos without rule files run unchanged.

## Per-repo Configuration (`.woo-review/config.json`)

Drop an optional `.woo-review/config.json` in the consumer repo to tune the review without forking the skill. Prefetch parses it into `$OUTDIR/config.json` (canonical copy); downstream stages read from there. Missing file = defaults (`severity_floor: high`). **All keys are optional — specify only the ones you want to override; the rest keep their built-in defaults.** Invalid JSON or unknown keys → loud `::error file=.woo-review/config.json,line=N::<msg>` annotation and the workflow fails (no silent fallback).

Minimal example — override one knob, everything else stays default:

```json
{ "severity_floor": "medium" }
```

Full schema (every key shown; all optional):

```json
{
  "angles": {
    "force": ["database"],
    "skip": ["seo"]
  },
  "severity_floor": "high",
  "ignore": [
    "**/*.generated.ts",
    "migrations/*.sql"
  ],
  "project_rules": [
    "constitution.md",
    "docs/standards/*.md"
  ],
  "authors_skip": [
    "dependabot[bot]",
    "renovate[bot]"
  ],
  "release_rollup_pattern": "^(staging|release|chore\\(release\\))",
  "models": {
    "fast": "anthropic/claude-haiku-4-5",
    "standard": "openai/gpt-5",
    "deep": "anthropic/claude-opus-4-7"
  },
  "fix_commands": ["pnpm lint:fix", "pnpm format"],
  "disable_adversarial": false,
  "chunking": {
    "max_loc": 4000
  }
}
```

Key reference (JSON has no comments, so the per-key semantics live here):
- **`angles.force`** — always run these, even if not auto-detected. **`angles.skip`** — never run these (`bugs`/`security` cannot be skipped).
- **`severity_floor`** — one of `low` | `medium` | `high`; drops findings below the floor. **Default `high`** — only high-priority findings surface. Set `low`/`medium` for noisier reviews.
- **`ignore`** — fnmatch globs; ignored paths skip angle triggers + diff body.
- **`project_rules`** — fnmatch globs appended to auto-discovered `rules.md`.
- **`authors_skip`** — PR author logins that short-circuit the entire review. Defaults: `dependabot[bot]`, `renovate[bot]`, `github-actions[bot]`. Set to `[]` to opt out.
- **`release_rollup_pattern`** — Python regex on the PR title (default shown above; note `\\(` to escape the paren in JSON). Empty string opts out.
- **`models`** — per-tier slug overrides; the action input `inputs.model` still wins.
- **`fix_commands`** — reserved for `--loop` mode (issue #15).
- **`disable_adversarial`** — cost-sensitive opt-out for the prosecutor+defender validator (issue #13). When `true`, only the defender pass runs and its output becomes `findings.json` directly.
- **`metrics`**: opt in to per-angle signal/noise metrics (bool, default `false`) — emit `findings.metrics.json` per run and fold a rolling `.woo-review/metrics.json` aggregate (local only). See Stage 6.5.
- **`chunking.max_loc`** — diff-chunking threshold (issue #14). When the post-ignore diff exceeds this many changed lines, prefetch splits it into chunks honoring workspace package roots > top-level dirs > file-LOC-balanced groups; each angle fans out as angles × chunks parallel sub-agents. `0` disables chunking; missing => 4000.

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

Build the same `$OUTDIR/` artifact tree the GitHub Action builds.

> **Atomic state.** `prefetch.sh` wipes `$OUTDIR` (defaults to a per-project `/tmp/pr-review-<hash>` via `scripts/resolve-outdir.sh`) before recreating it. Hosts that invoke individual stages directly (skipping `prefetch.sh`) MUST do the same — stale `findings.<angle>.json` from a prior run will otherwise re-enter the merge step and contaminate the review.
>
> **OUTDIR override.** All scripts (`prefetch.sh`, `load-config.sh`, `detect-angles.sh`, `merge-findings.sh`, `intersect-findings.sh`, `chunk-diff.sh`, `resolve-diff-line.sh`) honor the `OUTDIR` environment variable. Hosts that cannot use `$OUTDIR/` (e.g. sandboxed runtimes with workspace-scoped temp dirs) MUST export `OUTDIR=<their_dir>` to **every** sub-agent. Without that, sub-agents will write findings to a different directory than the merge step reads, silently dropping them.
>
> **Default is per-project.** When `OUTDIR` is unset, scripts derive `/tmp/pr-review-<hash>` from the repo's git toplevel (via `scripts/resolve-outdir.sh`), so different repos on one machine isolate automatically. The orchestrator resolves it once and exports it to every sub-agent; `prefetch.sh` also prints `outdir=<path>`. Two concurrent runs of the *same* repo still share one dir — set `OUTDIR` explicitly to isolate those.

**If a PR number was supplied** — export it and invoke `prefetch.sh` directly. The script handles diff fetch, meta fetch, project-rule discovery, auto-skip checks, and prior-findings extraction. Hosts whose tool gating blocks caller-side `$(...)` substitution (notably Gemini CLI) MUST use this path — `prefetch.sh` self-resolves the PR number from the current branch when none is exported and `GITHUB_ACTIONS != "true"`, so callers never need their own subshell.

```bash
# Resolve the per-project OUTDIR once and export it so prefetch.sh and every
# sub-agent share one tree. Default: /tmp/pr-review-<hash> derived from the git
# toplevel (scripts/resolve-outdir.sh), so different repos on one machine never
# collide. An explicit OUTDIR (e.g. a sandbox temp dir) is respected as-is.
source "$WOO_REVIEW_ACTION_PATH/scripts/resolve-outdir.sh"   # sets + exports OUTDIR
export PR_NUMBER=<n>   # optional; prefetch.sh derives it from the branch when unset
bash "$WOO_REVIEW_ACTION_PATH/scripts/prefetch.sh"   # prints outdir=<path>; honors the exported OUTDIR
```

When prefetch resolves a PR number AND finds an open PR, it produces the full artifact tree (`diff.txt`, `meta.json`, `last_sha.txt`, `prior-findings.json`, `rules.md` when applicable, `memory.md` when the consumer repo has `.woo-review/memory.md`). When no PR resolves, it emits `skip=true` — the host then falls back to local-diff mode below.

**Artifact reference.** All paths are under `$OUTDIR` (default per-project `/tmp/pr-review-<hash>/`):

| Artifact | Written by | Consumed by | Notes |
|---|---|---|---|
| `diff.txt` | `prefetch.sh` | angle workers, `merge-findings.sh` | Full or incremental diff |
| `meta.json` | `prefetch.sh` | all stages | PR metadata (title, files, SHA, author) |
| `last_sha.txt` | `prefetch.sh` | Stage 5 watermark | Present only when a prior watermark was found |
| `prior-findings.json` | `prefetch.sh` | event-floor gate | Unresolved + resolved prior review threads |
| `rules.md` | `prefetch.sh` | `conventions` angle, validator | Concatenated project rule files; triggers `conventions` angle when present |
| `memory.md` | `prefetch.sh` | all angles, validator | Cross-PR memory (`.woo-review/memory.md`); findings it records as known/accepted are dropped. Present only when the consumer repo has the file |
| `angles.txt` | `detect-angles.sh` | Stage 3 orchestrator | One angle name per line |
| `findings.<angle>.json` | angle workers | `merge-findings.sh` | Raw per-angle output |
| `raw_findings.json` | `merge-findings.sh` | validator passes | Merged, chunk-collapsed findings |
| `findings.json` | `intersect-findings.sh` | Stage 5 posting | Final validated set |
| `validator-metrics.json` | `intersect-findings.sh` | observability | `prosecutor_count`, `defender_count`, `kept_count`, `disagreement_count`, `mode`, `degraded` |
| `findings.metrics.json` | `intersect-findings.sh` | metrics fold, telemetry | Per-angle signal/noise breakdown. Emitted **only when `metrics: true`** in config. Keyed by angle: `raw_count`, `prosecutor_kept`, `defender_kept`, `kept`, `dropped_by_defender`, `dropped_by_prosecutor`, `blocking_count`, `nonblocking_count`, `severity` |

**If no PR number resolved (local mode):**

```bash
source "$WOO_REVIEW_ACTION_PATH/scripts/resolve-outdir.sh"   # per-project default OUTDIR (or honors an explicit override)
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
bash "$WOO_REVIEW_ACTION_PATH/scripts/load-config.sh"   # parses .woo-review/config.json (defaults severity_floor=high)
bash "$WOO_REVIEW_ACTION_PATH/scripts/detect-angles.sh"
```

Read the result from `$OUTDIR/angles.txt` (one angle per line). Always-on angles: `bugs`, `security`. Conditional (auto-detected from changed paths + diff body): `conventions` (when `rules.md` is present), `seo`, `aeo`, `design`, `react`, `database`, `tests`, `api`, `infra`, `observability`, `types`, `i18n`, `docs`, `deps`. See `scripts/detect-angles.sh` for per-angle gating heuristics.

Prefetch also produces optional chunking artifacts when the post-ignore diff exceeds `chunking.max_loc` (default 4000 LOC). When present, the host MUST fan out one sub-agent per `(angle, chunk)` pair in Stage 3:

- `$OUTDIR/chunks.txt` — chunk IDs, one per line (`chunk-0`, `chunk-1`, …).
- `$OUTDIR/chunks.json` — manifest: `[{id, files, loc, diff_path, boundary}]`.
- `$OUTDIR/diff.chunk-<id>.txt` — per-chunk diff (a valid `diff --git` stream).

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
- $OUTDIR/diff.txt, $OUTDIR/meta.json   (OUTDIR is exported by the orchestrator; prefer it over any literal path)

Execute any shell commands the angle prompt specifies (e.g. impeccable detect,
react-doctor). Write your findings as a JSON array to
$OUTDIR/findings.<angle>.json per the schema in _header.md. The file MUST
start with `[` and end with `]` — no preamble, no commentary, no markdown
fences. Before writing each finding's `line` field, validate it via
`bash $WOO_REVIEW_ACTION_PATH/scripts/resolve-diff-line.sh --file <path> --line <N>`
and drop the finding when the helper prints `null` (the line is not anchorable
on the diff's RIGHT side and the GitHub API will reject the comment). EXIT.
```

**Chunked fan-out.** When `$OUTDIR/chunks.txt` exists, spawn one sub-agent per `(angle, chunk_id)` instead of one per angle. Pass the chunk ID in the brief, and tell the sub-agent to read `$OUTDIR/diff.chunk-<id>.txt` and write `$OUTDIR/findings.<angle>.chunk-<id>.json`. The validator pass still runs **once globally** — `merge-findings.sh` collapses any within-angle duplicates across chunks before validation, and the validator handles cross-angle dedup as today.

Sub-agents MUST NOT post comments, edit the PR, touch other angles' files, run `prefetch.sh`, or delete/recreate `$OUTDIR`. `prefetch.sh` is a Stage-1-only operation; re-running it mid-swarm wipes `meta.json` / `prior-findings.json` and corrupts the posting stage (issue #48).

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
# Produces $OUTDIR/raw_findings.json
```

Validation runs as an **adversarial pipeline** (issue #13): two opposing-bias `deep`-tier validator passes followed by a deterministic intersection. The intersection (findings BOTH passes agree to keep) is what authors see — this trades 2× validator cost for materially higher signal-to-noise.

Read `disable_adversarial` from `$OUTDIR/config.json`:

```bash
DISABLE_ADV="$(jq -r '.disable_adversarial // false' $OUTDIR/config.json 2>/dev/null || echo false)"
```

**Stage 4a — Prosecutor pass** (skip if `DISABLE_ADV == true`):

Run `prompts/validator-prosecutor.md`. Bias: assume each finding is real; drop only the clearly wrong. Writes `$OUTDIR/findings.prosecutor.json` and exits.

**Stage 4b — Defender pass** (`prompts/validator.md`):

1. Dedupe across angles (keep the most actionable description; preserve the winner's `title` / `description` / `fix`).
2. Defense-attorney audit: try to prove each finding wrong. Drop pedantic / style-only / lint-catchable / "maybe" findings.
3. Severity check: you MAY downgrade (HIGH → MEDIUM, blocking true → false). You MAY NOT upgrade.
4. Comment-shape check: every surviving finding has `title` (bold headline ≤60 chars), `description` (issue only, no fix), and `fix` (recommended change in prose). Split overloaded `description` fields when an angle collapsed them.
5. `fix_type` enforcement: every surviving finding MUST carry `fix_type` (`"suggestion"` or `"prose"`). Downgrade any `fix_type: "suggestion"` that violates the ≤10-line / single-file / self-contained / no-placeholder / no-fence-break rules — set `fix_type: "prose"` and `suggestion: null`. Full rule list lives in `prompts/validator.md` step 7.
6. Writes `$OUTDIR/findings.defender.json`.

> **Swarm workers stop here.** In the chat-host swarm the defender writes `findings.defender.json` and EXITs — the orchestrator owns Stage 4c (intersect) and Stage 5 (post). Leave `WOO_REVIEW_SEQUENTIAL_VALIDATE` unset when running as a swarm worker — the GitHub Action's `validate` mode sets it because there one sequential agent owns the whole tail; a swarm host has separate orchestrator and worker roles, so the worker must not see it. Pointing a swarm defender at `validator.md` with the flag unset is the safe default — its Step 3/3b/4 gate keeps it from racing the prosecutor, posting prematurely, or mutating `$OUTDIR`.

**Stage 4c — Intersect**:

```bash
bash "$WOO_REVIEW_ACTION_PATH/scripts/intersect-findings.sh"
```

**Verify + retry (mirror the Stage 3 angle-retry guard).** Before intersect, run this **detection** check; it only reports — you (the orchestrator) perform the re-launch described after it:

```bash
for f in findings.prosecutor.json findings.defender.json; do
  if ! jq -e 'type == "array"' "$OUTDIR/$f" >/dev/null 2>&1; then
    echo "missing/non-array: $f — orchestrator must re-launch this pass once (see below)"
  fi
done
```

Re-launch a missing pass exactly **once** (prosecutor → `validator-prosecutor.md`; defender → `validator.md`), then re-run intersect. If a pass is still missing after the retry, intersect proceeds defender-only and sets `degraded: true` in `validator-metrics.json`.

**Surface degradation.** After intersect, read `validator-metrics.json`:

```bash
jq -r '.degraded // false' $OUTDIR/validator-metrics.json
```

If `true`, tell the user in your orchestrator summary that the review is defender-only / lower-confidence — the posting stage also appends a ⚠️ line to the review body (`_header.md`). A `disable_adversarial: true` opt-out reports `degraded: false` and needs no warning.

Produces `$OUTDIR/findings.json` — the final validated set — and `$OUTDIR/validator-metrics.json` with `prosecutor_count`, `defender_count`, `kept_count`, `disagreement_count`. Intersection key is `(file, line, title-stem)`. When `disable_adversarial: true` is set or `findings.prosecutor.json` is absent, the script copies defender output verbatim and tags metrics `mode: defender-only`. Severity = `min(prosecutor, defender)`, blocking = `prosecutor.blocking AND defender.blocking`, other fields take the defender's copy.

### Stage 5 — Report

**If invoked with a PR number** — post a single native batched GitHub Review per the procedure in `prompts/_header.md`:

- Build the STATUS_LINE (`APPROVED` / `APPROVED WITH SUGGESTIONS` / `CHANGES REQUESTED`).
- Submit one `gh api repos/<repo>/pulls/<PR>/reviews` POST containing all inline comments + the summary + status line. The review `event` (`APPROVE` / `COMMENT` / `REQUEST_CHANGES`) is the native gate — any blocking finding triggers `REQUEST_CHANGES`.
- DO NOT modify the PR title or body. DO NOT mutate PR labels.

**If invoked locally (no PR#)** — print the validated findings to the terminal grouped by severity, then stop. Do not touch any remote.

### Stage 6 — Update cross-PR memory (local hosts)

After reporting, when the user **dismisses** a finding as a known/intentional/accepted issue, or tells you a gotcha worth remembering, record the **learning** — not the individual issue resolution. The goal is a small, deduplicated set of generalizable rules ("the team accepts X pattern because Y"), not a growing log of every finding ever dismissed.

Before writing anything:

1. **Read the existing `.woo-review/memory.md`** (it was already loaded to `$OUTDIR/memory.md` in Stage 1; re-read the repo copy in case it changed).
2. **Check coverage.** If an existing entry already captures this learning — even phrased differently, or scoped more narrowly/broadly — do **NOT** append a duplicate. If the existing entry is close but the new dismissal generalizes it (e.g. the same pattern in a second file), edit that entry to widen its scope rather than adding a near-duplicate.
3. **Only when the learning is genuinely new**, append one short bullet phrased as a reusable rule, then stop.

```bash
mkdir -p .woo-review
# Append ONLY after confirming no existing entry covers this learning.
printf -- '- %s\n' "<general pattern>: <why it is accepted / what not to re-flag>" >> .woo-review/memory.md
```

Phrase entries as patterns, not instances — prefer "Generated `*.pb.go` files are intentional; do not flag their style" over "dismissed line 42 in user.pb.go". The local skill writes this file directly — no post-session hook, no permission-isolated job. Only record on an explicit dismissal or a stated gotcha — never auto-record every finding. Do NOT write memory in CI: the GitHub Action's validator job holds `contents: read` and posts the review only; memory is curated locally and by humans editing the file. Memory is read back as review context on the next run (Stage 1) and the validator drops findings it records.

## Addressing Reviews (`woo-review address <PR#>`, local hosts)

Stage 6 only fires when a finding is dismissed *during a live local run*. For
PR-targeted reviews the accept/dismiss decision happens **later**, on the PR
(often in a separate comment-addressing session) — so Stage 6's memory write
structurally never fires for the primary flow (issue #53). The `address` verb
closes that gap by owning the comment-addressing flow itself, with the memory
write at the exact moment a finding is accepted-by-design.

`address` is **local only** — it commits, pushes, and writes memory, none of
which the GitHub Action's `contents: read` validator job can do.

**Lifecycle (A1→A6):**

1. **Fetch** — resolve the PR# (explicit arg, else the current branch's open PR), then `bash "$WOO_REVIEW_ACTION_PATH/scripts/fetch-threads.sh"` writes every unresolved thread (any author) to `$OUTDIR/address-threads.json`. Memory + config are loaded as in Stage 1.
2. **Precondition** — the working tree must be clean **and** the current branch must be the PR head. Otherwise abort before any edit; tell the user to checkout the PR head on a clean tree.
3. **Reception loop** — per thread, follow `prompts/address.md`: read → understand → verify → evaluate → decide `FIX` / `ACCEPT` / `CLARIFY`.
4. **Commit + push** — one commit for all fixes → push to the PR head → capture `<sha>` (before any reply, so "Fixed in `<sha>`" is real). Never force-push.
5. **Reply + resolve** — per handled thread, `scripts/resolve-thread.sh` posts the reply then resolves (CLARIFY threads use `RESOLVE=0`: reply only, left open).
6. **Report** — summary table: thread → decision → action → memory-written?

Only an **ACCEPT** (accept-by-design) writes memory, deduplicated and phrased as
a reusable pattern — never a log of every fix. Memory is read back as context on
the next review run (Stage 1), keeping re-reviews quiet.

### Stage 6.5 — Fold per-angle metrics (local hosts, opt-in)

Only when the consumer repo sets `metrics: true` in `.woo-review/config.json`. The
per-run `findings.metrics.json` (written by `intersect-findings.sh`) is folded into a
rolling, **per-clone** aggregate at `.woo-review/metrics.json`. The fold script also
ensures that path is gitignored — the aggregate is local data, never committed
(cross-host aggregation is the job of the opt-in central sink, a separate feature).

```bash
bash "$WOO_REVIEW_ACTION_PATH/scripts/metrics-fold.sh"
```

This is a no-op when `metrics` is off or no per-run record exists. As with memory, the
GitHub Action does **not** fold — its job is `contents: read` + post; metrics persistence
is local only (the action uploads `findings.metrics.json` as a build artifact instead).

**Reading the aggregate.** Rank angles by validator-drop rate (noise candidates first):

```bash
jq -r '.angles | to_entries
  | map({angle: .key,
         raw: .value.raw_total,
         drop_rate: (if .value.raw_total > 0 then .value.dropped_by_defender_total / .value.raw_total else 0 end),
         keep_rate: (if .value.raw_total > 0 then .value.kept_total / .value.raw_total else 0 end)})
  | sort_by(-.drop_rate)[]
  | "\(.angle)\traw=\(.raw)\tdrop=\((.drop_rate*100|floor))%\tkeep=\((.keep_rate*100|floor))%"' \
  .woo-review/metrics.json
```

A high `raw` with a high `drop` rate is a noise candidate; a high `keep` rate is a useful angle.

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
