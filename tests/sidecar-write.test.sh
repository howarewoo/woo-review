#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/woo-review/scripts/sidecar-write.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/repo" && cd "$WORK/repo"
git init -q -b main
git config user.email t@t && git config user.name t
git config push.autoSetupRemote true
git commit --allow-empty -q -m init
mkdir -p .woo-review
mkdir -p "$WORK/pr-review"
export OUTDIR="$WORK/pr-review"
echo '{"enable_sidecar_write": true}' > "$OUTDIR/config.json"
export PR_NUMBER=42
export HEAD_SHA=abc
export GITHUB_ACTIONS=true
git init -q --bare "$WORK/remote.git"
git remote add origin "$WORK/remote.git"

pass=0; fail=0
expect() { local n="$1" c="$2"; if eval "$c"; then echo "PASS $n"; pass=$((pass+1)); else echo "FAIL $n (cond: $c)"; fail=$((fail+1)); fi }

shard_for() { printf '%s' "$1" | shasum -a 1 | cut -c1; }
total_lines() {
  # set -e safe: shard glob may not match yet → return 0 without aborting caller.
  local n
  n=$( { cat .woo-review/dismissed-*.jsonl 2>/dev/null || true; } | wc -l | tr -d ' ')
  printf '%s' "$n"
}

# ---- case A: two resolved threads with markers → real keys parsed, written to correct shards
SK1="bugs/off-by-one"; CA1="a1b2c3d4e5f6"
SK2="security/xss";    CA2="0123456789ab"
A_SHARD=$(shard_for a.ts); B_SHARD=$(shard_for b.ts)
export WOO_REVIEW_FAKE_RESOLVED_THREADS_JSON="{
  \"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"nodes\":[
    {\"isResolved\":true,\"path\":\"a.ts\",\"line\":1,\"comments\":{\"nodes\":[{\"body\":\"t1\n<!-- woo-review:sk=$SK1 ca=$CA1 -->\",\"author\":{\"login\":\"a\"}}]}},
    {\"isResolved\":true,\"path\":\"b.ts\",\"line\":2,\"comments\":{\"nodes\":[{\"body\":\"t2\n<!-- woo-review:sk=$SK2 ca=$CA2 -->\",\"author\":{\"login\":\"a\"}}]}}
  ]}}}}}"
bash "$SCRIPT"
expect "A: two entries written (one per shard)" "[ \"\$(total_lines)\" -eq 2 ]"
expect "A: a.ts in shard $A_SHARD" \
  "jq -e --arg sk '$SK1' '.semantic_key==\$sk and .file==\"a.ts\"' .woo-review/dismissed-$A_SHARD.jsonl >/dev/null"
expect "A: b.ts in shard $B_SHARD" \
  "jq -e --arg sk '$SK2' '.semantic_key==\$sk and .file==\"b.ts\"' .woo-review/dismissed-$B_SHARD.jsonl >/dev/null"
expect "A: real ca recorded" \
  "jq -e --arg ca '$CA1' '.code_anchor==\$ca' .woo-review/dismissed-$A_SHARD.jsonl >/dev/null"

# ---- case B: re-run with same threads → idempotent (dedup by (pr,sk,ca))
AFTER_A=$(total_lines)
bash "$SCRIPT"
expect "B: idempotent append" "[ \"\$(total_lines)\" -eq $AFTER_A ]"

# ---- case C: thread without marker → fallback to placeholders, still written
export WOO_REVIEW_FAKE_RESOLVED_THREADS_JSON='{
  "data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
    {"isResolved":true,"path":"c.ts","line":3,"comments":{"nodes":[{"body":"no marker here","author":{"login":"a"}}]}}
  ]}}}}}'
C_SHARD=$(shard_for c.ts)
BEFORE_C=$(total_lines)
bash "$SCRIPT"
expect "C: placeholder fallback recorded" \
  "jq -e '.semantic_key==\"unknown/unknown\" and .code_anchor==\"unknown000000\" and .file==\"c.ts\"' .woo-review/dismissed-$C_SHARD.jsonl >/dev/null"
expect "C: count grew by 1" "[ \"\$(total_lines)\" -eq $((BEFORE_C + 1)) ]"

# ---- case D: malformed marker → treated as absent → placeholder
export WOO_REVIEW_FAKE_RESOLVED_THREADS_JSON='{
  "data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
    {"isResolved":true,"path":"d.ts","line":4,"comments":{"nodes":[{"body":"<!-- woo-review:sk=bugs/<bad> ca=zzzz -->","author":{"login":"a"}}]}}
  ]}}}}}'
D_SHARD=$(shard_for d.ts)
bash "$SCRIPT"
expect "D: malformed marker → placeholder keys" \
  "jq -e '.file==\"d.ts\" and .semantic_key==\"unknown/unknown\"' .woo-review/dismissed-$D_SHARD.jsonl >/dev/null"

