# Google (Gemini CLI) — Tool-Loop Review

The Gemini CLI runs an agentic tool loop with access to `bash` and `gh`. Use the same structured-pass approach as Codex; Gemini has no native subagent primitive.

## Phase 1 — Read artifacts + draft summary

Read `/tmp/pr-review/diff.txt`, `/tmp/pr-review/meta.json`, `/tmp/pr-review/rules.md`. Generate Conventional Commit title, update via `gh pr edit "$PR_NUMBER" --title "<title>"`. Draft 1–2 sentence summary, change bullets, files-by-category, optional manual test plan.

## Phase 2 — Audit Pass A (constitution + bugs)

- Audit diff against `rules.md`. CLAUDE.md rules apply only at-or-above the changed file's dir.
- Find obvious bugs: syntax/type errors, missing imports, unresolved references, clearly-wrong logic.
- Surface defensible non-blocking suggestions. Skip lint-catchable.

Record as `pass_a` in memory.

## Phase 3 — Audit Pass B (security + logic)

- Security vulnerabilities introduced by this PR.
- Incorrect logic shipping wrong results.
- Non-blocking: defensive coding, edge cases, performance smells.
- Skip pre-existing issues.

Record as `pass_b`.

(See `_header.md` for blocking-criteria + do-NOT-flag list.)

## Phase 4 — Self-Validation

Merge `pass_a + pass_b`. For each finding, re-read the diff hunk and apply:
1. Real, in-diff, this-PR-introduced? If NO → drop.
2. If YES, confirm or downgrade `blocking`. Never upgrade.

Persist to `/tmp/pr-review/findings.json` per `_header.md` schema.

## Phase 5 — Post Inline Comments

For each finding in `findings.json`, follow the inline-comment-posting procedure in `_header.md`. Use `gh api ... --input /tmp/pr_comment.json`.

## Phase 6 — Update PR Body + Manage Label

Compute counts. Build `STATUS_LINE`. Update PR body. Add/remove `blocking-review` label per `_header.md`.

## Rules

- Execute autonomously — never request user confirmation.
- Use the `gh` CLI tool the runner provides; do not attempt other GitHub API approaches.
- Trust prefetched artifacts.
- `findings.json` is the single source of truth for posting.
