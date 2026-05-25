# Design: Split Design Agents and Synchronize Orchestration Prompts

Fix the split of Design agents (`design-audit` and `design-critique`) and synchronize orchestration prompts across all providers.

## Goals

1.  Revert `design-audit.md` and `design-critique.md` to use `npx impeccable detect --json` as the baseline.
2.  Update all orchestration layer prompts (`anthropic.md`, `openai.md`, `google.md`, `opencode.md`) to handle `design-audit` and `design-critique` instead of the legacy `design` angle.
3.  Update the shared `_header.md` to reflect the new angles in the "Review Angles" table and "Findings Schema".
4.  Update `scripts/detect-angles.sh` header documentation.
5.  Verify consistency across the system.

## Proposed Changes

### 1. Angle Prompts

#### `prompts/angles/design-audit.md`
- Replace `npx impeccable audit --json` with `npx impeccable detect --json`.
- The `detect` command provides a JSON report that we will use for quantitative audit.

#### `prompts/angles/design-critique.md`
- Replace `npx impeccable critique --json` with `npx impeccable detect --json`.
- The `detect` command provides a JSON report that serves as a baseline for qualitative LLM critique.

### 2. Orchestration Layer

#### `prompts/anthropic.md`, `prompts/openai.md`, `prompts/google.md`, `prompts/opencode.md`
- Remove any special-case logic for the `design` angle.
- Ensure they correctly iterate over `design-audit` and `design-critique`.
- Specifically, the Anthropic orchestrator (Step 2) needs to launch subagents for both if enabled.

### 3. Shared Header

#### `prompts/_header.md`
- Update the "Review Angles" table:
  - Remove `design`.
  - Add `design-audit` and `design-critique`.
- Update the `angle` enum in "Findings Schema" to include `design-audit | design-critique`.

### 4. Documentation

#### `scripts/detect-angles.sh`
- Update the header comment listing the angles to include `design-audit` and `design-critique`.

## Verification Plan

- Check that all orchestration prompts no longer mention the `design` angle.
- Check that all orchestration prompts mention/handle `design-audit` and `design-critique`.
- Validate the `npx` commands in the angle prompts.
- Ensure `_header.md` is consistent with `detect-angles.sh`.
