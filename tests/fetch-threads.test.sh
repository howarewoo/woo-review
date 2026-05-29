#!/usr/bin/env bash
# Unit test for skills/woo-review/scripts/fetch-threads.sh.
# Feeds a fake GraphQL reviewThreads payload via WOO_REVIEW_FAKE_THREADS_JSON
# and asserts address-threads.json: only UNRESOLVED threads, full comment
# bodies, and the thread node-id are preserved. No network.
set -euo pipefail
unset GITHUB_ACTIONS || true

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/woo-review/scripts/fetch-threads.sh"
OUTDIR="$(mktemp -d)"
trap 'rm -rf "$OUTDIR"' EXIT

export OUTDIR
export WOO_REVIEW_TEST_MODE=1
export GITHUB_REPOSITORY="acme/widgets"
export PR_NUMBER=42

# Two threads: one resolved (must be dropped), one open with two comments.
export WOO_REVIEW_FAKE_THREADS_JSON='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
  {"id":"PRRT_resolved","isResolved":true,"path":"a.js","line":3,
   "comments":{"nodes":[{"body":"old","diffHunk":"@@ -1 +1 @@","author":{"login":"claude-bot"}}]}},
  {"id":"PRRT_open","isResolved":false,"path":"src/cfg.go","line":17,
   "comments":{"nodes":[
     {"body":"**Bug:** parse may panic","diffHunk":"@@ -10 +17 @@\n+x","author":{"login":"claude-bot"}},
     {"body":"intentional fallback","diffHunk":"@@ -10 +17 @@\n+x","author":{"login":"maintainer"}}
   ]}}
]}}}}}'

bash "$SCRIPT"

OUT="$OUTDIR/address-threads.json"
[ -f "$OUT" ] || { echo "FAIL: $OUT not written"; exit 1; }

count=$(jq 'length' "$OUT")
[ "$count" = "1" ] || { echo "FAIL: expected 1 unresolved thread, got $count"; exit 1; }

tid=$(jq -r '.[0].threadId' "$OUT")
[ "$tid" = "PRRT_open" ] || { echo "FAIL: threadId expected PRRT_open, got $tid"; exit 1; }

file=$(jq -r '.[0].file' "$OUT")
[ "$file" = "src/cfg.go" ] || { echo "FAIL: file expected src/cfg.go, got $file"; exit 1; }

ncomments=$(jq '.[0].comments | length' "$OUT")
[ "$ncomments" = "2" ] || { echo "FAIL: expected 2 comments, got $ncomments"; exit 1; }

body2=$(jq -r '.[0].comments[1].body' "$OUT")
[ "$body2" = "intentional fallback" ] || { echo "FAIL: comment body not preserved: $body2"; exit 1; }

line=$(jq '.[0].line' "$OUT")
[ "$line" = "17" ] || { echo "FAIL: line expected 17, got $line"; exit 1; }

hunk_first=$(jq -r '.[0].diffHunk' "$OUT" | head -n1)
[ "$hunk_first" = "@@ -10 +17 @@" ] || { echo "FAIL: diffHunk first line not preserved: $hunk_first"; exit 1; }

echo "PASS fetch-threads.test.sh"
