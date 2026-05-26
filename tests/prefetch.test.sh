#!/usr/bin/env bash
# Unit test for skills/woo-review/scripts/prefetch.sh — incremental review paths.
# Six cases covering marker absent/present, force-push fallback, empty diff, and
# the --full / INPUT_INCREMENTAL=off override. Uses a gh shim on PATH + the
# WOO_REVIEW_FAKE_* env hooks built into prefetch.sh to avoid any network calls.
#
# Exits non-zero on the first failure. CI-safe.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/woo-review/scripts/prefetch.sh"
WORK="$(mktemp -d)"
PREFETCH="/tmp/pr-review"
mkdir -p "$PREFETCH"

trap 'rm -rf "$WORK" "$PREFETCH"' EXIT

# gh shim — dispatches on argv pattern. Only handles the invocations prefetch.sh
# makes; anything else is a test bug and exits non-zero.
BIN="$WORK/bin"
mkdir -p "$BIN"
cat > "$BIN/gh" <<'SHIM'
#!/usr/bin/env bash
set -e
ARGS="$*"
# gh pr view N --json labels --jq '...' → no labels, no skip.
if [[ "$ARGS" == *"--json labels"* ]]; then
  echo ""
  exit 0
fi
# gh pr view N --json comments --jq '... | length' → 0 prior bot comments.
if [[ "$ARGS" == *"--json comments"* ]]; then
  echo "${WOO_REVIEW_TEST_ISSUE_COMMENTS:-0}"
  exit 0
fi
# gh pr view N --json reviews → only used when WOO_REVIEW_FAKE_PR_REVIEWS_JSON unset.
if [[ "$ARGS" == *"--json reviews"* ]]; then
  echo '{"reviews":[]}'
  exit 0
fi
# gh pr view N --json headRefOid,... → full meta JSON.
if [[ "$ARGS" == *"--json headRefOid"* ]]; then
  cat "${WOO_REVIEW_TEST_META_FIXTURE}"
  exit 0
fi
# gh api .../pulls/N/comments --jq '... | length' → 0 review comments.
if [[ "$ARGS" == *"api"*"/pulls/"*"/comments"* ]]; then
  echo "${WOO_REVIEW_TEST_REVIEW_COMMENTS:-0}"
  exit 0
fi
# gh api .../compare/<sha>...<sha> → compare JSON or 404 (force-push case).
if [[ "$ARGS" == *"api"*"compare/"* ]]; then
  if [ -n "${WOO_REVIEW_TEST_COMPARE_404:-}" ]; then exit 1; fi
  cat "${WOO_REVIEW_TEST_COMPARE_FIXTURE:-/dev/null}"
  exit 0
fi
# gh api graphql ... → only used when WOO_REVIEW_FAKE_PRIOR_THREADS_JSON unset.
if [[ "$ARGS" == *"api graphql"* ]]; then
  echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}'
  exit 0
fi
# gh pr diff N → full PR diff.
if [[ "$ARGS" == *"pr diff"* ]]; then
  cat "${WOO_REVIEW_TEST_FULL_DIFF_FIXTURE:-/dev/null}"
  exit 0
fi
echo "test gh shim: unrecognized invocation: $ARGS" >&2
exit 1
SHIM
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"

OUTPUT_FILE="$WORK/output"
export GITHUB_OUTPUT="$OUTPUT_FILE"
export GITHUB_WORKSPACE="$WORK/workspace"
export GITHUB_REPOSITORY="owner/repo"
export GH_TOKEN="fake"
export PR_NUMBER="42"
export EVENT_NAME="pull_request"
export EVENT_ACTION="synchronize"
mkdir -p "$GITHUB_WORKSPACE"

# Default fixtures shared by every case.
META_FIXTURE="$WORK/meta.json"
FULL_DIFF_FIXTURE="$WORK/full-diff.txt"
cat > "$META_FIXTURE" <<'JSON'
{
  "headRefOid": "newhead123",
  "baseRefName": "main",
  "title": "test",
  "body": "",
  "files": [{"path":"src/app.ts","additions":20,"deletions":5}],
  "author": {"login":"user"}
}
JSON
cat > "$FULL_DIFF_FIXTURE" <<'DIFF'
diff --git a/src/app.ts b/src/app.ts
--- a/src/app.ts
+++ b/src/app.ts
@@ -1,3 +1,3 @@
-const x = 1
+const x = 2
+const y = 3
+const z = 4
DIFF
export WOO_REVIEW_TEST_META_FIXTURE="$META_FIXTURE"
export WOO_REVIEW_TEST_FULL_DIFF_FIXTURE="$FULL_DIFF_FIXTURE"

