#!/usr/bin/env bash
# Detects which provider to use based on inputs.
# Precedence: explicit INPUT_PROVIDER → first non-empty API key (anthropic → openai → google → openrouter).
# Writes `provider=...` to $GITHUB_OUTPUT, or exits 1 if none resolvable.

set -euo pipefail

PROVIDER="${INPUT_PROVIDER:-}"

if [ -z "$PROVIDER" ]; then
  if [ -n "${INPUT_ANTHROPIC_TOKEN:-}" ] || [ -n "${INPUT_ANTHROPIC_API_KEY:-}" ]; then
    PROVIDER="anthropic"
  elif [ -n "${INPUT_OPENAI_API_KEY:-}" ]; then
    PROVIDER="openai"
  elif [ -n "${INPUT_GOOGLE_API_KEY:-}" ] || [ -n "${INPUT_GEMINI_API_KEY:-}" ]; then
    PROVIDER="google"
  elif [ -n "${INPUT_OPENROUTER_API_KEY:-}" ]; then
    PROVIDER="openrouter"
  fi
fi

case "$PROVIDER" in
  anthropic|openai|google|openrouter) ;;
  "")
    echo "::error::No provider resolvable. Set 'provider' input or one of: anthropic_token, openai_api_key, google_api_key, openrouter_api_key."
    exit 1
    ;;
  *)
    echo "::error::Unknown provider '$PROVIDER'. Must be one of: anthropic, openai, google, openrouter."
    exit 1
    ;;
esac

echo "provider=$PROVIDER" >> "$GITHUB_OUTPUT"
echo "Resolved provider: $PROVIDER"
