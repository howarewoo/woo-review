# Agent Mandates: building woo-review

This document defines the rules and workflows for AI agents (Gemini CLI, Claude Code, etc.) contributing to the `woo-review` project.

## Project Context
`woo-review` is primarily an **AI coding-agent skill** (`skills/woo-review/SKILL.md`) that any host (Claude Code, Cursor, Gemini CLI, opencode, …) can invoke via `/woo-review`. The skill spawns one sub-agent per detected review angle, runs a Skeptical Validator, and optionally posts a batched GitHub Review.

The companion GitHub Action (`action.yml` + `.github/workflows/reusable-review.yml`) is an **extension** of the skill — same prompts, same angles, same validator, packaged for CI. When you change one, mirror the change in the other.

## Tech Stack
- **Skill contract**: Markdown (`skills/woo-review/SKILL.md`, the source of truth).
- **Shared prompts**: Markdown (`skills/woo-review/prompts/_header.md`, `skills/woo-review/prompts/angles/*.md`, `skills/woo-review/prompts/validator.md`) — consumed by both the skill and the action.
- **CI orchestration**: GitHub Actions (YAML), Bash (`skills/woo-review/scripts/`).
- **Audit Tools**: Node.js/npx (`react-doctor`, `impeccable`).
- **Testing**: Bash tests (`tests/`), GHA self-tests.

## Agent Mandates

### 1. Maintain the Parallel Contract
The 2026 architecture depends on a strict 3-stage pipeline (Detect -> Fan-out -> Validate). The skill spawns sub-agents in parallel; the action runs them as GHA matrix jobs. Both share the same artifact tree under `/tmp/pr-review/`.
- **NEVER** introduce sequential dependencies between angle workers.
- **ALWAYS** communicate via artifacts in `/tmp/pr-review/`.
- **ALWAYS** follow the JSON schema in `skills/woo-review/prompts/_header.md` for findings.
- **ALWAYS** keep the skill (`skills/woo-review/SKILL.md`) and the action in sync — the skill is the source of truth; the action is its CI extension.

### 2. Prompt Synchronization
`woo-review` supports multiple providers (Anthropic, OpenAI, Google, OpenRouter).
- When adding or renaming a review angle, you **MUST** update all orchestrator prompts:
  - `skills/woo-review/prompts/anthropic.md`
  - `skills/woo-review/prompts/openai.md`
  - `skills/woo-review/prompts/google.md`
  - `skills/woo-review/prompts/opencode.md`
- Ensure the `angle` enum in `skills/woo-review/prompts/_header.md` is updated.

### 3. Testing Protocol
- **Unit Tests**: Run `bash tests/detect-angles.test.sh` after modifying `skills/woo-review/scripts/detect-angles.sh`.
- **Integration**: Verify changes via `.github/workflows/self-test.yml` by simulating a PR environment.
- **Reproductions**: Before fixing a bug in the review logic, create a test case in `tests/` that fails.

### 4. Tool Integration
- Only add new tools if they support `--json` output or can be reliably parsed via Bash/jq.
- Prefer `npx` for CLI tools to keep the runner environment clean.
- Reference the following tool repositories in documentation:
  - [impeccable](https://github.com/pbakaus/impeccable)
  - [react-doctor](https://github.com/millionco/react-doctor)
  - [seo-audit](https://www.skills.sh/coreyhaines31/marketingskills/seo-audit)

### 5. Skills CLI Compatibility
- Always maintain the `skills/` directory structure with `SKILL.md` files.
- Ensure `skills.sh.json` at the root is updated when new skills are added or renamed.
- Use YAML frontmatter in `SKILL.md` for consistent metadata on [skills.sh](https://skills.sh).

### 6. Architectural Guardrails
- **The Skeptic (Opus 4.7)** is the final authority. Do not move critical logic out of the validation stage if it requires high-reasoning deduplication.
- **The Auditors (Sonnet 4.6)** should remain focused and optimistic. Do not bloat their scopes.
- **Output**: Always use the native GitHub PR Review API (batched) for final feedback. Avoid posting individual comments outside of a review.
