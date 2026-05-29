#!/usr/bin/env bash
# sidecar-write.sh
#
# Scans review threads resolved between last_sha..HEAD_SHA, appends them
# (idempotent on (pr_number, semantic_key, code_anchor)) to
# .woo-review/dismissed.json, and commits the change via the bot identity.
#
# Gated on:
#   - .woo-review.yml: enable_sidecar_write (default: true)
#   - env: WOO_REVIEW_DISABLE_GIT_WRITE=1 → skip (tests)
#
# Failures (no perm, push race, malformed) → log + exit 0. Never fail the run.
#
# NOTE: semantic_key and code_anchor are written as placeholder values
# ("unknown/unknown" and "unknown000000") because the GitHub reviewThreads
# GraphQL query only surfaces file + line + comment body — not the original
# finding's semantic_key/code_anchor. A future improvement would parse those
# out of the bot review body, where they are embedded as
# <!-- woo-review:sk=<key> --> / <!-- woo-review:ca=<anchor> --> inline
# markers (similar to how prefetch.sh reads the <!-- woo-review:sha=... -->
# watermark). prefetch.sh currently also doesn't extract those markers from
# prior-findings.json entries, so this limitation is shared across the board.
# The dedup step still benefits from these entries via the (file, line, title)
# tuple even when the dedup keys are placeholders.

set -euo pipefail

OUTDIR="${OUTDIR:-/tmp/pr-review}"

# Non-CI guard (local post-session Stop hook). The hook fires at the end of
# EVERY host session; act only when a local /woo-review run just posted a
# review (sentinel) AND we are standing in the repo that was reviewed. CI runs
# (GITHUB_ACTIONS=true) skip this entirely — the isolated job runs the script
# unconditionally with env state, preserving #33 parity.
#
# IMPORTANT: this block must run BEFORE any ENABLE/DISABLE gate so that the
# sentinel is consumed (trap registered) even when a later gate exits 0.
# Without this ordering the sentinel leaks and every future session prints
# "disabled" even when no review is pending.
if [ "${GITHUB_ACTIONS:-}" != "true" ]; then
  SENTINEL="$OUTDIR/sidecar-pending"
  if [ ! -f "$SENTINEL" ]; then
    echo "sidecar-write: no pending local review; skipping"
    exit 0
  fi
  # Consume the sentinel on every exit path from here on.
  trap 'rm -f "$SENTINEL"' EXIT
  CTX_PATH=$(jq -r '.repo_path // empty' "$OUTDIR/review-context.json" 2>/dev/null || echo)
  TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null || echo)
  # Safe default: only proceed when we can positively confirm the cwd repo IS
  # the reviewed repo. An empty CTX_PATH (context file missing/partial, or a
  # stale sentinel without a matching context) means we CANNOT confirm — skip
  # rather than risk committing to whatever repo the Stop hook fired in.
  if [ -z "$CTX_PATH" ] || [ "$CTX_PATH" != "$TOPLEVEL" ]; then
    echo "sidecar-write: cannot confirm reviewed repo (ctx=$CTX_PATH, cwd=$TOPLEVEL); skipping"
    exit 0
  fi
fi

# `if … == null` (not `//`) because jq's alternative operator treats `false`
# as "missing" — `false // true` evaluates to `true`, which would silently
# enable writes for users who explicitly set the flag to `false`.
ENABLE=$(jq -r 'if .enable_sidecar_write == null then true else .enable_sidecar_write end' \
           "$OUTDIR/config.json" 2>/dev/null || echo false)
if [ "$ENABLE" != "true" ]; then
  echo "sidecar-write: disabled (.woo-review.yml: enable_sidecar_write != true)"
  exit 0
fi
if [ "${WOO_REVIEW_DISABLE_GIT_WRITE:-0}" = "1" ]; then
  echo "sidecar-write: disabled via WOO_REVIEW_DISABLE_GIT_WRITE"
  exit 0
fi

