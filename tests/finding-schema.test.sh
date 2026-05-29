#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HEADER="$REPO_ROOT/skills/woo-review/prompts/_header.md"

fail=0

# Cross-PR memory file must appear in the prefetched-artifacts section.
if ! grep -q 'memory.md' "$HEADER"; then
  echo "FAIL: $HEADER missing memory.md artifact bullet"
  fail=1
fi

# The dedup-only fields must be gone from the schema example (the cross-PR
# dedup feature was removed in favour of the plain-markdown memory file).
if awk '/^```json/,/^```$/' "$HEADER" | grep -q '"semantic_key"\|"code_anchor"'; then
  echo "FAIL: semantic_key/code_anchor must not appear in the JSON schema example"
  fail=1
fi

[ "$fail" -eq 0 ] && echo "All finding-schema tests passed."
exit "$fail"
