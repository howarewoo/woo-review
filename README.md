# woo-review

Reusable GitHub Action that runs an agentic AI pull request review and dispatches to the **first-party action of your chosen provider**. Optimized for the **May 2026** AI landscape, it uses a parallel matrix-based architecture with a "Skeptical Validator" to deliver maximum speed and accuracy.

## Architecture: The Parallel Pipeline

Unlike traditional sequential reviewers, `woo-review` uses a three-stage parallel pipeline. For mandates on how AI agents should build and maintain this project, see [AGENTS.md](./AGENTS.md). For details on the internal review-swarm architecture, see the [Architecture Spec](./docs/superpowers/specs/2026-05-23-review-swarm-architecture.md).

1.  **Detect (Dispatcher)**: Analyzes the diff to identify relevant **Review Angles** (Bugs, Security, SEO, etc.).
2.  **Review (Matrix)**: Dispatches $N$ specialized agents in parallel via GitHub Actions Matrix. Each agent focuses on a single "Optimistic Audit" of its assigned angle.
3.  **Validate (Skeptical Auditor)**: A high-reasoning **Skeptical Validator** agent (Claude Opus 4.7) collects all findings, dedupes them, and performs a "defense attorney" audit to eliminate noise and false positives.

```mermaid
graph TD
    %% Stage 1: Detection
    Trigger[PR Event / Comment] --> Prefetch[Prefetch: Diff, Rules, Meta]
    Prefetch --> Detect[1. Detect: dispatcher job]
    
    Detect -- "angles_json" --> Matrix_Start{Matrix Fan-out}
    Detect -- "Artifact: review-artifacts" --> Storage[(GHA Artifact Storage)]

    %% Stage 2: Parallel Matrix
    subgraph Parallel_Audits [2. Matrix: Parallel Angle Jobs]
        direction TB
        
        subgraph Logic_Audits [Logic & Security]
            direction LR
            Bugs[bugs<br/>Sonnet 4.6]
            Security[security<br/>Sonnet 4.6]
        end
        
        subgraph UI_UX_Audits [Design & Frontend]
            direction LR
            D_Audit[design-audit<br/>Sonnet 4.6 + Impeccable]
            D_Critique[design-critique<br/>Sonnet 4.6 + Heuristics]
            React[react<br/>Sonnet 4.6 + React-Doctor]
        end
        
        subgraph Speed_Audits [Metadata & SEO]
            direction LR
            SEO[seo<br/>Flash 3.5]
        end
    end

    Matrix_Start --> Bugs
    Matrix_Start --> Security
    Matrix_Start --> D_Audit
    Matrix_Start --> D_Critique
    Matrix_Start --> React
    Matrix_Start --> SEO
    
    Storage -.-> Bugs
    Storage -.-> Security
    Storage -.-> D_Audit
    Storage -.-> D_Critique
    Storage -.-> React
    Storage -.-> SEO

    %% Stage 3: Fan-in & Validation
    Bugs --> Findings_Group
    Security --> Findings_Group
    D_Audit --> Findings_Group
    D_Critique --> Findings_Group
    React --> Findings_Group
    SEO --> Findings_Group

    Findings_Group{Matrix Fan-in} -- "Artifacts: findings-*" --> Merge[Merge: raw_findings.json]
    
    Merge --> Validate[3. Validate: Skeptical Validator<br/>Opus 4.7]
    
    subgraph Validator_Internal [Internal Logic]
        direction TB
        Dedupe[Deduplication] --> Skeptical[Skeptical Audit]
        Skeptical --> Severity[Severity Verification]
    end
    
    Validate --> Validator_Internal

    %% Stage 4: Output
    Validator_Internal -- "findings.json" --> Post[4. Post Results]
    
    subgraph Output_Actions [Final Actions]
        direction LR
        Comments[Inline Comments<br/>gh api]
        Status[PR Body Summary<br/>STATUS_LINE]
        Labels[blocking-review label<br/>gh pr edit]
    end
    
    Post --> Output_Actions
```

## Features

