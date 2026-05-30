#!/usr/bin/env bash
# Prefetches PR diff, metadata, and rules for the agentic review.
# Inputs (env): GH_TOKEN, GITHUB_REPOSITORY, INPUT_SKIP_LABELS, INPUT_INCREMENTAL,
#               PR_NUMBER, EVENT_NAME, EVENT_ACTION, COMMENT_BODY.
# Outputs: skip=true|false and outdir=<path> to $GITHUB_OUTPUT (outdir also to stdout).
# Side effects: writes /tmp/pr-review/{diff.txt,meta.json,last_sha.txt,prior-findings.json},
#               and rules.md when project-rule files (AGENTS.md / CLAUDE.md / .cursorrules /
#               .windsurfrules / GEMINI.md) are discovered.
#
# Incremental mode (INPUT_INCREMENTAL=auto, default): if a prior woo-review marker
# `<!-- woo-review:sha=<oid> -->` is found in any prior review body, diff
# <last_sha>...HEAD via the GitHub compare API instead of the full PR diff. A
# `--full` substring in COMMENT_BODY (issue_comment trigger) overrides to off.
# Test hooks (env, only active when WOO_REVIEW_TEST_MODE=1):
#   WOO_REVIEW_FAKE_PR_REVIEWS_JSON, WOO_REVIEW_FAKE_INCREMENTAL_DIFF,
#   WOO_REVIEW_FAKE_PRIOR_THREADS_JSON. The mode flag is intentionally not
#   exposed in action.yml — a calling workflow cannot opt itself into the
#   fake-data hooks without first setting an undocumented env var.
# WOO_REVIEW_FRESH=1 forces the OUTDIR wipe even when in-flight findings.* are
# present (issue #48 guard). Unset/0 = guard active (skip wipe if findings.* exist).

set -euo pipefail

# Atomic state. Prior runs may have left stale findings.<angle>.json,
# raw_findings.json, validator-metrics.json, etc. in $OUTDIR. Without a wipe,
# stale files (e.g. from an earlier meta-review of the skill itself) silently
# re-enter the merge step. Wipe first, recreate empty.
#
# GUARD (issue #48): refuse to wipe an $OUTDIR that already holds in-flight
# findings.* — a stray mid-run re-run (e.g. a sub-agent over-stepping its scope)
# would otherwise destroy meta.json / prior-findings.json and break the posting
# stage. prefetch is a Stage-1-only operation; set WOO_REVIEW_FRESH=1 to force a
# wipe (the only legitimate caller is a genuinely fresh run).
# shellcheck source=skills/woo-review/scripts/resolve-outdir.sh
source "$(dirname "${BASH_SOURCE[0]}")/resolve-outdir.sh"
if [ "${WOO_REVIEW_FRESH:-}" != "1" ] && compgen -G "$OUTDIR/findings.*" >/dev/null 2>&1; then
  echo "::warning::prefetch: $OUTDIR holds in-flight findings.* — refusing rm -rf (set WOO_REVIEW_FRESH=1 to force a fresh wipe)" >&2
else
  rm -rf "$OUTDIR"
fi
mkdir -p "$OUTDIR"

# Announce the resolved OUTDIR so a chat-host orchestrator can capture it and
# export OUTDIR verbatim to every sub-agent (no recompute drift). Emitted before
# any early skip-exit below so the value is always available. stdout always;
# GITHUB_OUTPUT additionally in CI.
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "outdir=$OUTDIR" >> "$GITHUB_OUTPUT"
fi
echo "outdir=$OUTDIR"

