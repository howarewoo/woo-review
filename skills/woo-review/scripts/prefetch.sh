#!/usr/bin/env bash
# Prefetches PR diff, metadata, and rules for the agentic review.
# Inputs (env): GH_TOKEN, GITHUB_REPOSITORY, INPUT_SKIP_LABELS,
#               PR_NUMBER, EVENT_NAME, EVENT_ACTION.
# Outputs: skip=true|false to $GITHUB_OUTPUT.
# Side effects: writes /tmp/pr-review/{diff.txt,meta.json}, and rules.md when
#               project-rule files (AGENTS.md / CLAUDE.md / .cursorrules /
#               .windsurfrules / GEMINI.md) are discovered.

set -euo pipefail

OUTDIR="/tmp/pr-review"
mkdir -p "$OUTDIR"

PR_NUMBER="${PR_NUMBER:-}"
EVENT_NAME="${EVENT_NAME:-}"
EVENT_ACTION="${EVENT_ACTION:-}"
# Hardcoded — not exposed as a knob. Fed into a jq test() regex below; allowing
# external override would let a misconfigured caller inject arbitrary regex.
BOT_NAME_PATTERN="claude|openai|gemini|opencode"
SKIP_LABELS="${INPUT_SKIP_LABELS:-}"

emit_skip() {
  echo "skip=true" >> "$GITHUB_OUTPUT"
  echo "Skipping: $1"
  exit 0
}

if [ -z "$PR_NUMBER" ]; then
  emit_skip "no PR number resolvable from event"
fi

# Skip if any user-configured skip label is present.
if [ -n "$SKIP_LABELS" ]; then
  CURRENT_LABELS=$(gh pr view "$PR_NUMBER" --json labels --jq '.labels[].name' || true)
  IFS=',' read -ra LBL_ARRAY <<< "$SKIP_LABELS"
  for lbl in "${LBL_ARRAY[@]}"; do
    lbl_trim=$(echo "$lbl" | xargs)
    if echo "$CURRENT_LABELS" | grep -qxF "$lbl_trim"; then
      emit_skip "skip label '$lbl_trim' is present"
    fi
  done
fi

# Re-run guard: if a prior AI bot has already commented and the current trigger is
# not an explicit user request, skip.
ISSUE_COMMENTS=$(gh pr view "$PR_NUMBER" --json comments \
  --jq "[.comments[] | select(.author.login | test(\"$BOT_NAME_PATTERN\"; \"i\"))] | length")
REVIEW_COMMENTS=$(gh api "repos/${GITHUB_REPOSITORY}/pulls/$PR_NUMBER/comments" \
  --jq "[.[] | select(.user.login | test(\"$BOT_NAME_PATTERN\"; \"i\"))] | length")
TOTAL_BOT_COMMENTS=$((ISSUE_COMMENTS + REVIEW_COMMENTS))

echo "Event: $EVENT_NAME, Action: $EVENT_ACTION, Prior bot comments: $TOTAL_BOT_COMMENTS"

if [ "$TOTAL_BOT_COMMENTS" -gt 0 ] && \
   [ "$EVENT_NAME" != "issue_comment" ] && \
   [ "$EVENT_NAME" != "pull_request_target" ] && \
   [ "$EVENT_NAME" != "workflow_dispatch" ] && \
   [ "$EVENT_ACTION" != "ready_for_review" ] && \
   [ "$EVENT_ACTION" != "opened" ] && \
   [ "$EVENT_ACTION" != "reopened" ]; then
  emit_skip "bot already commented and trigger is not explicit"
fi

# Fetch diff + metadata.
gh pr diff "$PR_NUMBER" > "$OUTDIR/diff.txt"
gh pr view "$PR_NUMBER" --json headRefOid,baseRefName,title,body,files > "$OUTDIR/meta.json"

