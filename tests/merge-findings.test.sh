#!/usr/bin/env bash
# Unit tests for skills/woo-review/scripts/merge-findings.sh.
# Covers concatenation across angle files + within-angle cross-chunk dedup
# (issue #14 acceptance bullet 4).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/woo-review/scripts/merge-findings.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail=0

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

# ---------- Case 1: plain concatenation across two angle files ----------
new_case "concat"
cat > "$CASE/findings.bugs.json" <<'JSON'
[{"angle":"bugs","file":"a.ts","line":1,"title":"A","severity":"HIGH","blocking":true,"description":"d","fix":"f","fix_type":"prose","suggestion":null}]
JSON
cat > "$CASE/findings.security.json" <<'JSON'
[{"angle":"security","file":"b.ts","line":2,"title":"B","severity":"MEDIUM","blocking":false,"description":"d","fix":"f","fix_type":"prose","suggestion":null}]
JSON
bash "$SCRIPT" >/dev/null
assert_eq "concat-count" "$(jq 'length' "$CASE/raw_findings.json")" "2" && echo "ok   plain-concat"

# ---------- Case 2: within-angle cross-chunk dedup ----------
new_case "chunk-dedup"
# Same (angle, file, line, title-stem) reported by chunk-0 and chunk-1.
cat > "$CASE/findings.bugs.chunk-0.json" <<'JSON'
[
  {"angle":"bugs","file":"shared/util.ts","line":42,"title":"Off-by-one in loop","severity":"HIGH","blocking":true,"description":"chunk-0 description","fix":"f","fix_type":"prose","suggestion":null},
  {"angle":"bugs","file":"chunk0/only.ts","line":10,"title":"Unique to chunk-0","severity":"LOW","blocking":false,"description":"d","fix":"f","fix_type":"prose","suggestion":null}
]
JSON
cat > "$CASE/findings.bugs.chunk-1.json" <<'JSON'
[
  {"angle":"bugs","file":"shared/util.ts","line":42,"title":"OFF BY ONE IN LOOP!","severity":"HIGH","blocking":true,"description":"chunk-1 description","fix":"f","fix_type":"prose","suggestion":null},
  {"angle":"bugs","file":"chunk1/only.ts","line":11,"title":"Unique to chunk-1","severity":"LOW","blocking":false,"description":"d","fix":"f","fix_type":"prose","suggestion":null}
]
JSON
bash "$SCRIPT" >/dev/null
ok=1
# Total = 4 across files; after dedup the shared finding collapses to 1, so 3 unique.
assert_eq "dedup-count" "$(jq 'length' "$CASE/raw_findings.json")" "3" || ok=0
# Both unique-only findings must survive.
if ! jq -e '[.[].file] | contains(["chunk0/only.ts","chunk1/only.ts"])' "$CASE/raw_findings.json" >/dev/null; then
  echo "FAIL chunk-dedup: unique findings dropped"
  fail=1
  ok=0
fi
# The shared finding should appear exactly once.
assert_eq "dedup-shared-count" "$(jq '[.[] | select(.file == "shared/util.ts")] | length' "$CASE/raw_findings.json")" "1" || ok=0
[ $ok -eq 1 ] && echo "ok   within-angle-cross-chunk-dedup"

# ---------- Case 3: cross-ANGLE duplicates are preserved (validator's job) ----------
new_case "cross-angle-preserved"
cat > "$CASE/findings.bugs.json" <<'JSON'
[{"angle":"bugs","file":"a.ts","line":1,"title":"Same finding","severity":"HIGH","blocking":true,"description":"d","fix":"f","fix_type":"prose","suggestion":null}]
JSON
cat > "$CASE/findings.security.json" <<'JSON'
[{"angle":"security","file":"a.ts","line":1,"title":"Same finding","severity":"HIGH","blocking":true,"description":"d","fix":"f","fix_type":"prose","suggestion":null}]
JSON
bash "$SCRIPT" >/dev/null
# Cross-angle dedup belongs to the validator stage; merge must keep both.
assert_eq "cross-angle-count" "$(jq 'length' "$CASE/raw_findings.json")" "2" && echo "ok   cross-angle-dedup-deferred-to-validator"

# ---------- Case 4: empty + malformed inputs ignored, valid one kept ----------
new_case "robust"
: > "$CASE/findings.empty.json"
echo 'not json' > "$CASE/findings.malformed.json"
cat > "$CASE/findings.bugs.json" <<'JSON'
[{"angle":"bugs","file":"a.ts","line":1,"title":"survivor","severity":"LOW","blocking":false,"description":"d","fix":"f","fix_type":"prose","suggestion":null}]
JSON
bash "$SCRIPT" >"$CASE/log.txt" 2>&1
ok=1
assert_eq "robust-count" "$(jq 'length' "$CASE/raw_findings.json")" "1" || ok=0
grep -q 'Skipping empty' "$CASE/log.txt" || { echo "FAIL robust: empty file not warned about"; fail=1; ok=0; }
grep -q 'Skipping malformed' "$CASE/log.txt" || { echo "FAIL robust: malformed file not warned about"; fail=1; ok=0; }
[ $ok -eq 1 ] && echo "ok   empty-and-malformed-files-skipped"

# ---------- Case 5: prose preamble before JSON array is recovered ----------
new_case "preamble-recovery"
cat > "$CASE/findings.security.json" <<'EOF'
I have completed the review and identified the following issue.

[{"angle":"security","file":"a.ts","line":1,"title":"Recovered","severity":"MEDIUM","blocking":false,"description":"d","fix":"f","fix_type":"prose","suggestion":null}]