# WOO_REVIEW_TEST_MODE gates the WOO_REVIEW_FAKE_* hooks in prefetch.sh —
# without it, the production code path runs and hits the gh shim instead.
export WOO_REVIEW_TEST_MODE=1

# Always set the priors hook so the graphql call is bypassed.
export WOO_REVIEW_FAKE_PRIOR_THREADS_JSON='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}'

fail=0

reset() {
  : > "$OUTPUT_FILE"
  rm -f "$PREFETCH"/* 2>/dev/null || true
  unset WOO_REVIEW_FAKE_PR_REVIEWS_JSON || true
  unset WOO_REVIEW_FAKE_INCREMENTAL_DIFF || true
  unset WOO_REVIEW_TEST_COMPARE_404 || true
  unset INPUT_INCREMENTAL || true
  unset COMMENT_BODY || true
  # Re-export canonical event context so each case starts from a known
  # baseline regardless of what the previous case set.
  export EVENT_NAME="pull_request"
  export EVENT_ACTION="synchronize"
}

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" != "$actual" ]; then
    echo "FAIL $name: expected '$expected', got '$actual'"
    fail=1
    return 1
  fi
  return 0
}

# --- Case 1: no prior marker -> full diff path, empty last_sha.txt
reset
export WOO_REVIEW_FAKE_PR_REVIEWS_JSON='{"reviews":[]}'
bash "$SCRIPT" > "$WORK/stdout" 2>&1 || { echo "FAIL case1 (script error):"; sed 's/^/    /' "$WORK/stdout"; fail=1; }
LAST_SHA=$(cat "$PREFETCH/last_sha.txt" 2>/dev/null || echo "MISSING")
assert_eq "case1 no-marker last_sha" "" "$LAST_SHA"
if ! diff -q "$PREFETCH/diff.txt" "$FULL_DIFF_FIXTURE" >/dev/null 2>&1; then
  echo "FAIL case1: diff.txt != full diff fixture"; fail=1
fi
echo "ok   case1 no-marker -> full diff"

# --- Case 2: valid marker -> incremental path via env-hook diff
reset
export WOO_REVIEW_FAKE_PR_REVIEWS_JSON='{"reviews":[{"body":"foo <!-- woo-review:sha=abcdef0 --> bar","author":{"login":"claude-code-bot"},"submittedAt":"2026-01-01T00:00:00Z"}]}'
INC_DIFF=$'diff --git a/src/app.ts b/src/app.ts\n@@ -1,1 +1,2 @@\n+const new_line = 1\n'
export WOO_REVIEW_FAKE_INCREMENTAL_DIFF="$INC_DIFF"
bash "$SCRIPT" > "$WORK/stdout" 2>&1 || { echo "FAIL case2 (script error):"; sed 's/^/    /' "$WORK/stdout"; fail=1; }
LAST_SHA=$(cat "$PREFETCH/last_sha.txt" 2>/dev/null || echo "MISSING")
assert_eq "case2 last_sha" "abcdef0" "$LAST_SHA"
if ! grep -q "const new_line" "$PREFETCH/diff.txt"; then
  echo "FAIL case2: incremental diff not in diff.txt"; fail=1
fi
echo "ok   case2 valid marker -> incremental"

# --- Case 3: multiple markers, latest submittedAt wins
reset
export WOO_REVIEW_FAKE_PR_REVIEWS_JSON='{"reviews":[
  {"body":"<!-- woo-review:sha=0fedcba -->","author":{"login":"claude-code-bot"},"submittedAt":"2026-01-01T00:00:00Z"},
  {"body":"<!-- woo-review:sha=1234567 -->","author":{"login":"claude-code-bot"},"submittedAt":"2026-02-01T00:00:00Z"},
  {"body":"<!-- woo-review:sha=9876543 -->","author":{"login":"claude-code-bot"},"submittedAt":"2026-01-15T00:00:00Z"}
]}'
export WOO_REVIEW_FAKE_INCREMENTAL_DIFF=$'diff --git a/src/app.ts b/src/app.ts\n+changed\n'
bash "$SCRIPT" > "$WORK/stdout" 2>&1 || { echo "FAIL case3 (script error):"; sed 's/^/    /' "$WORK/stdout"; fail=1; }
LAST_SHA=$(cat "$PREFETCH/last_sha.txt" 2>/dev/null || echo "MISSING")
assert_eq "case3 latest-wins last_sha" "1234567" "$LAST_SHA"
echo "ok   case3 multi-marker -> latest wins"

# --- Case 4: marker present, compare API 404 (force-push) -> warn + full fallback
reset
export WOO_REVIEW_FAKE_PR_REVIEWS_JSON='{"reviews":[{"body":"<!-- woo-review:sha=deadbee -->","author":{"login":"claude-code-bot"},"submittedAt":"2026-01-01T00:00:00Z"}]}'
export WOO_REVIEW_TEST_COMPARE_404=1
bash "$SCRIPT" > "$WORK/stdout" 2>&1 || { echo "FAIL case4 (script error):"; sed 's/^/    /' "$WORK/stdout"; fail=1; }
LAST_SHA=$(cat "$PREFETCH/last_sha.txt" 2>/dev/null || echo "MISSING")
assert_eq "case4 fallback last_sha" "" "$LAST_SHA"
if ! grep -q "::warning::.*deadbee.*unreachable" "$WORK/stdout"; then
  echo "FAIL case4: missing force-push warning in output"
  sed 's/^/    /' "$WORK/stdout"
  fail=1
fi
if ! diff -q "$PREFETCH/diff.txt" "$FULL_DIFF_FIXTURE" >/dev/null 2>&1; then
  echo "FAIL case4: diff.txt should be full diff after fallback"; fail=1
fi
echo "ok   case4 force-push 404 -> warn + full fallback"

# --- Case 5: incremental diff empty (no new commits) -> skip
reset
export WOO_REVIEW_FAKE_PR_REVIEWS_JSON='{"reviews":[{"body":"<!-- woo-review:sha=abcdef0 -->","author":{"login":"claude-code-bot"},"submittedAt":"2026-01-01T00:00:00Z"}]}'
export WOO_REVIEW_FAKE_INCREMENTAL_DIFF=$'\n'   # single newline → 1 byte, under 50-byte floor
bash "$SCRIPT" > "$WORK/stdout" 2>&1 || true   # emit_skip exits 0
if ! grep -q '^skip=true' "$OUTPUT_FILE"; then
  echo "FAIL case5: expected skip=true in GITHUB_OUTPUT"; fail=1
fi
if ! grep -q "no new commits" "$WORK/stdout"; then
  echo "FAIL case5: missing skip reason"
  sed 's/^/    /' "$WORK/stdout"
  fail=1
fi
echo "ok   case5 empty incremental -> skip"

# --- Case 6: INPUT_INCREMENTAL=off forces full diff even with valid marker
reset
export WOO_REVIEW_FAKE_PR_REVIEWS_JSON='{"reviews":[{"body":"<!-- woo-review:sha=abcdef0 -->","author":{"login":"claude-code-bot"},"submittedAt":"2026-01-01T00:00:00Z"}]}'
export INPUT_INCREMENTAL="off"
bash "$SCRIPT" > "$WORK/stdout" 2>&1 || { echo "FAIL case6 (script error):"; sed 's/^/    /' "$WORK/stdout"; fail=1; }
LAST_SHA=$(cat "$PREFETCH/last_sha.txt" 2>/dev/null || echo "MISSING")
assert_eq "case6 off-mode last_sha" "" "$LAST_SHA"
if ! diff -q "$PREFETCH/diff.txt" "$FULL_DIFF_FIXTURE" >/dev/null 2>&1; then
  echo "FAIL case6: diff.txt should be full diff in off mode"; fail=1
fi
echo "ok   case6 INPUT_INCREMENTAL=off -> full diff"

# --- Case 7: non-bot author's marker is ignored (spoofing defence)
reset
export WOO_REVIEW_FAKE_PR_REVIEWS_JSON='{"reviews":[{"body":"<!-- woo-review:sha=cafef00 -->","author":{"login":"attacker"},"submittedAt":"2026-03-01T00:00:00Z"}]}'
bash "$SCRIPT" > "$WORK/stdout" 2>&1 || { echo "FAIL case7 (script error):"; sed 's/^/    /' "$WORK/stdout"; fail=1; }
LAST_SHA=$(cat "$PREFETCH/last_sha.txt" 2>/dev/null || echo "MISSING")
assert_eq "case7 non-bot ignored last_sha" "" "$LAST_SHA"
if ! diff -q "$PREFETCH/diff.txt" "$FULL_DIFF_FIXTURE" >/dev/null 2>&1; then
  echo "FAIL case7: diff.txt should be full diff when marker is non-bot"; fail=1
fi
echo "ok   case7 non-bot marker -> ignored (full diff)"

# --- Case 8: LAST_SHA equals HEAD_SHA (re-trigger without push) -> skip
reset
# Use a meta fixture whose headRefOid matches the marker SHA.
EQUAL_META="$WORK/meta-equal.json"
cat > "$EQUAL_META" <<'JSON'
{
  "headRefOid": "abcdef0",
  "baseRefName": "main",
  "title": "test",
  "body": "",
  "files": [{"path":"src/app.ts","additions":1,"deletions":0}],
  "author": {"login":"user"}
}
JSON
WOO_REVIEW_TEST_META_FIXTURE_PREV="$WOO_REVIEW_TEST_META_FIXTURE"
export WOO_REVIEW_TEST_META_FIXTURE="$EQUAL_META"
export WOO_REVIEW_FAKE_PR_REVIEWS_JSON='{"reviews":[{"body":"<!-- woo-review:sha=abcdef0 -->","author":{"login":"claude-code-bot"},"submittedAt":"2026-01-01T00:00:00Z"}]}'
bash "$SCRIPT" > "$WORK/stdout" 2>&1 || true   # emit_skip exits 0
if ! grep -q '^skip=true' "$OUTPUT_FILE"; then
  echo "FAIL case8: expected skip=true in GITHUB_OUTPUT"; fail=1
fi
if ! grep -q "no new commits since last review" "$WORK/stdout"; then
  echo "FAIL case8: missing skip reason for equal-SHA path"
  sed 's/^/    /' "$WORK/stdout"
  fail=1
fi
export WOO_REVIEW_TEST_META_FIXTURE="$WOO_REVIEW_TEST_META_FIXTURE_PREV"
echo "ok   case8 LAST_SHA == HEAD_SHA -> skip"

# --- Case 9: --full in PR-comment body forces INCREMENTAL=off even with valid marker
reset
export EVENT_NAME="issue_comment"
export EVENT_ACTION="created"
export COMMENT_BODY="@review --full please re-check everything"
export WOO_REVIEW_FAKE_PR_REVIEWS_JSON='{"reviews":[{"body":"<!-- woo-review:sha=abcdef0 -->","author":{"login":"claude-code-bot"},"submittedAt":"2026-01-01T00:00:00Z"}]}'
bash "$SCRIPT" > "$WORK/stdout" 2>&1 || { echo "FAIL case9 (script error):"; sed 's/^/    /' "$WORK/stdout"; fail=1; }
LAST_SHA=$(cat "$PREFETCH/last_sha.txt" 2>/dev/null || echo "MISSING")
assert_eq "case9 --full last_sha" "" "$LAST_SHA"
if ! diff -q "$PREFETCH/diff.txt" "$FULL_DIFF_FIXTURE" >/dev/null 2>&1; then
  echo "FAIL case9: diff.txt should be full diff when --full in comment"; fail=1
fi
if ! grep -q "forced to 'off' by --full" "$WORK/stdout"; then
  echo "FAIL case9: missing --full override log line"
  sed 's/^/    /' "$WORK/stdout"
  fail=1
fi
echo "ok   case9 --full PR-comment trigger -> full diff"

if [ "$fail" -ne 0 ]; then
  echo "prefetch tests FAILED"
  exit 1
fi
echo "All prefetch tests passed."
