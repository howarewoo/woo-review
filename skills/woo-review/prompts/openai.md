# OpenAI (Codex) — Sequential Multi-Angle Review

Codex Action does not expose a subagent primitive. Run the review as a single agentic loop with explicit phases. Use `bash` + `gh` for all GitHub interactions.

The shared header above lists prefetched artifacts, findings schema, blocking criteria, and the do-NOT-flag list. **Apply them verbatim.** Per-angle prompt bodies live at `$WOO_REVIEW_ACTION_PATH/prompts/angles/<angle>.md` in the bundled action repo.

## Model selection

Codex Action runs one model for the full job (set via `inputs.model`, default `gpt-5`). Per-call routing is not possible, so the `tier:` frontmatter on each angle prompt is **informational only** under this provider. Default to the `standard`-tier model (`gpt-5`) — it covers every angle safely. To trade some quality on `bugs`/`security`/`design`/`react` for cost on `seo`/`aeo` runs, you can split the workflow into two jobs (e.g. one `gpt-5-mini` job that only runs `seo`/`aeo`, then one `gpt-5` job for the remaining angles + validator), but the default single-job flow stays on `standard`.

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

Read `/tmp/pr-review/diff.txt`, `/tmp/pr-review/meta.json`, `/tmp/pr-review/rules.md`, `/tmp/pr-review/angles.txt`. Draft a 1–2 sentence summary, change bullets, files-by-category, optional manual test plan — all destined for the **Review body** in Phase 4. Do NOT call `gh pr edit`; the PR title and description must remain untouched.

## Phase 2 — Per-Angle Audit (sequential loop)

For each angle listed in `/tmp/pr-review/angles.txt`, in order:

1. Read `$WOO_REVIEW_ACTION_PATH/prompts/angles/<angle>.md`.
2. Execute the angle prompt against the diff and rules. For `react` run `npx -y react-doctor@$REACT_DOCTOR_VERSION --diff $BASE_REF --offline`.
3. Write the angle's findings to `/tmp/pr-review/findings.<angle>.json` (JSON array conforming to the schema in `_header.md`).

Stay within each angle's scope; do not let `bugs` flag a design issue or vice versa.

## Phase 3 — Self-Validation

Merge all `findings.<angle>.json` arrays. For each finding:

1. Real, in-diff, this-PR-introduced? If NO → drop.
2. Confirm or downgrade `blocking`. Never upgrade.
3. Dedupe across angles: if two angles flag identical `(file, line, description-equivalent)`, keep one (prefer the angle most-specific to the issue type).

Persist surviving findings to `/tmp/pr-review/findings.json` per the schema in `_header.md`.

## Phase 4 — Submit Native PR Review

Compute `BLOCKING_COUNT`, `NONBLOCKING_COUNT`, `HIGH_COUNT`, `MEDIUM_COUNT`, `LOW_COUNT`. Build `STATUS_LINE`. Follow `_header.md` exactly: submit one batched `gh api repos/<repo>/pulls/<PR>/reviews` POST whose `body` carries the summary + `STATUS_LINE` and whose `comments[]` carries every finding as an inline comment. The review `event` is the native blocking gate: `REQUEST_CHANGES` when any finding is `blocking: true`, `COMMENT` when only non-blocking findings exist, `APPROVE` when none.

Do NOT call `gh pr edit`. Do NOT add, remove, or mutate PR labels. The PR title, PR description, and PR labels stay untouched.

## Rules

- Execute every phase autonomously — never request confirmation.
- Trust prefetched artifacts.
- Do not interleave audit phases with posting phases.
- `findings.json` is the single source of truth for Phase 4.
