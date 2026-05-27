#!/usr/bin/env bash
# Unit tests for skills/woo-review/scripts/resolve-diff-line.sh.
# Verifies source-line → RIGHT-side mapping across the cases that bit us in
# production: added-only hunks, mixed hunks, deletion-only regions, multi-hunk
# files, files not in the diff, decimal-formatted line numbers, and the cache.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/woo-review/scripts/resolve-diff-line.sh"
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

# ---------- Case 1: added-only hunk, line resolves ----------
new_case "added-only"
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
ok=1
assert_eq "added-line-13" "$(bash "$SCRIPT" --file src/foo.ts --line 13)" "13" || ok=0
assert_eq "added-line-14" "$(bash "$SCRIPT" --file src/foo.ts --line 14)" "14" || ok=0
# Context lines (10, 11) on the right side resolve to themselves.
assert_eq "context-line-10" "$(bash "$SCRIPT" --file src/foo.ts --line 10)" "10" || ok=0
[ $ok -eq 1 ] && echo "ok   added-and-context-lines-resolve"

# ---------- Case 2: deletion-only line returns null ----------
new_case "deletion-only"
cat > "$CASE/diff.txt" <<'DIFF'
diff --git a/src/foo.ts b/src/foo.ts
--- a/src/foo.ts
+++ b/src/foo.ts
@@ -5,3 +5,2 @@
 keep
-deleted
 keep
DIFF
ok=1
# Post-patch file has lines 5 and 6 only (both context). Line 7 doesn't exist
# on RIGHT (only on LEFT). Returns null.
assert_eq "deletion-only-line-7" "$(bash "$SCRIPT" --file src/foo.ts --line 7)" "null" || ok=0
# Lines 5 and 6 are RIGHT-side context; resolve to themselves.
assert_eq "context-after-deletion-line-5" "$(bash "$SCRIPT" --file src/foo.ts --line 5)" "5" || ok=0
assert_eq "context-after-deletion-line-6" "$(bash "$SCRIPT" --file src/foo.ts --line 6)" "6" || ok=0
[ $ok -eq 1 ] && echo "ok   deletion-only-region-returns-null"

# ---------- Case 3: line outside any hunk returns null ----------
new_case "out-of-range"
cat > "$CASE/diff.txt" <<'DIFF'
diff --git a/src/foo.ts b/src/foo.ts
--- a/src/foo.ts
+++ b/src/foo.ts
@@ -10,2 +10,2 @@
-old
+new
DIFF
assert_eq "out-of-range" "$(bash "$SCRIPT" --file src/foo.ts --line 999)" "null" && echo "ok   line-outside-any-hunk-returns-null"

# ---------- Case 4: multi-hunk file with two separate added regions ----------
new_case "multi-hunk"
cat > "$CASE/diff.txt" <<'DIFF'
diff --git a/src/foo.ts b/src/foo.ts
--- a/src/foo.ts
+++ b/src/foo.ts
@@ -3,2 +3,3 @@
 a
+inserted-near-top
 b
@@ -20,2 +21,3 @@
 c
+inserted-near-bottom
 d
DIFF
ok=1
# After the first +1 line, the second hunk's RIGHT starts at 21 per the header.
assert_eq "first-hunk-added" "$(bash "$SCRIPT" --file src/foo.ts --line 4)" "4" || ok=0
assert_eq "second-hunk-added" "$(bash "$SCRIPT" --file src/foo.ts --line 22)" "22" || ok=0
# Line 100 sits past both hunks → null.
assert_eq "past-all-hunks" "$(bash "$SCRIPT" --file src/foo.ts --line 100)" "null" || ok=0
[ $ok -eq 1 ] && echo "ok   multi-hunk-file-resolves-per-hunk"

# ---------- Case 5: file not in diff returns null ----------
new_case "file-absent"
cat > "$CASE/diff.txt" <<'DIFF'
diff --git a/src/foo.ts b/src/foo.ts
--- a/src/foo.ts
+++ b/src/foo.ts
@@ -1,1 +1,1 @@
-x
+y
DIFF
assert_eq "file-not-in-diff" "$(bash "$SCRIPT" --file src/nope.ts --line 1)" "null" && echo "ok   file-not-in-diff-returns-null"

# ---------- Case 6: decimal-string line number is parsed defensively ----------
new_case "decimal-string"
cat > "$CASE/diff.txt" <<'DIFF'
diff --git a/src/foo.ts b/src/foo.ts
--- a/src/foo.ts
+++ b/src/foo.ts
@@ -1,1 +1,2 @@
 x
+y
DIFF
assert_eq "non-integer-line" "$(bash "$SCRIPT" --file src/foo.ts --line "abc")" "null" && echo "ok   non-integer-line-returns-null"

# ---------- Case 7: missing diff file returns null (no crash) ----------
new_case "no-diff"
# Intentionally no diff.txt in $CASE.
assert_eq "no-diff-file" "$(bash "$SCRIPT" --file src/foo.ts --line 1)" "null" && echo "ok   missing-diff-returns-null"

# ---------- Case 8: cache memoization persists across calls ----------
new_case "cache"
cat > "$CASE/diff.txt" <<'DIFF'
diff --git a/src/foo.ts b/src/foo.ts
--- a/src/foo.ts
+++ b/src/foo.ts
@@ -1,1 +1,2 @@
 x
+y
DIFF
bash "$SCRIPT" --file src/foo.ts --line 2 >/dev/null
bash "$SCRIPT" --file src/foo.ts --line 99 >/dev/null
if [ ! -s "$CASE/diff-line-cache.json" ]; then
  echo "FAIL cache: diff-line-cache.json was not written"
  fail=1
else
  if ! jq -e '."src/foo.ts:2" == "2" and ."src/foo.ts:99" == "null"' "$CASE/diff-line-cache.json" >/dev/null; then
    echo "FAIL cache: cache content unexpected"
    cat "$CASE/diff-line-cache.json"
    fail=1
  else
    echo "ok   cache-memoization-persists"
  fi
fi

# ---------- Case 9: --no-cache skips the cache write ----------
new_case "no-cache"
cat > "$CASE/diff.txt" <<'DIFF'
diff --git a/src/foo.ts b/src/foo.ts
--- a/src/foo.ts
+++ b/src/foo.ts
@@ -1,1 +1,2 @@
 x
+y
DIFF
bash "$SCRIPT" --file src/foo.ts --line 2 --no-cache >/dev/null
if [ -f "$CASE/diff-line-cache.json" ]; then
  echo "FAIL no-cache: cache file should not exist with --no-cache"
  fail=1
else
  echo "ok   --no-cache-skips-cache-write"
fi

if [ $fail -ne 0 ]; then
  echo "TESTS FAILED"
  exit 1
fi
echo "All resolve-diff-line tests passed."
