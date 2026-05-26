#!/usr/bin/env bash
# Unit tests for skills/woo-review/scripts/intersect-findings.sh (issue #13).
# Covers: full overlap, partial overlap (disagreement counting), severity
# merge rule, blocking AND rule, disable_adversarial fallthrough, and the
# "prosecutor file missing" fallback.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/woo-review/scripts/intersect-findings.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail=0

# Helper: run intersect against a fresh $WORK/case dir.
new_case() {
  local name="$1"
  CASE="$WORK/$name"
  mkdir -p "$CASE"
  export OUTDIR="$CASE"
}

assert_eq() {
  local name="$1" actual="$2" expected="$3"
  if [ "$actual" != "$expected" ]; then
    echo "FAIL $name: expected '$expected', got '$actual'"
    fail=1
    return 1
  fi
  return 0
}

# ---------- Case 1: full overlap — both passes keep identical findings ----------
new_case "full-overlap"
cat > "$CASE/findings.defender.json" <<'JSON'
[
  {"file":"a.ts","line":10,"title":"Off by one","severity":"HIGH","blocking":true,"description":"x","fix":"y","fix_type":"prose","suggestion":null,"angle":"bugs"},
  {"file":"b.ts","line":20,"title":"Null deref","severity":"MEDIUM","blocking":false,"description":"x","fix":"y","fix_type":"prose","suggestion":null,"angle":"bugs"}
]
JSON
cp "$CASE/findings.defender.json" "$CASE/findings.prosecutor.json"
bash "$SCRIPT" >/dev/null
ok=1
assert_eq "full-overlap kept" "$(jq 'length' "$CASE/findings.json")" "2" || ok=0
assert_eq "full-overlap mode" "$(jq -r '.mode' "$CASE/validator-metrics.json")" "adversarial" || ok=0
assert_eq "full-overlap disagreement" "$(jq -r '.disagreement_count' "$CASE/validator-metrics.json")" "0" || ok=0
[ $ok -eq 1 ] && echo "ok   full-overlap"

# ---------- Case 2: partial overlap — disagreement counted ----------
new_case "partial-overlap"
cat > "$CASE/findings.defender.json" <<'JSON'
[
  {"file":"a.ts","line":10,"title":"Off by one","severity":"HIGH","blocking":true,"description":"x","fix":"y","fix_type":"prose","suggestion":null,"angle":"bugs"},
  {"file":"b.ts","line":20,"title":"Defender only","severity":"LOW","blocking":false,"description":"x","fix":"y","fix_type":"prose","suggestion":null,"angle":"bugs"}
]
JSON
cat > "$CASE/findings.prosecutor.json" <<'JSON'
[
  {"file":"a.ts","line":10,"title":"Off by one","severity":"MEDIUM","blocking":false,"description":"x","fix":"y","fix_type":"prose","suggestion":null,"angle":"bugs"},
  {"file":"c.ts","line":30,"title":"Prosecutor only","severity":"HIGH","blocking":true,"description":"x","fix":"y","fix_type":"prose","suggestion":null,"angle":"security"}
]
JSON
bash "$SCRIPT" >/dev/null
ok=1
assert_eq "partial-overlap kept" "$(jq 'length' "$CASE/findings.json")" "1" || ok=0
assert_eq "partial-overlap kept-file" "$(jq -r '.[0].file' "$CASE/findings.json")" "a.ts" || ok=0
# Severity is min(HIGH,MEDIUM) = MEDIUM; blocking is AND(true,false) = false.
assert_eq "partial-overlap severity-min" "$(jq -r '.[0].severity' "$CASE/findings.json")" "MEDIUM" || ok=0
assert_eq "partial-overlap blocking-and" "$(jq -r '.[0].blocking' "$CASE/findings.json")" "false" || ok=0
assert_eq "partial-overlap disagreement" "$(jq -r '.disagreement_count' "$CASE/validator-metrics.json")" "2" || ok=0
assert_eq "partial-overlap pros-count" "$(jq -r '.prosecutor_count' "$CASE/validator-metrics.json")" "2" || ok=0
assert_eq "partial-overlap def-count" "$(jq -r '.defender_count' "$CASE/validator-metrics.json")" "2" || ok=0
[ $ok -eq 1 ] && echo "ok   partial-overlap"

# ---------- Case 3: severity LOW kept when both pick LOW (smoke) ----------
new_case "severity-low"
cat > "$CASE/findings.defender.json" <<'JSON'
[{"file":"a.ts","line":1,"title":"Nit","severity":"LOW","blocking":false,"description":"x","fix":"y","fix_type":"prose","suggestion":null,"angle":"bugs"}]
JSON
cp "$CASE/findings.defender.json" "$CASE/findings.prosecutor.json"
bash "$SCRIPT" >/dev/null
assert_eq "severity-low kept" "$(jq -r '.[0].severity' "$CASE/findings.json")" "LOW" && echo "ok   severity-low-preserved"

