# Split Design Agents and Synchronize Orchestration Prompts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the split of Design agents and synchronize orchestration prompts across all providers.

**Architecture:** Update per-angle prompts for `design-audit` and `design-critique` to use the same `npx impeccable detect --json` baseline, and synchronize all orchestration layer files to handle these specific angles.

**Tech Stack:** Bash, Markdown, Node.js (npx), Impeccable CLI.

---

### Task 1: Update Design Angle Prompts

**Files:**
- Modify: `prompts/angles/design-audit.md`
- Modify: `prompts/angles/design-critique.md`

- [ ] **Step 1: Update `design-audit.md` to use `detect --json`**

```markdown
# Angle: Design Audit

**Scope.** Perform a structured, quantitative audit of UI changes using the Impeccable tool. Read `/tmp/pr-review/diff.txt` and the changed source files referenced in `/tmp/pr-review/meta.json`.

## Step 1 — Run Impeccable detect

Run the [pbakaus/impeccable](https://github.com/pbakaus/impeccable) detection tool via npx:

```bash
IMPECCABLE_VERSION="${IMPECCABLE_VERSION:-latest}"
mkdir -p /tmp/pr-review
# Collect changed design-relevant files into a list
jq -r '.files[].path' /tmp/pr-review/meta.json \
  | grep -E '\.(tsx|jsx|vue|svelte|html|css|scss|sass|less|styl|astro)$' \
  > /tmp/pr-review/design-audit-files.txt || true

if [ -s /tmp/pr-review/design-audit-files.txt ]; then
  # Pass changed files to impeccable detect; --json output for parsing.
  xargs -a /tmp/pr-review/design-audit-files.txt -r \
    npx -y "impeccable@${IMPECCABLE_VERSION}" detect --json \
    > /tmp/pr-review/impeccable-detect.json 2>/tmp/pr-review/impeccable-detect.err || \
    echo "impeccable detect exited non-zero — continuing with empty findings"
fi
```

Parse `/tmp/pr-review/impeccable-detect.json`. Focus on structured scoring across 5 dimensions:
...
```

- [ ] **Step 2: Update `design-critique.md` to use `detect --json`**

```markdown
# Angle: Design Critique

**Scope.** Perform a qualitative critique of UI changes based on design heuristics and cognitive load. Read `/tmp/pr-review/diff.txt` and the changed source files referenced in `/tmp/pr-review/meta.json`.

## Step 1 — Run Impeccable detect

Try running the Impeccable detection tool:

```bash
IMPECCABLE_VERSION="${IMPECCABLE_VERSION:-latest}"
mkdir -p /tmp/pr-review
jq -r '.files[].path' /tmp/pr-review/meta.json \
  | grep -E '\.(tsx|jsx|vue|svelte|html|css|scss|sass|less|styl|astro)$' \
  > /tmp/pr-review/design-critique-files.txt || true

if [ -s /tmp/pr-review/design-critique-files.txt ]; then
  xargs -a /tmp/pr-review/design-critique-files.txt -r \
    npx -y "impeccable@${IMPECCABLE_VERSION}" detect --json \
    > /tmp/pr-review/impeccable-detect.json 2>/tmp/pr-review/impeccable-detect.err || \
    echo "impeccable detect exited non-zero — falling back to LLM-only critique"
fi
```

If `impeccable detect` fails or returns no data, proceed with LLM-only critique.
...
```

- [ ] **Step 3: Commit**

```bash
git add prompts/angles/design-audit.md prompts/angles/design-critique.md
git commit -m "refactor(prompts): update design angles to use impeccable detect"
```

### Task 2: Synchronize Orchestrator Prompts

**Files:**
- Modify: `prompts/anthropic.md`
- Modify: `prompts/openai.md`
- Modify: `prompts/google.md`
- Modify: `prompts/opencode.md`

- [ ] **Step 1: Update `prompts/anthropic.md`**
Remove special case for `design` in Step 2.

- [ ] **Step 2: Update `prompts/openai.md`**
Remove special case for `design` in Phase 2.

- [ ] **Step 3: Update `prompts/google.md`**
Remove special case for `design` in Phase 2.

- [ ] **Step 4: Update `prompts/opencode.md`**
Remove special case for `design` in Phase 2.

- [ ] **Step 5: Commit**

```bash
git add prompts/anthropic.md prompts/openai.md prompts/google.md prompts/opencode.md
git commit -m "chore(prompts): sync orchestrators for split design angles"
```

### Task 3: Update Shared Header and Docs

**Files:**
- Modify: `prompts/_header.md`
- Modify: `scripts/detect-angles.sh`

- [ ] **Step 1: Update `prompts/_header.md`**
Update Review Angles table and Findings Schema `angle` enum.

- [ ] **Step 2: Update `scripts/detect-angles.sh`**
Update header comment.

- [ ] **Step 3: Commit**

```bash
git add prompts/_header.md scripts/detect-angles.sh
git commit -m "docs: update shared header and scripts for split design angles"
```

### Task 4: Verification

- [ ] **Step 1: Verify all files for consistency**
Run `grep -r "design" prompts/` to ensure no stale references to the single `design` angle remain where they shouldn't.
- [ ] **Step 2: Run self-test if available**
Run `tests/detect-angles.test.sh`.
