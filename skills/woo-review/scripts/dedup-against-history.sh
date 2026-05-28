#!/usr/bin/env bash
# dedup-against-history.sh — Pass 1 deterministic + Pass 2 LLM tiebreak.
set -euo pipefail

OUTDIR="${OUTDIR:-/tmp/pr-review}"
FINDINGS="$OUTDIR/findings.json"
PRIORS="$OUTDIR/prior-findings.json"
SIDECAR="$OUTDIR/sidecar-findings.json"
DEDUPED="$OUTDIR/findings.deduped.json"
METRICS="$OUTDIR/dedup-metrics.json"
PAIRS="$OUTDIR/dedup-pairs.json"
CONFIG="$OUTDIR/config.json"

# enable_history_dedup gate. Default true so existing tests and direct invocations
# still dedup without writing config.json. When false, copy findings through and exit.
ENABLE_DEDUP=true
if [ -f "$CONFIG" ]; then
  # jq `//` treats `false` as missing — use explicit `if has(...)` so a stored
  # `false` actually disables dedup (default stays `true` when the key is absent).
  ENABLE_DEDUP="$(jq -r 'if has("enable_history_dedup") then .enable_history_dedup else true end' "$CONFIG" 2>/dev/null || echo true)"
fi
if [ "$ENABLE_DEDUP" != "true" ]; then
  if [ -f "$FINDINGS" ]; then cp "$FINDINGS" "$DEDUPED"; else echo '[]' > "$DEDUPED"; fi
  echo '{"det_drops":0,"llm_drops":0,"pair_count":0,"skipped":true}' > "$METRICS"
  echo "dedup-against-history: disabled via enable_history_dedup=false; passed through"
  exit 0
fi

if [ ! -f "$FINDINGS" ]; then
  echo '[]' > "$DEDUPED.tmp"
  echo '{"det_drops":0,"llm_drops":0,"pair_count":0}' > "$METRICS.tmp"
  mv "$DEDUPED.tmp" "$DEDUPED"
  mv "$METRICS.tmp" "$METRICS"
  exit 0
fi
[ -f "$PRIORS"   ] || echo '[]' > "$PRIORS"
[ -f "$SIDECAR"  ] || echo '[]' > "$SIDECAR"

python3 - "$FINDINGS" "$PRIORS" "$SIDECAR" "$DEDUPED.tmp" "$METRICS.tmp" "$PAIRS" <<'PY'
import json, sys

findings_p, priors_p, sidecar_p, out_p, metrics_p, pairs_p = sys.argv[1:]

def load(p, default):
    try:
        with open(p) as fh: return json.load(fh)
    except Exception as e:
        sys.stderr.write(f"dedup: load {p} failed ({e}); treating as empty\n")
        return default

findings = load(findings_p, [])
priors   = load(priors_p,   [])
sidecar  = load(sidecar_p,  [])

def k(rec):
    return (rec.get("file"),
            rec.get("code_anchor") or "",
            rec.get("semantic_key") or "")

prior_index = {}
for p in priors + sidecar:
    if not p.get("file"): continue
    prior_index.setdefault(p["file"], []).append(p)

# Both code_anchor and semantic_key must be non-empty on the finding
# side before we trust a match — protects against partially-populated
# priors (e.g. legacy sidecar entries) silently dropping valid findings.
kept, dropped, pairs = [], 0, []
for f in findings:
    fk = k(f)
    file_priors = prior_index.get(f.get("file"), [])
    if any(k(p) == fk and f.get("code_anchor") and f.get("semantic_key")
           for p in file_priors):
        dropped += 1
        continue
    # Look for an ambiguous (XOR) match: same file, |Δline|≤10, and exactly one
    # of (code_anchor, semantic_key) matches. The finding is added to `pairs`
    # for LLM tiebreak — but ALWAYS kept here. Pass 2 decides whether to drop.
    for p in file_priors:
        try: dline = abs(int(f.get("line") or 0) - int(p.get("line") or 0))
        except Exception: dline = 999
        if dline > 10: continue
        anc_match = (f.get("code_anchor") and f.get("code_anchor") == p.get("code_anchor"))
        sem_match = (f.get("semantic_key") and f.get("semantic_key") == p.get("semantic_key"))
        if anc_match ^ sem_match:
            pairs.append({
                "id": f"{f.get('file')}:{f.get('line')}",
                "new": {kk: f.get(kk) for kk in ("file","line","title","description","semantic_key","code_anchor")},
                "prior": {kk: p.get(kk) for kk in ("file","line","title","semantic_key","code_anchor")},
            })
            break
    kept.append(f)

with open(out_p, "w") as fh: json.dump(kept, fh, indent=2)
with open(pairs_p, "w") as fh: json.dump(pairs, fh, indent=2)
with open(metrics_p, "w") as fh:
    json.dump({"det_drops": dropped, "llm_drops": 0,
               "pair_count": len(pairs),
               "input_count": len(findings),
               "kept_count": len(kept)}, fh, indent=2)
PY

LLM_DISABLED="${WOO_REVIEW_DISABLE_LLM_TIEBREAK:-0}"
PAIR_COUNT="$(jq length "$PAIRS")"

