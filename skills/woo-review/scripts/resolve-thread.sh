#!/usr/bin/env bash
# Posts a reply to a PR review thread, then (unless RESOLVE=0) resolves it.
# Used by `woo-review address` after a thread is FIXED or ACCEPTed. CLARIFY
# threads call with RESOLVE=0 (reply only, leave open).
#
# Inputs (env):
#   THREAD_ID   GraphQL node-id of the review thread (required)
#   REPLY_BODY  reply text (required)
#   RESOLVE     1 (default) resolve after replying; 0 reply only
#
# Reply failure (e.g. comment deleted, 422-equivalent) is logged and tolerated:
# the resolve is still attempted so the thread does not linger open.
#
# Test hooks (only when WOO_REVIEW_TEST_MODE=1):
#   prints "DRYRUN reply <id> :: <body>" / "DRYRUN resolve <id>" instead of
#   calling gh. WOO_REVIEW_FAKE_REPLY_FAIL=1 simulates a reply failure.
set -euo pipefail

THREAD_ID="${THREAD_ID:?THREAD_ID env var required}"
REPLY_BODY="${REPLY_BODY:?REPLY_BODY env var required}"
RESOLVE="${RESOLVE:-1}"
TEST_MODE="${WOO_REVIEW_TEST_MODE:-}"

# Refuse fake/dry-run hooks inside GitHub Actions — same guard as the sibling
# scripts. The address verb is local-only; never let CI silently no-op.
if [ "$TEST_MODE" = "1" ] && [ "${GITHUB_ACTIONS:-}" = "true" ]; then
  echo "::error::WOO_REVIEW_TEST_MODE refused in GitHub Actions" >&2
  exit 1
fi

reply() {
  if [ "$TEST_MODE" = "1" ]; then
    if [ "${WOO_REVIEW_FAKE_REPLY_FAIL:-}" = "1" ]; then return 1; fi
    echo "DRYRUN reply $THREAD_ID :: $REPLY_BODY"
    return 0
  fi
  gh api graphql -F tid="$THREAD_ID" -f body="$REPLY_BODY" -f query='
    mutation($tid: ID!, $body: String!) {
      addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $tid, body: $body}) {
        comment { id }
      }
    }' >/dev/null
}

resolve() {
  if [ "$TEST_MODE" = "1" ]; then
    echo "DRYRUN resolve $THREAD_ID"
    return 0
  fi
  gh api graphql -F tid="$THREAD_ID" -f query='
    mutation($tid: ID!) {
      resolveReviewThread(input: {threadId: $tid}) { thread { isResolved } }
    }' >/dev/null
}

warn() {
  local msg="$1"
  if [ "$TEST_MODE" = "1" ]; then
    echo "$msg"
  else
    echo "::warning::$msg" >&2
  fi
}

if ! reply; then
  warn "resolve-thread: reply failed for $THREAD_ID (comment gone or stale); continuing"
fi

if [ "$RESOLVE" = "1" ]; then
  resolve || warn "resolve-thread: resolve failed for $THREAD_ID"
fi
