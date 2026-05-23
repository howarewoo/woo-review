# OpenAI (Codex) — Sequential Multi-Lens Review

Codex Action does not expose a `Task` subagent primitive. Run the review as a single agentic loop with explicit phases. Use `bash` + `gh` tooling for all GitHub interactions.

## Phase 1 — Read artifacts + draft summary

- Read `/tmp/pr-review/diff.txt`, `/tmp/pr-review/meta.json`, `/tmp/pr-review/rules.md`.
- Generate a Conventional Commit title (`type(scope): description`; types: `feat, fix, chore, docs, refactor, test, ci, perf, style, build`).
- Update title: `gh pr edit "$PR_NUMBER" --title "<title>"`.
- Draft a 1–2 sentence summary, change bullets, and files-by-category.
- If diff has functional changes, draft a manual test plan checklist.

Hold the summary in working memory; do not post it yet.

## Phase 2 — Audit Pass A (constitution + bugs)

Scan the diff with this lens:
- Audit against `rules.md`. Apply CLAUDE.md rules only when the CLAUDE.md path is at-or-above the changed file's dir.
- Find obvious bugs: syntax/type errors, missing imports, unresolved references, clearly-wrong logic.
- Surface defensible non-blocking suggestions (style/quality, missing tests). Skip lint-catchable items.

Record findings in memory as `pass_a`.

## Phase 3 — Audit Pass B (security + logic)

Scan the diff with this lens:
- Security vulnerabilities introduced by this PR.
- Incorrect logic that ships wrong results.
- Non-blocking: defensive coding, edge cases, performance smells.
- Skip pre-existing issues.

Record findings as `pass_b`.

(See `_header.md` for blocking-criteria + do-NOT-flag list — apply verbatim.)

## Phase 4 — Self-Validation

Merge `pass_a + pass_b`. For each finding, re-read the relevant diff hunk and ask:
1. Is it real, in-diff, produced by this PR? If NO → drop it.
2. If YES, confirm or downgrade the `blocking` flag. NEVER upgrade `false → true`.

Persist the surviving findings to `/tmp/pr-review/findings.json` using the schema in `_header.md`.

## Phase 5 — Post Inline Comments

Loop over `/tmp/pr-review/findings.json`. For each finding, follow the inline-comment-posting procedure in `_header.md` (heredoc body file → Python JSON build → `gh api ... --input`).

## Phase 6 — Update PR Body + Manage Label

Compute `BLOCKING_COUNT`, `NONBLOCKING_COUNT`, `HIGH_COUNT`, `MEDIUM_COUNT`, `LOW_COUNT`. Build `STATUS_LINE` in bash. Update PR body per `_header.md`. Add or remove `blocking-review` label.

## Rules

- Execute every phase autonomously — never prompt for confirmation.
- Trust prefetched artifacts. Do NOT re-run `gh pr diff` or re-read rules files.
- Each phase is one logical unit; do not interleave audit phases with posting phases.
- `findings.json` is the single source of truth for Phases 5 + 6.
