# OpenRouter (OpenCode) — Multi-Angle Agentic Review

OpenCode runs an agentic shell. Use its subagent system if available (`@subagent`-style spawning); otherwise fall back to the sequential structure shown below. The output contract is identical to the other providers.

The shared header above lists prefetched artifacts, findings schema, blocking criteria, and the do-NOT-flag list. **Apply them verbatim.** Per-angle prompt bodies live at `$WOO_REVIEW_ACTION_PATH/prompts/angles/<angle>.md` in the bundled action repo.

## Model selection

OpenCode + OpenRouter can route per-subagent if the OpenCode runtime supports it. When spawning each angle / validator subagent, read its `tier:` frontmatter and resolve via the **Model Tiers** table in `_header.md`:

- `fast` → `openrouter/deepseek/deepseek-v4-flash`
- `standard` → `openrouter/deepseek/deepseek-v4-pro`
- `deep` → `openrouter/deepseek/deepseek-v4-pro` with `reasoning_effort: xhigh` (use `high` for a lower-cost reasoning pass)

OpenRouter exposes only two DeepSeek slugs — reasoning is a `reasoning_effort` parameter on the same `v4-pro` slug, not a separate model ID. DeepSeek V4 supersedes R1 — do not route to `deepseek-r1`. If the OpenCode build cannot route per-subagent or cannot pass `reasoning_effort`, fall back to a single model for the whole job and pin it to `openrouter/deepseek/deepseek-v4-pro`. `inputs.model` (action.yml) always overrides tier resolution.

**Per-repo override:** before applying any tier slug above, check `/tmp/pr-review/config.json` for `models.<tier>` and use that slug instead when present (`jq -r '.models.fast // empty' /tmp/pr-review/config.json`, etc.). Precedence: `inputs.model` > `models.<tier>` > table default.

---

## IMPORTANT: MODE-BASED EXECUTION

Check the `Execution mode` in the Review Context above.

### MODE: review
You are running as a parallel worker for a specific angle.
- The `Target angle` in Review Context is the only angle you must audit.
- Do NOT post inline comments.
- Do NOT update the PR body or title.
- Do NOT manage labels.
- Run ONLY Phase 2 below for your target angle.
- Write findings to `/tmp/pr-review/findings.<angle>.json` and then EXIT.

### MODE: validate
You are running as the final aggregator.
- Read all `/tmp/pr-review/findings.<angle>.json` files from the disk.
- Perform Phase 3 (Self-Validation) below.
- Perform Phase 4 (Submit Native PR Review) below.
- Do NOT modify the PR title, PR description, or PR labels.
- Exit.

### MODE: full (or detect)
Perform all phases (1 through 4) sequentially.

---

## Phase 1 — Read artifacts + draft summary

Read `/tmp/pr-review/diff.txt`, `/tmp/pr-review/meta.json`, `/tmp/pr-review/angles.txt`. Draft a 1–2 sentence summary, change bullets, files-by-category, optional manual test plan — all destined for the **Review body** in Phase 4. Do NOT call `gh pr edit`; the PR title and description must remain untouched.

## Phase 2 — Per-Angle Audit

For each angle listed in `/tmp/pr-review/angles.txt`:

- If the OpenCode runtime supports parallel subagents, spawn one subagent per angle in parallel.
- Otherwise run them sequentially in the order listed.

Each angle agent:

1. Loads `$WOO_REVIEW_ACTION_PATH/prompts/angles/<angle>.md`.
2. Executes the angle prompt. For `react` run `npx -y react-doctor@$REACT_DOCTOR_VERSION --diff $BASE_REF --offline`.
3. Writes findings to `/tmp/pr-review/findings.<angle>.json` (JSON array per the schema in `_header.md`).

Stay within each angle's scope; do not let one angle flag issues that belong to another.

## Phase 3 — Adversarial Validation (prosecutor + defender, sequential)

Merge all `findings.<angle>.json` into `/tmp/pr-review/raw_findings.json` via `$WOO_REVIEW_ACTION_PATH/scripts/merge-findings.sh`. Validation does NOT parallelize; it runs the two opposing-bias passes in sequence, followed by a deterministic intersection (issue #13). Read `disable_adversarial` first:

```bash
DISABLE_ADV="$(jq -r '.disable_adversarial // false' /tmp/pr-review/config.json 2>/dev/null || echo false)"
```

### Phase 3a — Prosecutor pass (skip if `DISABLE_ADV == true`)

If the OpenCode runtime supports per-call routing, spawn a `deep`-tier subagent with `$WOO_REVIEW_ACTION_PATH/prompts/validator-prosecutor.md`; otherwise apply the same prompt within the main loop. Bias: assume each finding is real; drop only the demonstrably wrong. Write surviving findings to `/tmp/pr-review/findings.prosecutor.json`.

### Phase 3b — Defender pass

Spawn another `deep`-tier subagent (or continue the main loop) with `$WOO_REVIEW_ACTION_PATH/prompts/validator.md`. Bias: defense attorney — drop pedantic / lint-catchable / "maybe" findings, enforce comment-shape + `fix_type` rules. Write surviving findings to `/tmp/pr-review/findings.defender.json`.

### Phase 3c — Intersect

```bash
bash "$WOO_REVIEW_ACTION_PATH/scripts/intersect-findings.sh"
```

Produces `/tmp/pr-review/findings.json` (intersection by `(file, line, title-stem)`; severity = min, blocking = AND). When adversarial is disabled or the prosecutor file is absent, copies defender output verbatim. Disagreement counts in `/tmp/pr-review/validator-metrics.json`.

## Phase 4 — Submit Native PR Review

Compute counts. Build `STATUS_LINE`. Follow `_header.md` exactly: submit one batched `gh api repos/<repo>/pulls/<PR>/reviews` POST whose `body` carries the summary + `STATUS_LINE` and whose `comments[]` carries every finding as an inline comment. The review `event` is computed by the `_header.md` payload-builder (do not duplicate the logic here): `REQUEST_CHANGES` when any new finding is `blocking: true` OR when `/tmp/pr-review/prior-findings.json` is non-empty (unresolved review threads keep the PR at minimum `REQUEST_CHANGES`), `COMMENT` when there are only non-blocking new findings and no unresolved priors, `APPROVE` only when both new findings and prior unresolved threads are empty.

Do NOT call `gh pr edit`. Do NOT add, remove, or mutate PR labels. The PR title, PR description, and PR labels stay untouched.

## Rules

- Execute autonomously — never request user confirmation.
- Trust prefetched artifacts.
- `findings.json` is the single source of truth for posting.
- Parallel subagents in Phase 2 must complete before Phase 3.
