---
tier: standard
---

# Angle: API Contracts

**Scope.** Find breaking or risky changes to public interfaces introduced by this PR's diff. Read `/tmp/pr-review/diff.txt`. "Public" means anything callable from outside the module: HTTP routes, GraphQL schema, RPC handlers, gRPC `.proto`, OpenAPI/Swagger specs, exported library symbols, CLI flags, webhook payloads, SDK method signatures.

**Find:**

- **Breaking shape changes:** field renamed/removed/retyped on a response, request param renamed/removed, required field added to request, optional field made required, enum value removed, union narrowed.
- **Status-code drift:** route now returns a different status for the same input class (e.g. 200 → 204, 404 → 200), error envelope shape changed.
- **Method/verb changes:** `GET` → `POST` on an existing route, route path changed without redirect / dual-mount.
- **Authn/authz scope changes:** endpoint that previously required auth no longer does, or scope/role required has been narrowed/widened without versioning.
- **Pagination / sort / filter contract drift:** default page size changed, cursor shape changed, `limit` max lowered.
- **Deprecation hygiene:** new breaking change without a deprecation period, removed field with no `Sunset` / `Deprecation` header or changelog entry.
- **Versioning leaks:** changes applied to a versioned route (`/v1/...`) that should land in `/v2`.
- **Backwards-incompat exported-symbol changes** in published packages: removed export, signature change on a function in `index.ts` / package entrypoint.
- **GraphQL specifics:** non-null added to existing field, enum value removed, directive contract changed.
- **CLI specifics:** removed flag, flag short-name reuse, flag default changed.

**Skip:**

- Internal-only function signatures that aren't re-exported.
- Cosmetic JSDoc / OpenAPI description edits.
- Additions of new optional fields or new endpoints (additive — non-breaking).
- Pre-existing contract issues not touched by this PR.

**Severity rubric:**

- `HIGH` + `blocking: true` — concrete breaking change for existing callers with no migration path / deprecation window.
- `MEDIUM` + `blocking: false` — risky but salvageable (e.g. ambiguous semantic change, needs versioning or dual-write).
- `LOW` + `blocking: false` — missing docs/changelog/deprecation header for an otherwise valid change.

**Output.** Write findings as a JSON array to `/tmp/pr-review/findings.api.json` using the schema in `_header.md`. Each finding gets `"angle": "api"` and MUST populate `title` (bold headline ≤60 chars), `description` (the breakage + caller impact, no fix), `fix` (migration/versioning recommendation in prose), and `fix_type`. Set `fix_type: "suggestion"` only when a ≤10-line single-file drop-in replacement at `line` is safe — and populate `suggestion` accordingly. Otherwise set `fix_type: "prose"` with `suggestion: null`. See `_header.md` for the full rule.

