# woo-review

Managed agentic PR reviews with parallel matrix execution and skeptical validation.

## Overview

Use this skill to manage, trigger, and debug `woo-review` operations. It understands the 2026 parallel architecture (Detect -> Matrix -> Validate) and can help you configure angles, providers, and rules.

## Commands

- `woo-review review` - Trigger a local review simulation or a remote PR review.
- `woo-review status` - Check the current review status and blocking labels.
- `woo-review config` - Configure review angles, models (Opus 4.7, etc.), and providers.

## Architecture Guidelines

This skill enforces the 3-stage parallel pipeline:
1. **Detect**: Identifies review angles (Bugs, Security, SEO, Design, React).
2. **Review**: Dispatches parallel optimistic audits.
3. **Validate**: Runs the **Skeptical Validator** (Claude Opus 4.7) to dedupe and filter.

### Native PR Reviews
As of May 2026, `woo-review` uses native GitHub Pull Request Reviews:
- **Batching**: All inline comments are submitted in a single "Review" event to minimize noise.
- **States**: The system automatically sets the review state to `APPROVE`, `REQUEST_CHANGES`, or `COMMENT` based on the finding severity and blocking status.
- **Summary**: The Review Body contains the high-level summary and status line, while the PR description contains the full audit details.

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
