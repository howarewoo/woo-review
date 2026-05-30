#!/usr/bin/env bash
# intersect-findings.sh — adversarial validator merge step (issue #13).
#
# Inputs (in $OUTDIR, defaults to /tmp/pr-review):
#   findings.prosecutor.json   array — output of validator-prosecutor.md
#   findings.defender.json     array — output of validator.md (defender)
#   config.json                {disable_adversarial?: bool, ...}
#
# Outputs:
#   findings.json              final validated findings (intersection, or
#                              copy of defender output when adversarial is off)
#   validator-metrics.json     {prosecutor_count, defender_count,
#                               kept_count, disagreement_count,
#                               dropped_by_defender, dropped_by_prosecutor,
#                               mode: "adversarial" | "defender-only",
#                               degraded: bool}
#
# Intersection key: two-pass match. Pass 1 is exact `(file, line, title_stem)`
# where `title_stem` is lowercase alphanumeric truncated to 40 chars — same
# key used by prior-thread dedupe in _header.md so the two stay consistent.
# Pass 2 is a fuzzy fallback for the unmatched remainder: same `file`, line
# within ±10, and `title_stem` matches on its first 20 characters (so minor
# rewording survives). Ties resolved by smallest absolute line delta. This
# stops genuine agreement from being dropped when the two validators anchor
# the same finding at slightly different lines (e.g. 33 vs 39 for the same
# REVOKE block) or reword the headline.
#
# When `disable_adversarial: true` is set in config.json, OR
# findings.prosecutor.json is missing/empty, intersection is skipped and
# findings.defender.json is copied verbatim to findings.json. This is the
# cost-sensitive opt-out described in issue #13's acceptance criteria.
#
# Merge rules for findings present in BOTH passes:
#   - severity: take the LOWER (more conservative) of the two values
#               (LOW < MEDIUM < HIGH).
#   - blocking: AND of the two (`true` only if both passes say blocking).
#   - other fields (title, description, fix, suggestion, fix_type, rule_quote):
#     prefer the DEFENDER's copy — it ran the stricter shape + fix_type checks
#     so its rewrites are the canonical version.

set -euo pipefail

# shellcheck source=skills/woo-review/scripts/resolve-outdir.sh
source "$(dirname "${BASH_SOURCE[0]}")/resolve-outdir.sh"
PROSECUTOR="$OUTDIR/findings.prosecutor.json"
DEFENDER="$OUTDIR/findings.defender.json"
FINAL="$OUTDIR/findings.json"
METRICS="$OUTDIR/validator-metrics.json"
CONFIG="$OUTDIR/config.json"

# Resolve disable_adversarial from config.json (default false).
disable_adversarial="false"
if [ -f "$CONFIG" ]; then
  v="$(jq -r '.disable_adversarial // false' "$CONFIG" 2>/dev/null || echo false)"
  case "$v" in true|false) disable_adversarial="$v" ;; *) disable_adversarial="false" ;; esac
fi

# Resolve metrics opt-in from config.json (default false). Gates the per-angle
# findings.metrics.json emit (issue #41). validator-metrics.json is unaffected.
metrics_enabled="false"
if [ -f "$CONFIG" ]; then
  v="$(jq -r '.metrics // false' "$CONFIG" 2>/dev/null || echo false)"
  case "$v" in true|false) metrics_enabled="$v" ;; *) metrics_enabled="false" ;; esac
fi
RAW="$OUTDIR/raw_findings.json"
ANGLE_METRICS="$OUTDIR/findings.metrics.json"

# Defender output is mandatory. If absent we cannot post a review at all —
# upstream is broken and we should fail loudly.
if [ ! -s "$DEFENDER" ]; then
  echo "::error::intersect-findings: $DEFENDER missing or empty — defender validator did not run" >&2
  exit 1
fi
if ! jq -e 'type == "array"' "$DEFENDER" >/dev/null 2>&1; then
  echo "::error::intersect-findings: $DEFENDER is not a JSON array" >&2
  exit 1
fi

defender_count="$(jq 'length' "$DEFENDER")"

# Defender-only path (adversarial disabled OR prosecutor file missing).
prosecutor_present="false"
if [ -s "$PROSECUTOR" ] && jq -e 'type == "array"' "$PROSECUTOR" >/dev/null 2>&1; then
  prosecutor_present="true"
fi

