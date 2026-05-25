# Shared Review Contract

This contract is identical across every provider runner. The orchestration sections below the `---` are provider-specific.

## Prefetched Artifacts (do NOT re-fetch)

- **Diff**: `/tmp/pr-review/diff.txt`
- **PR metadata** (title, body, headRefOid, baseRefName, files): `/tmp/pr-review/meta.json`
- **Combined rules** (applicable CLAUDE.md files): `/tmp/pr-review/rules.md`
- **Enabled angles** (one per line): `/tmp/pr-review/angles.txt`

Set `PR_NUMBER` and `HEAD_SHA` as shell variables before posting anything:

```bash
PR_NUMBER="<from Review Context>"
HEAD_SHA="$(jq -r '.headRefOid' /tmp/pr-review/meta.json)"
```

## Model Tiers (host-agnostic)

Each angle prompt and the validator declare a `tier:` in frontmatter — `fast`, `standard`, or `deep`. The host/runner resolves the tier to a concrete model from the table below. The context+summary subagent (defined in each provider prompt) is implicitly `fast`.

| Tier | Use for | Anthropic | OpenAI (Codex) | Google (Gemini) | OpenRouter |
|---|---|---|---|---|---|
| `fast` | rubric checklists (`seo`, `aeo`), context summaries | `claude-haiku-4-5` | `gpt-5-mini` | `gemini-3-5-flash` | `openrouter/deepseek/deepseek-v4-flash` |
| `standard` | reasoning workers (`bugs`, `security`, `design`, `react`) | `claude-sonnet-4-6` | `gpt-5` | `gemini-3-5-flash` | `openrouter/deepseek/deepseek-v4-pro` |
| `deep` | skeptical validator (highest-leverage filter) | `claude-opus-4-7` | `gpt-5` + `reasoning_effort: high` | `gemini-3-5-flash` | `openrouter/deepseek/deepseek-v4-pro` + `reasoning_effort: xhigh` |

> **Provider notes:**
> - **Google** currently ships only `gemini-3-5-flash` in the 3.5 line; no Pro/Ultra/Thinking variant exists yet, so all tiers collapse onto flash (tier routing is effectively a no-op until Google releases a larger model).
> - **OpenAI** GPT-5 reasoning is a parameter on the same slug, not a slug suffix. The valid `reasoning_effort` values are `minimal` / `low` / `medium` / `high` (`high` is max for `gpt-5`). There is no `gpt-5-pro`. A newer flagship family (`gpt-5.5`) exists and accepts `xhigh`; upgrade `inputs.model` to `gpt-5.5` when the Codex Action supports it.
> - **OpenRouter** DeepSeek exposes exactly two slugs — `deepseek/deepseek-v4-flash` and `deepseek/deepseek-v4-pro`. Reasoning is a `reasoning_effort` parameter (`high` / `xhigh`, where `xhigh` maps to max). Use plain `v4-pro` for standard and `v4-pro` with `reasoning_effort: xhigh` for deep. Do not route to `deepseek-r1` — V4 supersedes it.

**Routing rules by host capability:**

- **Per-call routing supported** (Claude Code `Task`, opencode `@subagent`): honor each prompt's `tier:` verbatim — spawn fast workers on the fast model, deep validator on the deep model. Maximum savings.
- **Single model per session** (Codex Action, Gemini CLI): pin the whole run to the `standard` tier model. You lose `fast`-tier savings on rubric angles, but `standard` is the safe default that handles every angle. If `inputs.model` is set explicitly, honor that and ignore tiers.
- **Override**: `inputs.model` (action.yml) or a runner-specific override always wins over the tier resolution.

## Review Angles

This action runs up to five distinct review angles, auto-selected from the changed files. The set of enabled angles is listed in `/tmp/pr-review/angles.txt`. The per-angle prompt bodies live at `${ACTION_PATH}/prompts/angles/<angle>.md` and are loaded by the orchestrator.

| Angle | Always-on | Tooling |
|---|---|---|
| `bugs` | yes | LLM only |
| `security` | yes | LLM + `openai/security-best-practices` rubric (loaded from installed skill or fetched via `gh api repos/openai/skills/contents/skills/.curated/security-best-practices/references/<file>`) |
| `seo` | no | LLM + `coreyhaines31/seo-audit` rubric (embedded in `prompts/angles/seo.md`) |
| `aeo` | no | LLM + `coreyhaines31/ai-seo` rubric (embedded in `prompts/angles/aeo.md`); deeper `references/` fetched on demand via `gh api repos/coreyhaines31/marketingskills/contents/skills/ai-seo/references/<file>` |
| `design` | no | LLM + `npx -y impeccable@$IMPECCABLE_VERSION detect --json` (one run; quantitative pass from JSON + qualitative critique scoped to flagged files) |
| `react` | no | `npx -y react-doctor@$REACT_DOCTOR_VERSION --diff $BASE_REF --offline` (React linter) + LLM |

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
# 1. Prepare the review body (Summary + Status Line)
cat <<'BODY_EOF' > /tmp/pr_review_body.txt
## AI Deep Code Review Summary

<1-2 sentence high-level summary of the review results>

---
${STATUS_LINE}
*Audited by woo-review · Provider: <provider> · Model: <model>*
BODY_EOF

# 2. Prepare the review payload with inline comments
python3 -c '
import json, sys, os

try:
    findings = json.load(open("/tmp/pr-review/findings.json"))
except:
    findings = []

commit_id = os.environ.get("HEAD_SHA")
pr_body = open("/tmp/pr_review_body.txt").read()

# Determine event: REQUEST_CHANGES if any blocking findings exist, else COMMENT (or APPROVE if 0 findings)
has_blocking = any(f.get("blocking", False) for f in findings)
if not findings:
    event = "APPROVE"
elif has_blocking:
    event = "REQUEST_CHANGES"
else:
    event = "COMMENT"

comments = []
for f in findings:
    # Inline comment format: bold title, issue description, recommended fix.
    title = f["title"].strip()
    description = f["description"].strip()
    fix = (f.get("fix") or "").strip()

    body = f"**{title}**\n\n{description}"
    if fix:
        body += f"\n\nFix: {fix}"
    if f.get("suggestion"):
        body += f"\n\n```suggestion\n{f['suggestion']}\n```"

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
    "fix": "Recommended change in prose (e.g. 'use `<=` instead of `<` so the boundary value is included').",
    "suggestion": "optional verbatim replacement snippet for the GitHub ```suggestion``` block, else null",
    "rule_quote": "exact quoted rule text if rule-based, else null"
  }
]
```

`angle` is one of `bugs | security | seo | aeo | design | react`.

### Inline Comment Format (rendered on the PR)

Every inline comment posted to GitHub MUST follow this three-part structure, assembled from the schema fields above:

```
**<title>**

<description>

Fix: <fix>
```

- **Title** — bold one-liner, ≤60 characters, no trailing punctuation. Names the problem.
- **Description** — the issue itself: what is broken, why it matters, with diff-anchored evidence. Do NOT prescribe the fix here.
- **Fix** — recommended change, prefixed literally with `Fix: `. Required for every finding. If a verbatim replacement is possible, ALSO populate `suggestion` so a GitHub ```suggestion``` block is appended after the `Fix:` line.

The body builder in the posting step (see python snippet above) renders this format automatically from `title` / `description` / `fix` / `suggestion`. Angle agents and the validator MUST populate `title`, `description`, and `fix` for every finding.

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
- Generic security concerns unless `rules.md` explicitly requires.

---
