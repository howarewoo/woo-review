# Anthropic (Claude Code) — Subagent Orchestration

You are reviewing a pull request using Claude Code's `Task` tool for parallel subagent dispatch. Every tool call must serve a clear purpose — no exploratory calls. Create a todo list before starting.

## Step 1: Context + Title + Summary (single Haiku subagent)

Launch one Haiku subagent. Pass it the artifact paths (it reads them from disk). Task:
- Read `/tmp/pr-review/diff.txt` and `/tmp/pr-review/meta.json`.
- Generate a Conventional Commit title (`type(scope): description`; types: `feat, fix, chore, docs, refactor, test, ci, perf, style, build`).
- Update title: `gh pr edit "$PR_NUMBER" --title "<title>"`.
- Produce a PR summary (1–2 sentences), a bullet list of changes, and files grouped by category.
- If the diff includes functional changes (business logic, UI, API, data mutations), produce a short manual test plan as a Markdown checklist. Skip if purely config/docs/types.
- Return: title, summary, bullets, files-by-category, test plan (if any).

## Step 2: Parallel Review (2 Sonnet subagents in parallel)

Launch two subagents in the same response. Each reads `/tmp/pr-review/diff.txt` and `/tmp/pr-review/rules.md` from disk. Pass the Step 1 summary to each.

**Subagent 2a — Constitution + bug detection**
- Audit diff against `rules.md`. Apply CLAUDE.md rules only when the CLAUDE.md path is in the same dir or a parent dir of the changed file.
- Scan diff for obvious bugs: syntax errors, type errors, missing imports, unresolved references, clear logic errors that produce wrong results regardless of inputs.
- Surface non-blocking suggestions worth posting (style/quality, missing tests on new business logic). Skip lint-catchable items.
- Focus only on the diff — do not read files outside it.
- Return: list of issues — each with `file`, `line`, `severity` (HIGH|MEDIUM|LOW), `blocking` (true|false), `description`, and for rule violations the exact quoted rule text.

**Subagent 2b — Security + logic errors**
- Scan diff for security vulnerabilities and incorrect logic introduced by this PR.
- Surface non-blocking suggestions (defensive coding, edge cases, performance smells). Skip pre-existing issues.
- Focus only on the diff.
- Return: list of issues with the same shape as 2a.

(See `_header.md` for blocking-criteria + do-NOT-flag list — apply verbatim.)

## Step 3: Validation (Sonnet, only if any issues found)

Skip if Steps 2a + 2b returned zero issues; status is `APPROVED`.

Otherwise launch one Sonnet subagent with the diff + all issues. For each issue:
1. **Verdict**: YES (confirmed) or NO (false positive) with brief reasoning. Only YES issues survive.
2. **Blocking confirmation**: For YES issues, confirm or override the auditor's `blocking` flag. May downgrade `true → false`. May NOT upgrade `false → true`.
3. Return filtered list with final `severity` and final `blocking` per issue.

## Step 4: Write findings.json

After validation, write the surviving findings to `/tmp/pr-review/findings.json` using the schema from `_header.md`.

## Step 5: Post Inline Comments + Update PR Body + Manage Label

Follow the procedures in `_header.md` exactly. Compute `BLOCKING_COUNT`, `NONBLOCKING_COUNT`, `HIGH_COUNT`, `MEDIUM_COUNT`, `LOW_COUNT` from the validated findings. Build `STATUS_LINE` in bash and inject via unquoted heredoc.

## Rules

- Execute all steps autonomously — no confirmation prompts.
- Trust prefetched artifacts. Do NOT re-run `gh pr diff` or re-read constitution/CLAUDE.md files.
- Parallel subagents in Step 2 must complete before Step 3.
- Every tool call serves a clear purpose.
