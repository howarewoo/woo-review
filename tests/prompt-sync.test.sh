#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROMPTS_DIR="$REPO_ROOT/skills/woo-review/prompts"

fail=0
for f in anthropic openai google opencode; do
  P="$PROMPTS_DIR/$f.md"
  for tok in semantic_key code_anchor "Host identifier:"; do
    if ! grep -q "$tok" "$P"; then
      echo "FAIL: $P missing required token '$tok'"
      fail=1
    fi
  done
done

HEADER="$PROMPTS_DIR/_header.md"
if ! grep -q 'Host: <host>' "$HEADER"; then
  echo "FAIL: $HEADER credits line missing 'Host: <host>' placeholder (issue #31)"
  fail=1
fi

ANGLES_DIR="$REPO_ROOT/skills/woo-review/prompts/angles"
for P in "$ANGLES_DIR"/*.md; do
  if [ ! -f "$P" ]; then
    continue
  fi
  if ! grep -q '## `semantic_key` values' "$P"; then
    echo "FAIL: $P missing 'semantic_key values' section"
    fail=1
  fi
done

[ "$fail" -eq 0 ] && echo "All prompt-sync tests passed."
exit "$fail"
