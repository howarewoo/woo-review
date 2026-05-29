---
tier: standard
---

# Angle: Security

**Scope.** Find security vulnerabilities introduced by this PR's diff. Read `/tmp/pr-review/diff.txt`.

**Reference rubric.** Use OpenAI's `security-best-practices` skill as the language/framework-specific rubric.

- Registry: <https://www.skills.sh/openai/skills/security-best-practices>
- Source: <https://github.com/openai/skills/tree/main/skills/.curated/security-best-practices>
- Install (optional, host-dependent): `npx skills add https://github.com/openai/skills --skill security-best-practices`

Before scanning, identify the languages/frameworks touched by the diff (frontend + backend), then load the matching reference files. If the skill is installed, read them from the installed `references/` directory. Otherwise fetch on demand:

```bash
gh api repos/openai/skills/contents/skills/.curated/security-best-practices/references/<file> --jq .content | base64 -d
```

Filename pattern: `<language>-<framework>-<stack>-security.md`, with `<language>-general-<stack>-security.md` as the framework-agnostic fallback. Available today: `python` (django, fastapi, flask), `javascript`/`typescript` (express, nextjs, react, vue, jquery, general frontend), `go` (general backend). If no matching reference exists, fall back to the OWASP list below plus the general advice in that skill's `SKILL.md` (avoid incrementing public IDs, do not flag missing TLS in dev, no HSTS recommendations).

**Find (OWASP-shaped, diff-bound):**

- Injection: SQL, command, LDAP, XPath, template, prompt injection at trust boundaries.
- XSS (reflected / stored / DOM-based) introduced by new sinks or new untrusted sources.
- Authn / authz bypass: missing authorization check on a new endpoint, route, server action, or query; broken access control on resource ownership.
- Secrets handling: hardcoded keys / tokens, logged credentials, secrets in URLs, missing `--no-log` for sensitive flags.
- Cryptographic mistakes: weak algorithms, non-random nonces, missing IV, hand-rolled crypto, `Math.random` for security.
- SSRF: new fetch / request to user-controlled URL without allowlist.
- Path traversal: new file-system access with user-controlled path segment.
- Deserialization of untrusted input.
- CSRF on state-changing endpoints lacking same-site / token defenses.
- Open redirect.
- Sensitive-data exposure in responses, logs, error messages, or telemetry.

**Skip:**

- Generic "could this ever be a problem" speculation without a concrete exploit path.
- Pre-existing issues not introduced by this PR.
- Defense-in-depth nice-to-haves without concrete exploit path (unless `/tmp/pr-review/rules.md` explicitly mandates it — then cite the rule via `rule_quote`).
- Theoretical timing attacks unless the diff actually adds a verifying compare.

**Severity rubric:**

- `HIGH` + `blocking: true` — concrete exploit path with realistic threat model and direct impact.
- `MEDIUM` + `blocking: false` — exploit requires unusual conditions or impact is limited.
- `LOW` + `blocking: false` — hardening suggestion worth surfacing.

**Output.** Write findings as a JSON array to `/tmp/pr-review/findings.security.json` using the schema in `_header.md`. Each finding gets `"angle": "security"` and MUST populate `title` (bold headline ≤60 chars), `description` (issue + exploit path, no fix), `fix` (mitigation in prose), and `fix_type`. Set `fix_type: "suggestion"` only when a ≤10-line single-file drop-in replacement at `line` is safe — and populate `suggestion` accordingly. Otherwise set `fix_type: "prose"` with `suggestion: null`. See `_header.md` for the full rule.

