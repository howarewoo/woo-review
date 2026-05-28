#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/woo-review/scripts/dedup-against-history.sh"
WORK="$(mktemp -d)"
OUT="$WORK/pr-review"
mkdir -p "$OUT"
trap 'rm -rf "$WORK"' EXIT
export OUTDIR="$OUT"
export WOO_REVIEW_DISABLE_LLM_TIEBREAK=1   # Pass 2 covered in task 5

pass=0; fail=0
expect() {
  local name="$1" cond="$2"
  if eval "$cond"; then echo "PASS $name"; pass=$((pass+1))
  else echo "FAIL $name (condition: $cond)"; fail=$((fail+1)); fi
}

# ---- case A: exact (file, anchor, sem_key) match → drop
cat > "$OUT/findings.json" <<'JSON'
[ {"angle":"bugs","file":"a.ts","line":10,"severity":"HIGH","blocking":true,
   "title":"x","description":"y","fix_type":"prose","fix":"f","suggestion":null,
   "rule_quote":null,"semantic_key":"bugs/null-deref-array-index","code_anchor":"aaa111bbb222"} ]
JSON
cat > "$OUT/prior-findings.json" <<'JSON'
[ {"file":"a.ts","line":10,"title":"x","author":"bot","status":"open",
   "semantic_key":"bugs/null-deref-array-index","code_anchor":"aaa111bbb222"} ]
JSON
echo '[]' > "$OUT/sidecar-findings.json"
bash "$SCRIPT"
expect "A: exact match drops finding" \
  '[ "$(jq length "$OUT/findings.deduped.json")" -eq 0 ]'
expect "A: dedup-metrics det_drops=1" \
  '[ "$(jq -r .det_drops "$OUT/dedup-metrics.json")" -eq 1 ]'

# ---- case B: different file → keep
cat > "$OUT/findings.json" <<'JSON'
[ {"angle":"bugs","file":"b.ts","line":10,"severity":"HIGH","blocking":true,
   "title":"x","description":"y","fix_type":"prose","fix":"f","suggestion":null,
   "rule_quote":null,"semantic_key":"bugs/null-deref-array-index","code_anchor":"aaa111bbb222"} ]
JSON
bash "$SCRIPT"
expect "B: different file keeps finding" \
  '[ "$(jq length "$OUT/findings.deduped.json")" -eq 1 ]'

# ---- case C: empty inputs → all findings pass through
cat > "$OUT/findings.json" <<'JSON'
[ {"angle":"bugs","file":"c.ts","line":1,"severity":"LOW","blocking":false,
   "title":"t","description":"d","fix_type":"prose","fix":"f","suggestion":null,
   "rule_quote":null,"semantic_key":"bugs/unknown","code_anchor":"ccc333ddd444"} ]
JSON
echo '[]' > "$OUT/prior-findings.json"
echo '[]' > "$OUT/sidecar-findings.json"
bash "$SCRIPT"
expect "C: empty priors keeps finding" \
  '[ "$(jq length "$OUT/findings.deduped.json")" -eq 1 ]'

# ---- case D: missing prior-findings.json → treated as []
rm -f "$OUT/prior-findings.json"
bash "$SCRIPT"
expect "D: missing prior file treated as empty" \
  '[ "$(jq length "$OUT/findings.deduped.json")" -eq 1 ]'

# ---- case E: sidecar match → drop
cat > "$OUT/findings.json" <<'JSON'
[ {"angle":"react","file":"X.tsx","line":50,"severity":"MEDIUM","blocking":false,
   "title":"t","description":"d","fix_type":"prose","fix":"f","suggestion":null,
   "rule_quote":null,"semantic_key":"react/missing-key","code_anchor":"eee555fff666"} ]
JSON
echo '[]' > "$OUT/prior-findings.json"
cat > "$OUT/sidecar-findings.json" <<'JSON'
[ {"file":"X.tsx","line":50,"title":"t","semantic_key":"react/missing-key",
   "code_anchor":"eee555fff666","resolved_at":"2026-01-01","pr_number":1} ]
