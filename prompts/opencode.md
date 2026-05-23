# OpenRouter (OpenCode) — Multi-Angle Agentic Review

OpenCode runs an agentic shell. Use its subagent system if available (`@subagent`-style spawning); otherwise fall back to the sequential structure shown below. The output contract is identical to the other providers.

The shared header above lists prefetched artifacts, findings schema, blocking criteria, and the do-NOT-flag list. **Apply them verbatim.** Per-angle prompt bodies live at `$WOO_REVIEW_ACTION_PATH/prompts/angles/<angle>.md` in the bundled action repo.

## Phase 1 — Read artifacts + draft summary

Read `/tmp/pr-review/diff.txt`, `/tmp/pr-review/meta.json`, `/tmp/pr-review/rules.md`, `/tmp/pr-review/angles.txt`. Generate a Conventional Commit title; update via `gh pr edit "$PR_NUMBER" --title "<title>"`. Draft 1–2 sentence summary, change bullets, files-by-category, optional manual test plan.

## Phase 2 — Per-Angle Audit

For each angle listed in `/tmp/pr-review/angles.txt`:

- If the OpenCode runtime supports parallel subagents, spawn one subagent per angle in parallel.
- Otherwise run them sequentially in the order listed.

Each angle agent:

1. Loads `$WOO_REVIEW_ACTION_PATH/prompts/angles/<angle>.md`.
2. Executes the angle prompt. For `design` run `npx -y impeccable@$IMPECCABLE_VERSION detect --json`. For `react` run `npx -y react-doctor@$REACT_DOCTOR_VERSION --diff $BASE_REF --offline`.
3. Writes findings to `/tmp/pr-review/findings.<angle>.json` (JSON array per the schema in `_header.md`).

Stay within each angle's scope; do not let one angle flag issues that belong to another.

## Phase 3 — Self-Validation

Sequential (do not parallelize validation). Merge all `findings.<angle>.json`. For each finding:

1. Real, in-diff, this-PR-introduced? If NO → drop.
2. Confirm or downgrade `blocking`. Never upgrade.
3. Dedupe across angles.

Persist to `/tmp/pr-review/findings.json` per `_header.md`.

## Phase 4 — Post Inline Comments

For each finding in `findings.json`, follow `_header.md`'s inline-comment-posting procedure exactly.

## Phase 5 — Update PR Body + Manage Label

Compute counts. Build `STATUS_LINE`. Update PR body. Add or remove `blocking-review` label per `_header.md`.

## Rules

- Execute autonomously — never request user confirmation.
- Trust prefetched artifacts.
- `findings.json` is the single source of truth for posting.
- Parallel subagents in Phase 2 must complete before Phase 3.
