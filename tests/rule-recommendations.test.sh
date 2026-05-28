#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/woo-review/scripts/dedup-against-history.sh"
WORK="$(mktemp -d)"
export OUTDIR="$WORK/pr-review"; mkdir -p "$OUTDIR"
export WOO_REVIEW_DISABLE_LLM_TIEBREAK=1
trap 'rm -rf "$WORK"' EXIT

export WOO_REVIEW_FAKE_LLM_RULES_MD='- Use `useEffect` cleanup for subscriptions.'

# 3 findings share react/missing-cleanup → recommendation should fire.
cat > "$OUTDIR/findings.json" <<'JSON'
[ {"angle":"react","file":"a.tsx","line":1,"semantic_key":"react/missing-cleanup","code_anchor":"a000a000a000","title":"x","severity":"MED","blocking":false,"fix_type":"prose","fix":"f","description":"d","suggestion":null,"rule_quote":null},
  {"angle":"react","file":"b.tsx","line":1,"semantic_key":"react/missing-cleanup","code_anchor":"b000b000b000","title":"y","severity":"MED","blocking":false,"fix_type":"prose","fix":"f","description":"d","suggestion":null,"rule_quote":null} ]
JSON
cat > "$OUTDIR/sidecar-findings.json" <<'JSON'
[ {"file":"c.tsx","line":1,"title":"z","semantic_key":"react/missing-cleanup","code_anchor":"c000c000c000","resolved_at":"2026-01-01","pr_number":3} ]
JSON
echo '[]' > "$OUTDIR/prior-findings.json"
bash "$SCRIPT"
[ -f "$OUTDIR/rule-recommendations.md" ] \
  && grep -qE 'useEffect.*cleanup' "$OUTDIR/rule-recommendations.md" \
  && echo "PASS rule-recommendations emitted on cluster" \
  || { echo "FAIL: rule-recommendations.md missing or empty"; exit 1; }

# Single finding → no recommendation.
cat > "$OUTDIR/findings.json" <<'JSON'
[ {"angle":"bugs","file":"a.ts","line":1,"semantic_key":"bugs/unknown","code_anchor":"a000a000a000","title":"x","severity":"LOW","blocking":false,"fix_type":"prose","fix":"f","description":"d","suggestion":null,"rule_quote":null} ]
JSON
echo '[]' > "$OUTDIR/sidecar-findings.json"
rm -f "$OUTDIR/rule-recommendations.md"
bash "$SCRIPT"
{ [ ! -f "$OUTDIR/rule-recommendations.md" ] || [ "$(wc -c < "$OUTDIR/rule-recommendations.md")" -eq 0 ]; } \
  && echo "PASS no recommendation on single finding" \
  || { echo "FAIL: recommendation emitted on single finding"; exit 1; }
