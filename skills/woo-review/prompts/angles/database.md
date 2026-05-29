---
tier: standard
---

# Angle: Database (Postgres / Supabase)

**Scope.** Find database correctness, performance, and security issues introduced by this PR's diff against Postgres / Supabase. Read `/tmp/pr-review/diff.txt`.

**Reference rubric.** Use Supabase's `supabase-postgres-best-practices` skill as the rule source.

- Registry: <https://www.skills.sh/supabase/agent-skills/supabase-postgres-best-practices>
- Source: <https://github.com/supabase/agent-skills/tree/main/skills/supabase-postgres-best-practices>
- Install (optional, host-dependent): `npx skills add https://github.com/supabase/agent-skills --skill supabase-postgres-best-practices`

Identify which rule families the diff touches, then load the matching reference files. If the skill is installed, read them from the installed `references/` directory. Otherwise fetch on demand:

```bash
gh api repos/supabase/agent-skills/contents/skills/supabase-postgres-best-practices/references/<file> --jq .content | base64 -d
```

Filename families (prefix-keyed in the source skill):

- `security-*` (RLS basics, RLS performance, privileges) — when diff contains `CREATE POLICY`, `ENABLE ROW LEVEL SECURITY`, `SECURITY DEFINER`, `auth.uid()`, or new tables in a Supabase project.
- `query-*` (missing indexes, partial / composite / covering indexes, index types) — when diff adds `SELECT` / `JOIN` / `WHERE` / `ORDER BY` against non-trivial tables.
- `schema-*` (primary keys, data types, FK indexes, constraints, partitioning, lowercase identifiers) — when diff adds `CREATE TABLE`, `ALTER TABLE`, or modifies columns.
- `conn-*` (pooling, limits, idle timeout, prepared statements) — when diff touches DB client construction or pool config.
- `lock-*` (deadlock prevention, short transactions, advisory locks, `SKIP LOCKED`) — when diff adds long-running transactions or queue-style consumers.
- `data-*` (N+1, batch inserts, pagination, upsert) — when diff adds ORM call sites.
- `monitor-*`, `advanced-*` — usually informational; cite only if directly relevant.

If a rule file does not exist, fall back to the general rubric below.

**Find (diff-bound):**

- **RLS:** new tables without `ENABLE ROW LEVEL SECURITY`; missing or over-permissive `CREATE POLICY` (e.g. `USING (true)`); `SECURITY DEFINER` functions without an explicit `SET search_path = ''`; policies that rely on `auth.uid()` against unindexed columns.
- **Indexing:** new foreign-key columns without a backing index; new filter / order columns without an index; redundant or duplicate indexes; missing partial index when query has a constant predicate.
- **Schema:** missing primary key on a new table; `text` where a stricter type fits (`uuid`, `timestamptz`, `bytea`, enum); `timestamp` without time zone; missing `NOT NULL` on FK columns; unguarded `NOT NULL` backfills on large tables; non-idempotent migrations (`CREATE TABLE` without `IF NOT EXISTS` for repeatable migrations).
- **Concurrency:** long transactions wrapping network or LLM calls; `LOCK TABLE` without timeout; queue patterns missing `FOR UPDATE SKIP LOCKED`.
- **Data access:** N+1 query patterns introduced by ORM call sites (loop-driven `findOne` / `select`); unbounded `SELECT` with no `LIMIT` / pagination; row-by-row inserts where a single `INSERT ... VALUES` (or `COPY`) fits.
- **Connection management:** new client code that bypasses the pooler; hardcoded statement timeouts that mask slow queries; missing `prepare: false` when targeting PgBouncer transaction-mode pooling.

**Skip:**

- Lint-catchable SQL style (uppercase keywords, trailing whitespace).
- Pre-existing schema issues not introduced by this PR.
- Theoretical perf concerns at low row counts (≤10k) with no growth signal.
- Suggestions that contradict an explicit, in-diff design choice (e.g. deliberate denormalization).
- Generic "could be slow" speculation without a named index, plan, or row-count signal.

**Severity rubric:**

- `HIGH` + `blocking: true` — RLS bypass with concrete unauthorized-access path; data-loss migration (drop / rename / truncate without backup); lock-out scenario with a realistic trigger; query that will definitely time out at expected scale.
- `MEDIUM` + `blocking: false` — missing FK index that will degrade under growth; non-idempotent migration; long transaction wrapping side effects.
- `LOW` + `blocking: false` — hardening suggestion (search_path, statement_timeout, prepared statements, query plan hint).

**Output.** Write findings as a JSON array to `/tmp/pr-review/findings.database.json` using the schema in `_header.md`. Each finding gets `"angle": "database"` and MUST populate `title` (bold headline ≤60 chars), `description` (issue + concrete impact path, no fix), `fix` (mitigation in prose), and `fix_type`. Set `fix_type: "suggestion"` only when a ≤10-line single-file drop-in SQL or code replacement at `line` is safe — and populate `suggestion` accordingly. Otherwise set `fix_type: "prose"` with `suggestion: null`. See `_header.md` for the full rule. When citing a Supabase rule, quote its filename (e.g. `security-rls-basics.md`) in `rule_quote`.