PR_NUMBER="${PR_NUMBER:-}"
EVENT_NAME="${EVENT_NAME:-}"
EVENT_ACTION="${EVENT_ACTION:-}"
# GITHUB_REPOSITORY is set by CI but unset on local hosts. Resolve it once here
# (via gh) so the later bare ${GITHUB_REPOSITORY} uses don't trip `set -u` and
# abort a local /woo-review run with "GITHUB_REPOSITORY: unbound variable".
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo)}"
export GITHUB_REPOSITORY
# Hardcoded — not exposed as a knob. Fed into a jq test() regex below; allowing
# external override would let a misconfigured caller inject arbitrary regex.
BOT_NAME_PATTERN="claude|openai|gemini|opencode"
SKIP_LABELS="${INPUT_SKIP_LABELS:-}"
INCREMENTAL="${INPUT_INCREMENTAL:-auto}"
# Test-mode gate: WOO_REVIEW_FAKE_* hooks only honored when this flag is set.
# Refused in any GitHub Actions context — a caller workflow could otherwise
# inject env vars via job/step `env:` blocks (those bypass action.yml inputs)
# and feed fabricated review/diff data into the production code path.
TEST_MODE="${WOO_REVIEW_TEST_MODE:-}"
if [ "$TEST_MODE" = "1" ] && [ "${GITHUB_ACTIONS:-}" = "true" ]; then
  echo "::error::WOO_REVIEW_TEST_MODE is refused inside GitHub Actions. Test hooks are local-only." >&2
  exit 1
fi
# Trigger-comment parsing (issue #19 + existing --full override). Two channels:
#   1. `--full` substring → INCREMENTAL=off (legacy `@review --full` syntax).
#   2. `/woo-review [force|recheck]` slash command:
#        force   → bypass authors_skip + release_rollup_pattern (FORCE_BYPASS=1)
#        recheck → INCREMENTAL=auto (default; explicit override of --full)
#        (none)  → INCREMENTAL=off (full re-review)
#      `force` and `recheck` may co-occur.
# Fixed-string match avoids regex injection from user-controlled comment body.
FORCE_BYPASS=""
if [ "$EVENT_NAME" = "issue_comment" ]; then
  if printf '%s' "${COMMENT_BODY:-}" | grep -qF -- '--full'; then
    INCREMENTAL="off"
    echo "Incremental: forced to 'off' by --full in trigger comment"
  fi
  if printf '%s' "${COMMENT_BODY:-}" | grep -qE '(^|[[:space:]])/woo-review([[:space:]]|$)'; then
    HAS_FORCE=0; HAS_RECHECK=0
    if printf '%s' "${COMMENT_BODY:-}" | grep -qE '(^|[[:space:]])/woo-review[[:space:]]+(force|recheck[[:space:]]+force)([[:space:]]|$)'; then
      HAS_FORCE=1
    elif printf '%s' "${COMMENT_BODY:-}" | grep -qE '(^|[[:space:]])/woo-review[[:space:]]+force([[:space:]]|$)'; then
      HAS_FORCE=1
    fi
    if printf '%s' "${COMMENT_BODY:-}" | grep -qE '(^|[[:space:]])/woo-review[[:space:]]+(recheck|force[[:space:]]+recheck)([[:space:]]|$)'; then
      HAS_RECHECK=1
    elif printf '%s' "${COMMENT_BODY:-}" | grep -qE '(^|[[:space:]])/woo-review[[:space:]]+recheck([[:space:]]|$)'; then
      HAS_RECHECK=1
    fi
    if [ "$HAS_FORCE" = "1" ]; then
      FORCE_BYPASS=1
      echo "Auto-skip bypass: '/woo-review force' detected in trigger comment"
    fi
    if [ "$HAS_RECHECK" = "1" ]; then
      INCREMENTAL="auto"
      echo "Incremental: forced to 'auto' by '/woo-review recheck'"
    elif [ "$HAS_FORCE" = "0" ]; then
      # Bare `/woo-review` → full review.
      INCREMENTAL="off"
      echo "Incremental: forced to 'off' by bare '/woo-review' trigger"
    fi
  fi
fi

emit_skip() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "skip=true" >> "$GITHUB_OUTPUT"
  fi
  echo "skip=true"
  echo "Skipping: $1"
  exit 0
}

# Auto-skip (issue #19): emit a single explanatory comment then exit. Idempotent
# via the `<!-- woo-review:skipped -->` marker — repeat triggers (synchronize on
# a dependabot PR, etc.) re-skip silently. Marker scan also picks up prior skip
# comments authored by the action across re-runs, so the comment is posted at
# most once per PR until a human types `/woo-review force`.
emit_skip_with_comment() {
  local reason="$1"
  local body="woo-review skipped: ${reason}

<!-- woo-review:skipped -->"
  local existing
  existing=$(gh pr view "$PR_NUMBER" --json comments \
    --jq '[.comments[]? | select((.body // "") | test("<!-- woo-review:skipped -->"))] | length' \
    2>/dev/null || echo 0)
  if [ "${existing:-0}" = "0" ]; then
    if gh pr comment "$PR_NUMBER" --body "$body" >/dev/null 2>&1; then
      echo "Posted skip comment: ${reason}"
    else
      echo "::warning::failed to post skip comment (gh pr comment exit nonzero); continuing to skip"
    fi
  else
    echo "Skip comment marker already present; not reposting"
  fi
  emit_skip "$reason"
}

