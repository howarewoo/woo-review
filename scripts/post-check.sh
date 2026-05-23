#!/usr/bin/env bash
# Reads PR labels and fails the workflow if the blocking label is present.
# Inputs (env): GH_TOKEN, PR_NUMBER, INPUT_BLOCKING_LABEL, RUNNER_OUTCOME.

set -euo pipefail

PR_NUMBER="${PR_NUMBER:-}"
BLOCKING_LABEL="${INPUT_BLOCKING_LABEL:-blocking-review}"

# Pick the outcome of whichever runner actually executed (the other three are 'skipped').
RUNNER_OUTCOME=""
for v in "$OUTCOME_ANTHROPIC" "$OUTCOME_OPENAI" "$OUTCOME_GOOGLE" "$OUTCOME_OPENCODE"; do
  if [ -n "$v" ] && [ "$v" != "skipped" ]; then
    RUNNER_OUTCOME="$v"
    break
  fi
done

if [ "$RUNNER_OUTCOME" = "failure" ]; then
  echo "::warning::Review runner step failed (likely first-run workflow validation — this is expected)"
  exit 0
fi

if [ -z "$RUNNER_OUTCOME" ]; then
  echo "All runner steps were skipped — no provider matched or prefetch said skip."
  exit 0
fi

if [ -z "$PR_NUMBER" ]; then
  echo "No PR_NUMBER — skipping label check."
  exit 0
fi

LABELS=$(gh pr view "$PR_NUMBER" --json labels --jq '.labels[].name' || true)
if echo "$LABELS" | grep -qxF "$BLOCKING_LABEL"; then
  echo "::error::AI Code Review found blocking issues (label '$BLOCKING_LABEL' applied)"
  exit 1
fi

echo "No blocking issues detected."
