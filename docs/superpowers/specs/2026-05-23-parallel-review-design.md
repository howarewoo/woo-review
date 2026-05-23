# Spec: Parallel PR Review Architecture (Matrix + Validator)

- **Date**: 2026-05-23
- **Status**: Draft
- **Topic**: Parallelizing AI PR reviews for speed and accuracy using GHA Matrix and a specialized Validator agent.

## Goals
- **Speed**: Run multiple review angles (bugs, security, SEO, design, react) concurrently.
- **Accuracy**: Use a "Skeptical Validator" agent to dedupe findings and eliminate false positives.
- **Cost/Model Optimization**: Match task complexity to model capability (e.g., Opus 4.7 for validation, Flash 3.5 for SEO).

## Architecture

The workflow is split into a three-stage pipeline.

### Stage 1: Dispatcher (`detect`)
- **Action**: Runs `scripts/detect-angles.sh`.
- **Output**: A JSON array of enabled angles based on the diff (e.g., `["bugs", "security", "react"]`).

### Stage 2: Parallel Audits (`review`, Matrix)
- **Concurrency**: One job per angle in the `detect` output.
- **Execution**: 
  - Each job is "optimistic" and focuses only on its assigned angle.
  - Results are written to `/tmp/pr-review/findings.<angle>.json`.
- **Artifacts**: Each job uploads its findings file as a GHA artifact named `findings-<angle>`.
- **Model Mapping**:
  - `bugs`, `security` -> Claude Opus 4.7 / GPT-5.5
  - `design`, `react` -> Claude Sonnet 4.6
  - `seo` -> Gemini 3.5 Flash

### Stage 3: The Validator (`validate`)
- **Dependency**: Waits for all `review` jobs to complete.
- **Action**: Downloads all artifacts into a unified directory.
- **Persona**: "Skeptical Auditor / Defense Attorney".
- **Tasks**:
  1. **Validation**: Attempt to prove each finding is a false positive; discard "maybe" or pedantic issues.
  2. **Deduplication**: Merge overlapping findings from different angles.
  3. **Severity Check**: Final authority on `blocking` status (can downgrade, cannot upgrade).
- **Posting**: The Validator (or a final script) posts the surviving inline comments and updates the PR status/labels.

## Data Exchange Protocol
- **Format**: Standardized JSON array (as defined in `prompts/_header.md`).
- **Storage**: GHA Artifacts with `merge-multiple: true` during download.

## New Components
1. **`prompts/validator.md`**: New system prompt for the skeptical audit.
2. **Matrix Logic in `action.yml`**: Refactor the composite action or move to a workflow template.
3. **`scripts/merge-findings.sh`**: Utility to concatenate raw findings for the Validator.

## Success Criteria
- PR review duration reduced by >40% for multi-angle diffs.
- False positive rate (comments marked as "not helpful" or ignored) decreased.
- No redundant/duplicate comments posted to the same line.
