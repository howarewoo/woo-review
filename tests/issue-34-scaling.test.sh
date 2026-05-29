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
echo '{"enable_sidecar_write": true, "sidecar_ttl_days": 0}' > "$OUTDIR/config.json"
export PR_NUMBER=99
export HEAD_SHA=zzz
export GITHUB_ACTIONS=true
git init -q --bare "$WORK/remote.git"
git remote add origin "$WORK/remote.git"

shard_for() { printf '%s' "$1" | shasum -a 1 | cut -c1; }

pass=0; fail=0
expect() { local n="$1" c="$2"; if eval "$c"; then echo "PASS $n"; pass=$((pass+1)); else echo "FAIL $n (cond: $c)"; fail=$((fail+1)); fi }

# Seed 10,000 entries distributed by hash.
python3 - <<'PY'
import json, hashlib, os
root = ".woo-review"
os.makedirs(root, exist_ok=True)
counts = {f"{i:x}": 0 for i in range(16)}
for i in range(10000):
    file = f"src/auto/file-{i}.ts"
    sh = hashlib.sha1(file.encode()).hexdigest()[0]
    e = {
      "file": file, "line": (i % 200) + 1,
      "title": f"auto {i}",
      "semantic_key": f"bugs/auto-{i % 200}",
      "code_anchor": f"{i:012x}",
      "resolved_at": "2026-05-01T00:00:00Z",
      "pr_number": (i % 500) + 1
    }
    with open(f"{root}/dismissed-{sh}.jsonl","a") as f:
        f.write(json.dumps(e) + "\n")
    counts[sh] += 1
print("seeded:", counts)
PY
git add .woo-review && git commit -q -m seed-10k

# Per-shard size cap.
for f in .woo-review/dismissed-*.jsonl; do
  SIZE=$(wc -c < "$f")
  expect "per-shard size < 1MB ($f = $SIZE bytes)" "[ $SIZE -lt 1048576 ]"
done

# Capture cold-shard checksums.
COLD_SHARDS=""
for h in 0 1 2 3 4 5 6 7 8 9 a b c d e f; do
  COLD_SHARDS="$COLD_SHARDS $h:$(shasum -a 1 .woo-review/dismissed-$h.jsonl | awk '{print $1}')"
done

# Find a probe path that hashes to shard 'a'.
PROBE=""
for i in $(seq 1 200); do
  CAND="probe-${i}.ts"
  if [ "$(shard_for "$CAND")" = "a" ]; then PROBE="$CAND"; break; fi
done
[ -n "$PROBE" ] || { echo "FAIL setup: no probe path for shard a"; exit 1; }

export WOO_REVIEW_FAKE_RESOLVED_THREADS_JSON="{
  \"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"nodes\":[
    {\"isResolved\":true,\"path\":\"$PROBE\",\"line\":1,\"comments\":{\"nodes\":[{\"body\":\"<!-- woo-review:sk=bugs/probe ca=ffffffffffff -->\",\"author\":{\"login\":\"a\"}}]}}
  ]}}}}}"

START=$(date +%s)
bash "$SCRIPT"
END=$(date +%s)
ELAPSED=$((END - START))
echo "regression: write to populated shard took ${ELAPSED}s"

expect "write completes under 30s wall clock (got ${ELAPSED}s)" "[ $ELAPSED -lt 30 ]"

# Hot shard 'a' touched.
expect "hot shard a contains probe entry" \
  "jq -e 'select(.semantic_key==\"bugs/probe\")' .woo-review/dismissed-a.jsonl >/dev/null"

# Cold shards unchanged.
for entry in $COLD_SHARDS; do
  H="${entry%%:*}"; OLD_HASH="${entry##*:}"
  [ "$H" = "a" ] && continue
  NEW_HASH=$(shasum -a 1 .woo-review/dismissed-$H.jsonl | awk '{print $1}')
  expect "cold shard $H untouched" "[ \"$NEW_HASH\" = \"$OLD_HASH\" ]"
done

echo "----"
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
