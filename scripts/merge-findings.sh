#!/usr/bin/env bash
set -euo pipefail

OUTDIR="${OUTDIR:-/tmp/pr-review}"
MERGED_FILE="$OUTDIR/raw_findings.json"

echo "[]" > "$MERGED_FILE"

# Final findings file is owned by the validator — exclude it from the merge.
shopt -s nullglob
ALL=("$OUTDIR"/findings.*.json)
FILES=()
for f in "${ALL[@]+"${ALL[@]}"}"; do
  case "$f" in
    "$OUTDIR"/findings.json) continue ;;
  esac
  FILES+=("$f")
done

if [ ${#FILES[@]} -eq 0 ]; then
  echo "No findings found to merge."
  exit 0
fi

# Robust merge: per-file parse, skip empty/malformed, keep only JSON arrays.
# One bad angle file must not sink the whole review.
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
: > "$TMP"

merged_count=0
for f in "${FILES[@]}"; do
  if [ ! -s "$f" ]; then
    echo "::warning::Skipping empty findings file: $f"
    continue
  fi
  if ! jq -e 'type == "array"' "$f" >/dev/null 2>&1; then
    echo "::warning::Skipping malformed/non-array findings file: $f"
    continue
  fi
  cat "$f" >> "$TMP"
  printf '\n' >> "$TMP"
  merged_count=$((merged_count + 1))
done

if [ "$merged_count" -eq 0 ]; then
  echo "No usable findings files after validation."
  exit 0
fi

jq -s 'add // []' "$TMP" > "$MERGED_FILE"
echo "Merged $merged_count finding files into $MERGED_FILE"
