---
tier: standard
---

# Angle: Tests

**Scope.** Audit test quality and coverage for behavior introduced by this PR's diff. Read `/tmp/pr-review/diff.txt`. Consider both new test files and untested production changes.

**Find:**

- New business logic in production files with no accompanying test (HIGH if the function is exported or routed; MEDIUM if internal).
- Tests that assert implementation details instead of observable behavior (snapshot of internal state, mock-call counts as the sole assertion, asserting log strings).
- Tests that cannot fail: missing `expect`, only `console.log`, conditional skips, `expect(true).toBe(true)`, awaiting then discarding rejection without `rejects` matcher.
- Mocks that drift from real contract: stubbed return shapes that no longer match the production type, stubbed network/DB calls when an integration harness exists in the repo (cite `rules.md` if it mandates real-DB tests).
- Flaky patterns: time-based `setTimeout` in assertions, ordering reliance on `Object.keys`, `Math.random` / `Date.now()` without seeding, network calls without a fake.
- Missing edge cases on new branches: error paths, empty input, boundary values, auth-denied paths for new endpoints.
- Test isolation breaks: shared module-level state, missing cleanup of DB rows / temp files / spies between cases.

**Skip:**

- Style on test files (describe/it phrasing, file naming) unless `/tmp/pr-review/rules.md` mandates it.
- Coverage demands on trivial getters, type aliases, or pure re-exports.
- Pre-existing untested code not touched by this PR.
- Speculative "you should also test X" when the diff doesn't add X.

**Severity rubric:**

- `HIGH` + `blocking: true` — new public endpoint / exported function with no test at all, or a test that asserts nothing.
- `MEDIUM` + `blocking: false` — flaky pattern, drifting mock, missing critical edge case.
- `LOW` + `blocking: false` — additional case worth adding, isolation improvement.

**Output.** Write findings as a JSON array to `/tmp/pr-review/findings.tests.json` using the schema in `_header.md`. Each finding gets `"angle": "tests"` and MUST populate `title` (bold headline ≤60 chars), `description` (the gap or flaw only — no fix), `fix` (recommended test or change in prose), and `fix_type`. Set `fix_type: "suggestion"` only when a ≤10-line single-file drop-in replacement at `line` is safe — and populate `suggestion` accordingly. Otherwise set `fix_type: "prose"` with `suggestion: null`. See `_header.md` for the full rule.

