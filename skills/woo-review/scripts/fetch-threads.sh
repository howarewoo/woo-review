#!/usr/bin/env bash
# Fetches every UNRESOLVED review thread on a PR (any author) with full comment
# bodies, the thread GraphQL node-id (for reply + resolve), and the diff hunk.
# Used by the `woo-review address <PR#>` verb (local hosts only).
#
# Inputs (env): GITHUB_REPOSITORY, PR_NUMBER, OUTDIR (default /tmp/pr-review).
# Output: $OUTDIR/address-threads.json — an array of:
#   { threadId, file, line, diffHunk, comments: [ { author, body } ] }
#
# Test hook (only when WOO_REVIEW_TEST_MODE=1 and NOT in GitHub Actions):
#   WOO_REVIEW_FAKE_THREADS_JSON — stand in for the gh GraphQL response.
#
# First page only (100 threads, 50 comments each); pagination is a follow-up —
# truncation is logged below, never silent.
set -euo pipefail

# shellcheck source=skills/woo-review/scripts/resolve-outdir.sh
source "$(dirname "${BASH_SOURCE[0]}")/resolve-outdir.sh"
mkdir -p "$OUTDIR"
PR_NUMBER="${PR_NUMBER:?PR_NUMBER env var required}"
[[ "$PR_NUMBER" =~ ^[0-9]+$ ]] || { echo "fetch-threads: PR_NUMBER must be numeric, got '$PR_NUMBER'" >&2; exit 1; }
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo)}"
[ -n "$GITHUB_REPOSITORY" ] || { echo "fetch-threads: cannot resolve GITHUB_REPOSITORY (set it or run inside a gh-authenticated repo)" >&2; exit 1; }
TEST_MODE="${WOO_REVIEW_TEST_MODE:-}"

# Refuse fake-data hooks inside GitHub Actions — same guard as prefetch.sh.
if [ "$TEST_MODE" = "1" ] && [ "${GITHUB_ACTIONS:-}" = "true" ]; then
  echo "::error::WOO_REVIEW_TEST_MODE refused in GitHub Actions" >&2
  exit 1
fi

if [ "$TEST_MODE" = "1" ] && [ -n "${WOO_REVIEW_FAKE_THREADS_JSON:-}" ]; then
  THREADS_JSON="$WOO_REVIEW_FAKE_THREADS_JSON"
else
  OWNER_NAME="${GITHUB_REPOSITORY%/*}"
  REPO_NAME="${GITHUB_REPOSITORY#*/}"
  THREADS_JSON=$(gh api graphql -F owner="$OWNER_NAME" -F repo="$REPO_NAME" -F pr="$PR_NUMBER" -f query='
    query($owner: String!, $repo: String!, $pr: Int!) {
      repository(owner: $owner, name: $repo) {
        pullRequest(number: $pr) {
          reviewThreads(first: 100) {
            nodes {
              id
              isResolved
              path
              line
              comments(first: 50) {
                nodes { body diffHunk author { login } }
              }
            }
          }
        }
      }
    }' 2>/dev/null || echo '{}')
fi

TOTAL=$(printf '%s' "$THREADS_JSON" | jq '[.data.repository.pullRequest.reviewThreads.nodes[]?] | length' 2>/dev/null || echo 0)
if [ "$TOTAL" -ge 100 ]; then
  echo "::warning::fetch-threads: fetched the first 100 threads (resolved+unresolved); some unresolved threads beyond the page cap may be missed" >&2
fi

printf '%s' "$THREADS_JSON" | jq '
  [ .data.repository.pullRequest.reviewThreads.nodes[]?
    | select(.isResolved == false)
    | select(.path != null)
    | { threadId: .id,
        file: .path,
        line: (.line // 1),
        diffHunk: (.comments.nodes[0].diffHunk // ""),
        comments: [ .comments.nodes[]? | { author: (.author.login // ""), body: (.body // "") } ]
      }
  ]' > "$OUTDIR/address-threads.json" 2>/dev/null || echo '[]' > "$OUTDIR/address-threads.json"

COUNT=$(jq 'length' "$OUTDIR/address-threads.json" 2>/dev/null || echo 0)
echo "Unresolved threads to address: $COUNT"
