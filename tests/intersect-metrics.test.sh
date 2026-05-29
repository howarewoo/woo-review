#!/usr/bin/env bash
# Tests for the per-angle metrics emit in intersect-findings.sh (issue #41).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INTERSECT="$SCRIPT_DIR/skills/woo-review/scripts/intersect-findings.sh"

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
assert_eq() { local l="$1" g="$2" w="$3"; if [ "$g" = "$w" ]; then pass "$l"; else fail "$l (got '$g' want '$w')"; fi; }

mk() {
  local out="$1"; shift
  local arr="[]"
  for spec in "$@"; do
    IFS='|' read -r file line title sev blocking angle <<< "$spec"
    arr="$(jq --arg file "$file" --arg line "$line" --arg title "$title" \
      --arg sev "$sev" --argjson blocking "${blocking:-false}" --arg angle "$angle" \
      '. + [{file:$file, line:($line|tonumber), title:$title, severity:$sev, blocking:$blocking, angle:$angle}]' <<< "$arr")"
  done
  echo "$arr" > "$out"
}
new_outdir() { mktemp -d "${TMPDIR:-/tmp}/intersect-metrics.XXXXXX"; }

# Case 1: metrics OFF => no file
OUT="$(new_outdir)"
mk "$OUT/raw_findings.json"        "a.py|1|leak|HIGH|true|bugs"
mk "$OUT/findings.prosecutor.json" "a.py|1|leak|HIGH|true|bugs"
mk "$OUT/findings.defender.json"   "a.py|1|leak|HIGH|true|bugs"
OUTDIR="$OUT" bash "$INTERSECT" >/dev/null 2>&1
if [ -f "$OUT/findings.metrics.json" ]; then fail "metrics off => no file"; else pass "metrics off => no file"; fi
rm -rf "$OUT"

# Case 2: metrics ON, adversarial
OUT="$(new_outdir)"
echo '{"metrics":true}' > "$OUT/config.json"
mk "$OUT/raw_findings.json"        "a.py|1|leak|HIGH|true|bugs" "a.py|2|npe|MEDIUM|false|bugs" "b.py|9|xss|HIGH|true|security"
mk "$OUT/findings.prosecutor.json" "a.py|1|leak|HIGH|true|bugs" "a.py|2|npe|MEDIUM|false|bugs" "b.py|9|xss|HIGH|true|security"
mk "$OUT/findings.defender.json"   "a.py|1|leak|HIGH|true|bugs" "b.py|9|xss|HIGH|true|security"
OUTDIR="$OUT" bash "$INTERSECT" >/dev/null 2>&1
M="$OUT/findings.metrics.json"
assert_eq "c2 exists" "$( [ -f "$M" ] && echo yes )" "yes"
assert_eq "c2 bugs raw"       "$(jq -r '.angles.bugs.raw_count' "$M")" "2"
assert_eq "c2 bugs kept"      "$(jq -r '.angles.bugs.kept' "$M")" "1"
assert_eq "c2 bugs drop_def"  "$(jq -r '.angles.bugs.dropped_by_defender' "$M")" "1"
assert_eq "c2 bugs pros_kept" "$(jq -r '.angles.bugs.prosecutor_kept' "$M")" "2"
assert_eq "c2 bugs blocking"  "$(jq -r '.angles.bugs.blocking_count' "$M")" "1"
assert_eq "c2 bugs sevHIGH"   "$(jq -r '.angles.bugs.severity.HIGH' "$M")" "1"
assert_eq "c2 sec raw"        "$(jq -r '.angles.security.raw_count' "$M")" "1"
assert_eq "c2 sec kept"       "$(jq -r '.angles.security.kept' "$M")" "1"
assert_eq "c2 mode"           "$(jq -r '.mode' "$M")" "adversarial"
rm -rf "$OUT"

# Case 3: metrics ON, defender-only
OUT="$(new_outdir)"
echo '{"metrics":true,"disable_adversarial":true}' > "$OUT/config.json"
mk "$OUT/raw_findings.json"      "a.py|1|leak|HIGH|true|bugs"
mk "$OUT/findings.defender.json" "a.py|1|leak|HIGH|true|bugs"
OUTDIR="$OUT" bash "$INTERSECT" >/dev/null 2>&1
M="$OUT/findings.metrics.json"
assert_eq "c3 mode"          "$(jq -r '.mode' "$M")" "defender-only"
assert_eq "c3 bugs kept"     "$(jq -r '.angles.bugs.kept' "$M")" "1"
assert_eq "c3 pros null"     "$(jq -r '.angles.bugs.prosecutor_kept' "$M")" "null"
assert_eq "c3 dropdef null"  "$(jq -r '.angles.bugs.dropped_by_defender' "$M")" "null"
assert_eq "c3 droppros zero" "$(jq -r '.angles.bugs.dropped_by_prosecutor' "$M")" "0"
rm -rf "$OUT"

echo "intersect-metrics: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
