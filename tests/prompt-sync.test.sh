#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROMPTS_DIR="$REPO_ROOT/skills/woo-review/prompts"

fail=0
for f in anthropic openai google opencode; do
  P="$PROMPTS_DIR/$f.md"
  for tok in "Host identifier:"; do
    if ! grep -q "$tok" "$P"; then
      echo "FAIL: $P missing required token '$tok'"
      fail=1
    fi
  done
done

HEADER="$PROMPTS_DIR/_header.md"
if ! grep -q 'Host: <host>' "$HEADER"; then
  echo "FAIL: $HEADER credits line missing 'Host: <host>' placeholder (issue #31)"
  fail=1
fi

# --- Validator swarm-durability contract (issues #46–#48) ---
V="$PROMPTS_DIR/validator.md"
VP="$PROMPTS_DIR/validator-prosecutor.md"
SKILL="$REPO_ROOT/skills/woo-review/SKILL.md"
ACTION="$REPO_ROOT/action.yml"

grep -q 'WOO_REVIEW_SEQUENTIAL_VALIDATE' "$V"     || { echo "FAIL: validator.md missing WOO_REVIEW_SEQUENTIAL_VALIDATE gate (#46)"; fail=1; }
grep -q 'WOO_REVIEW_SEQUENTIAL_VALIDATE' "$SKILL" || { echo "FAIL: SKILL.md missing gate note (#46)"; fail=1; }
grep -q 'WOO_REVIEW_SEQUENTIAL_VALIDATE' "$ACTION" || { echo "FAIL: action.yml missing gate env (#46)"; fail=1; }
grep -q "printf '\[\]" "$V"  || { echo "FAIL: validator.md missing []-first write (#47)"; fail=1; }
grep -q "printf '\[\]" "$VP" || { echo "FAIL: validator-prosecutor.md missing []-first write (#47)"; fail=1; }
for f in "$V" "$VP"; do
  grep -q 'prefetch.sh' "$f" || { echo "FAIL: $f missing prefetch.sh MUST-NOT (#48)"; fail=1; }
done
grep -q 'WOO_REVIEW_FRESH' "$REPO_ROOT/skills/woo-review/scripts/prefetch.sh" || { echo "FAIL: prefetch.sh missing WOO_REVIEW_FRESH guard (#48)"; fail=1; }

# --- Orchestrator-owned intersect contract (issue #46 regression guard) ---
# Every provider orchestrator must run intersect-findings.sh itself, NOT
# delegate it to the gated defender subagent.
for prov in anthropic openai google opencode; do
  grep -q 'intersect-findings.sh' "$PROMPTS_DIR/$prov.md" || { echo "FAIL: $prov.md missing orchestrator-level intersect-findings.sh (#46)"; fail=1; }
done
# anthropic.md / google.md must NOT tell the defender subagent to post or to run intersect itself.
for prov in anthropic google; do
  grep -qiE 'defender subagent continues into step 4|defender (subagent|@generalist|pass)[^.]*then runs[^.]*intersect|it then runs[^.]*intersect' "$PROMPTS_DIR/$prov.md" && { echo "FAIL: $prov.md still delegates post to defender subagent (#46)"; fail=1; }
done

[ "$fail" -eq 0 ] && echo "All prompt-sync tests passed."
exit "$fail"
