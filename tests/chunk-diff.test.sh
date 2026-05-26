#!/usr/bin/env bash
# Unit tests for skills/woo-review/scripts/chunk-diff.sh (issue #14).
# Covers: under-threshold no-op, threshold=0 disabled, workspace boundary
# preference, top-level fallback, oversized-group splitting, stale-chunk cleanup.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/woo-review/scripts/chunk-diff.sh"
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

# Emit a synthetic diff section for `path` with `loc` added lines.
make_section() {
  local path="$1" loc="$2"
  printf 'diff --git a/%s b/%s\n' "$path" "$path"
  printf 'index 0000001..0000002 100644\n'
  printf '%s\n' "--- a/$path"
  printf '%s\n' "+++ b/$path"
  printf '@@ -1,%d +1,%d @@\n' 1 "$loc"
  local i=1
  while [ "$i" -le "$loc" ]; do
    printf '+line %d in %s\n' "$i" "$path"
    i=$((i + 1))
  done
}

# ---------- Case 1: under-threshold no-op ----------
new_case "under-threshold"
{
  make_section "src/foo.ts" 100
} > "$CASE/diff.txt"
echo '{}' > "$CASE/config.json"
bash "$SCRIPT" >"$CASE/log.txt"
ok=1
[ -f "$CASE/chunks.txt" ] && { echo "FAIL under-threshold: chunks.txt should not exist"; fail=1; ok=0; }
[ -f "$CASE/chunks.json" ] && { echo "FAIL under-threshold: chunks.json should not exist"; fail=1; ok=0; }
ls "$CASE"/diff.chunk-*.txt 2>/dev/null | grep -q . && { echo "FAIL under-threshold: stray diff.chunk-* files"; fail=1; ok=0; }
[ $ok -eq 1 ] && echo "ok   under-threshold-no-op"

# ---------- Case 2: max_loc=0 disables chunking entirely ----------
new_case "disabled"
{
  make_section "src/a.ts" 5000
  make_section "src/b.ts" 5000
} > "$CASE/diff.txt"
echo '{"chunking":{"max_loc":0}}' > "$CASE/config.json"
bash "$SCRIPT" >"$CASE/log.txt"
ok=1
[ -f "$CASE/chunks.txt" ] && { echo "FAIL disabled: chunks.txt should not exist"; fail=1; ok=0; }
[ $ok -eq 1 ] && echo "ok   max-loc-zero-disables"

# ---------- Case 3: workspace boundaries preferred ----------
new_case "workspace"
{
  make_section "packages/foo/index.ts" 800
  make_section "packages/bar/index.ts" 800
  make_section "apps/web/page.tsx"     800
} > "$CASE/diff.txt"
echo '{"chunking":{"max_loc":1000}}' > "$CASE/config.json"
bash "$SCRIPT" >"$CASE/log.txt"
ok=1
[ -f "$CASE/chunks.txt" ] || { echo "FAIL workspace: chunks.txt missing"; fail=1; ok=0; }
if [ $ok -eq 1 ]; then
  # Three separate workspace groups, each <= 1000 — first-fit-decreasing
  # cannot share a bin (800+800=1600 > 1000), so we get 3 chunks.
  assert_eq "workspace chunk-count" "$(wc -l < "$CASE/chunks.txt" | xargs)" "3" || ok=0
  # Boundaries should be `ws:packages/<n>` or `ws:apps/<n>` — never "td:".
  boundaries=$(jq -r '.[].boundary' "$CASE/chunks.json" | sort -u)
  if echo "$boundaries" | grep -q '^td:'; then
    echo "FAIL workspace: top-level boundary leaked in: $boundaries"
    fail=1
    ok=0
  fi
  if ! echo "$boundaries" | grep -qE '^ws:(packages|apps)/'; then
    echo "FAIL workspace: no workspace boundary present: $boundaries"
    fail=1
    ok=0
  fi
  # Each chunk's `files` should be a subset of one workspace package.
  while read -r files; do
    pkg=$(echo "$files" | jq -r '.[0]' | awk -F/ '{print $1"/"$2}')
    if echo "$files" | jq -e --arg p "$pkg/" 'all(.[]; startswith($p))' >/dev/null; then :; else
      echo "FAIL workspace: chunk mixes workspaces: $files"
      fail=1
      ok=0
    fi
  done < <(jq -c '.[].files' "$CASE/chunks.json")
fi
[ $ok -eq 1 ] && echo "ok   workspace-boundary-preference"

