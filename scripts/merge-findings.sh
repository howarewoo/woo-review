#!/usr/bin/env bash
set -euo pipefail

OUTDIR="${OUTDIR:-/tmp/pr-review}"
MERGED_FILE="$OUTDIR/raw_findings.json"

echo "[]" > "$MERGED_FILE"

# Find all findings files from matrix jobs
shopt -s nullglob
FILES=("$OUTDIR"/findings.*.json)

if [ ${#FILES[@]} -eq 0 ]; then
  echo "No findings found to merge."
  exit 0
fi

# Merge using jq
jq -s 'add' "${FILES[@]}" > "$MERGED_FILE"
echo "Merged ${#FILES[@]} finding files into $MERGED_FILE"