# ---- case E: TTL prune drops expired entries on touched shards (default 180d)
# Seed shard 0 with one ancient entry. Trigger a write to shard 0 by routing a
# file that hashes to it (probe a fixed string).
PROBE=""; for i in $(seq 1 64); do P="probe-$i.ts"; if [ "$(shard_for "$P")" = "0" ]; then PROBE="$P"; break; fi; done
[ -n "$PROBE" ] || { echo "FAIL E: could not find a path hashing to shard 0"; exit 1; }
mkdir -p .woo-review
echo '{"file":"x.ts","line":1,"title":"old","semantic_key":"bugs/old","code_anchor":"000000000001","resolved_at":"2000-01-01T00:00:00Z","pr_number":1}' > .woo-review/dismissed-0.jsonl
git add .woo-review/dismissed-0.jsonl && git commit -q -m seed-old
export WOO_REVIEW_FAKE_RESOLVED_THREADS_JSON="{
  \"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"nodes\":[
    {\"isResolved\":true,\"path\":\"$PROBE\",\"line\":5,\"comments\":{\"nodes\":[{\"body\":\"<!-- woo-review:sk=bugs/new ca=deadbeefcafe -->\",\"author\":{\"login\":\"a\"}}]}}
  ]}}}}}"
bash "$SCRIPT"
expect "E: ancient entry pruned from touched shard 0" \
  "! jq -e 'select(.semantic_key==\"bugs/old\")' .woo-review/dismissed-0.jsonl >/dev/null"
expect "E: new entry present in shard 0" \
  "jq -e 'select(.semantic_key==\"bugs/new\")' .woo-review/dismissed-0.jsonl >/dev/null"

# ---- case F: TTL prune skips cold shards
mkdir -p .woo-review
echo '{"file":"y.ts","line":1,"title":"old","semantic_key":"bugs/cold","code_anchor":"000000000002","resolved_at":"2000-01-01T00:00:00Z","pr_number":1}' > .woo-review/dismissed-7.jsonl
git add .woo-review/dismissed-7.jsonl && git commit -q -m seed-cold
# Write to shard 0 again (PROBE from case E)
export WOO_REVIEW_FAKE_RESOLVED_THREADS_JSON="{
  \"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"nodes\":[
    {\"isResolved\":true,\"path\":\"$PROBE\",\"line\":99,\"comments\":{\"nodes\":[{\"body\":\"<!-- woo-review:sk=bugs/coldcase ca=feedfeedfeed -->\",\"author\":{\"login\":\"a\"}}]}}
  ]}}}}}"
bash "$SCRIPT"
expect "F: cold shard 7 unchanged" \
  "jq -e 'select(.semantic_key==\"bugs/cold\")' .woo-review/dismissed-7.jsonl >/dev/null"

# ---- case G: configurable TTL via .woo-review.yml
cat > .woo-review.yml <<EOF
enable_sidecar_write: true
sidecar_ttl_days: 30
EOF
# Re-run with a 60-day-old entry on shard 0 → should be pruned at 30d.
THIRTY=$(date -u -v-60d +%FT%TZ 2>/dev/null || date -u -d '60 days ago' +%FT%TZ)
mkdir -p .woo-review
echo "{\"file\":\"z.ts\",\"line\":1,\"title\":\"mid\",\"semantic_key\":\"bugs/mid\",\"code_anchor\":\"000000000003\",\"resolved_at\":\"$THIRTY\",\"pr_number\":1}" >> .woo-review/dismissed-0.jsonl
git add .woo-review/dismissed-0.jsonl && git commit -q -m seed-mid
export WOO_REVIEW_FAKE_RESOLVED_THREADS_JSON="{
  \"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"nodes\":[
    {\"isResolved\":true,\"path\":\"$PROBE\",\"line\":101,\"comments\":{\"nodes\":[{\"body\":\"<!-- woo-review:sk=bugs/recent ca=111111111111 -->\",\"author\":{\"login\":\"a\"}}]}}
  ]}}}}}"
bash "$SCRIPT"
expect "G: 60d entry pruned under 30d TTL" \
  "! jq -e 'select(.semantic_key==\"bugs/mid\")' .woo-review/dismissed-0.jsonl >/dev/null"
rm .woo-review.yml

