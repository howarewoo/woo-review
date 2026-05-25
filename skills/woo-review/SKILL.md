---
name: woo-review
description: Managed agentic PR reviews with parallel matrix execution and skeptical validation.
install: npx skills add howarewoo/woo-review
requires:
  bins: [gh, jq, node]
---

# woo-review

Managed agentic PR reviews with parallel matrix execution and skeptical validation.

## Overview

Use this skill to manage, trigger, and debug `woo-review` operations. It understands the 2026 parallel architecture (Detect -> Matrix -> Validate) and can help you configure angles, providers, and rules.

## Commands

- `/woo-review` - Run the full agent swarm review locally on the current diff.
- `woo-review install` - Ensure all local dependencies (gh, jq, impeccable, react-doctor) are installed and ready.
- `woo-review status` - Check the current review status and blocking labels.
- `woo-review config` - Configure review angles, models, and providers.

## Local Swarm Execution (`/woo-review`)

When the user invokes `/woo-review`, the agent MUST perform the following multi-step workflow:

### 1. Prefetch & Context
- Ensure `/tmp/pr-review` exists and is clean.
- Generate `/tmp/pr-review/diff.txt` for the current unstaged/staged changes (or `origin/main..HEAD`).
- Generate a mock `/tmp/pr-review/meta.json` containing the current branch info and a summary of changes.
- Copy or symlink project rules (e.g., `CLAUDE.md`) to `/tmp/pr-review/rules.md`.

### 2. Detection
- Run `bash scripts/detect-angles.sh`.
- Read the detected angles from `/tmp/pr-review/angles.txt`.

### 3. Orchestrate Auditors
For each detected angle (e.g., `bugs`, `security`, `design-audit`):
- Read the corresponding prompt from `prompts/angles/<angle>.md`.
- Execute any shell commands specified in the prompt (e.g., `impeccable detect`).
- Perform the LLM audit as described in the prompt.
- Write the findings as a JSON array to `/tmp/pr-review/findings.<angle>.json`.

### 4. Merge & Validate
- Run `bash scripts/merge-findings.sh` to create `/tmp/pr-review/raw_findings.json`.
- Read `prompts/validator.md`.
- Act as the **Skeptical Validator**:
  - Deduplicate and audit the findings.
  - Apply the severity rubric.
  - Produce the final `/tmp/pr-review/findings.json`.

### 5. Report
- Present the final validated findings to the user in a structured format.
- Do NOT attempt to post to GitHub unless explicitly asked; this is a local simulation.

## Architecture Guidelines

This skill enforces the 3-stage parallel pipeline:
1. **Detect**: Identifies review angles (Bugs, Security, SEO, Design, React).
2. **Review**: Dispatches parallel optimistic audits.
3. **Validate**: Runs the **Skeptical Validator** (Claude Opus 4.7) to dedupe and filter.

### Native PR Reviews
As of May 2026, `woo-review` uses native GitHub Pull Request Reviews:
- **Batching**: All inline comments are submitted in a single "Review" event to minimize noise.
- **States**: The system automatically sets the review state to `APPROVE`, `REQUEST_CHANGES`, or `COMMENT` based on the finding severity and blocking status.
- **Scope**: The action is strictly focused on the **Review** event. It does **not** modify the PR title or description.

## Best Practices

- **Speed**: Always prefer the parallel matrix mode for PRs with >3 files.
- **Accuracy**: Trust the Skeptical Validator to filter noise; do not manually disable it.
- **Models**: Ensure `action.yml` uses May 2026 flagships (Opus 4.7, GPT-5.5, Gemini 3.5).

## Configuration

Angles are auto-detected, but you can override them in `action.yml` or via the `disable_angles` input.

```yaml
with:
  disable_angles: "seo,design" # Keep bugs, security, react
```

## Troubleshooting

- **Missing Artifacts**: Ensure the `detect` job is successfully uploading `review-artifacts`.
- **Validation Failures**: Check `/tmp/pr-review/raw_findings.json` to see if worker results were merged correctly.