# Host-portability: when invoked outside GitHub Actions and no PR number was
# supplied, try to derive one from the current branch. Subshell is internal to
# this script (script-local subshells are not blocked by host sandboxes the way
# caller-side `PR_NUMBER="$(gh pr view ...)"` is — that pattern is what forced
# manual PR# resolution under Gemini CLI's tool gating).
if [ -z "$PR_NUMBER" ] && [ "${GITHUB_ACTIONS:-}" != "true" ]; then
  PR_NUMBER=$(gh pr view --json number --jq .number 2>/dev/null || true)
  if [ -n "$PR_NUMBER" ]; then
    echo "Resolved PR_NUMBER=$PR_NUMBER from current branch"
  fi
fi

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

# Marker lookup: pull the latest woo-review SHA watermark from prior review bodies.
# Empty result means no prior marker → full diff path (first run, or marker absent).
# Hand-edited / malformed markers also yield empty → silent fallback to full diff.
LAST_SHA=""
if [ "$TEST_MODE" = "1" ] && [ -n "${WOO_REVIEW_FAKE_PR_REVIEWS_JSON:-}" ]; then
  REVIEWS_JSON="$WOO_REVIEW_FAKE_PR_REVIEWS_JSON"
else
  REVIEWS_JSON=$(gh pr view "$PR_NUMBER" --json reviews 2>/dev/null || echo '{"reviews":[]}')
