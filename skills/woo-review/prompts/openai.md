# OpenAI (Codex) — Sequential Multi-Angle Review

Codex Action does not expose a subagent primitive. Run the review as a single agentic loop with explicit phases. Use `bash` + `gh` for all GitHub interactions.

The shared header above lists prefetched artifacts, findings schema, blocking criteria, and the do-NOT-flag list. **Apply them verbatim.** Per-angle prompt bodies live at `$WOO_REVIEW_ACTION_PATH/prompts/angles/<angle>.md` in the bundled action repo.

## Model selection

Codex Action runs one model for the full job (set via `inputs.model`, default `gpt-5`). Per-call routing is not possible, so the `tier:` frontmatter on each angle prompt is **informational only** under this provider. Default to the `standard`-tier model (`gpt-5`) — it covers every angle safely. GPT-5 reasoning is a `reasoning_effort` parameter (`minimal`/`low`/`medium`/`high`), not a slug suffix; there is no `gpt-5-pro`. Pass it via `inputs.openai_effort` on this action (wired through to codex-action's `effort` input, available since codex-action v1.1). To trade some quality on `bugs`/`security`/`design`/`react` for cost on `seo`/`aeo` runs, split the workflow into two jobs (e.g. one `gpt-5-mini` job for `seo`/`aeo`, then one `gpt-5` job with `openai_effort: high` for the remaining angles + validator). The newer `gpt-5.5` family is resolved by Codex CLI (the action installs the latest stable `@openai/codex` by default), so `inputs.model: gpt-5.5` should work today — verify with a preview run before relying on it.

**Per-repo override:** if `/tmp/pr-review/config.json` has `models.standard` set, treat it as the effective slug for this run (precedence: `inputs.model` > `models.standard` > default `gpt-5`). Read with `jq -r '.models.standard // empty' /tmp/pr-review/config.json`.

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

## Phase 2 — Per-Angle Audit (sequential loop)

For each angle listed in `/tmp/pr-review/angles.txt`, in order:

1. Read `$WOO_REVIEW_ACTION_PATH/prompts/angles/<angle>.md`.
2. Execute the angle prompt against the diff. For `react` run `npx -y react-doctor@$REACT_DOCTOR_VERSION --diff $BASE_REF --offline`.
3. Write the angle's findings to `/tmp/pr-review/findings.<angle>.json` (JSON array conforming to the schema in `_header.md`).

Stay within each angle's scope; do not let `bugs` flag a design issue or vice versa.

## Phase 3 — Adversarial Validation (prosecutor + defender, sequential)

Merge all `findings.<angle>.json` arrays into `/tmp/pr-review/raw_findings.json` (use `$WOO_REVIEW_ACTION_PATH/scripts/merge-findings.sh`).

Then run TWO opposing-bias validation passes followed by a deterministic intersection (issue #13). Codex Action has no subagent primitive, so this is sequenced inside the single agentic loop using `bash` to invoke the intersect script. Read `disable_adversarial` first:

```bash
DISABLE_ADV="$(jq -r '.disable_adversarial // false' /tmp/pr-review/config.json 2>/dev/null || echo false)"
```

### Phase 3a — Prosecutor pass (skip if `DISABLE_ADV == true`)

Apply `$WOO_REVIEW_ACTION_PATH/prompts/validator-prosecutor.md` against `raw_findings.json`. Bias: assume each finding is real; drop only the demonstrably wrong. Write surviving findings to `/tmp/pr-review/findings.prosecutor.json`.

### Phase 3b — Defender pass

Apply `$WOO_REVIEW_ACTION_PATH/prompts/validator.md` against `raw_findings.json`. Bias: try to prove each finding wrong; drop pedantic / lint-catchable / "maybe" findings; enforce the comment-shape + `fix_type` rules. Write surviving findings to `/tmp/pr-review/findings.defender.json`.

### Phase 3c — Intersect

```bash
bash "$WOO_REVIEW_ACTION_PATH/scripts/intersect-findings.sh"
```

This produces the final `/tmp/pr-review/findings.json` (intersection by `(file, line, title-stem)`; severity = min, blocking = AND). When `disable_adversarial == true` or the prosecutor file is absent, the script copies defender output verbatim. Per-pass and disagreement counts land in `/tmp/pr-review/validator-metrics.json`.

## Phase 4 — Submit Native PR Review

Compute `BLOCKING_COUNT`, `NONBLOCKING_COUNT`, `HIGH_COUNT`, `MEDIUM_COUNT`, `LOW_COUNT`. Build `STATUS_LINE`. Follow `_header.md` exactly: submit one batched `gh api repos/<repo>/pulls/<PR>/reviews` POST whose `body` carries the summary + `STATUS_LINE` and whose `comments[]` carries every finding as an inline comment. The review `event` is computed by the `_header.md` payload-builder (do not duplicate the logic here): `REQUEST_CHANGES` when any new finding is `blocking: true` OR when `/tmp/pr-review/prior-findings.json` is non-empty (unresolved review threads keep the PR at minimum `REQUEST_CHANGES`), `COMMENT` when there are only non-blocking new findings and no unresolved priors, `APPROVE` only when both new findings and prior unresolved threads are empty.

Do NOT call `gh pr edit`. Do NOT add, remove, or mutate PR labels. The PR title, PR description, and PR labels stay untouched.

## Rules

- Execute every phase autonomously — never request confirmation.
- Trust prefetched artifacts.
- Do not interleave audit phases with posting phases.
- `findings.json` is the single source of truth for Phase 4.
