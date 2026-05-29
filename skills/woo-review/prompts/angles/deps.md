---
tier: fast
---

# Angle: Dependencies

**Scope.** Audit dependency / supply-chain changes introduced by this PR's diff. Read `/tmp/pr-review/diff.txt`. Covers `package.json` / `package-lock.json` / `pnpm-lock.yaml` / `yarn.lock` / `bun.lockb`, `requirements.txt` / `pyproject.toml` / `poetry.lock` / `uv.lock`, `go.mod` / `go.sum`, `Cargo.toml` / `Cargo.lock`, `Gemfile` / `Gemfile.lock`, `composer.json` / `composer.lock`. Coordinate with `security` (don't double-flag the same CVE) and `infra` (don't double-flag Dockerfile FROM pins).

**Find:**

- **Manifest / lockfile drift:**
  - Dependency added/removed in `package.json` with no matching change in the lockfile (or vice-versa).
  - Lockfile bumped without a manifest change AND with no `npm audit` / `npm outdated` motivation — surface as a low-severity sanity check, not a block.
- **Range-pin hygiene:**
  - New dep added with an unbounded range (`*`, `latest`, `>=x`) or with a caret on a `0.x` package (caret is meaningless before 1.0).
  - Downgrade of a transitive dep below a previously pinned floor.
- **Supply-chain red flags:**
  - New dep from a non-public / non-standard registry (URL string under `dependencies`, `git+https://` source, tarball URL).
  - New dep with a `postinstall` / `preinstall` script (look in the lockfile diff or call out for verification).
  - New dep that's a typosquat candidate of a popular package — flag for human eyes, do not assert.
  - Sudden new maintainer or scoped → unscoped rename (e.g. `@org/foo` → `foo`).
- **License drift:**
  - New dep with a non-permissive license (GPL family, AGPL, SSPL, custom) added to a project that's MIT/Apache today — only flag when license info is visible in the diff context or repo, do not guess.
- **Duplication / bloat:**
  - Same library added at two different major versions in the lockfile (e.g. `lodash@3` and `lodash@4` both present after this PR).
  - New dep duplicates functionality of an existing dep (e.g. adding `axios` when `fetch` / `ky` is already used throughout) — only when obvious from the diff.
- **Dev vs prod placement:**
  - Build-only / test-only tool added to `dependencies` instead of `devDependencies`.
- **Removal hygiene:**
  - Code still imports a package that was just removed from manifest → flag as a bug-adjacent (will fail install or runtime).

**Skip:**

- Patch bumps of widely-used libraries with no behavior change cited.
- Speculative CVE claims without a reference (defer to `security` angle and let it cite the OWASP rubric).
- Pre-existing dependency issues not touched by this PR.
- Style / ordering of `package.json` keys.
- **Claims that a specific version "doesn't exist" / "isn't published"** — do NOT assert this from training-cutoff memory. New versions ship constantly and the validator has repeatedly produced false positives on this. Only raise a "version doesn't exist" finding when you can verify it via a web search of the relevant registry (npm/PyPI/crates.io/pkg.go.dev/etc.) within this run; otherwise leave it alone.

**Severity rubric:**

- `HIGH` + `blocking: true` — concrete supply-chain risk (typosquat, postinstall from new untrusted source, license incompatible with the project's distribution), or code still imports a deleted dep.
- `MEDIUM` + `blocking: false` — manifest/lockfile drift, unbounded range, duplicate major versions of a load-bearing library.
- `LOW` + `blocking: false` — placement (dev vs prod), redundancy with an existing dep, sanity-check on a large unexplained lockfile diff.

**Output.** Write findings as a JSON array to `/tmp/pr-review/findings.deps.json` using the schema in `_header.md`. Each finding gets `"angle": "deps"` and MUST populate `title` (bold headline ≤60 chars), `description` (the drift / risk + concrete signal from the diff, no fix), `fix` (pin / remove / move / verify recommendation in prose), and `fix_type`. Set `fix_type: "suggestion"` only when a ≤10-line single-file drop-in replacement at `line` is safe — and populate `suggestion` accordingly. Otherwise set `fix_type: "prose"` with `suggestion: null`. See `_header.md` for the full rule.