JSON
bash "$SCRIPT"
expect "E: sidecar match drops finding" \
  '[ "$(jq length "$OUT/findings.deduped.json")" -eq 0 ]'

# ---- case F: same file + sem_key, anchor differs, |Δline|≤10 → LLM tiebreak
cat > "$OUT/findings.json" <<'JSON'
[ {"angle":"bugs","file":"d.ts","line":15,"severity":"HIGH","blocking":true,
   "title":"x","description":"y","fix_type":"prose","fix":"f","suggestion":null,
   "rule_quote":null,"semantic_key":"bugs/off-by-one-loop-bound","code_anchor":"NEW111111111"} ]
JSON
cat > "$OUT/prior-findings.json" <<'JSON'
[ {"file":"d.ts","line":10,"title":"old","author":"bot","status":"open",
   "semantic_key":"bugs/off-by-one-loop-bound","code_anchor":"OLD000000000"} ]
JSON
echo '[]' > "$OUT/sidecar-findings.json"
export WOO_REVIEW_FAKE_LLM_DEDUP_JSON='{"drop_ids":["d.ts:15"]}'
unset WOO_REVIEW_DISABLE_LLM_TIEBREAK
bash "$SCRIPT"
expect "F: LLM stub drops finding" \
  '[ "$(jq length "$OUT/findings.deduped.json")" -eq 0 ]'
expect "F: dedup-metrics llm_drops=1" \
  '[ "$(jq -r .llm_drops "$OUT/dedup-metrics.json")" -eq 1 ]'

# ---- case G: LLM stub returns keep
cat > "$OUT/findings.json" <<'JSON'
[ {"angle":"bugs","file":"d.ts","line":15,"severity":"HIGH","blocking":true,
   "title":"x","description":"y","fix_type":"prose","fix":"f","suggestion":null,
   "rule_quote":null,"semantic_key":"bugs/off-by-one-loop-bound","code_anchor":"NEW111111111"} ]
JSON
export WOO_REVIEW_FAKE_LLM_DEDUP_JSON='{"drop_ids":[]}'
bash "$SCRIPT"
expect "G: LLM keep verdict keeps finding" \
  '[ "$(jq length "$OUT/findings.deduped.json")" -eq 1 ]'

# ---- case H: malformed LLM response → fail open, keep
export WOO_REVIEW_FAKE_LLM_DEDUP_JSON='{ this is not valid json'
bash "$SCRIPT"
expect "H: malformed LLM response keeps finding (fail-open)" \
  '[ "$(jq length "$OUT/findings.deduped.json")" -eq 1 ]'
unset WOO_REVIEW_FAKE_LLM_DEDUP_JSON
export WOO_REVIEW_DISABLE_LLM_TIEBREAK=1

# ---- case I: enable_history_dedup=false in config → pass-through, no drops
cat > "$OUT/findings.json" <<'JSON'
[ {"angle":"bugs","file":"a.ts","line":10,"severity":"HIGH","blocking":true,
   "title":"x","description":"y","fix_type":"prose","fix":"f","suggestion":null,
   "rule_quote":null,"semantic_key":"bugs/null-deref-array-index","code_anchor":"aaa111bbb222"} ]
JSON
cat > "$OUT/prior-findings.json" <<'JSON'
[ {"file":"a.ts","line":10,"title":"x","author":"bot","status":"open",
   "semantic_key":"bugs/null-deref-array-index","code_anchor":"aaa111bbb222"} ]
JSON
echo '{"enable_history_dedup": false}' > "$OUT/config.json"
bash "$SCRIPT"
expect "I: config flag disabled keeps finding (would normally drop)" \
  '[ "$(jq length "$OUT/findings.deduped.json")" -eq 1 ]'
expect "I: metrics marks skipped=true" \
  '[ "$(jq -r .skipped "$OUT/dedup-metrics.json")" = "true" ]'
rm -f "$OUT/config.json"

echo "----"
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
