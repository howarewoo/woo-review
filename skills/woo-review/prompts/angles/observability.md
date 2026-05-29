---
tier: fast
---

# Angle: Observability

**Scope.** Audit logging, metrics, tracing, and error-handling changes introduced by this PR's diff. Read `/tmp/pr-review/diff.txt`. Focus on signal quality (will an oncall see what they need?) and signal hygiene (no PII / secret leakage, no log floods).

**Find:**

- **Sensitive data in logs:**
  - Logged request/response bodies that may contain PII (email, phone, address), payment data, auth tokens, session IDs.
  - `console.log(req.headers)` or equivalent dump of an `Authorization`, `Cookie`, or `X-Api-Key` header.
  - Stack traces re-thrown with the original input concatenated in the message.
- **Swallowed errors:**
  - `catch {}` with no log, no rethrow, no fallback (new in diff).
  - `.catch(() => null)` / `.catch(() => undefined)` on a non-trivial async call that silently hides failure.
  - Promise rejection ignored (`void asyncFn()` without `.catch`).
- **Log-level abuse:**
  - `error` used for expected control flow (e.g. validation rejections, 404s).
  - `info` / `log` inside a hot loop with no rate limit or sampling.
  - `debug` left in a path that runs in production (no env gating).
- **Missing signals on new paths:**
  - New endpoint / job / consumer with no log on entry, no log on failure, no metric / counter.
  - New retry loop with no log on retry-exhaustion.
  - New external call (HTTP / DB / queue) with no timing / span / error-rate signal.
- **Tracing hygiene:**
  - New async boundary without context propagation (lost `traceparent`, lost AsyncLocalStorage).
  - Span created without ending in error/finally → leaked span.
- **Cardinality risks:**
  - User ID, request ID, or unbounded user input used as a metric label / tag.

**Skip:**

- Style of log message strings (capitalization, period at end).
- Pre-existing logging gaps in code untouched by this PR.
- "Add a log here too" without a concrete oncall scenario where the absence would slow diagnosis.
- Logger library choice unless `/tmp/pr-review/rules.md` mandates one.

**Severity rubric:**

- `HIGH` + `blocking: true` — secret/PII leak into logs, error-swallowing on a path that should alert.
- `MEDIUM` + `blocking: false` — missing signal on a new external call, unbounded label cardinality, log flood risk.
- `LOW` + `blocking: false` — level adjustment, additional context field on an existing log.

**Output.** Write findings as a JSON array to `/tmp/pr-review/findings.observability.json` using the schema in `_header.md`. Each finding gets `"angle": "observability"` and MUST populate `title` (bold headline ≤60 chars), `description` (the gap or leak only — no fix), `fix` (recommended logging/metric/tracing change in prose), and `fix_type`. Set `fix_type: "suggestion"` only when a ≤10-line single-file drop-in replacement at `line` is safe — and populate `suggestion` accordingly. Otherwise set `fix_type: "prose"` with `suggestion: null`. See `_header.md` for the full rule.