Done.
EOF
bash "$SCRIPT" >"$CASE/log.txt" 2>&1
ok=1
assert_eq "preamble-count" "$(jq 'length' "$CASE/raw_findings.json")" "1" || ok=0
grep -q 'Recovered JSON array from preamble' "$CASE/log.txt" || { echo "FAIL preamble: recovery warning missing"; fail=1; ok=0; }
if ! jq -e '.[0].title == "Recovered"' "$CASE/raw_findings.json" >/dev/null; then
  echo "FAIL preamble: recovered finding has wrong title"
  fail=1
  ok=0
fi
[ $ok -eq 1 ] && echo "ok   preamble-recovered"

# ---------- Case 6: line-resolve safety net drops unresolvable findings ----------
new_case "line-resolve-drop"
# Diff: adds two lines (post-patch lines 13 and 14) in src/foo.ts.
cat > "$CASE/diff.txt" <<'DIFF'
diff --git a/src/foo.ts b/src/foo.ts
--- a/src/foo.ts
+++ b/src/foo.ts
@@ -10,4 +10,5 @@ function foo() {
   const a = 1;
   const b = 2;
-  return a;
+  return a + b;
+  // new line
 }
DIFF
cat > "$CASE/findings.bugs.json" <<'JSON'
[
  {"angle":"bugs","file":"src/foo.ts","line":13,"title":"in-diff","severity":"HIGH","blocking":true,"description":"d","fix":"f","fix_type":"prose","suggestion":null},
  {"angle":"bugs","file":"src/foo.ts","line":99,"title":"out-of-range","severity":"LOW","blocking":false,"description":"d","fix":"f","fix_type":"prose","suggestion":null},
  {"angle":"bugs","file":"src/nope.ts","line":1,"title":"file-not-in-diff","severity":"LOW","blocking":false,"description":"d","fix":"f","fix_type":"prose","suggestion":null}
]
JSON
bash "$SCRIPT" >"$CASE/log.txt" 2>&1
ok=1
assert_eq "line-resolve-count" "$(jq 'length' "$CASE/raw_findings.json")" "1" || ok=0
if ! jq -e '.[0].title == "in-diff"' "$CASE/raw_findings.json" >/dev/null; then
  echo "FAIL line-resolve: wrong finding survived"
  fail=1
  ok=0
fi
grep -q 'line-resolve safety net dropped' "$CASE/log.txt" || { echo "FAIL line-resolve: drop log missing"; fail=1; ok=0; }
[ $ok -eq 1 ] && echo "ok   line-resolve-safety-net-drops-unresolvable"

# ---------- Case 7: prosecutor/defender files excluded from merge ----------
new_case "intermediate-files-excluded"
cat > "$CASE/findings.bugs.json" <<'JSON'
[{"angle":"bugs","file":"a.ts","line":1,"title":"only-survivor","severity":"LOW","blocking":false,"description":"d","fix":"f","fix_type":"prose","suggestion":null}]
JSON
cat > "$CASE/findings.prosecutor.json" <<'JSON'
[{"angle":"bugs","file":"a.ts","line":1,"title":"prosecutor-leak","severity":"LOW","blocking":false,"description":"d","fix":"f","fix_type":"prose","suggestion":null}]
JSON
cat > "$CASE/findings.defender.json" <<'JSON'
[{"angle":"bugs","file":"a.ts","line":1,"title":"defender-leak","severity":"LOW","blocking":false,"description":"d","fix":"f","fix_type":"prose","suggestion":null}]
JSON
bash "$SCRIPT" >"$CASE/log.txt" 2>&1
ok=1
assert_eq "intermediates-excluded-count" "$(jq 'length' "$CASE/raw_findings.json")" "1" || ok=0
if ! jq -e '.[0].title == "only-survivor"' "$CASE/raw_findings.json" >/dev/null; then
  echo "FAIL intermediates: prosecutor/defender leaked into merge"
  fail=1
  ok=0
fi
[ $ok -eq 1 ] && echo "ok   prosecutor-and-defender-files-excluded"

# ---------- Case 8: bad-escape JSON recovered via sanitizer ----------
# Sub-agents occasionally emit `\x`, `\!`, or a bare control byte inside a
# string field — strict JSON parsers reject it. The recovery path should
# strip invalid escapes + control bytes (json.loads strict=False fallback)
# and still surface the finding rather than dropping the whole file.
new_case "bad-escape-recovery"
python3 - "$CASE/findings.bugs.json" <<'PY'
import sys
# Use Python to write the file with deliberate JSON-invalid bytes so the
# heredoc itself cannot accidentally normalize them.
text = (
    '[\n'
    '  {"angle":"bugs","file":"a.ts","line":1,"title":"escape-survivor",'
    '"severity":"HIGH","blocking":true,'
    # Invalid \x escape inside description + a bare 0x07 BEL control byte.
    '"description":"path C:\\x5cusers\\x07","fix":"f",'
    '"fix_type":"prose","suggestion":null}\n'
    ']\n'
)
open(sys.argv[1], "w").write(text)
PY
bash "$SCRIPT" >"$CASE/log.txt" 2>&1
ok=1
assert_eq "bad-escape-count" "$(jq 'length' "$CASE/raw_findings.json")" "1" || ok=0
if ! jq -e '.[0].title == "escape-survivor"' "$CASE/raw_findings.json" >/dev/null; then
  echo "FAIL bad-escape: finding lost during sanitization"
  cat "$CASE/log.txt"
  fail=1
  ok=0
fi
grep -q 'Recovered JSON array from preamble' "$CASE/log.txt" \
  || { echo "FAIL bad-escape: recovery path did not engage (file went straight to skip)"; fail=1; ok=0; }
[ $ok -eq 1 ] && echo "ok   bad-escape-recovered"

if [ $fail -ne 0 ]; then
  echo "TESTS FAILED"
  exit 1
fi
echo "All merge-findings tests passed."
