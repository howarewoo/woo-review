#!/usr/bin/env bash
# dedup-against-history.sh
#
# Reads /tmp/pr-review/findings.json (post-validator) and drops findings that
# duplicate prior PR threads (open OR resolved) or repo-wide sidecar entries.
#
# Pass 1 (this file): deterministic match on (file, code_anchor, semantic_key).
# Pass 2 (LLM tiebreak): added in task 5; gated on WOO_REVIEW_DISABLE_LLM_TIEBREAK.
#
# Outputs:
#   $OUTDIR/findings.deduped.json
#   $OUTDIR/dedup-metrics.json   {det_drops, llm_drops, pair_count}

set -euo pipefail

OUTDIR="${OUTDIR:-/tmp/pr-review}"
FINDINGS="$OUTDIR/findings.json"
PRIORS="$OUTDIR/prior-findings.json"
SIDECAR="$OUTDIR/sidecar-findings.json"
DEDUPED="$OUTDIR/findings.deduped.json"
METRICS="$OUTDIR/dedup-metrics.json"

if [ ! -f "$FINDINGS" ]; then
  echo '[]' > "$DEDUPED.tmp"
  echo '{"det_drops":0,"llm_drops":0,"pair_count":0}' > "$METRICS.tmp"
  mv "$DEDUPED.tmp" "$DEDUPED"
  mv "$METRICS.tmp" "$METRICS"
  exit 0
fi
[ -f "$PRIORS"   ] || echo '[]' > "$PRIORS"
[ -f "$SIDECAR"  ] || echo '[]' > "$SIDECAR"

python3 - "$FINDINGS" "$PRIORS" "$SIDECAR" "$DEDUPED.tmp" "$METRICS.tmp" <<'PY'
import json, sys
findings_p, priors_p, sidecar_p, out_p, metrics_p = sys.argv[1:]

def load(p, default):
    try:
        with open(p) as fh:
            return json.load(fh)
    except Exception as e:
        sys.stderr.write(f"dedup: load {p} failed ({e}); treating as empty\n")
        return default

findings = load(findings_p, [])
priors   = load(priors_p,   [])
sidecar  = load(sidecar_p,  [])

def key(rec):
    return (rec.get("file"),
            rec.get("code_anchor") or "",
            rec.get("semantic_key") or "")

prior_keys = {key(p) for p in priors if p.get("file")}
prior_keys |= {key(s) for s in sidecar if s.get("file")}

kept = []
det_drops = 0
# Both code_anchor and semantic_key must be non-empty on the finding
# side before we trust a match — protects against partially-populated
# priors (e.g. legacy sidecar entries) silently dropping valid findings.
for f in findings:
    if key(f) in prior_keys and f.get("code_anchor") and f.get("semantic_key"):
        det_drops += 1
        continue
    kept.append(f)

with open(out_p, "w") as fh:
    json.dump(kept, fh, indent=2)

metrics = {"det_drops": det_drops, "llm_drops": 0, "pair_count": 0,
           "input_count": len(findings), "kept_count": len(kept)}
with open(metrics_p, "w") as fh:
    json.dump(metrics, fh, indent=2)
PY

mv "$DEDUPED.tmp" "$DEDUPED"
mv "$METRICS.tmp" "$METRICS"

echo "dedup-against-history: input=$(jq length "$FINDINGS") "\
"kept=$(jq length "$DEDUPED") "\
"det_drops=$(jq -r .det_drops "$METRICS")"
