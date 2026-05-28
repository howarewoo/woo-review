#!/usr/bin/env bash
# Local-path tests for sidecar-write.sh: state read from review-context.json
# when session env is absent, plus the non-CI sentinel + repo-match guard.
# No network — resolved threads are injected via WOO_REVIEW_FAKE_RESOLVED_THREADS_JSON.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/woo-review/scripts/sidecar-write.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
expect() { local n="$1" c="$2"; if eval "$c"; then echo "PASS $n"; pass=$((pass+1));
           else echo "FAIL $n (cond: $c)"; fail=$((fail+1)); fi; }

# Two newly-resolved threads (collapse to >=1 entry via placeholder dedup keys).
FAKE='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
  {"isResolved":true,"path":"a.ts","line":1,"comments":{"nodes":[{"body":"t1","author":{"login":"a"}}]}}
]}}}}}'

setup_repo() {  # $1 = repo dir
  mkdir -p "$1" && git -C "$1" init -q -b main
  git -C "$1" config user.email t@t && git -C "$1" config user.name t
  git -C "$1" config push.autoSetupRemote true
  git -C "$1" commit --allow-empty -q -m init
  mkdir -p "$1/.woo-review"
  git init -q --bare "$1.remote.git"
  git -C "$1" remote add origin "$1.remote.git"
}

write_ctx() {  # $1 = OUTDIR, $2 = repo_path
  echo '{"enable_sidecar_write": true}' > "$1/config.json"
  jq -n --arg p "$2" '{pr_number:42, head_sha:"abc", repo:"owner/repo", repo_path:$p}' \
    > "$1/review-context.json"
}

# ---- case A: env unset, state from review-context.json (CI mode → guard skipped)
REPO="$WORK/a"; setup_repo "$REPO"
OUT="$WORK/out-a"; mkdir -p "$OUT"; write_ctx "$OUT" "$(git -C "$REPO" rev-parse --show-toplevel)"
( cd "$REPO"
  unset PR_NUMBER HEAD_SHA GITHUB_REPOSITORY 2>/dev/null || true
  OUTDIR="$OUT" GITHUB_ACTIONS=true WOO_REVIEW_FAKE_RESOLVED_THREADS_JSON="$FAKE" bash "$SCRIPT" )
expect "A: state read from review-context.json → entry written" \
  '[ "$(jq length "$REPO/.woo-review/dismissed.json" 2>/dev/null || echo 0)" -ge 1 ]'

# ---- case B: local mode, sentinel present + repo matches → write, sentinel consumed
REPO="$WORK/b"; setup_repo "$REPO"
OUT="$WORK/out-b"; mkdir -p "$OUT"; write_ctx "$OUT" "$(git -C "$REPO" rev-parse --show-toplevel)"
touch "$OUT/sidecar-pending"
( cd "$REPO"
  unset PR_NUMBER HEAD_SHA GITHUB_REPOSITORY GITHUB_ACTIONS 2>/dev/null || true
  OUTDIR="$OUT" WOO_REVIEW_FAKE_RESOLVED_THREADS_JSON="$FAKE" bash "$SCRIPT" )
expect "B: sentinel+match → entry written" \
  '[ "$(jq length "$REPO/.woo-review/dismissed.json" 2>/dev/null || echo 0)" -ge 1 ]'
expect "B: sentinel consumed" '[ ! -f "$OUT/sidecar-pending" ]'

# ---- case B2: local mode, NO sentinel → no-op
REPO="$WORK/b2"; setup_repo "$REPO"
OUT="$WORK/out-b2"; mkdir -p "$OUT"; write_ctx "$OUT" "$(git -C "$REPO" rev-parse --show-toplevel)"
( cd "$REPO"
  unset PR_NUMBER HEAD_SHA GITHUB_REPOSITORY GITHUB_ACTIONS 2>/dev/null || true
  OUTDIR="$OUT" WOO_REVIEW_FAKE_RESOLVED_THREADS_JSON="$FAKE" bash "$SCRIPT" )
expect "B2: no sentinel → no write" \
  '[ "$(jq length "$REPO/.woo-review/dismissed.json" 2>/dev/null || echo 0)" -eq 0 ]'

# ---- case E2: sentinel present but review-context.json absent → no write, sentinel consumed.
# CTX_PATH resolves empty; the safe-default guard must NOT proceed to write in
# whatever repo the hook fires in (a stale sentinel + missing context must not
# defeat the repo-match guard).
REPO="$WORK/e2"; setup_repo "$REPO"
OUT="$WORK/out-e2"; mkdir -p "$OUT"
echo '{"enable_sidecar_write": true}' > "$OUT/config.json"   # config present, context NOT written
touch "$OUT/sidecar-pending"
( cd "$REPO"
  unset PR_NUMBER HEAD_SHA GITHUB_REPOSITORY GITHUB_ACTIONS 2>/dev/null || true
  OUTDIR="$OUT" WOO_REVIEW_FAKE_RESOLVED_THREADS_JSON="$FAKE" bash "$SCRIPT" )
expect "E2: missing context → no write" \
  '[ "$(jq length "$REPO/.woo-review/dismissed.json" 2>/dev/null || echo 0)" -eq 0 ]'
expect "E2: missing context consumes sentinel" '[ ! -f "$OUT/sidecar-pending" ]'

# ---- case C: sentinel present but cwd repo != reviewed repo → no write, sentinel consumed
REPO="$WORK/c"; setup_repo "$REPO"        # the repo we actually run in
OTHER="$WORK/c-other"; setup_repo "$OTHER"  # the repo review-context points at
OUT="$WORK/out-c"; mkdir -p "$OUT"; write_ctx "$OUT" "$(git -C "$OTHER" rev-parse --show-toplevel)"
touch "$OUT/sidecar-pending"
( cd "$REPO"
  unset PR_NUMBER HEAD_SHA GITHUB_REPOSITORY GITHUB_ACTIONS 2>/dev/null || true
  OUTDIR="$OUT" WOO_REVIEW_FAKE_RESOLVED_THREADS_JSON="$FAKE" bash "$SCRIPT" )
expect "C: repo mismatch → no write" \
  '[ "$(jq length "$REPO/.woo-review/dismissed.json" 2>/dev/null || echo 0)" -eq 0 ]'
expect "C: mismatch consumes sentinel" '[ ! -f "$OUT/sidecar-pending" ]'

# ---- case D: non-CI, sentinel present but enable_sidecar_write=false → no write, sentinel STILL consumed
REPO="$WORK/d"; setup_repo "$REPO"
OUT="$WORK/out-d"; mkdir -p "$OUT"
echo '{"enable_sidecar_write": false}' > "$OUT/config.json"
jq -n --arg p "$(git -C "$REPO" rev-parse --show-toplevel)" \
  '{pr_number:42, head_sha:"abc", repo:"owner/repo", repo_path:$p}' > "$OUT/review-context.json"
touch "$OUT/sidecar-pending"
( cd "$REPO"
  unset PR_NUMBER HEAD_SHA GITHUB_REPOSITORY GITHUB_ACTIONS 2>/dev/null || true
  OUTDIR="$OUT" WOO_REVIEW_FAKE_RESOLVED_THREADS_JSON="$FAKE" bash "$SCRIPT" )
expect "D: disabled → no write" \
  '[ "$(jq length "$REPO/.woo-review/dismissed.json" 2>/dev/null || echo 0)" -eq 0 ]'
expect "D: disabled still consumes sentinel (no leak)" '[ ! -f "$OUT/sidecar-pending" ]'

echo "----"; echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