# ---------- Case 4: title-stem matches across punctuation/case differences ----------
new_case "stem-match"
cat > "$CASE/findings.defender.json" <<'JSON'
[{"file":"a.ts","line":42,"title":"Off-by-one in loop","severity":"HIGH","blocking":true,"description":"x","fix":"y","fix_type":"prose","suggestion":null,"angle":"bugs"}]
JSON
cat > "$CASE/findings.prosecutor.json" <<'JSON'
[{"file":"a.ts","line":42,"title":"OFF BY ONE IN LOOP!","severity":"HIGH","blocking":true,"description":"x","fix":"y","fix_type":"prose","suggestion":null,"angle":"bugs"}]
JSON
bash "$SCRIPT" >/dev/null
assert_eq "stem-match kept" "$(jq 'length' "$CASE/findings.json")" "1" && echo "ok   stem-match-normalization"

# ---------- Case 5: disable_adversarial=true → defender-only ----------
new_case "disable-flag"
cat > "$CASE/findings.defender.json" <<'JSON'
[{"file":"a.ts","line":1,"title":"keep me","severity":"HIGH","blocking":true,"description":"x","fix":"y","fix_type":"prose","suggestion":null,"angle":"bugs"}]
JSON
cat > "$CASE/findings.prosecutor.json" <<'JSON'
[]
JSON
echo '{"disable_adversarial":true}' > "$CASE/config.json"
bash "$SCRIPT" >/dev/null
ok=1
assert_eq "disable-flag kept" "$(jq 'length' "$CASE/findings.json")" "1" || ok=0
assert_eq "disable-flag mode" "$(jq -r '.mode' "$CASE/validator-metrics.json")" "defender-only" || ok=0
assert_eq "disable-flag pros-count" "$(jq -r '.prosecutor_count' "$CASE/validator-metrics.json")" "null" || ok=0
[ $ok -eq 1 ] && echo "ok   disable-flag-fallthrough"

# ---------- Case 6: prosecutor file missing → defender-only with ::warning ----------
new_case "pros-missing"
cat > "$CASE/findings.defender.json" <<'JSON'
[{"file":"a.ts","line":1,"title":"keep me","severity":"HIGH","blocking":true,"description":"x","fix":"y","fix_type":"prose","suggestion":null,"angle":"bugs"}]
JSON
warn_out="$CASE/warn.txt"
bash "$SCRIPT" 2>"$warn_out" >/dev/null
ok=1
assert_eq "pros-missing kept" "$(jq 'length' "$CASE/findings.json")" "1" || ok=0
assert_eq "pros-missing mode" "$(jq -r '.mode' "$CASE/validator-metrics.json")" "defender-only" || ok=0
if ! grep -q '::warning::intersect-findings' "$warn_out"; then
  echo "FAIL pros-missing-warning: no ::warning:: annotation emitted"
  cat "$warn_out"
  fail=1
  ok=0
fi
[ $ok -eq 1 ] && echo "ok   prosecutor-missing-fallthrough"

# ---------- Case 7: defender file missing → loud ::error + exit 1 ----------
new_case "def-missing"
cat > "$CASE/findings.prosecutor.json" <<'JSON'
[]
JSON
err_out="$CASE/err.txt"
if bash "$SCRIPT" 2>"$err_out" >/dev/null; then
  echo "FAIL defender-missing-fatal: script exited 0"
  fail=1
else
  if grep -q '::error::intersect-findings' "$err_out"; then
    echo "ok   defender-missing-fatal"
  else
    echo "FAIL defender-missing-fatal: no ::error:: annotation emitted"
    cat "$err_out"
    fail=1
  fi
fi

# ---------- Case 8: empty defender array → empty findings.json, metrics zeroed ----------
new_case "empty-both"
echo '[]' > "$CASE/findings.defender.json"
echo '[]' > "$CASE/findings.prosecutor.json"
bash "$SCRIPT" >/dev/null
ok=1
assert_eq "empty-both kept" "$(jq 'length' "$CASE/findings.json")" "0" || ok=0
assert_eq "empty-both disagreement" "$(jq -r '.disagreement_count' "$CASE/validator-metrics.json")" "0" || ok=0
[ $ok -eq 1 ] && echo "ok   empty-both-arrays"

if [ $fail -ne 0 ]; then
  echo "TESTS FAILED"
  exit 1
fi
echo "All intersect-findings tests passed."