SKIP_LLM_DEDUP=0
if [ "$LLM_DISABLED" = "1" ] || [ "$PAIR_COUNT" -eq 0 ]; then
  mv "$DEDUPED.tmp" "$DEDUPED"
  mv "$METRICS.tmp" "$METRICS"
  echo "dedup-against-history: input=$(jq length "$FINDINGS") "\
"kept=$(jq length "$DEDUPED") "\
"det_drops=$(jq -r .det_drops "$METRICS") llm_drops=0 (pairs=$PAIR_COUNT, llm_disabled=$LLM_DISABLED)"
  SKIP_LLM_DEDUP=1
fi

if [ "$SKIP_LLM_DEDUP" = "0" ]; then
  COST_CEILING_CALLS="${WOO_REVIEW_DEDUP_MAX_CALLS:-10}"
  PER_CALL_PAIRS=20
  CALLS=$(( (PAIR_COUNT + PER_CALL_PAIRS - 1) / PER_CALL_PAIRS ))
  if [ "$CALLS" -gt "$COST_CEILING_CALLS" ]; then
    echo "dedup-against-history: pair_count=$PAIR_COUNT exceeds ceiling "\
"($COST_CEILING_CALLS calls × $PER_CALL_PAIRS pairs); truncating"
    CALLS="$COST_CEILING_CALLS"
  fi

  DROP_IDS_ALL='[]'
  for i in $(seq 0 $((CALLS - 1))); do
    START=$((i * PER_CALL_PAIRS))
    BATCH=$(jq ".[$START:$START+$PER_CALL_PAIRS]" "$PAIRS")
    if [ -n "${WOO_REVIEW_FAKE_LLM_DEDUP_JSON:-}" ]; then
      RESP="$WOO_REVIEW_FAKE_LLM_DEDUP_JSON"
    else
      RESP="$(bash "$(dirname "$0")/llm-dedup.sh" "$BATCH" 2>/dev/null || echo '{}')"
    fi
    PARSED=$(printf '%s' "$RESP" | jq -c '.drop_ids // []' 2>/dev/null || echo '[]')
    DROP_IDS_ALL=$(jq -c -n --argjson a "$DROP_IDS_ALL" --argjson b "$PARSED" '$a + $b')
  done

  python3 - "$DEDUPED.tmp" "$METRICS.tmp" "$DEDUPED" "$METRICS" "$DROP_IDS_ALL" <<'PY'
import json, sys
src, mtmp, dst, mdst, drops_raw = sys.argv[1:]
findings = json.load(open(src))
metrics  = json.load(open(mtmp))
try: drops = set(json.loads(drops_raw))
except Exception: drops = set()
kept = [f for f in findings if f"{f.get('file')}:{f.get('line')}" not in drops]
metrics["llm_drops"] = len(findings) - len(kept)
metrics["kept_count"] = len(kept)
json.dump(kept,  open(dst,  "w"), indent=2)
json.dump(metrics, open(mdst, "w"), indent=2)
PY

  rm -f "$DEDUPED.tmp" "$METRICS.tmp"
  echo "dedup-against-history: input=$(jq length "$FINDINGS") "\
"kept=$(jq length "$DEDUPED") "\
"det_drops=$(jq -r .det_drops "$METRICS") "\
"llm_drops=$(jq -r .llm_drops "$METRICS") "\
"pairs=$PAIR_COUNT"
fi

# ─── Rule recommendations ──────────────────────────────────────────────
# Cluster findings ∪ sidecar by semantic_key. Any key with ≥ THRESHOLD
# occurrences is a candidate. One Sonnet call drafts a short bullet list.
RULES_OUT="$OUTDIR/rule-recommendations.md"
THRESHOLD="${WOO_REVIEW_RULES_THRESHOLD:-2}"

CLUSTER_JSON="$(jq -s --argjson t "$THRESHOLD" '
  add
  | map(select(.semantic_key and .semantic_key != "unknown/unknown"))
  | group_by(.semantic_key)
  | map({key: .[0].semantic_key, count: length,
         examples: [.[0:3] | .[] | {file: .file, line: .line, title: (.title // "")}]})
  | map(select(.count >= $t))
' "$DEDUPED" "$SIDECAR" 2>/dev/null || echo '[]')"

if [ "$(printf '%s' "$CLUSTER_JSON" | jq length)" -eq 0 ]; then
  rm -f "$RULES_OUT"
  exit 0
fi

# Clear any stale recs from a prior run before either branch can write.
rm -f "$RULES_OUT"

if [ -n "${WOO_REVIEW_FAKE_LLM_RULES_MD:-}" ]; then
  printf '%s' "$WOO_REVIEW_FAKE_LLM_RULES_MD" > "$RULES_OUT"
else
  if [ -x "$(dirname "$0")/llm-rules.sh" ]; then
    if ! bash "$(dirname "$0")/llm-rules.sh" "$CLUSTER_JSON" > "$RULES_OUT" 2>/dev/null; then
      rm -f "$RULES_OUT"
    fi
  fi
fi

if [ -s "$RULES_OUT" ]; then
  echo "dedup-against-history: rule-recommendations.md emitted ("\
"$(wc -c < "$RULES_OUT") bytes from $(printf '%s' "$CLUSTER_JSON" | jq length) clusters)"
fi
