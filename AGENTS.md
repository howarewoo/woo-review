# Agent Mandates: building woo-review

This document defines the rules and workflows for AI agents (Gemini CLI, Claude Code, etc.) contributing to the `woo-review` project.

## Project Context
`woo-review` is a high-speed, parallelized GitHub Action for agentic PR reviews. It uses GHA Matrix to run multiple specialized auditors (Optimists) and a final Skeptical Validator pass.

## Tech Stack
- **Orchestration**: GitHub Actions (YAML), Bash (`scripts/`).
- **Prompt Engineering**: Markdown (`prompts/`).
- **Audit Tools**: Node.js/npx (`react-doctor`, `impeccable`).
- **Testing**: Bats-style Bash tests (`tests/`), GHA Self-tests.

## Agent Mandates

### 1. Maintain the Parallel Contract
The 2026 architecture depends on a strict 3-stage pipeline (Detect -> Matrix -> Validate).
- **NEVER** introduce sequential dependencies between matrix jobs.
- **ALWAYS** communicate via artifacts in `/tmp/pr-review/`.
- **ALWAYS** follow the JSON schema in `prompts/_header.md` for findings.

### 2. Prompt Synchronization
`woo-review` supports multiple providers (Anthropic, OpenAI, Google, OpenRouter).
- When adding or renaming a review angle, you **MUST** update all orchestrator prompts:
  - `prompts/anthropic.md`
  - `prompts/openai.md`
  - `prompts/google.md`
  - `prompts/opencode.md`
- Ensure the `angle` enum in `prompts/_header.md` is updated.

### 3. Testing Protocol
- **Unit Tests**: Run `bash tests/detect-angles.test.sh` after modifying `scripts/detect-angles.sh`.
- **Integration**: Verify changes via `.github/workflows/self-test.yml` by simulating a PR environment.
- **Reproductions**: Before fixing a bug in the review logic, create a test case in `tests/` that fails.

### 4. Tool Integration
- Only add new tools if they support `--json` output or can be reliably parsed via Bash/jq.
- Prefer `npx` for CLI tools to keep the runner environment clean.
- Reference the following tool repositories in documentation:
  - [impeccable](https://github.com/pbakaus/impeccable)
  - [react-doctor](https://github.com/millionco/react-doctor)
  - [seo-audit](https://www.skills.sh/coreyhaines31/marketingskills/seo-audit)

### 5. Architectural Guardrails
- **The Skeptic (Opus 4.7)** is the final authority. Do not move critical logic out of the validation stage if it requires high-reasoning deduplication.
- **The Auditors (Sonnet 4.6)** should remain focused and optimistic. Do not bloat their scopes.
