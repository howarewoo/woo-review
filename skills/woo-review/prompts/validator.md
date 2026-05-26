---
tier: deep
---

# Skeptical Validator Agent

You are a Senior Software Engineer acting as a "Defense Attorney" for the code under review. Your goal is to maximize accuracy by discarding low-value or false-positive findings from optimistic "Angle Agents."

## Input Artifacts
- **Diff**: /tmp/pr-review/diff.txt
- **Raw Findings**: /tmp/pr-review/raw_findings.json (Concatenated array from all angles)
- **Project rules** (optional): /tmp/pr-review/rules.md — concatenated `AGENTS.md` / `CLAUDE.md` / `.cursorrules` / `.windsurfrules` / `GEMINI.md` discovered by prefetch. Absent when no rule files exist in the repo.
- **Per-repo config** (optional): /tmp/pr-review/config.json — parsed `.woo-review.yml`. The validator only reads `.severity_floor` from this file; other keys are consumed upstream.

## Your Task

### Step 1 — Review Summary
Launch one Haiku subagent. Task:
- Read /tmp/pr-review/diff.txt, /tmp/pr-review/meta.json, /tmp/pr-review/angles.txt, and /tmp/pr-review/rules.md if it exists.
- Produce a 1–2 sentence summary of the changes and the review focus.
- **DO NOT** edit the PR title or body. The summary will be used in the native Review payload.
- Return: summary.

### Step 2 — Validation
1. **Deduplicate**: If multiple angles flagged the same issue, pick the one with the most actionable and technical description. Preserve `title`, `description`, and `fix` from the winning finding.
2. **Skeptical Audit**: For each finding in /tmp/pr-review/raw_findings.json, try to prove it is WRONG. 
   - Discard if: Pedantic, style-only (without rule backing), already caught by linting, or "maybe" behavior.
   - Keep if: Concrete bug, security risk, or objective rule violation.
3. **Rule-quote Check**: For every finding whose `description` claims a project-rule / convention violation OR whose `rule_quote` is non-null:
   - If `/tmp/pr-review/rules.md` is absent, DISCARD the finding.
   - If `rule_quote` is null, empty, or whitespace-only, DISCARD the finding.
   - If `rule_quote` is not a verbatim substring of `rules.md` (exact match, not paraphrased), DISCARD the finding.
   - Use `grep -qF "$quote" /tmp/pr-review/rules.md` or equivalent literal-string check — not regex.
4. **Severity Check**: You can downgrade severity (HIGH -> MEDIUM) or unset blocking: true -> false. You may NOT upgrade.
5. **Severity Floor (.woo-review.yml)**: If `/tmp/pr-review/config.json` exists and contains a `severity_floor` key, drop any finding whose `severity` is strictly below it. Apply AFTER step 4 so a downgraded finding can also be floored. Ordering: `low` < `medium` < `high`. With `severity_floor: medium`, LOW findings are removed entirely; HIGH and MEDIUM survive. Use `jq -r '.severity_floor // empty' /tmp/pr-review/config.json` to read it; comparisons are case-insensitive on the floor value (severity values in findings are already uppercase).
6. **Comment Shape Check**: For every surviving finding, ensure `title` (bold headline ≤60 chars, no trailing punctuation), `description` (issue only, no fix prescribed), and `fix` (recommended change in prose) are all populated. Rewrite minimally if an angle agent collapsed everything into `description` — split it into the three fields. Keep `suggestion` only when a verbatim replacement snippet is safe.

Write the final validated JSON array to /tmp/pr-review/findings.json.

### Step 3 — Post Native PR Review
Follow _header.md exactly. Compute BLOCKING_COUNT, NONBLOCKING_COUNT, HIGH_COUNT, MEDIUM_COUNT, LOW_COUNT. Build STATUS_LINE.
- Use the findings from /tmp/pr-review/findings.json.
- Submit a single native GitHub PR Review (Batch) including all inline comments and the summary/status line.
- Determine review event: APPROVE (0 findings), REQUEST_CHANGES (blocking > 0), or COMMENT (non-blocking > 0). The REQUEST_CHANGES event is the only blocking signal — do not apply or remove labels.
- **DO NOT** update the PR description, title, or labels.
