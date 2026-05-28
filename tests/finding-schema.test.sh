#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HEADER="$REPO_ROOT/skills/woo-review/prompts/_header.md"

fail=0
for field in semantic_key code_anchor sidecar-findings.json; do
  if ! grep -q "$field" "$HEADER"; then
    echo "FAIL: $HEADER missing required token '$field'"
    fail=1
  fi
done

if ! awk '/^```json/,/^```$/' "$HEADER" | grep -q '"semantic_key"'; then
  echo "FAIL: semantic_key not present in JSON schema example"
  fail=1
fi
if ! awk '/^```json/,/^```$/' "$HEADER" | grep -q '"code_anchor"'; then
  echo "FAIL: code_anchor not present in JSON schema example"
  fail=1
fi

[ "$fail" -eq 0 ] && echo "PASS finding-schema.test.sh"
exit "$fail"
