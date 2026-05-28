#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROMPTS_DIR="$REPO_ROOT/skills/woo-review/prompts"

fail=0
for f in anthropic openai google opencode; do
  P="$PROMPTS_DIR/$f.md"
  for tok in semantic_key code_anchor; do
    if ! grep -q "$tok" "$P"; then
      echo "FAIL: $P missing required token '$tok'"
      fail=1
    fi
  done
done

[ "$fail" -eq 0 ] && echo "All prompt-sync tests passed."
exit "$fail"
