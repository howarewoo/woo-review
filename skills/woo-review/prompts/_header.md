# Shared Review Contract

This contract is identical across every provider runner. The orchestration sections below the `---` are provider-specific.

## Output Discipline (READ FIRST)

Every artifact you write under `$OUTDIR/findings.*.json` (default `/tmp/pr-review/findings.<angle>.json`) MUST be a valid JSON array — and **only** a JSON array.

- The file MUST start with `[` and end with `]`.
- No preamble, no commentary, no "I have completed the review…" sentence, no markdown fences (` ``` `), no trailing chatter.
- If you have nothing to report, write the literal `[]`.
- **Write `[]` to your findings file as the FIRST action.** Replace it with the real array just before EXIT. Sub-agents have died mid-run (stream errors, turn-limit interrupts) and left no file at all — the merge step then has no array to merge for that angle. An up-front empty array makes failure non-destructive: the worst case becomes "this angle reported nothing," not "this angle silently dropped out of the review."
- If your runtime offers a "write file" tool, use it directly — do NOT echo the JSON through a chat channel that prepends prose.
- **Escape discipline inside string fields.** Every `"description"`, `"fix"`, and `"suggestion"` is a JSON string — inside it, the only valid backslash escapes are `\"`, `\\`, `\/`, `\b`, `\f`, `\n`, `\r`, `\t`, and `\uXXXX`. Bare backslashes in code samples (Windows paths, regex like `\d`, LaTeX) MUST be doubled to `\\`. Tabs and newlines in code samples MUST be `\t` / `\n`, never raw control bytes. The merge step has a fallback sanitizer, but a finding that loses content during sanitization is one that fails to land cleanly on the PR.
- Before writing each finding's `line` field, validate it via:
  ```bash
  bash "$WOO_REVIEW_ACTION_PATH/scripts/resolve-diff-line.sh" \
    --file "<path>" --line "<N>"
  ```
  When the helper prints `null`, the line is not anchorable on the diff's RIGHT side and GitHub will reject the comment (HTTP 422). DROP the finding entirely rather than guessing a different line. The merge step also runs a final-pass safety net on this, but resolving up-front saves a round-trip and keeps the finding count honest.
- `$OUTDIR` defaults to `/tmp/pr-review` — when the host has set it to something else (e.g. a sandboxed workspace temp dir), prefer the env var over the literal path throughout this contract.

## Prefetched Artifacts (do NOT re-fetch)

- **Diff**: `/tmp/pr-review/diff.txt` — may be a full PR diff OR an incremental `last_sha...HEAD` diff (see `last_sha.txt`).
- **PR metadata** (title, body, headRefOid, baseRefName, files, author): `/tmp/pr-review/meta.json`
- **Enabled angles** (one per line): `/tmp/pr-review/angles.txt`
- **Project rules** (optional, present only if discovered): `/tmp/pr-review/rules.md`
- **Per-repo config** (always present, defaults to `{}`): `/tmp/pr-review/config.json` — parsed from `.woo-review.yml` at the consumer repo root.
- **Incremental base SHA** (always present, may be empty): `/tmp/pr-review/last_sha.txt` — non-empty means `diff.txt` covers only the new commits since the last woo-review pass. Treat findings as scoped to those commits.
- **Prior unresolved review threads** (always present, may be `[]`): `/tmp/pr-review/prior-findings.json` — array of `{file, line, title, author}` for any unresolved thread on the PR. Consumed by the posting stage for event-floor + dedupe; angle workers MUST ignore this file. No per-entry `blocking` flag — any non-empty list floors the review event to `REQUEST_CHANGES` (conservative "do not APPROVE while threads open" rule).
- **Repository dismissal sidecar** (always present, may be `[]`):
  `/tmp/pr-review/sidecar-findings.json` — array of
  `{file, line, title, semantic_key, code_anchor, resolved_at, pr_number}`
  loaded from `.woo-review/dismissed.json` at the consumer repo root.
  Consumed by `dedup-against-history.sh` (added in a later task); angle workers MUST ignore this file.
- **Chunk manifest** (optional, present only when the diff exceeds `chunking.max_loc`): `/tmp/pr-review/chunks.txt` (one chunk id per line) and `/tmp/pr-review/chunks.json` (manifest: `[{id, files, loc, diff_path, boundary}]`). Each chunk also has its own diff at `/tmp/pr-review/diff.chunk-<id>.txt`. When a worker is dispatched with a chunk id (env `CHUNK` non-empty), it MUST read the chunk-specific diff and write findings to `/tmp/pr-review/findings.<angle>.<chunk>.json`. In the GitHub Action this swap happens transparently — `diff.txt` is replaced with the chunk's diff before the worker runs, and the worker's output is renamed afterwards. When `chunks.txt` is absent, chunking did not activate and the diff fits a single worker (no overhead).

If `/tmp/pr-review/rules.md` exists, treat it as an additional rubric on top of the per-angle scope. Each section is prefixed by a `## SOURCE: <path>` header identifying its origin file (`AGENTS.md`, `CLAUDE.md`, `.cursorrules`, `.windsurfrules`, or `GEMINI.md`). Any finding that claims a project-rule violation MUST populate `rule_quote` with a verbatim substring of `rules.md` (the rule text itself, not the source header). The validator discards rule-cited findings whose `rule_quote` is missing or not literally present in `rules.md`.

Set `PR_NUMBER` and `HEAD_SHA` as shell variables before posting anything:

```bash
PR_NUMBER="<from Review Context>"
HEAD_SHA="$(jq -r '.headRefOid' /tmp/pr-review/meta.json)"
```

## Model Tiers (host-agnostic)

Each angle prompt and the validator declare a `tier:` in frontmatter — `fast`, `standard`, or `deep`. The host/runner resolves the tier to a concrete model from the table below. The context+summary subagent (defined in each provider prompt) is implicitly `fast`.

| Tier | Use for | Anthropic | OpenAI (Codex) | Google (Gemini) | OpenRouter |
|---|---|---|---|---|---|
| `fast` | rubric checklists (`seo`, `aeo`, `observability`, `types`, `i18n`, `docs`, `deps`), context summaries | `claude-haiku-4-5` | `gpt-5-mini` | `gemini-3-5-flash` | `openrouter/deepseek/deepseek-v4-flash` |
| `standard` | reasoning workers (`bugs`, `security`, `design`, `react`, `database`, `tests`, `api`, `infra`) | `claude-sonnet-4-6` | `gpt-5` | `gemini-3-5-flash` | `openrouter/deepseek/deepseek-v4-pro` |
| `deep` | skeptical validator (highest-leverage filter) | `claude-opus-4-7` | `gpt-5` + `reasoning_effort: high` | `gemini-3-5-flash` | `openrouter/deepseek/deepseek-v4-pro` + `reasoning_effort: xhigh` |

> **Provider notes:**
> - **Google** currently ships only `gemini-3-5-flash` in the 3.5 line; no Pro/Ultra/Thinking variant exists yet, so all tiers collapse onto flash (tier routing is effectively a no-op until Google releases a larger model).
> - **OpenAI** GPT-5 reasoning is a parameter on the same slug, not a slug suffix. The valid `reasoning_effort` values are `minimal` / `low` / `medium` / `high` (`high` is max for `gpt-5`). There is no `gpt-5-pro`. A newer flagship family (`gpt-5.5`) exists and accepts `xhigh`; upgrade `inputs.model` to `gpt-5.5` when the Codex Action supports it.
> - **OpenRouter** DeepSeek exposes exactly two slugs — `deepseek/deepseek-v4-flash` and `deepseek/deepseek-v4-pro`. Reasoning is a `reasoning_effort` parameter (`high` / `xhigh`, where `xhigh` maps to max). Use plain `v4-pro` for standard and `v4-pro` with `reasoning_effort: xhigh` for deep. Do not route to `deepseek-r1` — V4 supersedes it.

**Routing rules by host capability:**

- **Per-call routing supported** (Claude Code `Task`, opencode `@subagent`): honor each prompt's `tier:` verbatim — spawn fast workers on the fast model, deep validator on the deep model. Maximum savings.
- **Single model per session** (Codex Action, Gemini CLI): pin the whole run to the `standard` tier model. You lose `fast`-tier savings on rubric angles, but `standard` is the safe default that handles every angle. If `inputs.model` is set explicitly, honor that and ignore tiers.
- **Override**: `inputs.model` (action.yml) or a runner-specific override always wins over the tier resolution.

**Per-repo tier overrides (`.woo-review.yml`):** before resolving any `tier:` to a model slug, read `/tmp/pr-review/config.json`. If `models.<tier>` is set, use that slug INSTEAD of the table entry above. Example: `jq -r '.models.deep // empty' /tmp/pr-review/config.json` — empty means use the table default. `inputs.model` (action.yml) still wins over the per-repo override.

## Per-repo Config (`/tmp/pr-review/config.json`)

The prefetch step parses an optional `.woo-review.yml` at the consumer repo root and writes a canonical JSON copy to `/tmp/pr-review/config.json`. Missing file = `{}` (no-op). The full schema is documented in `SKILL.md`; runners only need to know which keys are consumed at which stage:

| Key | Consumed by | When |
|---|---|---|
| `angles.force`, `angles.skip` | `detect-angles.sh` | Stage 1 |
| `ignore` | `prefetch.sh` (filters diff + paths) | Stage 1 |
| `project_rules` | `prefetch.sh` (appends to `rules.md`) | Stage 1 |
| `authors_skip` | `prefetch.sh` (skips + posts one-line comment; default list applied when absent — issue #19) | Stage 1 |
| `release_rollup_pattern` | `prefetch.sh` (skips + posts one-line comment when PR title matches; default `^(staging\|release\|chore\(release\))` applied when absent — issue #19) | Stage 1 |
| `severity_floor` | validator | Stage 3 |
| `models.fast` / `.standard` / `.deep` | orchestrator prompts (tier resolution) | Stage 2 |
| `fix_commands` | persisted only; consumed by `--loop` mode (#15) | n/a |
| `chunking.max_loc` | `chunk-diff.sh` (split oversized diff into chunks; default 4000) | Stage 1 |

## Review Angles

This action runs up to sixteen distinct review angles, auto-selected from the changed files. The set of enabled angles is listed in `/tmp/pr-review/angles.txt`. The per-angle prompt bodies live at `${ACTION_PATH}/prompts/angles/<angle>.md` and are loaded by the orchestrator.

| Angle | Always-on | Tooling |
|---|---|---|
| `bugs` | yes | LLM only |
| `security` | yes | LLM + `openai/security-best-practices` rubric (loaded from installed skill or fetched via `gh api repos/openai/skills/contents/skills/.curated/security-best-practices/references/<file>`) |
| `conventions` | gated on `rules.md` presence | LLM + project-discovered `rules.md` (concatenated `AGENTS.md` / `CLAUDE.md` / `.cursorrules` / `.windsurfrules` / `GEMINI.md`) |
| `seo` | no | LLM + `coreyhaines31/seo-audit` rubric (embedded in `prompts/angles/seo.md`) |
| `aeo` | no | LLM + `coreyhaines31/ai-seo` rubric (embedded in `prompts/angles/aeo.md`); deeper `references/` fetched on demand via `gh api repos/coreyhaines31/marketingskills/contents/skills/ai-seo/references/<file>` |
| `design` | no | LLM + `npx -y impeccable@$IMPECCABLE_VERSION detect --json` (one run; quantitative pass from JSON + qualitative critique scoped to flagged files) |
| `react` | no | `npx -y react-doctor@$REACT_DOCTOR_VERSION --diff $BASE_REF --offline` (React linter) + LLM |
| `database` | no | LLM + `supabase/supabase-postgres-best-practices` rubric (loaded from installed skill or fetched via `gh api repos/supabase/agent-skills/contents/skills/supabase-postgres-best-practices/references/<file>`) |
| `tests` | no | LLM only — gated on test-file path in diff |
| `api` | no | LLM only — gated on OpenAPI / GraphQL / `.proto` / route-handler paths or HTTP-verb tokens in the diff |
| `infra` | no | LLM only — gated on `.github/workflows/`, `Dockerfile*`, Terraform / Pulumi / CDK, K8s manifests, Helm |
| `observability` | no | LLM only — gated on logging / error-handling tokens in the diff |
| `types` | no | LLM only — gated on `*.ts` / `*.tsx` / `*.cts` / `*.mts` in diff |
| `i18n` | no | LLM only — gated on `locales/` / `messages/` / `i18n/` / `translations/` directory trees, `*.po` / `*.pot` files, or `i18n.t(` / `useTranslations(` / `<Trans` / `<FormattedMessage` / `$t(` / `t("…")` tokens in the diff body |
| `docs` | no | LLM only — gated on docs paths (`README*`, `CHANGELOG*`, `docs/`, `.env.example`, `*.md`/`*.mdx`, `openapi.{yaml,yml,json}`, `swagger.{yaml,yml,json}`) in diff |
| `deps` | no | LLM only — gated on dependency-manifest paths (`package.json`, lockfiles, `requirements.txt`, `go.mod`, `Cargo.toml`, …) in diff |

Each angle writes its findings to `/tmp/pr-review/findings.<angle>.json`. The orchestrator merges them into `/tmp/pr-review/findings.json` after the validator pass, then posts inline comments via a single batched GitHub Review. PR labels MUST NOT be mutated — blocking is signalled exclusively through the native `REQUEST_CHANGES` review event.

## Output Contract

Every run MUST end with one batched GitHub Review submitted via `gh api repos/<repo>/pulls/<PR>/reviews` containing all inline comments, the summary, and the `STATUS_LINE` in the **review body**. The review `event` is the native blocking gate: `APPROVE` (0 findings), `COMMENT` (no blocking findings), or `REQUEST_CHANGES` (≥1 blocking finding). PR labels MUST NOT be added, removed, or otherwise mutated.

The PR title and the PR description (issue body) MUST NOT be modified. The `STATUS_LINE` lives inside the Review body — never in the PR body.

### STATUS_LINE (exact format)

- `BLOCKING_COUNT >= 1` → `**Status: CHANGES REQUESTED** — N blocking finding(s) (H HIGH, M MEDIUM, L LOW) + K non-blocking. See inline comments.`
- `BLOCKING_COUNT == 0, NONBLOCKING_COUNT >= 1` → `**Status: APPROVED WITH SUGGESTIONS** — N non-blocking finding(s) (H HIGH, M MEDIUM, L LOW). See inline comments.`
- Both zero → `**Status: APPROVED** — No validated findings.`

### Pull Request Review (Batch)

Instead of posting individual comments, batch all findings into a single GitHub Review. This uses the `pull_request_review` API.

```bash
# 0. Self-PR detection. The GitHub API rejects `event: REQUEST_CHANGES` when
# the authenticated user is the PR author (HTTP 422 "Can not request changes
# on your own pull request"). Capture both logins so the payload-builder can
# downgrade silently when they match — without this, every self-review run
# with a blocking finding fails to post at all.
AUTH_LOGIN=$(gh api user --jq .login 2>/dev/null || echo "")
PR_AUTHOR=$(jq -r '.author.login // empty' /tmp/pr-review/meta.json 2>/dev/null || echo "")
export AUTH_LOGIN PR_AUTHOR

# 1. Prepare the review body (Summary + Status Line + hidden SHA marker).
# The trailing <!-- woo-review:sha=$HEAD_SHA --> marker is read by the next run's
# prefetch step to enable incremental review (diffs LAST_SHA...HEAD only). DO NOT
# remove or rename — it is the only state we persist across runs.
#
# Heredoc is single-quoted to disable shell expansion. The orchestrator agent
# substitutes ${STATUS_LINE} and ${HEAD_SHA} into the template text BEFORE
# running cat — same pattern already used for STATUS_LINE. Single-quoted form
# avoids any shell-expansion surface from values that pass through here.
cat <<'BODY_EOF' > /tmp/pr_review_body.txt
## AI Deep Code Review Summary

<1-2 sentence high-level summary of the review results>

---
${STATUS_LINE}
*Audited by woo-review · Provider: <provider> · Model: <model>*

<!-- woo-review:sha=${HEAD_SHA} -->
BODY_EOF

# 2. Prepare the review payload with inline comments
python3 -c '
import json, sys, os, re

try:
    findings = json.load(open("/tmp/pr-review/findings.json"))
except:
    findings = []

# Prior unresolved threads (from prefetch, GraphQL reviewThreads). Used for:
#   - event floor: ANY non-empty priors → minimum REQUEST_CHANGES (conservative
#     "do not APPROVE while review threads are open" rule),
#   - dedupe: drop a new finding whose (file, line, title-stem) matches a prior
#     unresolved thread (already on the PR — re-posting would duplicate).
# Priors have no per-entry blocking flag; the floor is a bool over the array.
try:
    priors = json.load(open("/tmp/pr-review/prior-findings.json"))
except:
    priors = []

def title_stem(s):
    return re.sub(r"[^a-z0-9]+", "", (s or "").lower())[:40]

prior_keys = {(p.get("file"), int(p.get("line") or 0), title_stem(p.get("title")))
              for p in priors}

filtered = []
for f in findings:
    key = (f.get("file"), int(f.get("line") or 0), title_stem(f.get("title")))
    if key in prior_keys:
        continue  # already on the PR as an unresolved thread
    filtered.append(f)
findings = filtered

commit_id = os.environ.get("HEAD_SHA")
pr_body = open("/tmp/pr_review_body.txt").read()

# Event determination. Floor: any unresolved prior thread (regardless of its
# original severity) forces REQUEST_CHANGES — conservative gate so a stale open
# thread is never auto-resolved by a clean incremental pass. The full schema
# rationale is in SKILL.md under "Incremental Mode".
has_new_blocking = any(f.get("blocking", False) for f in findings)
has_priors = len(priors) > 0
if not findings and not has_priors:
    event = "APPROVE"
elif has_new_blocking or has_priors:
    event = "REQUEST_CHANGES"
else:
    event = "COMMENT"

# Self-PR downgrade. GitHub rejects REQUEST_CHANGES + APPROVE when the
# authenticated user is the PR author (HTTP 422 "Can not request changes on
# your own pull request" / "Can not approve your own pull request"). Downgrade
# both to COMMENT so the review still posts; the STATUS_LINE in the body
# already carries the accurate signal.
auth_login = (os.environ.get("AUTH_LOGIN") or "").lower()
pr_author = (os.environ.get("PR_AUTHOR") or "").lower()
self_pr = bool(auth_login) and bool(pr_author) and auth_login == pr_author
if self_pr and event in ("REQUEST_CHANGES", "APPROVE"):
    pr_body = pr_body.rstrip() + (
        f"\n\n_Review event downgraded to COMMENT — GitHub blocks "
        f"{event} on your own PR. Status line above carries the actual verdict._\n"
    )
    event = "COMMENT"

comments = []
for f in findings:
    # Inline comment format: bold title, issue description, recommended fix,
    # trailing attribution footer naming the severity + angle agent that
    # flagged the finding (plus a "blocking" tag when blocking == true).
    title = f["title"].strip()
    description = f["description"].strip()
    fix = (f.get("fix") or "").strip()
    angle = (f.get("angle") or "").strip()
    severity = (f.get("severity") or "").strip().upper()
    blocking = bool(f.get("blocking", False))

    body = f"**{title}**\n\n{description}"
    if fix:
        body += f"\n\nFix: {fix}"
    # Render ```suggestion``` block only when validator-approved as fix_type=suggestion.
    # fix_type=prose (or missing) → prose-only recommendation, no block.
    if f.get("fix_type") == "suggestion" and f.get("suggestion"):
        # Defense-in-depth: neutralize any line of ≥3 backticks inside the snippet
        # that would close the fenced block early and let agent-supplied content
        # escape into the surrounding PR-comment Markdown. Validator step 7
        # already downgrades such findings, but we re-guard at the render site
        # because the renderer is the trust boundary to GitHub.
        safe_lines = []
        for line in f["suggestion"].splitlines():
            if re.match(r"^\s*`{3,}", line):
                line = line.replace("`", "'")
            safe_lines.append(line)
        safe = "\n".join(safe_lines)
        body += f"\n\n```suggestion\n{safe}\n```"

    # Attribution footer: severity + which angle agent found this. Both values
    # are whitelisted against their known sets so malformed/garbage input
    # cannot inject text into the rendered comment.
    footer_parts = []
    if severity in {"HIGH", "MEDIUM", "LOW"}:
        sev_tag = f"{severity} · BLOCKING" if blocking else severity
        footer_parts.append(f"<strong>{sev_tag}</strong>")
    if angle in {"bugs","security","conventions","seo","aeo","design","react","database","tests","api","infra","observability","types","i18n","docs","deps"}:
        footer_parts.append(f"flagged by the <code>{angle}</code> agent")
    if footer_parts:
        body += "\n\n<sub>— " + " · ".join(footer_parts) + "</sub>"

    comments.append({
        "path": f["file"],
        "line": int(f["line"]),
        "side": "RIGHT",
        "body": body
    })

payload = {
    "commit_id": commit_id,
    "body": pr_body,
    "event": event,
    "comments": comments
}
print(json.dumps(payload))
' > /tmp/pr_review_payload.json

# 3. Submit the review
gh api "repos/${GITHUB_REPOSITORY}/pulls/$PR_NUMBER/reviews" \
  --method POST --input /tmp/pr_review_payload.json
```

### Review Body Rules
The `pr_review_body.txt` should contain:
- A 1-2 sentence high-level summary of the findings.
- The `${STATUS_LINE}`.
- Credits line (*Audited by woo-review...*).
- A hidden HTML comment `<!-- woo-review:sha=${HEAD_SHA} -->` as the last line. This is the watermark the next run's prefetch step reads to enable incremental review.
- **DO NOT** update the main PR description or title.

## Findings Schema (`/tmp/pr-review/findings.json`)

Every runner MUST write a final `findings.json` (for debugging + potential post-processing parity). Each per-angle step writes to `/tmp/pr-review/findings.<angle>.json`; the orchestrator merges them after validation:

```json
[
  {
    "angle": "bugs",
    "file": "src/foo.ts",
    "line": 42,
    "severity": "HIGH",
    "blocking": true,
    "title": "Short bold headline (≤60 chars, no trailing punctuation)",
    "description": "Issue description: what is wrong and why it matters. Do NOT include the fix here.",
    "fix_type": "suggestion",
    "fix": "Recommended change in prose (e.g. 'use `<=` instead of `<` so the boundary value is included').",
    "suggestion": "verbatim replacement code for the GitHub ```suggestion``` block — REQUIRED when fix_type == \"suggestion\", MUST be null when fix_type == \"prose\"",
    "rule_quote": "exact quoted rule text if rule-based, else null",
    "semantic_key": "bugs/off-by-one-loop-bound",
    "code_anchor": "a1b2c3d4e5f6"
  }
]
```

`angle` is one of `bugs | security | conventions | seo | aeo | design | react | database | tests | api | infra | observability | types | i18n | docs | deps`.

### `semantic_key` and `code_anchor` (dedup keys)

Every finding MUST set both fields. They form the stable identity used by
`dedup-against-history.sh` (added in a later task) to skip findings already
on the PR or in the committed sidecar.

- `semantic_key` — kebab-case `<angle>/<issue-type>`, max 40 chars. Each
  angle prompt enumerates the valid values for that angle. Unknown issues
  use `<angle>/unknown` (still dedupable by file + anchor alone).
- `code_anchor` — SHA-1 (first 12 hex chars) of the trimmed concatenation
  of the 3 lines before, the finding line, and the 3 lines after, from
  the post-PR diff content. Compute via:

  ```bash
  printf '%s' "$context" | shasum -a 1 | cut -c1-12
  ```

  The anchor survives line shifts in unrelated code; the surrounding
  context must change for the anchor to change.

`line` MUST be the post-patch absolute file line — i.e. a line that exists on the RIGHT side of the diff (a `+` added line or a ` ` context line within a hunk for `file`). Lines that fall in a deletion-only region, or outside any hunk for the file, will be rejected by the GitHub API. Validate every line via `scripts/resolve-diff-line.sh` before writing the finding (see *Output Discipline* above); drop the finding when the helper returns `null`.

### `fix_type` discriminator

Every finding MUST set `fix_type` to exactly one of:

- `"suggestion"` — a one-click GitHub ```suggestion``` block is safe. Requires `suggestion` to be populated with self-contained replacement code that is ALL of:
  - ≤10 lines,
  - scoped to the single file at `file`,
  - a complete drop-in replacement for the existing line(s) at `line` (no `...` placeholders, no partial diffs),
  - self-contained (does not reference symbols, imports, or context the diff does not already establish).
- `"prose"` — the change is too large, multi-file, structural, or context-dependent for a one-click block. `suggestion` MUST be `null`; the human-readable `fix` field carries the recommendation.

The validator enforces these rules and will downgrade a violating `fix_type: suggestion` to `fix_type: prose` (clearing `suggestion`) rather than emitting a broken block. When in doubt, prefer `prose` — a usable prose recommendation beats a broken one-click suggestion that loses author trust.

### Inline Comment Format (rendered on the PR)

Every inline comment posted to GitHub MUST follow this four-part structure, assembled from the schema fields above:

```
**<title>**

<description>

Fix: <fix>

<sub>— <strong><severity> · BLOCKING</strong> · flagged by the <code><angle></code> agent</sub>
```

- **Title** — bold one-liner, ≤60 characters, no trailing punctuation. Names the problem.
- **Description** — the issue itself: what is broken, why it matters, with diff-anchored evidence. Do NOT prescribe the fix here.
- **Fix** — recommended change, prefixed literally with `Fix: `. Required for every finding. The body builder appends a GitHub ```suggestion``` block after the `Fix:` line if and only if `fix_type == "suggestion"` AND `suggestion` is a non-empty string; `fix_type == "prose"` renders the recommendation in prose only.
- **Attribution footer** — small-print line carrying the finding's `severity` (HIGH / MEDIUM / LOW; suffixed with `· BLOCKING` when `blocking == true`) and the angle agent that flagged it (e.g. `<sub>— <strong>HIGH · BLOCKING</strong> · flagged by the <code>bugs</code> agent</sub>`). The body builder appends this automatically from the finding's `severity` / `blocking` / `angle` fields. Both `severity` and `angle` are whitelisted against their known sets; unknown/missing values are dropped from the footer rather than injecting raw text. If both are missing, the footer is omitted entirely.

The body builder in the posting step (see python snippet above) renders this format automatically from `title` / `description` / `fix` / `fix_type` / `suggestion` / `angle` / `severity` / `blocking`. Angle agents and the validator MUST populate `title`, `description`, `fix`, `fix_type`, `angle`, `severity`, and `blocking` for every finding.

## Blocking Criteria

A finding is `blocking: true` only when ALL hold:
- Real, in-diff, produced by this PR (not pre-existing).
- One of:
  - Code that will fail to compile/parse.
  - Code that will definitely produce wrong results regardless of inputs.
  - Clear, unambiguous rule violation with exact quoted rule text.
  - Security vulnerability with concrete exploit path.

Otherwise `blocking: false`:
- Style/quality concerns worth surfacing (but not lint-catchable).
- Performance smells (obvious N+1, unnecessary re-render).
- Missing tests on new business logic.
- Defensive coding improvements.
- Defensible subjective suggestions.

## Do NOT Flag

- Lint-catchable issues handled by Biome / ESLint / tsc / similar.
- Input-dependent maybe-issues with no concrete failure case.
- Pedantic nitpicks (whitespace, naming taste without rule backing).
- Pre-existing issues not introduced by this PR.
- Generic security concerns without concrete exploit path in this PR.

---
