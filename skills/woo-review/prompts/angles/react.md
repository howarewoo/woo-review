---
tier: standard
---

# Angle: React

**Scope.** Find React-specific defects introduced by this PR. Combine deterministic linting (React Doctor) with LLM review.

## Step 1 — Run React Doctor

Run the [millionco/react-doctor](https://github.com/millionco/react-doctor) linter via npx:

```bash
REACT_DOCTOR_VERSION="${REACT_DOCTOR_VERSION:-latest}"
BASE_REF="$(jq -r '.baseRefName // "main"' /tmp/pr-review/meta.json 2>/dev/null || echo main)"

npx -y "react-doctor@${REACT_DOCTOR_VERSION}" \
  --directory . \
  --diff "$BASE_REF" \
  --offline \
  --fail-on none \
  > /tmp/pr-review/react-doctor.txt 2>/tmp/pr-review/react-doctor.err || true
```

Parse `/tmp/pr-review/react-doctor.txt`. Each diagnostic includes a rule id, file, line, and severity. Surface every diagnostic on a changed file as a finding. Rule severity from react-doctor (`error` vs `warning`) maps to our severity:

- react-doctor `error` → `HIGH` + `blocking: true`.
- react-doctor `warning` → `MEDIUM` + `blocking: false`.

If the binary is unavailable in the sandbox, log the error and skip Step 1 — Step 2 still runs.

## Step 2 — LLM review (rules-of-hooks + diff-bound)

Read `/tmp/pr-review/diff.txt`. Find React mistakes that react-doctor doesn't catch:

- **Rules of Hooks**: hooks called conditionally, in loops, after early returns, in event handlers.
- **Effect bugs**: missing deps (when not deliberately omitted); cleanup leaks (timer / subscription / listener not torn down); effect that should be derived state.
- **Re-render traps**: inline objects / arrays / functions passed as props to memoized children; identity-unstable dependencies in `useMemo` / `useCallback`; missing `key` or `key={index}` on lists with reorder potential.
- **State bugs**: setState during render; `setState((prev) => ...)` omitted where current state matters; multiple setState calls that should be batched / consolidated.
- **Suspense / async**: blocking transitions where `useTransition` belongs; missing error boundaries for new async UI.
- **Accessibility**: missing labels on form controls, missing roles on custom interactive elements (overlap with design angle is OK — both can flag).
- **Server / Client component boundary mistakes** (Next.js App Router): client-only API in a server component; missing `"use client"`; serialization across the boundary.

## Skip

- TS / ESLint-catchable rules.
- Generic React opinions without a defect.
- Pre-existing patterns not touched by this PR.

## Severity rubric

- `HIGH` + `blocking: true` — Rules of Hooks violation, infinite render loop, broken Server / Client boundary.
- `MEDIUM` + `blocking: false` — re-render trap, missing key, effect cleanup miss.
- `LOW` + `blocking: false` — accessibility polish, suggested memoization.

**Output.** Write findings as a JSON array to `/tmp/pr-review/findings.react.json` using the schema in `_header.md`. Each finding gets `"angle": "react"` and MUST populate `title` (bold headline ≤60 chars), `description` (the issue only — no fix), `fix` (recommended change in prose), and `fix_type`. Set `fix_type: "suggestion"` only when a ≤10-line single-file drop-in replacement at `line` is safe — and populate `suggestion` accordingly. Otherwise set `fix_type: "prose"` with `suggestion: null`. See `_header.md` for the full rule.

