# Parallel PR Review Architecture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transition to a parallel matrix-based PR review architecture with a Skeptical Validator to increase speed and accuracy.

**Architecture:** A three-stage GHA pipeline (Detect -> Matrix Parallel Audit -> Skeptical Validation) using artifact hand-off and specialized model mapping (Claude Opus 4.7, Gemini 3.5 Flash).

**Tech Stack:** GitHub Actions (Composite + Reusable Workflows), Shell, Python, Anthropic/Google/OpenAI APIs.

---

### Task 1: Skeptical Validator Prompt

**Files:**
- Create: `prompts/validator.md`

- [ ] **Step 1: Create the validator prompt file**
Create `prompts/validator.md` with instructions for the "Defense Attorney" persona to dedupe and invalidate findings.

```markdown
# Skeptical Validator Agent

You are a Senior Software Engineer acting as a "Defense Attorney" for the code under review. Your goal is to maximize accuracy by discarding low-value or false-positive findings from optimistic "Angle Agents."

## Input Artifacts
- **Diff**: `/tmp/pr-review/diff.txt`
- **Rules**: `/tmp/pr-review/rules.md`
- **Raw Findings**: `/tmp/pr-review/raw_findings.json` (Concatenated array from all angles)

## Your Task
1. **Deduplicate**: If multiple angles flagged the same issue, pick the one with the most actionable and technical description.
2. **Skeptical Audit**: For each finding, try to prove it is WRONG. 
   - Discard if: Pedantic, style-only (without rule backing), already caught by linting, or "maybe" behavior.
   - Keep if: Concrete bug, security risk, or objective rule violation.
3. **Severity Check**: You can downgrade severity (HIGH -> MEDIUM) or unset `blocking: true` -> `false`. You may NOT upgrade.

## Output
Write the final validated JSON array to `/tmp/pr-review/findings.json`.
```

- [ ] **Step 2: Commit**
```bash
git add prompts/validator.md
git commit -m "feat(prompts): add skeptical validator prompt"
```

---

### Task 2: Findings Merge Script

**Files:**
- Create: `scripts/merge-findings.sh`

- [ ] **Step 1: Write the merge script**
Create a script to concatenate all `findings.*.json` files into a single `raw_findings.json` array.

```bash
#!/usr/bin/env bash
set -euo pipefail

OUTDIR="/tmp/pr-review"
MERGED_FILE="$OUTDIR/raw_findings.json"

echo "[]" > "$MERGED_FILE"

# Find all findings files from matrix jobs
shopt -s nullglob
FILES=("$OUTDIR"/findings.*.json)

if [ ${#FILES[@]} -eq 0 ]; then
  echo "No findings found to merge."
  exit 0
fi

# Merge using jq
jq -s 'add' "${FILES[@]}" > "$MERGED_FILE"
echo "Merged ${#FILES[@]} finding files into $MERGED_FILE"
```

- [ ] **Step 2: Make executable and test with dummy data**
```bash
chmod +x scripts/merge-findings.sh
mkdir -p /tmp/pr-review
echo '[{"id": 1}]' > /tmp/pr-review/findings.bugs.json
echo '[{"id": 2}]' > /tmp/pr-review/findings.react.json
./scripts/merge-findings.sh
jq . /tmp/pr-review/raw_findings.json # Should show both IDs
```

- [ ] **Step 3: Commit**
```bash
git add scripts/merge-findings.sh
git commit -m "feat(scripts): add findings merge utility"
```

---

### Task 3: Matrix-Aware Angle Detection

**Files:**
- Modify: `scripts/detect-angles.sh`

- [ ] **Step 1: Update detect-angles to output JSON array**
Modify the script to output a JSON array string to `$GITHUB_OUTPUT` for GHA `strategy.matrix.angle`.

```bash
# ... existing logic to build ANGLES array ...
CSV=$(IFS=,; echo "${ANGLES[*]}")
JSON_ARRAY=$(printf '%s\n' "${ANGLES[@]}" | jq -R . | jq -s -c .)

echo "angles=$CSV" >> "$GITHUB_OUTPUT"
echo "angles_json=$JSON_ARRAY" >> "$GITHUB_OUTPUT"
```

- [ ] **Step 2: Verify output**
Run the script locally (mocking environment) and check `angles_json` value.

- [ ] **Step 3: Commit**
```bash
git add scripts/detect-angles.sh
git commit -m "feat(scripts): update detect-angles for GHA matrix support"
```

---

### Task 4: Refactor `action.yml` for Multi-Mode

**Files:**
- Modify: `action.yml`

- [ ] **Step 1: Add `mode` input**
Add an input `mode` with options `full` (default), `detect`, `review`, `validate`.

```yaml
inputs:
  mode:
    description: 'Execution mode: full (sequential) | detect | review | validate'
    required: false
    default: 'full'
  angle:
    description: 'Specific angle to run (required if mode=review)'
    required: false
    default: ''
```

- [ ] **Step 2: Gate steps by `mode`**
Wrap current steps in `if: inputs.mode == 'full' || inputs.mode == '...'` logic.

- [ ] **Step 3: Add Validator step logic**
Add logic to invoke the selected provider with the `prompts/validator.md` if `mode == 'validate'`.

- [ ] **Step 4: Commit**
```bash
git add action.yml
git commit -m "refactor(action): support multi-mode execution for matrix parallelism"
```

---

### Task 5: Reusable Workflow Template

**Files:**
- Create: `.github/workflows/reusable-review.yml`

- [ ] **Step 1: Create the reusable workflow**
Define the 3-job pipeline that uses the `action.yml` in different modes.

```yaml
name: Parallel AI Review
on:
  workflow_call:
    inputs:
      provider: { type: string, required: true }
      # ... other inputs ...

jobs:
  detect:
    runs-on: ubuntu-latest
    outputs:
      angles: ${{ steps.woo.outputs.angles_json }}
    steps:
      - uses: actions/checkout@v4
      - id: woo
        uses: ./ # Use local action
        with:
          mode: detect

  review:
    needs: detect
    runs-on: ubuntu-latest
    strategy:
      matrix:
        angle: ${{ fromJson(needs.detect.outputs.angles) }}
    steps:
      - uses: actions/checkout@v4
      - uses: ./
        with:
          mode: review
          angle: ${{ matrix.angle }}
      - uses: actions/upload-artifact@v4
        with:
          name: findings-${{ matrix.angle }}
          path: /tmp/pr-review/findings.${{ matrix.angle }}.json

  validate:
    needs: review
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/download-artifact@v4
        with:
          pattern: findings-*
          path: /tmp/pr-review/
          merge-multiple: true
      - uses: ./
        with:
          mode: validate
```

- [ ] **Step 2: Commit**
```bash
git add .github/workflows/reusable-review.yml
git commit -m "feat(ci): add reusable workflow for parallel matrix reviews"
```
