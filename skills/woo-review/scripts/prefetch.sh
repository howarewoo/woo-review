#!/usr/bin/env bash
# Prefetches PR diff, metadata, and rules for the agentic review.
# Inputs (env): GH_TOKEN, GITHUB_REPOSITORY, INPUT_SKIP_LABELS, INPUT_INCREMENTAL,
#               PR_NUMBER, EVENT_NAME, EVENT_ACTION, COMMENT_BODY.
# Outputs: skip=true|false to $GITHUB_OUTPUT.
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
# Fixed-string match for `--full` in a trigger comment overrides to off. Fixed
# string (grep -F) avoids any regex injection from user-controlled comment body.
if [ "$EVENT_NAME" = "issue_comment" ] && \
   printf '%s' "${COMMENT_BODY:-}" | grep -qF -- '--full'; then
  INCREMENTAL="off"
  echo "Incremental: forced to 'off' by --full in trigger comment"
fi

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

if [ "$TOTAL_BOT_COMMENTS" -gt 0 ] && [ -z "$LAST_SHA" ] && \
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

# Per-repo config (.woo-review.yml). Loads, validates, persists to config.json.
# Missing file is bit-identical to current behaviour. Bad YAML aborts.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$SCRIPT_DIR/load-config.sh"

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

# authors_skip — match the PR author against the configured allowlist.
if [ -s "$OUTDIR/config.json" ] && jq -e '.authors_skip // empty' "$OUTDIR/config.json" >/dev/null 2>&1; then
  AUTHOR_LOGIN=$(jq -r '.author.login // empty' "$OUTDIR/meta.json")
  if [ -n "$AUTHOR_LOGIN" ]; then
    if jq -e --arg login "$AUTHOR_LOGIN" '.authors_skip | index($login)' "$OUTDIR/config.json" >/dev/null 2>&1; then
      emit_skip "author '$AUTHOR_LOGIN' is in authors_skip"
    fi
  fi
fi

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
# Each entry is informational only — used by the posting stage for (a) dedupe
# against new findings at the same (file, line, title-stem) and (b) a single
# event floor: ANY non-empty prior-findings list keeps the PR at minimum
# REQUEST_CHANGES (per the conservative "no APPROVE while threads open" rule).
# No per-entry `blocking` flag — the floor is bool over the whole array.
printf '%s' "$THREADS_JSON" | jq '
  [ .data.repository.pullRequest.reviewThreads.nodes[]?
    | select(.isResolved == false)
    | select(.path != null)
    | { file: .path,
        line: (.line // 1),
        title: (((.comments.nodes[0].body // "") | split("\n")[0] | gsub("^\\*\\*|\\*\\*$"; ""))[0:60]),
        author: (.comments.nodes[0].author.login // "")
      }
  ]' > "$OUTDIR/prior-findings.json" 2>/dev/null || echo '[]' > "$OUTDIR/prior-findings.json"

PRIOR_COUNT=$(jq 'length' "$OUTDIR/prior-findings.json" 2>/dev/null || echo 0)
echo "Prior unresolved threads: $PRIOR_COUNT"

echo "skip=false" >> "$GITHUB_OUTPUT"
echo "Prefetch complete: $OUTDIR/"
