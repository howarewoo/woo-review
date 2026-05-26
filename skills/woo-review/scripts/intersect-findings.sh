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
#                               mode: "adversarial" | "defender-only"}
#
# Intersection key: (file, line, title_stem) where title_stem is lowercase
# alphanumeric truncated to 40 chars — same key used by prior-thread dedupe
# in _header.md so the two stay consistent.
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

OUTDIR="${OUTDIR:-/tmp/pr-review}"
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

if [ "$disable_adversarial" = "true" ] || [ "$prosecutor_present" = "false" ]; then
  mode="defender-only"
  reason="$disable_adversarial"
  if [ "$disable_adversarial" != "true" ]; then
    echo "::warning::intersect-findings: prosecutor findings absent — falling back to defender-only output" >&2
  fi
  cp "$DEFENDER" "$FINAL"
  jq -n \
    --argjson defender_count "$defender_count" \
    --arg mode "$mode" \
    '{
      mode: $mode,
      prosecutor_count: null,
      defender_count: $defender_count,
      kept_count: $defender_count,
      disagreement_count: 0,
      dropped_by_defender: 0,
      dropped_by_prosecutor: 0
    }' > "$METRICS"
  echo "intersect-findings: mode=$mode kept=$defender_count"
  exit 0
fi

prosecutor_count="$(jq 'length' "$PROSECUTOR")"

# Intersection via jq. The key is (file, line, title_stem). title_stem matches
# the _header.md prior-thread dedupe stem so the two systems agree on identity.
jq -n \
  --slurpfile p "$PROSECUTOR" \
  --slurpfile d "$DEFENDER" '
def title_stem(s): (s // "" | ascii_downcase | gsub("[^a-z0-9]+"; "")) [0:40];
def key(f): [(f.file // ""), (f.line // 0 | tonumber? // 0), title_stem(f.title)];
def sev_rank(s):
  if s == "LOW" then 0
  elif s == "MEDIUM" then 1
  elif s == "HIGH" then 2
  else 1 end;
def sev_label(n):
  if n <= 0 then "LOW"
  elif n == 1 then "MEDIUM"
  else "HIGH" end;

($p[0]) as $pros
| ($d[0]) as $def
| ([$pros[] | { (key(.) | @json): . }] | add // {}) as $pros_map
| ([$def[]  | { (key(.) | @json): . }] | add // {}) as $def_map
| [ $def[]
    | . as $df
    | (key(.) | @json) as $k
    | if $pros_map[$k] == null then empty
      else
        ($pros_map[$k]) as $pr
        | $df
        | .severity = sev_label([sev_rank($df.severity), sev_rank($pr.severity)] | min)
        | .blocking = (($df.blocking // false) and ($pr.blocking // false))
      end
  ]
' > "$FINAL"

kept_count="$(jq 'length' "$FINAL")"
# Disagreement: findings either pass kept but the other dropped.
# Equivalent to (defender_count - kept) + (prosecutor_count - kept).
dropped_by_defender="$((prosecutor_count - kept_count))"
dropped_by_prosecutor="$((defender_count - kept_count))"
if [ "$dropped_by_defender" -lt 0 ]; then dropped_by_defender=0; fi
if [ "$dropped_by_prosecutor" -lt 0 ]; then dropped_by_prosecutor=0; fi
disagreement_count="$((dropped_by_defender + dropped_by_prosecutor))"

jq -n \
  --argjson prosecutor_count "$prosecutor_count" \
  --argjson defender_count "$defender_count" \
  --argjson kept_count "$kept_count" \
  --argjson disagreement_count "$disagreement_count" \
  --argjson dropped_by_defender "$dropped_by_defender" \
  --argjson dropped_by_prosecutor "$dropped_by_prosecutor" \
  '{
    mode: "adversarial",
    prosecutor_count: $prosecutor_count,
    defender_count: $defender_count,
    kept_count: $kept_count,
    disagreement_count: $disagreement_count,
    dropped_by_defender: $dropped_by_defender,
    dropped_by_prosecutor: $dropped_by_prosecutor
  }' > "$METRICS"

echo "intersect-findings: mode=adversarial prosecutor=$prosecutor_count defender=$defender_count kept=$kept_count disagreement=$disagreement_count"
