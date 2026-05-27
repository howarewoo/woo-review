#!/usr/bin/env bash
set -euo pipefail

OUTDIR="${OUTDIR:-/tmp/pr-review}"
MERGED_FILE="$OUTDIR/raw_findings.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[]" > "$MERGED_FILE"

# Final findings file is owned by the validator — exclude it from the merge.
# Also exclude prosecutor/defender intermediate files (consumed by the
# intersect step, not the merge step).
shopt -s nullglob
ALL=("$OUTDIR"/findings.*.json)
FILES=()
for f in "${ALL[@]+"${ALL[@]}"}"; do
  case "$f" in
    "$OUTDIR"/findings.json) continue ;;
    "$OUTDIR"/findings.prosecutor.json) continue ;;
    "$OUTDIR"/findings.defender.json) continue ;;
  esac
  FILES+=("$f")
done

if [ ${#FILES[@]} -eq 0 ]; then
  echo "No findings found to merge."
  exit 0
fi

# Robust merge: per-file parse, recover from prose preambles, skip empty /
# unrecoverable, keep only JSON arrays. One bad angle file must not sink the
# whole review.
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
: > "$TMP"

merged_count=0
recovered_count=0
for f in "${FILES[@]}"; do
  if [ ! -s "$f" ]; then
    echo "::warning::Skipping empty findings file: $f"
    continue
  fi
  if jq -e 'type == "array"' "$f" >/dev/null 2>&1; then
    cat "$f" >> "$TMP"
    printf '\n' >> "$TMP"
    merged_count=$((merged_count + 1))
    continue
  fi
  # Prose-preamble recovery. Sub-agents occasionally emit text like
  # "I have completed the review..." before the JSON array. Strip everything
  # before the first `[` and after the matching `]`, then retry jq. Only
  # skip when no JSON array can be extracted at all.
  RECOVERED="$(python3 - "$f" <<'PY' 2>/dev/null || true
import json
import sys

with open(sys.argv[1], "r", errors="replace") as fh:
    text = fh.read()

start = text.find("[")
if start < 0:
    sys.exit(1)

# Walk from the first `[` matching brackets, respecting strings and escapes.
depth = 0
in_str = False
esc = False
end = -1
for i in range(start, len(text)):
    ch = text[i]
    if in_str:
        if esc:
            esc = False
        elif ch == "\\":
            esc = True
        elif ch == '"':
            in_str = False
        continue
    if ch == '"':
        in_str = True
    elif ch == "[":
        depth += 1
    elif ch == "]":
        depth -= 1
        if depth == 0:
            end = i
            break

if end < 0:
    sys.exit(1)

candidate = text[start:end + 1]
try:
    data = json.loads(candidate)
except json.JSONDecodeError:
    sys.exit(1)

if not isinstance(data, list):
    sys.exit(1)

print(json.dumps(data))
PY
)"
  if [ -n "$RECOVERED" ]; then
    printf '%s\n' "$RECOVERED" >> "$TMP"
    merged_count=$((merged_count + 1))
    recovered_count=$((recovered_count + 1))
    echo "::warning::Recovered JSON array from preamble in $f"
    continue
  fi
  echo "::warning::Skipping malformed/non-array findings file: $f"
done

if [ "$merged_count" -eq 0 ]; then
  echo "No usable findings files after validation."
  exit 0
fi

jq -s 'add // []' "$TMP" > "$MERGED_FILE"

# Safety net: drop any finding whose (file, line) cannot be anchored on the
# RIGHT side of the prefetched diff. Catches agents that ignored the
# resolve-diff-line.sh contract in _header.md — without this, the gh api
# POST returns HTTP 422 "Line could not be resolved" and the whole review
# fails. Findings without `file` / `line` pass through (validator handles
# them); only lookups that resolve to "null" are dropped.
#
# Skipped when no diff is present in $OUTDIR (unit tests, hosts that
# invoke merge-findings.sh directly without a prefetched diff) or when the
# resolver script is missing.
DIFF_FOR_RESOLVE=""
if [ -s "$OUTDIR/diff.filtered.txt" ]; then
  DIFF_FOR_RESOLVE="$OUTDIR/diff.filtered.txt"
elif [ -s "$OUTDIR/diff.txt" ]; then
  DIFF_FOR_RESOLVE="$OUTDIR/diff.txt"
fi

if [ -n "$DIFF_FOR_RESOLVE" ] && [ -f "$SCRIPT_DIR/resolve-diff-line.sh" ]; then
  PRE_RESOLVE=$(jq 'length' "$MERGED_FILE")
  TMP_RESOLVED="$(mktemp)"
  trap 'rm -f "$TMP" "$TMP_RESOLVED"' EXIT
  python3 - "$MERGED_FILE" "$TMP_RESOLVED" "$SCRIPT_DIR/resolve-diff-line.sh" "$OUTDIR" <<'PY'
import json
import subprocess
import sys

merged_path, out_path, resolver, outdir = sys.argv[1:5]

with open(merged_path, "r") as fh:
    findings = json.load(fh)

kept = []
dropped = 0
for f in findings:
    path = f.get("file")
    line = f.get("line")
    if not path or line in (None, ""):
        kept.append(f)
        continue
    try:
        res = subprocess.run(
            [
                "bash", resolver,
                "--file", str(path),
                "--line", str(line),
            ],
            env={"OUTDIR": outdir, "PATH": "/usr/local/bin:/usr/bin:/bin"},
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError:
        kept.append(f)
        continue
    if res.stdout.strip() == "null":
        dropped += 1
        continue
    kept.append(f)

with open(out_path, "w") as fh:
    json.dump(kept, fh)

sys.stderr.write(
    f"merge-findings: resolve-diff-line dropped {dropped} finding(s) with unresolvable lines\n"
)
PY
  mv "$TMP_RESOLVED" "$MERGED_FILE"
  POST_RESOLVE=$(jq 'length' "$MERGED_FILE")
  if [ "$PRE_RESOLVE" != "$POST_RESOLVE" ]; then
    echo "Merge: line-resolve safety net dropped $((PRE_RESOLVE - POST_RESOLVE)) finding(s)"
  fi
else
  echo "Merge: line-resolve safety net skipped (no diff at $OUTDIR/diff.txt)"
fi

if [ "$recovered_count" -gt 0 ]; then
  echo "Merge: recovered JSON from $recovered_count file(s) with preamble"
fi

# Issue #14: cross-chunk dedup. When the same angle runs against multiple
# chunks (large-PR fan-out), the same logical finding can land in two
# chunks. Collapse by (angle, file, line, title_stem) — same key as the
# validator's cross-angle dedup, so the two stages agree on identity.
# Cross-ANGLE dedup is intentionally left to the validator; this step only
# folds within-angle duplicates so the validator sees a clean input.
BEFORE_COUNT=$(jq 'length' "$MERGED_FILE")
jq '
  def title_stem(s): (s // "" | ascii_downcase | gsub("[^a-z0-9]+"; ""))[0:40];
  unique_by([
    (.angle // ""),
    (.file // ""),
    (.line // 0 | tonumber? // 0),
    title_stem(.title)
  ])
' "$MERGED_FILE" > "$MERGED_FILE.deduped"
mv "$MERGED_FILE.deduped" "$MERGED_FILE"
AFTER_COUNT=$(jq 'length' "$MERGED_FILE")

echo "Merged $merged_count finding files into $MERGED_FILE (within-angle dedup: $BEFORE_COUNT -> $AFTER_COUNT)"