# ---------- Case 4: top-level dir fallback when no workspace markers ----------
new_case "top-level"
{
  make_section "src/foo.ts"     400
  make_section "src/bar.ts"     400
  make_section "tests/baz.test.ts" 400
} > "$CASE/diff.txt"
echo '{"chunking":{"max_loc":500}}' > "$CASE/config.json"
bash "$SCRIPT" >"$CASE/log.txt"
ok=1
[ -f "$CASE/chunks.txt" ] || { echo "FAIL top-level: chunks.txt missing"; fail=1; ok=0; }
if [ $ok -eq 1 ]; then
  # `src` group is 800 LOC > 500 max → splits in 2 sub-chunks. `tests` is 400 → fits one chunk.
  # Total chunks: 3.
  assert_eq "top-level chunk-count" "$(wc -l < "$CASE/chunks.txt" | xargs)" "3" || ok=0
  # All boundaries should be `td:*` (no workspace involved here).
  if jq -r '.[].boundary' "$CASE/chunks.json" | grep -q '^ws:'; then
    echo "FAIL top-level: workspace boundary in non-workspace diff"
    fail=1
    ok=0
  fi
fi
[ $ok -eq 1 ] && echo "ok   top-level-dir-fallback"

# ---------- Case 5: single oversized file ----------
new_case "oversized-single"
{
  make_section "src/giant.ts" 600
} > "$CASE/diff.txt"
echo '{"chunking":{"max_loc":300}}' > "$CASE/config.json"
bash "$SCRIPT" >"$CASE/log.txt"
ok=1
[ -f "$CASE/chunks.txt" ] || { echo "FAIL oversized-single: chunks.txt missing"; fail=1; ok=0; }
if [ $ok -eq 1 ]; then
  # Single file cannot be physically split mid-section — best we can do is one chunk.
  # Documented limitation; the chunk still gets through to the worker.
  assert_eq "oversized-single chunk-count" "$(wc -l < "$CASE/chunks.txt" | xargs)" "1" || ok=0
fi
[ $ok -eq 1 ] && echo "ok   oversized-single-file-best-effort"

# ---------- Case 6: stale chunk artifacts cleaned up on no-chunk run ----------
new_case "stale-cleanup"
{
  make_section "packages/foo/index.ts" 5000
  make_section "packages/bar/index.ts" 5000
} > "$CASE/diff.txt"
echo '{"chunking":{"max_loc":1000}}' > "$CASE/config.json"
bash "$SCRIPT" >"$CASE/log.txt"
[ -f "$CASE/chunks.txt" ] || { echo "FAIL stale-cleanup: setup didn't produce chunks"; fail=1; }
# Now shrink the diff under threshold and re-run.
{
  make_section "src/tiny.ts" 50
} > "$CASE/diff.txt"
bash "$SCRIPT" >"$CASE/log.txt"
ok=1
[ -f "$CASE/chunks.txt" ] && { echo "FAIL stale-cleanup: chunks.txt should have been removed"; fail=1; ok=0; }
ls "$CASE"/diff.chunk-*.txt 2>/dev/null | grep -q . && { echo "FAIL stale-cleanup: stale diff.chunk-* not cleaned"; fail=1; ok=0; }
[ $ok -eq 1 ] && echo "ok   stale-chunks-cleaned-up"

# ---------- Case 7: per-chunk diff files re-assemble into a valid diff stream ----------
new_case "diff-roundtrip"
{
  make_section "packages/foo/a.ts" 800
  make_section "packages/bar/b.ts" 800
} > "$CASE/diff.txt"
echo '{"chunking":{"max_loc":1000}}' > "$CASE/config.json"
bash "$SCRIPT" >"$CASE/log.txt"
ok=1
EXPECTED_LOC=$(grep -cE '^[+-][^+-]' "$CASE/diff.txt" || true)
TOTAL_LOC=0
for cf in "$CASE"/diff.chunk-*.txt; do
  c=$(grep -cE '^[+-][^+-]' "$cf" || true)
  TOTAL_LOC=$((TOTAL_LOC + c))
done
assert_eq "diff-roundtrip LOC sum" "$TOTAL_LOC" "$EXPECTED_LOC" || ok=0
# Every chunk's diff must start with a `diff --git ` header — a worker reading
# it must see a valid stream.
for cf in "$CASE"/diff.chunk-*.txt; do
  head -n 1 "$cf" | grep -q '^diff --git ' || {
    echo "FAIL diff-roundtrip: $cf does not start with diff --git header"
    fail=1
    ok=0
  }
done
[ $ok -eq 1 ] && echo "ok   chunk-diff-roundtrip"

if [ $fail -ne 0 ]; then
  echo "TESTS FAILED"
  exit 1
fi
echo "All chunk-diff tests passed."