DIFF_BYTES=$(wc -c < "$OUTDIR/diff.txt")
CODE_FILES=$(jq -r '.files[].path' "$OUTDIR/meta.json" \
  | grep -vE '\.(md|tsv|json|lock|yaml|yml)$|^docs/|^specs/|database\.types\.ts$' \
  | wc -l || true)
LOC_CHANGED=$(jq -r '[.files[] | .additions + .deletions] | add // 0' "$OUTDIR/meta.json")

echo "Diff bytes: $DIFF_BYTES, Code files: $CODE_FILES, LOC: $LOC_CHANGED"

if [ "$CODE_FILES" -eq 0 ]; then
  emit_skip "no code files changed"
fi

if [ "$LOC_CHANGED" -lt 10 ]; then
  emit_skip "<10 LOC changed"
fi

# Cap diff at 300KB. Build the capped copy in one shot (truncated bytes + sentinel)
# then atomically replace — so a failure mid-write cannot corrupt the original.
if [ "$DIFF_BYTES" -gt 300000 ]; then
  {
    head -c 300000 "$OUTDIR/diff.txt"
    printf '\n[DIFF TRUNCATED AT 300KB]\n'
  } > "$OUTDIR/diff.txt.capped"
  mv "$OUTDIR/diff.txt.capped" "$OUTDIR/diff.txt"
fi

# Discover project-rule files.
# Root scan: AGENTS.md / CLAUDE.md / .cursorrules / .windsurfrules / GEMINI.md.
# Per-changed-file walk: collect AGENTS.md / CLAUDE.md from every parent dir
# between the changed file and repo root. Each path is collected at most once.
ROOT="$(git -C "${GITHUB_WORKSPACE:-.}" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$ROOT" ]; then
  RULES_LIST="$(mktemp)"
  RULES_BUF="$(mktemp)"

  for f in AGENTS.md CLAUDE.md .cursorrules .windsurfrules GEMINI.md; do
    [ -f "$ROOT/$f" ] && printf '%s\n' "$f" >> "$RULES_LIST"
  done

  while IFS= read -r changed; do
    [ -n "$changed" ] || continue
    dir="$(dirname "$changed")"
    while [ "$dir" != "." ] && [ "$dir" != "/" ]; do
      for f in AGENTS.md CLAUDE.md; do
        [ -f "$ROOT/$dir/$f" ] && printf '%s\n' "$dir/$f" >> "$RULES_LIST"
      done
      dir="$(dirname "$dir")"
    done
  done < <(jq -r '.files[].path' "$OUTDIR/meta.json")

  RULES_UNIQUE="$(awk 'NF && !seen[$0]++' "$RULES_LIST")"

  if [ -n "$RULES_UNIQUE" ]; then
    while IFS= read -r rel; do
      printf '## SOURCE: %s\n' "$rel" >> "$RULES_BUF"
      cat "$ROOT/$rel" >> "$RULES_BUF"
      printf '\n\n' >> "$RULES_BUF"
    done <<< "$RULES_UNIQUE"

    RULES_BYTES=$(wc -c < "$RULES_BUF")
    if [ "$RULES_BYTES" -gt 100000 ]; then
      {
        head -c 100000 "$RULES_BUF"
        printf '\n[RULES TRUNCATED AT 100KB]\n'
      } > "$OUTDIR/rules.md"
    else
      mv "$RULES_BUF" "$OUTDIR/rules.md"
    fi

    RULES_COUNT=$(printf '%s\n' "$RULES_UNIQUE" | wc -l | xargs)
    FINAL_BYTES=$(wc -c < "$OUTDIR/rules.md")
    echo "Discovered $RULES_COUNT rule file(s), $FINAL_BYTES bytes:"
    printf '%s\n' "$RULES_UNIQUE" | sed 's/^/  /'
  fi

  rm -f "$RULES_LIST" "$RULES_BUF"
fi

echo "skip=false" >> "$GITHUB_OUTPUT"
echo "Prefetch complete: $OUTDIR/"