# Single writer for validator-metrics.json so the two emit sites share one
# schema. Args: mode degraded prosecutor_count defender_count kept_count
# disagreement dropped_by_defender dropped_by_prosecutor. Numeric/null args are
# raw JSON (e.g. `null`, `0`); degraded is `true`/`false`.
write_metrics() {
  jq -n \
    --arg mode "$1" \
    --argjson degraded "$2" \
    --argjson prosecutor_count "$3" \
    --argjson defender_count "$4" \
    --argjson kept_count "$5" \
    --argjson disagreement_count "$6" \
    --argjson dropped_by_defender "$7" \
    --argjson dropped_by_prosecutor "$8" \
    '{
      mode: $mode,
      degraded: $degraded,
      prosecutor_count: $prosecutor_count,
      defender_count: $defender_count,
      kept_count: $kept_count,
      disagreement_count: $disagreement_count,
      dropped_by_defender: $dropped_by_defender,
      dropped_by_prosecutor: $dropped_by_prosecutor
    }' > "$METRICS"
}

# Per-angle signal/noise breakdown (issue #41). Writes findings.metrics.json
# keyed by angle. No-op unless metrics_enabled=true. Reads the merged raw set
# plus both validator passes and the final intersection — all already on disk —
# and attributes counts by each finding's .angle. In defender-only mode the
# prosecutor file is absent; prosecutor-derived numbers come out null.
# Args: mode degraded
emit_angle_metrics() {
  [ "$metrics_enabled" = "true" ] || return 0
  python3 - "$RAW" "$PROSECUTOR" "$DEFENDER" "$FINAL" "$ANGLE_METRICS" "$1" "$2" <<'PY'
import json, sys

raw_p, pros_p, def_p, final_p, out_p, mode, degraded = sys.argv[1:8]

def load(path):
    try:
        with open(path) as fh:
            data = json.load(fh)
        return data if isinstance(data, list) else []
    except (OSError, ValueError):
        return []

def present(path):
    try:
        open(path).close()
        return True
    except OSError:
        return False

raw_present = present(raw_p)
raw   = load(raw_p)
defn  = load(def_p)
final = load(final_p)
has_pros = mode != "defender-only"
pros = load(pros_p) if has_pros else []

def angle_of(f):
    a = f.get("angle")
    return a if isinstance(a, str) and a else "_unknown"

def count_by_angle(items):
    out = {}
    for f in items:
        out[angle_of(f)] = out.get(angle_of(f), 0) + 1
    return out

raw_c, pros_c, def_c, final_c = (count_by_angle(x) for x in (raw, pros, defn, final))
angles = sorted(set(raw_c) | set(pros_c) | set(def_c) | set(final_c))

SEVS = ("HIGH", "MEDIUM", "LOW")

def sev_hist(items, a):
    h = {s: 0 for s in SEVS}
    for f in items:
        if angle_of(f) == a:
            s = (f.get("severity") or "").upper()
            if s in h:
                h[s] += 1
    return h

def blocking_count(items, a):
    return sum(1 for f in items if angle_of(f) == a and bool(f.get("blocking", False)))

out = {"schema_version": 1, "mode": mode, "degraded": degraded == "true", "angles": {}}

for a in angles:
    kept = final_c.get(a, 0)
    defk = def_c.get(a, 0)
    blk  = blocking_count(final, a)
    rawn = raw_c.get(a, 0) if raw_present else max(defk, kept, pros_c.get(a, 0))
    rec = {
        "raw_count": rawn,
        "defender_kept": defk,
        "kept": kept,
        "dropped_by_prosecutor": max(0, defk - kept),
        "blocking_count": blk,
        "nonblocking_count": kept - blk,
        "severity": sev_hist(final, a),
    }
    if has_pros:
        prok = pros_c.get(a, 0)
        rec["prosecutor_kept"] = prok
        rec["dropped_by_defender"] = max(0, prok - kept)
    else:
        rec["prosecutor_kept"] = None
        rec["dropped_by_defender"] = None
    out["angles"][a] = rec

with open(out_p, "w") as fh:
    json.dump(out, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
}

if [ "$disable_adversarial" = "true" ] || [ "$prosecutor_present" = "false" ]; then
  mode="defender-only"
  # degraded = the adversarial pass was EXPECTED but the prosecutor output is
  # missing/invalid (a silent failure). A legitimate `disable_adversarial: true`
  # opt-out is NOT degraded. Only the former should be surfaced to the user.
  degraded="false"
  if [ "$disable_adversarial" != "true" ]; then
    degraded="true"
    echo "::warning::intersect-findings: prosecutor findings absent — falling back to defender-only output (degraded)" >&2
  fi
  cp "$DEFENDER" "$FINAL"
  write_metrics "$mode" "$degraded" null "$defender_count" "$defender_count" 0 0 0
  echo "intersect-findings: mode=$mode degraded=$degraded kept=$defender_count"
  emit_angle_metrics "$mode" "$degraded" || echo "::warning::emit_angle_metrics failed (non-fatal)" >&2
  exit 0
fi

prosecutor_count="$(jq 'length' "$PROSECUTOR")"

# Two-pass intersection. Pass 1 is exact (file, line, title_stem). Pass 2
# attempts fuzzy match for the remainder: same file, |line_a - line_b| <= 10,
# title_stem prefix-20 matches, smallest line delta wins ties. A defender
# finding can match at most one prosecutor finding; each match is consumed.
python3 - "$PROSECUTOR" "$DEFENDER" "$FINAL" <<'PY'
import json
import re
import sys

prosecutor_path, defender_path, final_path = sys.argv[1:4]

with open(prosecutor_path, "r") as fh:
    prosecutor = json.load(fh)
with open(defender_path, "r") as fh:
    defender = json.load(fh)


def title_stem(s):
    return re.sub(r"[^a-z0-9]+", "", (s or "").lower())[:40]


def title_stem_prefix(s, n=20):
    return title_stem(s)[:n]


def safe_line(v):
    try:
        return int(v)
    except (TypeError, ValueError):
        return 0


SEV_RANK = {"LOW": 0, "MEDIUM": 1, "HIGH": 2}
SEV_LABEL = {0: "LOW", 1: "MEDIUM", 2: "HIGH"}


def sev_rank(s):
    return SEV_RANK.get((s or "").upper(), 1)


def sev_label(n):
    return SEV_LABEL.get(max(0, min(2, n)), "MEDIUM")


def exact_key(f):
    return (
        f.get("file") or "",
        safe_line(f.get("line")),
        title_stem(f.get("title")),
    )


# Pass 1: exact tuple match.
pros_by_exact = {}
for pf in prosecutor:
    pros_by_exact.setdefault(exact_key(pf), []).append(pf)

kept = []
matched_pros_ids = set()
unmatched_def = []

for df in defender:
    key = exact_key(df)
    pool = pros_by_exact.get(key, [])
    chosen = None
    for pf in pool:
        if id(pf) in matched_pros_ids:
            continue
        chosen = pf
        break
    if chosen is None:
        unmatched_def.append(df)
        continue
    matched_pros_ids.add(id(chosen))
    merged = dict(df)
    merged["severity"] = sev_label(min(sev_rank(df.get("severity")), sev_rank(chosen.get("severity"))))
    merged["blocking"] = bool(df.get("blocking", False)) and bool(chosen.get("blocking", False))
    kept.append(merged)

# Pass 2: fuzzy fallback. For each unmatched defender finding, find the
# closest unmatched prosecutor finding by same `file`, |line delta| <= 10,
# prefix-20 title stem equal. Ties broken by smallest line delta.
unmatched_pros = [pf for pf in prosecutor if id(pf) not in matched_pros_ids]

LINE_WINDOW = 10
fuzzy_matches = 0
for df in unmatched_def:
    df_file = df.get("file") or ""
    df_line = safe_line(df.get("line"))
    df_prefix = title_stem_prefix(df.get("title"))
    if not df_file or not df_prefix:
        continue
    best = None
    best_delta = LINE_WINDOW + 1
    for pf in unmatched_pros:
        if id(pf) in matched_pros_ids:
            continue
        if (pf.get("file") or "") != df_file:
            continue
        pf_line = safe_line(pf.get("line"))
        delta = abs(df_line - pf_line)
        if delta > LINE_WINDOW:
            continue
        if title_stem_prefix(pf.get("title")) != df_prefix:
            continue
        if delta < best_delta:
            best = pf
            best_delta = delta
    if best is None:
        continue
    matched_pros_ids.add(id(best))
    merged = dict(df)
    merged["severity"] = sev_label(min(sev_rank(df.get("severity")), sev_rank(best.get("severity"))))
    merged["blocking"] = bool(df.get("blocking", False)) and bool(best.get("blocking", False))
    kept.append(merged)
    fuzzy_matches += 1

with open(final_path, "w") as fh:
    json.dump(kept, fh, indent=2)
    fh.write("\n")

sys.stderr.write(f"intersect-findings: fuzzy-matched {fuzzy_matches} finding(s) on second pass\n")
PY

kept_count="$(jq 'length' "$FINAL")"
# Disagreement: findings either pass kept but the other dropped.
# Equivalent to (defender_count - kept) + (prosecutor_count - kept).
dropped_by_defender="$((prosecutor_count - kept_count))"
dropped_by_prosecutor="$((defender_count - kept_count))"
if [ "$dropped_by_defender" -lt 0 ]; then dropped_by_defender=0; fi
if [ "$dropped_by_prosecutor" -lt 0 ]; then dropped_by_prosecutor=0; fi
disagreement_count="$((dropped_by_defender + dropped_by_prosecutor))"

write_metrics adversarial false "$prosecutor_count" "$defender_count" "$kept_count" "$disagreement_count" "$dropped_by_defender" "$dropped_by_prosecutor"

echo "intersect-findings: mode=adversarial degraded=false prosecutor=$prosecutor_count defender=$defender_count kept=$kept_count disagreement=$disagreement_count"
emit_angle_metrics adversarial false || echo "::warning::emit_angle_metrics failed (non-fatal)" >&2
