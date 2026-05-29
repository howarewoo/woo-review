#!/usr/bin/env bash
# Unit test for skills/woo-review/scripts/resolve-thread.sh.
# In dry-run mode the script prints the two GraphQL mutations it WOULD send
# (reply, then resolve) instead of calling gh. Asserts both are built with the
# right thread id + body, and that a simulated reply failure still resolves.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/woo-review/scripts/resolve-thread.sh"

export WOO_REVIEW_TEST_MODE=1

# --- Case 1: happy path — reply then resolve ---
out=$(THREAD_ID="PRRT_xyz" REPLY_BODY="Fixed in abc123" bash "$SCRIPT")
echo "$out" | grep -q "DRYRUN reply PRRT_xyz :: Fixed in abc123" \
  || { echo "FAIL case1: reply not built: $out"; exit 1; }
echo "$out" | grep -q "DRYRUN resolve PRRT_xyz" \
  || { echo "FAIL case1: resolve not built: $out"; exit 1; }

# --- Case 2: reply fails (simulated) — must still resolve ---
out=$(THREAD_ID="PRRT_fail" REPLY_BODY="hi" WOO_REVIEW_FAKE_REPLY_FAIL=1 bash "$SCRIPT" 2>&1)
echo "$out" | grep -q "reply failed" \
  || { echo "FAIL case2: reply failure not logged: $out"; exit 1; }
echo "$out" | grep -q "DRYRUN resolve PRRT_fail" \
  || { echo "FAIL case2: resolve skipped after reply failure: $out"; exit 1; }

# --- Case 3: RESOLVE=0 replies but does NOT resolve (CLARIFY threads) ---
out=$(THREAD_ID="PRRT_open" REPLY_BODY="please clarify" RESOLVE=0 bash "$SCRIPT")
echo "$out" | grep -q "DRYRUN reply PRRT_open" \
  || { echo "FAIL case3: reply not built: $out"; exit 1; }
if echo "$out" | grep -q "DRYRUN resolve"; then
  echo "FAIL case3: resolved despite RESOLVE=0: $out"; exit 1
fi


# --- Case 4: RESOLVE=0 + reply fails — warn, and still NO resolve ---
out=$(THREAD_ID="PRRT_c4" REPLY_BODY="q" RESOLVE=0 WOO_REVIEW_FAKE_REPLY_FAIL=1 bash "$SCRIPT" 2>&1)
echo "$out" | grep -q "reply failed" \
  || { echo "FAIL case4: reply failure not logged: $out"; exit 1; }
if echo "$out" | grep -q "DRYRUN resolve"; then
  echo "FAIL case4: resolved despite RESOLVE=0: $out"; exit 1
fi

echo "PASS resolve-thread.test.sh"
