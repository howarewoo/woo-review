# OpenRouter (OpenCode) — Agentic Loop Review

OpenCode runs an agentic shell. Use its subagent system if available (`@subagent`-style spawning); otherwise fall back to the sequential structure shown below. The output contract is identical to the other providers.

## Phase 1 — Read artifacts + draft summary

Read `/tmp/pr-review/diff.txt`, `/tmp/pr-review/meta.json`, `/tmp/pr-review/rules.md`. Generate a Conventional Commit title and update via `gh pr edit "$PR_NUMBER" --title "<title>"`. Draft 1–2 sentence summary, change bullets, files-by-category, optional manual test plan.

## Phase 2 — Audit (constitution + bugs, security + logic)

Run two audit lenses, in parallel via subagents if the runtime supports it, otherwise sequentially:

**Lens A — Constitution + bugs**
- Audit diff against `rules.md`. CLAUDE.md rules apply only at-or-above the changed file's dir.
- Find obvious bugs: syntax/type errors, missing imports, unresolved references, clearly-wrong logic.
- Defensible non-blocking suggestions. Skip lint-catchable.

**Lens B — Security + logic**
- Security vulnerabilities introduced by this PR.
- Incorrect logic shipping wrong results.
- Non-blocking: defensive coding, edge cases, performance smells.
- Skip pre-existing issues.

(See `_header.md` for blocking-criteria + do-NOT-flag list.)

## Phase 3 — Self-Validation

Merge findings from both lenses. For each finding:
1. Real, in-diff, this-PR-introduced? If NO → drop.
2. If YES, confirm or downgrade `blocking`. Never upgrade.

Persist to `/tmp/pr-review/findings.json` per `_header.md` schema.

## Phase 4 — Post Inline Comments

Loop over `findings.json`. Follow the inline-comment-posting procedure in `_header.md` exactly.

## Phase 5 — Update PR Body + Manage Label

Compute counts. Build `STATUS_LINE`. Update PR body. Add/remove `blocking-review` label per `_header.md`.

## Rules

- Execute autonomously — never request user confirmation.
- Trust prefetched artifacts.
- `findings.json` is the single source of truth for posting.
- If parallel subagents are available, use them for Phase 2; do not parallelize Phase 3 (validation is sequential).
