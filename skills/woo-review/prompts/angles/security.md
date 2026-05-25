# Angle: Security

**Scope.** Find security vulnerabilities introduced by this PR's diff. Read `/tmp/pr-review/diff.txt` and `/tmp/pr-review/rules.md`.

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
- Defense-in-depth nice-to-haves unless `rules.md` explicitly requires.
- Theoretical timing attacks unless the diff actually adds a verifying compare.

**Severity rubric:**

- `HIGH` + `blocking: true` — concrete exploit path with realistic threat model and direct impact.
- `MEDIUM` + `blocking: false` — exploit requires unusual conditions or impact is limited.
- `LOW` + `blocking: false` — hardening suggestion worth surfacing.

**Output.** Write findings as a JSON array to `/tmp/pr-review/findings.security.json` using the schema in `_header.md`. Each finding gets `"angle": "security"`.