-   **Maximum Speed**: Parallel execution via GHA Matrix reduces review time by up to 80% for complex PRs.
-   **High Accuracy**: Skeptical Validator pass eliminates "hallucinated" nits and pedantic suggestions.
-   **Model Optimization**: Automatically maps tasks to the best 2026 models (Opus 4.7 for reasoning, Flash 3.5 for speed).
-   **Multi-Provider**: Supports Anthropic, OpenAI, Google, and OpenRouter.
-   **Integrated Tooling**: Runs [react-doctor](https://github.com/millionco/react-doctor) and [impeccable](https://github.com/pbakaus/impeccable) (visual audit) natively within the agentic loop.

## Prerequisites & Dependencies

To ensure maximum speed and accuracy, `woo-review` relies on the following environment:

### GitHub Action Dependencies
- **Runner**: `ubuntu-latest` is recommended (includes `gh` and `jq`).
- **GitHub CLI (`gh`)**: Required for posting inline comments and managing PR labels.
- **`jq`**: Required for JSON-based finding aggregation.
- **Node.js 22+**: Automatically installed when `design-audit`, `design-critique`, or `react` angles are active to support [impeccable](https://github.com/pbakaus/impeccable) and [react-doctor](https://github.com/millionco/react-doctor).
- **2026 Flagship Models**: Access to **Claude 4.7+**, **GPT-5.5+**, or **Gemini 3.5+** is required for the Skeptical Validator and specialized audit agents.

### AI Skill Dependencies
- **Agent**: Requires [Gemini CLI](https://github.com/google-gemini/gemini-cli) or [Claude Code](https://docs.anthropic.com/en/docs/agents-and-tools/claude-code).
- **Workspace**: The `woo-review` skill (found in `skills/woo-review/`) should be active in your local development environment.
- **Frameworks**: The SEO agent follows the [coreyhaines31/seo-audit](https://www.skills.sh/coreyhaines31/marketingskills/seo-audit) framework for comprehensive search-engine analysis.

## Quickstart (Recommended: Parallel Mode)

To get the full benefit of parallelism, use the provided **Reusable Workflow**:

```yaml
# .github/workflows/ai-review.yml
name: AI PR Review
on:
  pull_request:
    types: [opened, reopened, ready_for_review]
  issue_comment:
    types: [created]

jobs:
  review:
    uses: howarewoo/woo-review/.github/workflows/reusable-review.yml@main
    with:
      provider: anthropic
    secrets:
      # Map your preferred provider secret
      anthropic_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

## Angles

| Angle | Always-on | Detection trigger | Tooling |
|---|---|---|---|
| `bugs` | yes | — | LLM only |
| `security` | yes | — | LLM only |
| `seo` | no | `*.html`, `head.{ts,tsx}`, `layout.{ts,tsx}`, `robots.txt`, `sitemap.{xml,ts}`, `next.config.*`, `app/manifest.*`, OR diff tokens | LLM only |
| `design` | no | `*.{tsx,jsx,vue,svelte,html,css,scss,sass,less,styl,astro}` | LLM + `impeccable detect` |
| `react` | no | `*.{tsx,jsx}` AND `react` dep in `package.json` | `react-doctor` + LLM |

## Provider Support (May 2026 Flagships)

`woo-review` defaults to the latest state-of-the-art models for maximum reliability.

| Provider | Default Worker Model | Default Validator Model | Key inputs |
|---|---|---|---|
| `anthropic` | `claude-sonnet-4-6` | `claude-opus-4-7` | `anthropic_token` |
| `openai` | `gpt-5-5-instant` | `gpt-5-5` | `openai_api_key` |
| `google` | `gemini-3-5-flash` | `gemini-3-1-pro` | `google_api_key` |
| `openrouter` | `sonnet-4-6` | `opus-4-7` | `openrouter_api_key` |

## Inputs & Configuration

| Name | Default | Notes |
|---|---|---|
| `mode` | `full` | `full` (sequential), `detect`, `review`, or `validate`. Reusable workflow handles this automatically. |
| `provider` | `""` | `anthropic`, `openai`, `google`, `openrouter`. |
| `blocking_label` | `blocking-review` | Label applied when a blocking finding is detected. |
| `disable_angles` | `""` | Comma-separated list of optional angles to skip (`seo`, `design`, `react`). |
| `max_turns` | `30` | Turn cap for agentic loops. |

## Rules and Style Guides

The action reads `constitution.md` from your repo root plus every `CLAUDE.md` file in the directories touched by the PR. They are concatenated and fed to the reviewer as the primary source of truth for "Project Norms."

## Output

1.  **Inline Comments**: Posted via `gh api` with optional `suggestion` blocks.
2.  **Status Line**: A bold summary in the PR body (e.g., `**Status: CHANGES REQUESTED** — 2 blocking findings`).
3.  **Blocking Label**: Adds `blocking-review` to the PR if critical issues are found, allowing you to gate merges via branch protection rules.

## Security

When using `pull_request_target` (write-scope event), always pin the action to a full commit SHA to prevent supply-chain attacks.

## License

MIT.
