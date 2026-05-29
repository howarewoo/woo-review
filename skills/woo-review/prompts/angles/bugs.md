---
tier: standard
---

# Angle: Bugs

**Scope.** Find correctness defects introduced by this PR's diff. Read `/tmp/pr-review/diff.txt`. Focus only on changed lines and their immediate context.

**Find:**

- Syntax / parse errors that will fail compile.
- Type errors that will fail typecheck.
- Missing imports, unresolved references, undefined symbols.
- Clear logic errors that produce wrong results for ANY valid input (off-by-one, inverted condition, wrong operator, swapped arguments, dead branches, unreachable code).
- Resource leaks (unclosed files / handles / connections) introduced in the diff.
- Concurrency mistakes introduced in the diff (race, deadlock, non-atomic check-then-act).
- Missing tests on **new** business logic (non-blocking).

**Skip:**

- Anything lint-catchable (Biome / ESLint / Prettier / tsc warnings).
- Input-dependent maybe-issues with no concrete failure case.
- Pre-existing issues not introduced by this PR.
- Style / naming taste without rule backing (unless `/tmp/pr-review/rules.md` explicitly requires it — then cite the rule via `rule_quote`).

**Severity rubric:**

- `HIGH` + `blocking: true` — code will fail to compile or definitely produces wrong results.
- `MEDIUM` + `blocking: false` — likely-incorrect behavior under common conditions but not provable from diff alone.
- `LOW` + `blocking: false` — missing test, defensive coding improvement.

**Output.** Write findings as a JSON array to `/tmp/pr-review/findings.bugs.json` using the schema in `_header.md`. Each finding gets `"angle": "bugs"` and MUST populate `title` (bold headline ≤60 chars), `description` (the issue only — no fix), `fix` (recommended change in prose), and `fix_type`. Set `fix_type: "suggestion"` only when a ≤10-line single-file drop-in replacement at `line` is safe — and populate `suggestion` accordingly. Otherwise set `fix_type: "prose"` with `suggestion: null`. See `_header.md` for the full rule.

