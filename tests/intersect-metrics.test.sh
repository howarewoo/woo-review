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

# Case 4: metrics-emit failure must NOT abort the review (PR #52, set -euo pipefail
# guard regression). A failing emit_angle_metrics call site previously propagated
# under `set -e` and killed the pipeline before/after the review work. Shim python3
# so ONLY the emit invocation (the one passed findings.metrics.json) fails; the
# intersect's own python3 calls pass through to the real binary.
make_failing_emit_python() {
  local bindir="$1"
  mkdir -p "$bindir"
  cat > "$bindir/python3" <<'SHIM'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    *findings.metrics.json) echo "boom: simulated emit failure" >&2; exit 1 ;;
  esac
done
exec /usr/bin/env -i PATH="$REAL_PATH" python3 "$@"
SHIM
  chmod +x "$bindir/python3"
}

# 4a: adversarial exit path (line 360)
OUT="$(new_outdir)"; BIN="$(new_outdir)"
echo '{"metrics":true}' > "$OUT/config.json"
mk "$OUT/raw_findings.json"        "a.py|1|leak|HIGH|true|bugs"
mk "$OUT/findings.prosecutor.json" "a.py|1|leak|HIGH|true|bugs"
mk "$OUT/findings.defender.json"   "a.py|1|leak|HIGH|true|bugs"
make_failing_emit_python "$BIN"
REAL_PATH="$PATH" PATH="$BIN:$PATH" OUTDIR="$OUT" bash "$INTERSECT" >/dev/null 2>&1
assert_eq "c4a exit 0 despite emit fail" "$?" "0"
assert_eq "c4a findings.json written"    "$( [ -f "$OUT/findings.json" ] && echo yes )" "yes"
assert_eq "c4a final kept"               "$(jq 'length' "$OUT/findings.json")" "1"
rm -rf "$OUT" "$BIN"

# 4b: defender-only exit path (line 218)
OUT="$(new_outdir)"; BIN="$(new_outdir)"
echo '{"metrics":true,"disable_adversarial":true}' > "$OUT/config.json"
mk "$OUT/raw_findings.json"      "a.py|1|leak|HIGH|true|bugs"
mk "$OUT/findings.defender.json" "a.py|1|leak|HIGH|true|bugs"
make_failing_emit_python "$BIN"
REAL_PATH="$PATH" PATH="$BIN:$PATH" OUTDIR="$OUT" bash "$INTERSECT" >/dev/null 2>&1
assert_eq "c4b exit 0 despite emit fail" "$?" "0"
assert_eq "c4b findings.json written"    "$( [ -f "$OUT/findings.json" ] && echo yes )" "yes"
rm -rf "$OUT" "$BIN"

echo "intersect-metrics: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
