---
tier: standard
---

# Angle: Conventions

**Scope.** Find places where this PR's diff violates the project's own documented rules. The rules live at `/tmp/pr-review/rules.md` — a concatenation of `AGENTS.md`, `CLAUDE.md`, `.cursorrules`, `.windsurfrules`, and `GEMINI.md` discovered at the repo root and along the changed-file paths. Each section is prefixed by a `## SOURCE: <path>` header.

This angle runs **only** when `rules.md` exists. If it is absent, exit immediately with `[]` written to `/tmp/pr-review/findings.conventions.json`.

**Find:**

- Diff lines that contradict an explicit, quotable directive in `rules.md` (architecture boundaries, file-size limits, naming conventions, banned APIs, required patterns, monorepo package isolation, dependency restrictions, commit / branch conventions when the diff includes such artifacts).

**Skip:**

- Anything not covered by an explicit rule. This angle is not a generalist code-review pass — `bugs`, `security`, `design`, `react`, `database` already cover those.
- Pedantic prose-style nits inside doc files unless `rules.md` itself prescribes a doc-style rule.
- Pre-existing rule violations not introduced by this PR.

**Severity rubric:**

- `HIGH` + `blocking: true` — diff directly violates a MUST / required rule.
- `MEDIUM` + `blocking: false` — diff conflicts with a SHOULD / preferred rule.
- `LOW` + `blocking: false` — diff drifts from a documented convention without breaking it.

**Rule-quote requirement.** Every finding MUST populate `rule_quote` with a verbatim substring of `rules.md` (the actual rule text — not a paraphrase, not the `## SOURCE:` header). The validator will discard any finding whose `rule_quote` is absent or not literally present in `rules.md`.

**Output.** Write findings as a JSON array to `/tmp/pr-review/findings.conventions.json` using the schema in `_header.md`. Each finding gets `"angle": "conventions"` and MUST populate `title` (bold headline ≤60 chars), `description` (which rule is violated and where in the diff — no fix), `fix` (recommended change in prose), `rule_quote` (verbatim from `rules.md`), and `fix_type`. Set `fix_type: "suggestion"` only when a ≤10-line single-file drop-in replacement at `line` is safe — and populate `suggestion` accordingly. Otherwise set `fix_type: "prose"` with `suggestion: null`. See `_header.md` for the full rule.
