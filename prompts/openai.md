# OpenAI (Codex) — Sequential Multi-Angle Review

Codex Action does not expose a subagent primitive. Run the review as a single agentic loop with explicit phases. Use `bash` + `gh` for all GitHub interactions.

The shared header above lists prefetched artifacts, findings schema, blocking criteria, and the do-NOT-flag list. **Apply them verbatim.** Per-angle prompt bodies live at `$WOO_REVIEW_ACTION_PATH/prompts/angles/<angle>.md` in the bundled action repo.

## Phase 1 — Read artifacts + draft summary

Read `/tmp/pr-review/diff.txt`, `/tmp/pr-review/meta.json`, `/tmp/pr-review/rules.md`, `/tmp/pr-review/angles.txt`. Generate a Conventional Commit title; update via `gh pr edit "$PR_NUMBER" --title "<title>"`. Draft 1–2 sentence summary, change bullets, files-by-category, optional manual test plan.

## Phase 2 — Per-Angle Audit (sequential loop)

For each angle listed in `/tmp/pr-review/angles.txt`, in order:

1. Read `$WOO_REVIEW_ACTION_PATH/prompts/angles/<angle>.md`.
2. Execute the angle prompt against the diff and rules. For `design` run `npx -y impeccable@$IMPECCABLE_VERSION detect --json`. For `react` run `npx -y react-doctor@$REACT_DOCTOR_VERSION --diff $BASE_REF --offline`.
3. Write the angle's findings to `/tmp/pr-review/findings.<angle>.json` (JSON array conforming to the schema in `_header.md`).

Stay within each angle's scope; do not let `bugs` flag a design issue or vice versa.

## Phase 3 — Self-Validation

Merge all `findings.<angle>.json` arrays. For each finding:

1. Real, in-diff, this-PR-introduced? If NO → drop.
2. Confirm or downgrade `blocking`. Never upgrade.
3. Dedupe across angles: if two angles flag identical `(file, line, description-equivalent)`, keep one (prefer the angle most-specific to the issue type).

Persist surviving findings to `/tmp/pr-review/findings.json` per the schema in `_header.md`.

## Phase 4 — Post Inline Comments

Loop over `findings.json`. Follow the inline-comment-posting procedure in `_header.md` exactly (heredoc → Python JSON → `gh api ... --input`).

## Phase 5 — Update PR Body + Manage Label

Compute `BLOCKING_COUNT`, `NONBLOCKING_COUNT`, `HIGH_COUNT`, `MEDIUM_COUNT`, `LOW_COUNT`. Build `STATUS_LINE`. Update PR body. Add or remove `blocking-review` label.

## Rules

- Execute every phase autonomously — never request confirmation.
- Trust prefetched artifacts.
- Do not interleave audit phases with posting phases.
- `findings.json` is the single source of truth for Phases 4 + 5.
