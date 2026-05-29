---
tier: standard
---

# Angle: Infrastructure & CI

**Scope.** Audit infrastructure-as-code and CI/CD changes introduced by this PR's diff. Read `/tmp/pr-review/diff.txt`. Covers GitHub Actions workflows, Dockerfiles / `compose.yml`, Terraform / Pulumi / CDK, Kubernetes manifests / Helm charts, Ansible, `.devcontainer/`, deploy scripts.

**Find:**

- **GitHub Actions:**
  - Untrusted-input → script injection (`${{ github.event.* }}` interpolated into `run:` blocks; reference: github.com/security `script-injection`).
  - `pull_request_target` granting write tokens to PR-controlled code.
  - `permissions:` block missing or set to `write-all` when read-only would suffice.
  - Secrets passed via `env:` on a step that runs untrusted code, or echoed to logs.
- **Dockerfiles:**
  - `FROM image:latest` or no tag, `FROM image` without digest pinning for production images.
  - `RUN` as root with no `USER` directive for the runtime stage.
  - Secrets baked into image layers (`ARG SECRET=...`, `COPY .env`, `RUN echo $TOKEN > ...`).
  - `apt-get install` without `--no-install-recommends` + cleanup, or `npm install` (not `ci`) in a build stage.
- **Terraform / IaC:**
  - Public-by-default resources: S3 bucket without `block_public_access`, security group `0.0.0.0/0` on a non-public port, RDS `publicly_accessible = true`.
  - State file written to a local backend instead of remote, or backend changed without a migration plan.
  - Resources renamed without `moved {}` blocks → destroy + recreate.
  - `lifecycle { prevent_destroy = false }` on stateful resources (DB, bucket).
- **Kubernetes / Helm:**
  - Container without `resources.limits` or `requests`, `privileged: true`, `hostNetwork: true`, `runAsUser: 0`.
  - `imagePullPolicy: Always` paired with a mutable tag (`:latest`).
  - Secret mounted as env var that ends up in error logs / process listings.
- **General:**
  - Hardcoded credentials, API keys, or tokens anywhere in the diff (cross-check with `security` angle but flag here too if infra-scoped).
  - CI step that uploads logs/artifacts containing build env or `printenv` output.

**Skip:**

- Cosmetic YAML reformatting / whitespace.
- Comment-only changes.
- Pre-existing issues in untouched files.

**Severity rubric:**

- `HIGH` + `blocking: true` — secret exposure, public-by-default cloud resource, script injection, prod destroy-recreate without migration.
- `MEDIUM` + `blocking: false` — unpinned third-party action, missing resource limits, missing `permissions:` block.
- `LOW` + `blocking: false` — base-image tagging hygiene, cleanup steps, doc hygiene.

**Output.** Write findings as a JSON array to `/tmp/pr-review/findings.infra.json` using the schema in `_header.md`. Each finding gets `"angle": "infra"` and MUST populate `title` (bold headline ≤60 chars), `description` (the risk + concrete exposure, no fix), `fix` (hardening step in prose), and `fix_type`. Set `fix_type: "suggestion"` only when a ≤10-line single-file drop-in replacement at `line` is safe — and populate `suggestion` accordingly. Otherwise set `fix_type: "prose"` with `suggestion: null`. See `_header.md` for the full rule.

