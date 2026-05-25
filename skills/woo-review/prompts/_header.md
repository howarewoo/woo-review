# Shared Review Contract

This contract is identical across every provider runner. The orchestration sections below the `---` are provider-specific.

## Prefetched Artifacts (do NOT re-fetch)

- **Diff**: `/tmp/pr-review/diff.txt`
- **PR metadata** (title, body, headRefOid, baseRefName, files): `/tmp/pr-review/meta.json`
- **Combined rules** (constitution.md + applicable CLAUDE.md files): `/tmp/pr-review/rules.md`
- **Enabled angles** (one per line): `/tmp/pr-review/angles.txt`

Set `PR_NUMBER` and `HEAD_SHA` as shell variables before posting anything:

```bash
PR_NUMBER="<from Review Context>"
HEAD_SHA="$(jq -r '.headRefOid' /tmp/pr-review/meta.json)"
```

## Review Angles

This action runs up to five distinct review angles, auto-selected from the changed files. The set of enabled angles is listed in `/tmp/pr-review/angles.txt`. The per-angle prompt bodies live at `${ACTION_PATH}/prompts/angles/<angle>.md` and are loaded by the orchestrator.

| Angle | Always-on | Tooling |
|---|---|---|
| `bugs` | yes | LLM only |
| `security` | yes | LLM only |
| `seo` | no | LLM only |
| `design-audit` | no | LLM + `npx -y impeccable@$IMPECCABLE_VERSION detect --json` (quantitative audit) |
| `design-critique` | no | LLM + `npx -y impeccable@$IMPECCABLE_VERSION detect --json` (qualitative critique) |
| `react` | no | `npx -y react-doctor@$REACT_DOCTOR_VERSION --diff $BASE_REF --offline` (React linter) + LLM |

Each angle writes its findings to `/tmp/pr-review/findings.<angle>.json`. The orchestrator merges them into `/tmp/pr-review/findings.json` after the validator pass, then posts inline comments and manages the blocking label.

## Output Contract

Every run MUST end with **(a)** one batched GitHub Review submitted via `gh api repos/<repo>/pulls/<PR>/reviews` containing all inline comments, the summary, and the `STATUS_LINE` in the **review body**, and **(b)** the `blocking-review` label added or removed.

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
    body = f["description"]
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
    "description": "Brief problem statement + why",
    "rule_quote": "exact quoted rule text if rule-based, else null"
  }
]
```

`angle` is one of `bugs | security | seo | design-audit | design-critique | react`.

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
