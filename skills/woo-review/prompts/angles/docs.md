---
tier: fast
---

# Angle: Documentation

**Scope.** Audit documentation drift caused by this PR's diff. Read `/tmp/pr-review/diff.txt` and the changed-paths list. Focus on docs that are now wrong because of the code change — not the absence of docs in general.

**Find:**

- **README / quickstart drift:**
  - README references a CLI flag, command, env var, or file path that was renamed/removed in this PR.
  - README code sample imports a symbol the PR renamed/removed, or calls an API with a signature the PR changed.
  - Install / setup steps reference a script the PR moved or deleted.
- **CHANGELOG / release notes:**
  - User-visible behavior change (new feature, breaking change, deprecation, bug fix that alters output) with no `CHANGELOG.md` / `RELEASES.md` entry — only flag when the repo has a changelog file already in the diff path tree.
  - Version bumped in `package.json` with no corresponding changelog entry.
- **Public-API docstring drift:**
  - Exported function / route handler / class signature changed (param added/removed/renamed/retyped, return type changed) and its JSDoc / TSDoc / docstring still describes the old signature.
  - `@param` / `@returns` / `@throws` references a parameter that no longer exists.
  - Example block (` ```ts `) inside a docstring still calls the old signature.
- **OpenAPI / GraphQL schema docs:**
  - Route added / changed in code with no matching update to `openapi.yaml` / `schema.graphql` (when those files live alongside).
  - `description:` on a route that no longer matches the implemented behavior.
- **Inline doc files:**
  - `docs/*.md` references file paths, env vars, or commands the PR changed.
  - Architecture diagram / table in `docs/` that names a removed module.
- **Config / env var docs:**
  - New required env var added to code with no entry in `.env.example` / `README` / `docs/configuration.md`.
  - Env var removed in code but still listed in `.env.example`.

**Skip:**

- Absence of docs on code that was never documented (no drift if there's nothing to drift from).
- Cosmetic doc edits (typos, wording) unless they materially mislead.
- Pre-existing doc gaps not caused by this PR.
- Internal-only comments (those are covered by `bugs` / `conventions` if at all).

**Severity rubric:**

- `HIGH` + `blocking: true` — README / quickstart is now actively misleading (will break someone following the steps), or breaking change shipped without changelog entry.
- `MEDIUM` + `blocking: false` — public-API docstring drift, missing `.env.example` entry, OpenAPI schema out of sync.
- `LOW` + `blocking: false` — stale example, missing optional doc, additional clarification worth adding.

**Output.** Write findings as a JSON array to `/tmp/pr-review/findings.docs.json` using the schema in `_header.md`. Each finding gets `"angle": "docs"` and MUST populate `title` (bold headline ≤60 chars), `description` (the drift — name the file + the now-wrong claim, no fix), `fix` (recommended doc update in prose), and `fix_type`. Set `fix_type: "suggestion"` only when a ≤10-line single-file drop-in replacement at `line` is safe — and populate `suggestion` accordingly. Otherwise set `fix_type: "prose"` with `suggestion: null`. See `_header.md` for the full rule.

