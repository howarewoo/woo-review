#!/usr/bin/env bash
# Tests for metrics-fold.sh — rolling aggregate fold (issue #41).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FOLD="$SCRIPT_DIR/skills/woo-review/scripts/metrics-fold.sh"

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
assert_eq() { local l="$1" g="$2" w="$3"; if [ "$g" = "$w" ]; then pass "$l"; else fail "$l (got '$g' want '$w')"; fi; }

mk_run() {
  local outdir="$1" raw="$2" kept="$3" dd="$4" dp="$5" blk="$6" high="$7"
  cat > "$outdir/findings.metrics.json" <<EOF
{ "schema_version":1, "mode":"adversarial", "degraded":false,
  "angles": { "bugs": {
    "raw_count":$raw, "defender_kept":$kept, "kept":$kept,
    "dropped_by_defender":$dd, "dropped_by_prosecutor":$dp,
    "prosecutor_kept":$kept, "blocking_count":$blk,
    "nonblocking_count":0, "severity":{"HIGH":$high,"MEDIUM":0,"LOW":0} } } }
EOF
}
setup() {
  WS="$(mktemp -d "${TMPDIR:-/tmp}/fold-ws.XXXXXX")"
  OUT="$(mktemp -d "${TMPDIR:-/tmp}/fold-out.XXXXXX")"
  echo '{"metrics":true}' > "$OUT/config.json"
}
teardown() { rm -rf "$WS" "$OUT"; }
run_fold() { GITHUB_WORKSPACE="$WS" OUTDIR="$OUT" bash "$FOLD" >/dev/null 2>&1; }
ROLLING() { echo "$WS/.woo-review/metrics.json"; }

# Case 1: seed
setup
mk_run "$OUT" 12 7 4 1 3 2; run_fold
R="$(ROLLING)"
assert_eq "seed runs"        "$(jq -r '.runs' "$R")" "1"
assert_eq "seed raw_total"   "$(jq -r '.angles.bugs.raw_total' "$R")" "12"
assert_eq "seed kept_total"  "$(jq -r '.angles.bugs.kept_total' "$R")" "7"
assert_eq "seed dd_total"    "$(jq -r '.angles.bugs.dropped_by_defender_total' "$R")" "4"
assert_eq "seed runs_present" "$(jq -r '.angles.bugs.runs_present' "$R")" "1"
assert_eq "seed sevHIGH"     "$(jq -r '.angles.bugs.severity_total.HIGH' "$R")" "2"
teardown

# Case 2: accumulate
setup
mk_run "$OUT" 12 7 4 1 3 2; run_fold
mk_run "$OUT" 8 5 2 1 1 1;  run_fold
R="$(ROLLING)"
assert_eq "accum runs"         "$(jq -r '.runs' "$R")" "2"
assert_eq "accum raw_total"    "$(jq -r '.angles.bugs.raw_total' "$R")" "20"
assert_eq "accum kept_total"   "$(jq -r '.angles.bugs.kept_total' "$R")" "12"
assert_eq "accum runs_present" "$(jq -r '.angles.bugs.runs_present' "$R")" "2"
teardown

# Case 3: gitignore ensured + idempotent
setup
mk_run "$OUT" 1 1 0 0 0 1; run_fold; run_fold
assert_eq "gitignore one entry" "$(grep -cxF '.woo-review/metrics.json' "$WS/.gitignore")" "1"
teardown

# Case 4: version mismatch => reseed + .bak
setup
mkdir -p "$WS/.woo-review"
echo '{"schema_version":999,"runs":50,"angles":{}}' > "$(ROLLING)"
mk_run "$OUT" 3 3 0 0 1 1; run_fold
R="$(ROLLING)"
assert_eq "ver reseed runs" "$(jq -r '.runs' "$R")" "1"
assert_eq "ver bak exists"  "$( [ -f "$R.bak" ] && echo yes )" "yes"
teardown

# Case 5: corrupt => reseed + .bak
setup
mkdir -p "$WS/.woo-review"
printf 'not json{{' > "$(ROLLING)"
mk_run "$OUT" 3 3 0 0 1 1; run_fold
R="$(ROLLING)"
assert_eq "corrupt reseed runs" "$(jq -r '.runs' "$R")" "1"
assert_eq "corrupt bak exists"  "$( [ -f "$R.bak" ] && echo yes )" "yes"
teardown

# Case 6: metrics off => no-op
setup
echo '{"metrics":false}' > "$OUT/config.json"
mk_run "$OUT" 9 9 0 0 0 0; run_fold
assert_eq "off no rolling" "$( [ -f "$(ROLLING)" ] && echo yes || echo no )" "no"
teardown

# Case 8: metrics on but no per-run file => no-op (spec-stated guard)
setup
run_fold
assert_eq "no-input no rolling" "$( [ -f "$(ROLLING)" ] && echo yes || echo no )" "no"
teardown

# Case 7: defender-only nulls fold as zero
setup
cat > "$OUT/findings.metrics.json" <<'EOF'
{ "schema_version":1, "mode":"defender-only", "degraded":false,
  "angles": { "bugs": {
    "raw_count":5, "defender_kept":5, "kept":5,
    "dropped_by_defender":null, "dropped_by_prosecutor":0,
    "prosecutor_kept":null, "blocking_count":2, "nonblocking_count":3,
    "severity":{"HIGH":2,"MEDIUM":3,"LOW":0} } } }
EOF
run_fold
R="$(ROLLING)"
assert_eq "defonly runs"   "$(jq -r '.runs' "$R")" "1"
assert_eq "defonly dd_tot" "$(jq -r '.angles.bugs.dropped_by_defender_total' "$R")" "0"
assert_eq "defonly raw"    "$(jq -r '.angles.bugs.raw_total' "$R")" "5"
teardown

echo "metrics-fold: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