fi
# Marker trust: only honor reviews authored by woo-review bots. Without this
# filter any PR collaborator could submit a fake review with a forged marker
# pointing past their own malicious commits, narrowing the next incremental
# window to exclude them. The login pattern is anchored to the start of the
# string so logins like `myclaudebot` are rejected; a residual risk remains
# for logins that START with a bot prefix (e.g. `claude-evil`), which would
# require an attacker to register such a login AND obtain PR-collaborator
# access — defense-in-depth, not a hard guarantee.
LAST_SHA=$(printf '%s' "$REVIEWS_JSON" | jq -r --arg bots "$BOT_NAME_PATTERN" '
  [ .reviews[]?
    | { body: (.body // ""),
        submittedAt: (.submittedAt // ""),
        login: (.author.login // "") }
    | select(.login | test("^(" + $bots + ")"; "i"))
    | select(.body | test("<!-- woo-review:sha=[a-f0-9]+ -->"))
  ]
  | sort_by(.submittedAt)
  | last
  | if . == null then empty
    else (.body | capture("<!-- woo-review:sha=(?<sha>[a-f0-9]+) -->") | .sha)
    end
' 2>/dev/null || true)

# Re-run guard: if a prior AI bot has already commented and the current trigger is
# not an explicit user request, skip. Skipped when a marker is present — the marker
# means we've reviewed this PR before, so any new trigger (including synchronize)
# is the intended re-run signal for incremental mode. Pattern is anchored to
# match the marker filter — keeps "bot" classification consistent across both
# trust gates.
ISSUE_COMMENTS=$(gh pr view "$PR_NUMBER" --json comments \
  --jq "[.comments[] | select(.author.login | test(\"^($BOT_NAME_PATTERN)\"; \"i\"))] | length")
REVIEW_COMMENTS=$(gh api "repos/${GITHUB_REPOSITORY}/pulls/$PR_NUMBER/comments" \
  --jq "[.[] | select(.user.login | test(\"^($BOT_NAME_PATTERN)\"; \"i\"))] | length")
TOTAL_BOT_COMMENTS=$((ISSUE_COMMENTS + REVIEW_COMMENTS))

echo "Event: $EVENT_NAME, Action: $EVENT_ACTION, Prior bot comments: $TOTAL_BOT_COMMENTS, Marker: ${LAST_SHA:-none}, Incremental: $INCREMENTAL"

# Re-run guard scope: this check only applies inside GitHub Actions, where the
# review is auto-triggered by GitHub events and "explicit" is a meaningful
# concept. When invoked from a local host (Claude Code, Gemini CLI, opencode
# /woo-review skill), the user typed the command — by definition explicit —
# so EVENT_NAME is empty and the gate would otherwise misclassify the run as
# implicit and skip it whenever any prior bot comment exists on the PR.
if [ "${GITHUB_ACTIONS:-}" = "true" ] && \
   [ "$TOTAL_BOT_COMMENTS" -gt 0 ] && [ -z "$LAST_SHA" ] && \
   [ "$EVENT_NAME" != "issue_comment" ] && \
   [ "$EVENT_NAME" != "pull_request_target" ] && \
   [ "$EVENT_NAME" != "workflow_dispatch" ] && \
   [ "$EVENT_ACTION" != "ready_for_review" ] && \
   [ "$EVENT_ACTION" != "opened" ] && \
   [ "$EVENT_ACTION" != "reopened" ]; then
  emit_skip "bot already commented and trigger is not explicit"
fi

# Fetch metadata first — HEAD_SHA is needed for the compare-API incremental path.
gh pr view "$PR_NUMBER" --json headRefOid,baseRefName,title,body,files,author > "$OUTDIR/meta.json"
HEAD_SHA=$(jq -r '.headRefOid' "$OUTDIR/meta.json")

# Load per-repo config early (issue #19) so the bot-author / release-rollup
# skip checks can read user overrides BEFORE we pay for the diff fetch.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$SCRIPT_DIR/load-config.sh"

# Issue #19: auto-skip mechanical bot PRs (renovate / dependabot / etc.) and
# release-rollup PRs. Effective lists fall back to defaults when the user did
# not supply them. An explicit empty list (`authors_skip: []`) opts out.
# `/woo-review force` in a trigger comment bypasses both checks.
if [ "${FORCE_BYPASS:-}" != "1" ]; then
  AUTHOR_LOGIN=$(jq -r '.author.login // empty' "$OUTDIR/meta.json")
  PR_TITLE=$(jq -r '.title // ""' "$OUTDIR/meta.json")

  # authors_skip — config wins; defaults apply when key absent (`// null`
  # distinguishes "absent" from "explicit []").
  SKIP_MATCH=$(jq -r --arg login "$AUTHOR_LOGIN" '
    (if has("authors_skip") then .authors_skip
     else ["dependabot[bot]","renovate[bot]","github-actions[bot]"] end)
    | if index($login) then "yes" else "no" end
  ' "$OUTDIR/config.json" 2>/dev/null || echo "no")
  if [ -n "$AUTHOR_LOGIN" ] && [ "$SKIP_MATCH" = "yes" ]; then
    emit_skip_with_comment "author '$AUTHOR_LOGIN' matches authors_skip (override with \`/woo-review force\`)"
  fi

  # release_rollup_pattern — same precedence. Empty string opts out.
  ROLLUP_PATTERN=$(jq -r '
    if has("release_rollup_pattern") then .release_rollup_pattern
    else "^(staging|release|chore\\(release\\))" end
  ' "$OUTDIR/config.json" 2>/dev/null || echo '^(staging|release|chore\(release\))')
  if [ -n "$ROLLUP_PATTERN" ] && [ -n "$PR_TITLE" ]; then
    # Python regex (matches the engine used to validate the pattern in
    # load-config.sh, so a pattern that validated will execute identically).
    if python3 -c '
import re, sys
pattern, title = sys.argv[1], sys.argv[2]
sys.exit(0 if re.search(pattern, title) else 1)
' "$ROLLUP_PATTERN" "$PR_TITLE" 2>/dev/null; then
      emit_skip_with_comment "PR title matches release_rollup_pattern (override with \`/woo-review force\`)"
    fi
  fi
fi

# No-new-commits short-circuit: marker present and HEAD already matches it
# (e.g. user re-triggered without pushing). SKILL.md documents this skip.
if [ "$INCREMENTAL" = "auto" ] && [ -n "$LAST_SHA" ] && [ "$LAST_SHA" = "$HEAD_SHA" ]; then
  emit_skip "no new commits since last review ($LAST_SHA)"
fi

# Fetch diff. Three paths:
#   1. INCREMENTAL=auto + valid LAST_SHA + LAST_SHA != HEAD_SHA → compare API.
#   2. Compare-API 404 (force-push dropped LAST_SHA) → warn + full diff fallback.
#   3. Otherwise → full PR diff (today's behaviour).
INCREMENTAL_USED=""
if [ "$INCREMENTAL" = "auto" ] && [ -n "$LAST_SHA" ] && [ "$LAST_SHA" != "$HEAD_SHA" ]; then
  if [ "$TEST_MODE" = "1" ] && [ -n "${WOO_REVIEW_FAKE_INCREMENTAL_DIFF:-}" ]; then
    printf '%s' "$WOO_REVIEW_FAKE_INCREMENTAL_DIFF" > "$OUTDIR/diff.txt"
    INCREMENTAL_USED="$LAST_SHA"
    echo "Incremental diff: $LAST_SHA...$HEAD_SHA (test hook)"
  elif COMPARE_JSON=$(gh api "repos/${GITHUB_REPOSITORY}/compare/${LAST_SHA}...${HEAD_SHA}" 2>/dev/null); then
    # NOTE: cannot pipe $COMPARE_JSON to `python3 -` — `python3 -` reads its
    # script from stdin via the heredoc, so a pipe + heredoc would contend
    # for fd 0 (heredoc wins, JSON is lost). Stage JSON in a workflow-scoped
    # scratch file under $OUTDIR (not mktemp) so a Python crash under
    # `set -e` cannot leak a tempfile — $OUTDIR is already the run's
    # scratch directory.
    COMPARE_TMP="$OUTDIR/.compare.json"
    printf '%s' "$COMPARE_JSON" > "$COMPARE_TMP"
    python3 - "$OUTDIR/diff.txt" "$COMPARE_TMP" <<'PY'
import json, sys
out_path, in_path = sys.argv[1], sys.argv[2]
with open(in_path) as fh:
    data = json.load(fh)
with open(out_path, "w") as fh:
    for f in data.get("files", []):
        path = f.get("filename", "")
        if not path:
            continue
        fh.write(f"diff --git a/{path} b/{path}\n")
        patch = f.get("patch")
        if patch:
            fh.write(patch)
            if not patch.endswith("\n"):
                fh.write("\n")
PY
    rm -f "$COMPARE_TMP"
    INCREMENTAL_USED="$LAST_SHA"
    echo "Incremental diff: $LAST_SHA...$HEAD_SHA via compare API"
  else
    echo "::warning::last review SHA $LAST_SHA unreachable (force-push?); falling back to full diff"
  fi
fi

if [ -z "$INCREMENTAL_USED" ]; then
  gh pr diff "$PR_NUMBER" > "$OUTDIR/diff.txt"
fi
printf '%s' "$INCREMENTAL_USED" > "$OUTDIR/last_sha.txt"

DIFF_BYTES=$(wc -c < "$OUTDIR/diff.txt")
if [ -n "$INCREMENTAL_USED" ]; then
  # Derive CODE_FILES / LOC_CHANGED from the incremental diff itself (meta.json
  # reflects full PR scope, not the new commits).
  CODE_FILES=$(grep -E '^diff --git ' "$OUTDIR/diff.txt" \
    | sed -E 's|.* b/||' \
    | grep -vE '\.(md|tsv|json|lock|yaml|yml)$|^docs/|^specs/|database\.types\.ts$' \
    | wc -l || true)
  LOC_CHANGED=$(grep -cE '^[+-][^+-]' "$OUTDIR/diff.txt" || true)
else
  CODE_FILES=$(jq -r '.files[].path' "$OUTDIR/meta.json" \
    | grep -vE '\.(md|tsv|json|lock|yaml|yml)$|^docs/|^specs/|database\.types\.ts$' \
    | wc -l || true)
  LOC_CHANGED=$(jq -r '[.files[] | .additions + .deletions] | add // 0' "$OUTDIR/meta.json")
fi

echo "Diff bytes: $DIFF_BYTES, Code files: $CODE_FILES, LOC: $LOC_CHANGED"

if [ -n "$INCREMENTAL_USED" ] && [ "$DIFF_BYTES" -lt 50 ]; then
  emit_skip "no new commits since last review ($INCREMENTAL_USED)"
fi

if [ "$CODE_FILES" -eq 0 ]; then
  emit_skip "no code files changed"
fi

# LOC floor: only enforced on full-diff runs. Incremental runs may legitimately
# review a tiny fixup; the validator dedupe handles noise.
if [ -z "$INCREMENTAL_USED" ] && [ "$LOC_CHANGED" -lt 10 ]; then
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

# `load-config.sh` already ran near the top (issue #19 auto-skip needs it).
# Append config-listed project_rules to rules.md (augments auto-discovery).
if [ -n "${ROOT:-}" ] && [ -s "$OUTDIR/config.json" ] && jq -e '.project_rules // empty' "$OUTDIR/config.json" >/dev/null 2>&1; then
  EXTRA_LIST="$(mktemp)"
  EXTRA_BUF="$(mktemp)"
  # Expand each glob from inside the repo root so relative globs work as expected.
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    while IFS= read -r match; do
      [ -n "$match" ] && [ -f "$ROOT/$match" ] && printf '%s\n' "$match" >> "$EXTRA_LIST"
    done < <(cd "$ROOT" && compgen -G "$pat" 2>/dev/null || true)
  done < <(jq -r '.project_rules[]?' "$OUTDIR/config.json")
  EXTRA_UNIQUE="$(awk 'NF && !seen[$0]++' "$EXTRA_LIST")"
  if [ -n "$EXTRA_UNIQUE" ]; then
    while IFS= read -r rel; do
      printf '## SOURCE: %s\n' "$rel" >> "$EXTRA_BUF"
      cat "$ROOT/$rel" >> "$EXTRA_BUF"
      printf '\n\n' >> "$EXTRA_BUF"
    done <<< "$EXTRA_UNIQUE"
    cat "$EXTRA_BUF" >> "$OUTDIR/rules.md"
    EXTRA_COUNT=$(printf '%s\n' "$EXTRA_UNIQUE" | wc -l | xargs)
    echo "Appended $EXTRA_COUNT config-listed rule file(s) to rules.md:"
    printf '%s\n' "$EXTRA_UNIQUE" | sed 's/^/  /'
  fi
  rm -f "$EXTRA_LIST" "$EXTRA_BUF"
fi

# `authors_skip` + `release_rollup_pattern` already enforced above (issue #19),
# pre-diff-fetch so a skipped PR never pays for the diff download.

# ignore[] — pre-filter changed paths and diff body for downstream angle gates.
# fnmatch semantics; '**' matches any depth via Python's fnmatch.
if [ -s "$OUTDIR/config.json" ] && jq -e '.ignore // empty' "$OUTDIR/config.json" >/dev/null 2>&1; then
  python3 - "$OUTDIR/meta.json" "$OUTDIR/diff.txt" "$OUTDIR/config.json" "$OUTDIR/changed-paths.filtered.txt" "$OUTDIR/diff.filtered.txt" <<'PY'
import json
import os
import re
import sys
from fnmatch import fnmatch

meta_path, diff_path, cfg_path, paths_out, diff_out = sys.argv[1:6]

cfg = json.load(open(cfg_path))
patterns = cfg.get("ignore") or []

def globmatch(path, pattern):
    # Support '**' (any depth) on top of plain fnmatch.
    if "**" in pattern:
        regex = re.escape(pattern).replace(r"\*\*", ".*").replace(r"\*", "[^/]*").replace(r"\?", ".")
        return re.fullmatch(regex, path) is not None
    return fnmatch(path, pattern)

def ignored(path):
    return any(globmatch(path, p) for p in patterns)

meta = json.load(open(meta_path))
kept_paths = [f["path"] for f in meta.get("files", []) if not ignored(f["path"])]
with open(paths_out, "w") as fh:
    for p in kept_paths:
        fh.write(p + "\n")

# Strip per-file diff sections whose header path is ignored.
with open(diff_path, "r", errors="replace") as fh:
    diff = fh.read()
out = []
keep = True
for line in diff.splitlines(keepends=True):
    if line.startswith("diff --git "):
        m = re.match(r"diff --git a/(\S+) b/(\S+)", line)
        path = (m.group(2) if m else "")
        keep = not ignored(path)
    if keep:
        out.append(line)
with open(diff_out, "w") as fh:
    fh.writelines(out)

stripped = len(meta.get("files", [])) - len(kept_paths)
print("load-config: ignore[] stripped {} path(s); filtered artifacts written".format(stripped))
PY
fi

# Prior unresolved review threads — feed the posting stage's event-floor + dedupe
# logic. REST does not expose isResolved; GraphQL reviewThreads does. Counts ANY
# unresolved thread (human + bot) — a conservative gate that keeps a PR in
# REQUEST_CHANGES while any reviewer still has an open thread. First page only
# (100 threads); pagination is a follow-up.
if [ "$TEST_MODE" = "1" ] && [ -n "${WOO_REVIEW_FAKE_PRIOR_THREADS_JSON:-}" ]; then
  THREADS_JSON="$WOO_REVIEW_FAKE_PRIOR_THREADS_JSON"
else
  OWNER_NAME="${GITHUB_REPOSITORY%/*}"
  REPO_NAME="${GITHUB_REPOSITORY#*/}"
  THREADS_JSON=$(gh api graphql -F owner="$OWNER_NAME" -F repo="$REPO_NAME" -F pr="$PR_NUMBER" -f query='
    query($owner: String!, $repo: String!, $pr: Int!) {
      repository(owner: $owner, name: $repo) {
        pullRequest(number: $pr) {
          reviewThreads(first: 100) {
            nodes {
              isResolved
              path
              line
              comments(first: 1) {
                nodes { body author { login } }
              }
            }
          }
        }
      }
    }' 2>/dev/null || echo '{}')
fi
# Each entry is informational only — used by the dedup + posting stage.
# Includes resolved threads (status: "resolved") so dedup can suppress
# re-raising them. Posting event-floor counts ONLY open threads.
printf '%s' "$THREADS_JSON" | jq '
  [ .data.repository.pullRequest.reviewThreads.nodes[]?
    | select(.path != null)
    | { file: .path,
        line: (.line // 1),
        title: (((.comments.nodes[0].body // "") | split("\n")[0] | gsub("^\\*\\*|\\*\\*$"; ""))[0:60]),
        author: (.comments.nodes[0].author.login // ""),
        status: (if .isResolved then "resolved" else "open" end)
      }
  ]' > "$OUTDIR/prior-findings.json" 2>/dev/null || echo '[]' > "$OUTDIR/prior-findings.json"

PRIOR_COUNT=$(jq 'length' "$OUTDIR/prior-findings.json" 2>/dev/null || echo 0)
echo "Prior review threads (open + resolved): $PRIOR_COUNT"

# Cross-PR memory — a plain-markdown file of gotchas / accepted issues the team
# curates (and the local skill appends to). Surfaced to every angle + the
# validator as additional context so already-known issues are not re-flagged.
# Missing file => no memory context (normal for fresh repos).
MEMORY_SRC="${GITHUB_WORKSPACE:-$(pwd)}/.woo-review/memory.md"
MEMORY_OUT="$OUTDIR/memory.md"
if [ -f "$MEMORY_SRC" ]; then
  MEM_SIZE=$(wc -c < "$MEMORY_SRC" 2>/dev/null || echo 0)
  if [ "$MEM_SIZE" -gt 102400 ]; then
    # 100KB cap (same as rules.md) — truncate rather than skip so recent
    # entries still land. Memory is append-mostly; the head is the oldest.
    tail -c 102400 "$MEMORY_SRC" > "$MEMORY_OUT"
    echo "Memory file large (${MEM_SIZE}B); truncated to last 100KB."
  else
    cp "$MEMORY_SRC" "$MEMORY_OUT"
  fi
  echo "Loaded cross-PR memory: $MEMORY_SRC (${MEM_SIZE}B)"
else
  rm -f "$MEMORY_OUT"
fi

# Issue #14: split oversized diffs into chunks. Runs LAST so it sees the final
# post-ignore diff (diff.filtered.txt when present). Under the threshold this
# is a no-op (no chunks.txt produced, downstream behaves exactly as before).
bash "$SCRIPT_DIR/chunk-diff.sh"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "skip=false" >> "$GITHUB_OUTPUT"
fi
echo "skip=false"
echo "Prefetch complete: $OUTDIR/"
