#!/usr/bin/env bash
# Loads the prompt for the resolved provider.
# Source order: INPUT_PROMPT_OVERRIDE (consumer-repo path) → ACTION_PATH/prompts/<provider>.md.
# Always prepends ACTION_PATH/prompts/_header.md for output-contract parity.
# Inputs (env): PROVIDER, ACTION_PATH, INPUT_PROMPT_OVERRIDE, PR_NUMBER, GITHUB_REPOSITORY, EVENT_NAME, COMMENT_BODY.
# Writes a multi-line `prompt` output via the delimited-heredoc form.

set -euo pipefail

PROVIDER="${PROVIDER:?PROVIDER env var required}"
ACTION_PATH="${ACTION_PATH:?ACTION_PATH env var required}"
OVERRIDE="${INPUT_PROMPT_OVERRIDE:-}"

HEADER_FILE="$ACTION_PATH/prompts/_header.md"
if [ -n "$OVERRIDE" ] && [ -f "$OVERRIDE" ]; then
  BODY_FILE="$OVERRIDE"
  echo "Loading custom prompt from $OVERRIDE"
else
  BODY_FILE="$ACTION_PATH/prompts/${PROVIDER}.md"
  echo "Loading bundled prompt for $PROVIDER"
fi

if [ ! -f "$BODY_FILE" ]; then
  echo "::error::Prompt file not found: $BODY_FILE"
  exit 1
fi

# Render templated context.
CONTEXT_HEAD=$(cat <<CTX_EOF
# Review Context

- Repository: ${GITHUB_REPOSITORY:-unknown}
- PR Number: ${PR_NUMBER:-unknown}
- Trigger event: ${EVENT_NAME:-unknown}
- Comment body (populated only for issue_comment trigger): ${COMMENT_BODY:-}

CTX_EOF
)

PROMPT_CONTENT=$(printf '%s\n\n%s\n\n%s\n' "$CONTEXT_HEAD" "$(cat "$HEADER_FILE")" "$(cat "$BODY_FILE")")

BYTES=$(printf '%s' "$PROMPT_CONTENT" | wc -c)
echo "Loaded prompt size: $BYTES bytes"
if [ "$BYTES" -gt 200000 ]; then
  echo "::warning::Prompt is large ($BYTES bytes). Some runners may truncate."
fi

# Emit via delimited heredoc to preserve newlines + arbitrary content.
DELIM="EOF_$(date +%s)_$$"
{
  echo "prompt<<$DELIM"
  printf '%s\n' "$PROMPT_CONTENT"
  echo "$DELIM"
} >> "$GITHUB_OUTPUT"
