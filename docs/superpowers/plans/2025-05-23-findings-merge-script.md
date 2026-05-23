# Findings Merge Script Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a script to concatenate all `findings.*.json` files into a single `raw_findings.json` array.

**Architecture:** Bash script using `jq` to merge multiple JSON arrays into one.

**Tech Stack:** Bash, jq

---

### Task 1: Initialize Script and Write Test

**Files:**
- Create: `scripts/merge-findings.sh`
- Create: `tests/test-merge-findings.sh`

- [ ] **Step 1: Create failing test script**

```bash
#!/usr/bin/env bash
set -euo pipefail

# Setup
TEST_DIR="/tmp/pr-review-test"
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR"

echo '[{"id": 1}]' > "$TEST_DIR/findings.bugs.json"
echo '[{"id": 2}]' > "$TEST_DIR/findings.react.json"

# Run (expecting success but checking output)
OUTDIR="$TEST_DIR" ./scripts/merge-findings.sh

# Verify
RESULT=$(jq '. | length' "$TEST_DIR/raw_findings.json")
if [ "$RESULT" -eq 2 ]; then
  echo "PASS"
else
  echo "FAIL: expected length 2, got $RESULT"
  exit 1
fi
```

- [ ] **Step 2: Create placeholder script**

```bash
#!/usr/bin/env bash
echo "Not implemented"
exit 1
```

- [ ] **Step 3: Run test to verify it fails**

Run: `chmod +x scripts/merge-findings.sh tests/test-merge-findings.sh && ./tests/test-merge-findings.sh`
Expected: FAIL

### Task 2: Implement Merge Logic

**Files:**
- Modify: `scripts/merge-findings.sh`

- [ ] **Step 1: Write implementation**

```bash
#!/usr/bin/env bash
set -euo pipefail

OUTDIR="${OUTDIR:-/tmp/pr-review}"
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

- [ ] **Step 2: Run test to verify it passes**

Run: `./tests/test-merge-findings.sh`
Expected: PASS

### Task 3: Final Verification and Commit

- [ ] **Step 1: Clean up test files**
- [ ] **Step 2: Commit**

```bash
git add scripts/merge-findings.sh
git commit -m "feat(scripts): add findings merge utility"
```
