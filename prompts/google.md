# Google (Gemini CLI) — Tool-Loop Multi-Angle Review

The Gemini CLI runs an agentic tool loop with access to `bash` and `gh`. Use the same structured-pass approach as Codex; Gemini has no native subagent primitive.

The shared header above lists prefetched artifacts, findings schema, blocking criteria, and the do-NOT-flag list. **Apply them verbatim.** Per-angle prompt bodies live at `$WOO_REVIEW_ACTION_PATH/prompts/angles/<angle>.md` in the bundled action repo.

## Phase 1 — Read artifacts + draft summary

Read `/tmp/pr-review/diff.txt`, `/tmp/pr-review/meta.json`, `/tmp/pr-review/rules.md`, `/tmp/pr-review/angles.txt`. Generate a Conventional Commit title; update via `gh pr edit "$PR_NUMBER" --title "<title>"`. Draft 1–2 sentence summary, change bullets, files-by-category, optional manual test plan.

## Phase 2 — Per-Angle Audit (sequential loop)

For each angle listed in `/tmp/pr-review/angles.txt`, in order:

1. Read `$WOO_REVIEW_ACTION_PATH/prompts/angles/<angle>.md`.
2. Execute the angle prompt. For `design` run `npx -y impeccable@$IMPECCABLE_VERSION detect --json`. For `react` run `npx -y react-doctor@$REACT_DOCTOR_VERSION --diff $BASE_REF --offline`.
3. Write findings to `/tmp/pr-review/findings.<angle>.json` (JSON array conforming to `_header.md` schema).

Stay within each angle's scope.

## Phase 3 — Self-Validation

Merge all `findings.<angle>.json`. For each finding:

1. Real, in-diff, this-PR-introduced? If NO → drop.
2. Confirm or downgrade `blocking`. Never upgrade.
3. Dedupe across angles.

Persist to `/tmp/pr-review/findings.json` per `_header.md` schema.

## Phase 4 — Post Inline Comments

For each finding in `findings.json`, follow `_header.md`'s inline-comment procedure. Use the `gh` tool the Gemini runtime provides.

## Phase 5 — Update PR Body + Manage Label

Compute counts. Build `STATUS_LINE`. Update PR body. Add or remove `blocking-review` label per `_header.md`.

## Rules

- Execute autonomously — never request user confirmation.
- Use only the `gh` CLI for GitHub access.
- Trust prefetched artifacts.
- `findings.json` is the single source of truth for posting.
