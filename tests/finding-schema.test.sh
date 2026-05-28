#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HEADER="$REPO_ROOT/skills/woo-review/prompts/_header.md"

fail=0

# Sidecar filename must appear in the prefetched-artifacts section.
if ! grep -q 'sidecar-findings.json' "$HEADER"; then
  echo "FAIL: $HEADER missing sidecar-findings.json artifact bullet"
  fail=1
fi

# Range matches the findings schema example block. Anchored to line-start
# so an inline ```suggestion``` token inside a string does not close it.
if ! awk '/^```json/,/^```$/' "$HEADER" | grep -q '"semantic_key"'; then
  echo "FAIL: semantic_key not present in JSON schema example"
  fail=1
fi
if ! awk '/^```json/,/^```$/' "$HEADER" | grep -q '"code_anchor"'; then
  echo "FAIL: code_anchor not present in JSON schema example"
  fail=1
fi

[ "$fail" -eq 0 ] && echo "All finding-schema tests passed."
exit "$fail"
