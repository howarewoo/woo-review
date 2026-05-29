#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/woo-review/scripts/install-gitattributes.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

pass=0; fail=0
expect() { local n="$1" c="$2"; if eval "$c"; then echo "PASS $n"; pass=$((pass+1)); else echo "FAIL $n (cond: $c)"; fail=$((fail+1)); fi }
LINE='.woo-review/dismissed-*.jsonl merge=union'

# Case A: no .gitattributes → created with the line
rm -f .gitattributes
bash "$SCRIPT"
expect "A: file created" "[ -f .gitattributes ]"
expect "A: line present"  "grep -qxF '$LINE' .gitattributes"

# Case B: re-run → idempotent (still exactly one matching line)
bash "$SCRIPT"
expect "B: idempotent (one matching line)" \
  "[ \"\$(grep -cxF '$LINE' .gitattributes)\" -eq 1 ]"

# Case C: pre-existing content preserved
cat > .gitattributes <<EOF
* text=auto
*.png binary
EOF
bash "$SCRIPT"
expect "C: pre-existing lines preserved" \
  "grep -q '\\* text=auto' .gitattributes && grep -q '\\*\\.png binary' .gitattributes"
expect "C: our line appended" \
  "grep -qxF '$LINE' .gitattributes"

# Case D: pre-existing file missing trailing newline → still appends cleanly
printf '* text=auto' > .gitattributes
bash "$SCRIPT"
expect "D: original line preserved when no trailing newline" \
  "grep -q '\\* text=auto' .gitattributes"
expect "D: our line appended on its own line" \
  "grep -qxF '$LINE' .gitattributes"

echo "----"
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
