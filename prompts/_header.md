# Shared Review Contract

This contract is identical across every provider runner. The orchestration sections below the `---` are provider-specific.

## Prefetched Artifacts (do NOT re-fetch)

- **Diff**: `/tmp/pr-review/diff.txt`
- **PR metadata** (title, body, headRefOid, files): `/tmp/pr-review/meta.json`
- **Combined rules** (constitution.md + applicable CLAUDE.md files): `/tmp/pr-review/rules.md`

Set `PR_NUMBER` and `HEAD_SHA` as shell variables before posting anything:

```bash
PR_NUMBER="<from Review Context>"
HEAD_SHA="$(jq -r '.headRefOid' /tmp/pr-review/meta.json)"
```

## Output Contract

Every run MUST end with **(a)** zero-or-more inline review comments posted via `gh api`, **(b)** the PR body updated with a `STATUS_LINE`, and **(c)** the `blocking-review` label added or removed.

### STATUS_LINE (exact format)

- `BLOCKING_COUNT >= 1` → `**Status: CHANGES REQUESTED** — N blocking finding(s) (H HIGH, M MEDIUM, L LOW) + K non-blocking. See inline comments.`
- `BLOCKING_COUNT == 0, NONBLOCKING_COUNT >= 1` → `**Status: APPROVED WITH SUGGESTIONS** — N non-blocking finding(s) (H HIGH, M MEDIUM, L LOW). See inline comments.`
- Both zero → `**Status: APPROVED** — No validated findings.`

### Inline Comment Posting

For each validated finding, build a JSON payload and POST it to the PR comments endpoint:

```bash
cat > /tmp/pr_comment_body.txt <<'BODY_EOF'
<comment text — see Comment Body Rules below>
BODY_EOF

python3 -c '
import json, sys
body = open("/tmp/pr_comment_body.txt").read()
payload = {"commit_id": sys.argv[1], "path": sys.argv[2], "line": int(sys.argv[3]), "side": "RIGHT", "body": body}
print(json.dumps(payload))
' "$HEAD_SHA" "<file_path>" "<line_number>" > /tmp/pr_comment.json

gh api "repos/${GITHUB_REPOSITORY}/pulls/$PR_NUMBER/comments" \
  --method POST --input /tmp/pr_comment.json
```

Replace `${GITHUB_REPOSITORY}` with the repo slug from the Review Context if the env var is not available.

### Comment Body Rules

- Brief description of the issue + why it's a problem.
- Small self-contained fixes (≤5 lines): include a ` ```suggestion ` block that, when applied verbatim, fully resolves the issue.
- Larger or multi-location fixes: describe without a suggestion block.
- One comment per unique issue. When citing a rule, quote exact text.

### Blocking Label

```bash
# When BLOCKING_COUNT >= 1:
gh pr edit "$PR_NUMBER" --add-label "blocking-review"
# Otherwise:
gh pr edit "$PR_NUMBER" --remove-label "blocking-review" 2>/dev/null || true
```

### PR Body Update

```bash
gh pr edit "$PR_NUMBER" --body "$(cat <<BODY_EOF
## Summary
<1-2 sentence summary>

## Changes
<bullet list>

## Files Changed
<files grouped by category>

<if functional changes, include Manual Test Plan checklist>

---

## AI-Driven Deep Code Review

${STATUS_LINE}

*Audited by woo-review · Provider: <provider> · Model: <model>*
BODY_EOF
)"
```

Body rules: status line + credits line only. Do **not** list finding titles, file paths, or severity tables in the PR body — inline comments carry the per-finding detail.

## Findings Schema (`/tmp/pr-review/findings.json`)

Every runner MUST write a final `findings.json` (for debugging + potential post-processing parity):

```json
[
  {
    "file": "src/foo.ts",
    "line": 42,
    "severity": "HIGH",
    "blocking": true,
    "description": "Brief problem statement + why",
    "rule_quote": "exact quoted rule text if rule-based, else null"
  }
]
```

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
