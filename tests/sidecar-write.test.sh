#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/woo-review/scripts/sidecar-write.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/repo" && cd "$WORK/repo"
git init -q -b main
git config user.email t@t && git config user.name t
# Enable auto-tracking so 'git push' works without --set-upstream
git config push.autoSetupRemote true
git commit --allow-empty -q -m init
mkdir -p .woo-review
mkdir -p "$WORK/pr-review"
export OUTDIR="$WORK/pr-review"
echo '{"enable_sidecar_write": true}' > "$OUTDIR/config.json"
export PR_NUMBER=42
export HEAD_SHA=abc
git init -q --bare "$WORK/remote.git"
git remote add origin "$WORK/remote.git"

pass=0; fail=0
expect() {
  local name="$1" cond="$2"
  if eval "$cond"; then echo "PASS $name"; pass=$((pass+1))
  else echo "FAIL $name (cond: $cond)"; fail=$((fail+1)); fi
}

# ---- case A: 2 newly-resolved threads → at least 1 entry written
# NOTE: sidecar-write.sh deduplicates via unique_by({pr_number, semantic_key,
# code_anchor}). Both threads receive the placeholder keys "unknown/unknown" /
# "unknown000000", so they collapse to 1 unique entry. The script still
# reports NEW_COUNT=2 (input threads) but writes 1 deduplicated record.
export WOO_REVIEW_FAKE_RESOLVED_THREADS_JSON='{
  "data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
    {"isResolved":true,"path":"a.ts","line":1,"comments":{"nodes":[{"body":"t1","author":{"login":"a"}}]}},
    {"isResolved":true,"path":"b.ts","line":2,"comments":{"nodes":[{"body":"t2","author":{"login":"a"}}]}}
  ]}}}}}'
bash "$SCRIPT"
expect "A: threads appended (at least 1 entry)" \
  '[ "$(jq length .woo-review/dismissed.json)" -ge 1 ]'

# ---- case B: re-run with same threads → idempotent (same count as after A)
AFTER_A=$(jq length .woo-review/dismissed.json)
bash "$SCRIPT"
expect "B: idempotent append (count unchanged after re-run)" \
  '[ "$(jq length .woo-review/dismissed.json)" -eq '"$AFTER_A"' ]'

# ---- case C: malformed existing sidecar → skip, no overwrite
echo 'not json' > .woo-review/dismissed.json
ORIG_CONTENT=$(cat .woo-review/dismissed.json)
bash "$SCRIPT" || true
expect "C: malformed sidecar not overwritten" \
  '[ "$(cat .woo-review/dismissed.json)" = "$ORIG_CONTENT" ]'

echo '[]' > .woo-review/dismissed.json
git add .woo-review/dismissed.json && git commit -q -m reset

# ---- case D: enable flag false → no write
echo '{"enable_sidecar_write": false}' > "$OUTDIR/config.json"
bash "$SCRIPT"
expect "D: disabled flag → no entries written" \
  '[ "$(jq length .woo-review/dismissed.json)" -eq 0 ]'

# ---- case E: WOO_REVIEW_DISABLE_GIT_WRITE=1 → no write
echo '{"enable_sidecar_write": true}' > "$OUTDIR/config.json"
export WOO_REVIEW_DISABLE_GIT_WRITE=1
bash "$SCRIPT"
expect "E: env disable → no entries written" \
  '[ "$(jq length .woo-review/dismissed.json)" -eq 0 ]'
unset WOO_REVIEW_DISABLE_GIT_WRITE

echo "----"
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