# ---- case H: migrate legacy dismissed.json on first write
rm -rf .woo-review/dismissed-*.jsonl
cat > .woo-review/dismissed.json <<EOF
[
  {"file":"legacy-a.ts","line":1,"title":"l1","semantic_key":"bugs/legacy1","code_anchor":"aaaaaaaaaaaa","resolved_at":"2026-05-01T00:00:00Z","pr_number":10},
  {"file":"legacy-b.ts","line":2,"title":"l2","semantic_key":"bugs/legacy2","code_anchor":"bbbbbbbbbbbb","resolved_at":"2026-05-02T00:00:00Z","pr_number":11}
]
EOF
git add .woo-review/dismissed.json && git commit -q -m seed-legacy
LA_SHARD=$(shard_for legacy-a.ts); LB_SHARD=$(shard_for legacy-b.ts)
export WOO_REVIEW_FAKE_RESOLVED_THREADS_JSON="{
  \"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"nodes\":[
    {\"isResolved\":true,\"path\":\"new.ts\",\"line\":1,\"comments\":{\"nodes\":[{\"body\":\"<!-- woo-review:sk=bugs/new ca=cccccccccccc -->\",\"author\":{\"login\":\"a\"}}]}}
  ]}}}}}"
bash "$SCRIPT"
expect "H: legacy file removed" "[ ! -f .woo-review/dismissed.json ]"
expect "H: legacy entry in shard $LA_SHARD" \
  "jq -e 'select(.semantic_key==\"bugs/legacy1\")' .woo-review/dismissed-$LA_SHARD.jsonl >/dev/null"
expect "H: legacy entry in shard $LB_SHARD" \
  "jq -e 'select(.semantic_key==\"bugs/legacy2\")' .woo-review/dismissed-$LB_SHARD.jsonl >/dev/null"

# ---- case I: migration when no new entries (legacy present, 0 resolved threads)
rm -rf .woo-review/dismissed-*.jsonl
cat > .woo-review/dismissed.json <<EOF
[{"file":"legacy-only.ts","line":1,"title":"only","semantic_key":"bugs/only","code_anchor":"dddddddddddd","resolved_at":"2026-05-01T00:00:00Z","pr_number":12}]
EOF
git add .woo-review/dismissed.json && git commit -q -m seed-legacy-only
LO_SHARD=$(shard_for legacy-only.ts)
export WOO_REVIEW_FAKE_RESOLVED_THREADS_JSON='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}'
bash "$SCRIPT"
expect "I: legacy migrated even without new entries" \
  "jq -e 'select(.semantic_key==\"bugs/only\")' .woo-review/dismissed-$LO_SHARD.jsonl >/dev/null"
expect "I: legacy file removed even without new entries" \
  "[ ! -f .woo-review/dismissed.json ]"

# ---- case J: malformed shard line → skipped, write still succeeds
rm -rf .woo-review/dismissed-*.jsonl
mkdir -p .woo-review
printf 'not json\n{"file":"keep.ts","line":1,"title":"keep","semantic_key":"bugs/keep","code_anchor":"eeeeeeeeeeee","resolved_at":"2026-05-20T00:00:00Z","pr_number":13}\n' > .woo-review/dismissed-0.jsonl
git add .woo-review/dismissed-0.jsonl && git commit -q -m seed-malformed
export WOO_REVIEW_FAKE_RESOLVED_THREADS_JSON="{
  \"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"nodes\":[
    {\"isResolved\":true,\"path\":\"$PROBE\",\"line\":7,\"comments\":{\"nodes\":[{\"body\":\"<!-- woo-review:sk=bugs/added ca=ffffffffffff -->\",\"author\":{\"login\":\"a\"}}]}}
  ]}}}}}"
bash "$SCRIPT"
expect "J: valid line preserved" \
  "jq -e 'select(.semantic_key==\"bugs/keep\")' .woo-review/dismissed-0.jsonl >/dev/null"
expect "J: new entry added" \
  "jq -e 'select(.semantic_key==\"bugs/added\")' .woo-review/dismissed-0.jsonl >/dev/null"

# ---- case K: .gitattributes installed on first write
expect "K: .gitattributes contains merge=union rule" \
  "grep -qxF '.woo-review/dismissed-*.jsonl merge=union' .gitattributes"

# ---- case L: enable flag false → no write
echo '{"enable_sidecar_write": false}' > "$OUTDIR/config.json"
SHARDS_BEFORE=$(ls .woo-review/dismissed-*.jsonl 2>/dev/null | wc -l | tr -d ' ')
bash "$SCRIPT"
SHARDS_AFTER=$(ls .woo-review/dismissed-*.jsonl 2>/dev/null | wc -l | tr -d ' ')
expect "L: disabled flag → no new shard files" "[ \"$SHARDS_BEFORE\" = \"$SHARDS_AFTER\" ]"

# ---- case M: WOO_REVIEW_DISABLE_GIT_WRITE=1 → no write
echo '{"enable_sidecar_write": true}' > "$OUTDIR/config.json"
export WOO_REVIEW_DISABLE_GIT_WRITE=1
BEFORE=$(total_lines)
bash "$SCRIPT"
expect "M: env disable → no new entries" "[ \"\$(total_lines)\" -eq $BEFORE ]"
unset WOO_REVIEW_DISABLE_GIT_WRITE

echo "----"
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