# State resolution: env wins (CI), else fall back to the handoff file the
# skill session left in $OUTDIR (local post-session Stop hook path).
CTX="$OUTDIR/review-context.json"
PR_NUMBER="${PR_NUMBER:-$(jq -r '.pr_number // empty' "$CTX" 2>/dev/null || echo)}"
HEAD_SHA="${HEAD_SHA:-$(jq -r '.head_sha // empty' "$CTX" 2>/dev/null || echo)}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-$(jq -r '.repo // empty' "$CTX" 2>/dev/null || echo)}"
export GITHUB_REPOSITORY

if [ -z "$PR_NUMBER" ] || [ -z "$HEAD_SHA" ]; then
  echo "sidecar-write: PR_NUMBER or HEAD_SHA missing; skipping"
  exit 0
fi

if [ -n "${WOO_REVIEW_FAKE_RESOLVED_THREADS_JSON:-}" ]; then
  RESOLVED="$WOO_REVIEW_FAKE_RESOLVED_THREADS_JSON"
else
  OWNER="${GITHUB_REPOSITORY%/*}"
  REPO="${GITHUB_REPOSITORY#*/}"
  RESOLVED=$(gh api graphql -F owner="$OWNER" -F repo="$REPO" -F pr="$PR_NUMBER" -f query='
    query($owner:String!,$repo:String!,$pr:Int!){
      repository(owner:$owner,name:$repo){
        pullRequest(number:$pr){
          reviewThreads(first:100){
            nodes{
              isResolved
              path line
              comments(first:1){nodes{body author{login}}}
            }
          }
        }
      }
    }' 2>/dev/null || echo '{}')
fi

NEW_ENTRIES=$(printf '%s' "$RESOLVED" | jq --arg pr "$PR_NUMBER" --arg now "$(date -u +%FT%TZ)" '
  [ .data.repository.pullRequest.reviewThreads.nodes[]?
    | select(.isResolved == true)
    | select(.path != null)
    | { file: .path,
        line: (.line // 1),
        title: (((.comments.nodes[0].body // "") | split("\n")[0])[0:60]),
        semantic_key: "unknown/unknown",
        code_anchor: "unknown000000",
        resolved_at: $now,
        pr_number: ($pr | tonumber)
      } ]')

NEW_COUNT=$(printf '%s' "$NEW_ENTRIES" | jq length)
[ "$NEW_COUNT" -eq 0 ] && { echo "sidecar-write: no newly-resolved threads"; exit 0; }

SIDECAR=".woo-review/dismissed.json"
mkdir -p .woo-review
[ -f "$SIDECAR" ] || echo '[]' > "$SIDECAR"

if ! jq empty "$SIDECAR" 2>/dev/null; then
  echo "sidecar-write: existing sidecar malformed; skipping (not overwriting)"
  exit 0
fi

MERGED=$(jq -n --argjson a "$(cat "$SIDECAR")" --argjson b "$NEW_ENTRIES" '
  ($a + $b) | unique_by({pr_number, file, line})
')
printf '%s' "$MERGED" > "$SIDECAR"

git config --local user.name  "${WOO_REVIEW_BOT_NAME:-woo-review[bot]}"
git config --local user.email "${WOO_REVIEW_BOT_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"

if ! git add "$SIDECAR"; then
  echo "sidecar-write: git add failed; skipping"; exit 0; fi
if git diff --cached --quiet "$SIDECAR"; then
  echo "sidecar-write: nothing new to commit"; exit 0; fi

git commit -m "chore(woo-review): record $NEW_COUNT dismissed finding(s)" || {
  echo "sidecar-write: commit failed; skipping"; exit 0; }

if ! git push; then
  echo "sidecar-write: push failed; trying rebase + push once"
  git pull --rebase || { echo "sidecar-write: rebase failed; skipping"; exit 0; }
  git push || { echo "sidecar-write: push still failing; skipping"; exit 0; }
fi
echo "sidecar-write: appended $NEW_COUNT entries to $SIDECAR"
