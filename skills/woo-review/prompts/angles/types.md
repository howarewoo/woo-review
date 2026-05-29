---
tier: fast
---

# Angle: Types

**Scope.** Audit TypeScript / type-system hygiene for code introduced by this PR's diff. Read `/tmp/pr-review/diff.txt`. Focus on type holes the compiler accepts but that defeat the purpose of static typing.

**Find:**

- **Escape hatches without justification:**
  - New `any` (explicit, or via untyped parameter, or via `: Function`).
  - `@ts-ignore` / `@ts-expect-error` with no comment explaining the hole.
  - `as` casts that widen or change the type without a runtime guard (`x as Foo`, `x as unknown as Foo`).
  - `!` non-null assertion in code paths where the value can legitimately be nullish.
- **Unsafe inference / boundary leaks:**
  - `JSON.parse(...)` result used directly without a schema/guard.
  - `Object.keys(x)` typed as `string[]` then indexed back into `x` without narrowing.
  - Public API surface (exported function, route handler, server action) accepting `unknown` and acting on it without validation.
  - `fetch().then(r => r.json())` result flowing into business logic untyped.
- **Generic / utility misuse:**
  - `Omit<T, 'k'>` / `Pick<T, 'k'>` on a key that doesn't exist on `T` (silent no-op).
  - `Partial<T>` used where a smaller, named subtype would be clearer and catch more.
  - Discriminated union flattened to a wide object → narrowing impossible.
  - `Record<string, unknown>` where the keys are known.
- **Nullability drift:**
  - Function return type changed from `T` to `T | undefined` (or vice-versa) and callers not updated.
  - Optional field added to a domain type used in DB writes / serialization without backfill consideration.
- **Enum / literal shape risks:**
  - String literal union expanded silently (added a member with no exhaustive `switch` update).
  - `enum` numeric default values relied on by serialization.
- **React-specific (only if the `react` angle is NOT enabled — otherwise defer):**
  - `props: any`, `useState<any>()`, event handler typed as `Function`.

**Skip:**

- Stylistic type vs interface, `readonly` vs not, naming.
- Type errors the compiler already flags (those are `bugs`).
- Generic-arity tweaks that don't change call-site safety.
- Pre-existing `any` in untouched code.

**Severity rubric:**

- `HIGH` + `blocking: true` — `unknown`/`any` flowing into a security-sensitive sink (DB write, command, auth check), or `as` cast that lies about runtime shape on a public API.
- `MEDIUM` + `blocking: false` — escape hatch without justification on internal code, unsafe boundary deserialization.
- `LOW` + `blocking: false` — tightening opportunity (narrower utility type, exhaustive switch hint).

**Output.** Write findings as a JSON array to `/tmp/pr-review/findings.types.json` using the schema in `_header.md`. Each finding gets `"angle": "types"` and MUST populate `title` (bold headline ≤60 chars), `description` (the type hole + how it leaks at runtime, no fix), `fix` (tightening recommendation in prose), and `fix_type`. Set `fix_type: "suggestion"` only when a ≤10-line single-file drop-in replacement at `line` is safe — and populate `suggestion` accordingly. Otherwise set `fix_type: "prose"` with `suggestion: null`. See `_header.md` for the full rule.

