#!/usr/bin/env bash
# Unit test for skills/woo-review/scripts/memory-append.sh.
# Covers: file is created on first write (the #53 reproduction — the memory
# write now fires), and an exact-duplicate learning is NOT appended twice.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/woo-review/scripts/memory-append.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

LEARNING="Per-call env-threshold parse intentionally falls back to a default; do not flag the missing guard"

# --- #53 reproduction: no .woo-review/memory.md yet; ACCEPT must create it ---
[ ! -e .woo-review/memory.md ] || { echo "FAIL: precondition — memory.md already exists"; exit 1; }
LEARNING="$LEARNING" bash "$SCRIPT"
[ -f .woo-review/memory.md ] || { echo "FAIL: memory.md not created (the #53 bug)"; exit 1; }
grep -qF "$LEARNING" .woo-review/memory.md || { echo "FAIL: learning not written"; exit 1; }

# --- Dedup: appending the same learning again must NOT duplicate the bullet ---
LEARNING="$LEARNING" bash "$SCRIPT"
n=$(grep -cF "$LEARNING" .woo-review/memory.md)
[ "$n" = "1" ] || { echo "FAIL: expected 1 occurrence after re-append, got $n"; exit 1; }

# --- A genuinely new learning DOES append ---
LEARNING="Generated *.pb.go files are intentional; do not flag their style" bash "$SCRIPT"
total=$(grep -c '^- ' .woo-review/memory.md)
[ "$total" = "2" ] || { echo "FAIL: expected 2 bullets, got $total"; exit 1; }

# --- Whitespace-normalized dedup: extra spaces must still dedup ---
LEARNING="Per-call env-threshold parse  intentionally falls back  to a default; do not flag the missing guard" bash "$SCRIPT"
total_ws=$(grep -c '^- ' .woo-review/memory.md)
[ "$total_ws" = "2" ] || { echo "FAIL: whitespace-norm dedup added a bullet, total=$total_ws"; exit 1; }

# --- MEMORY_FILE override: writes to a custom path + creates parent dir ---
LEARNING="custom path learning" MEMORY_FILE="$WORK/nested/custom-mem.md" bash "$SCRIPT"
[ -f "$WORK/nested/custom-mem.md" ] || { echo "FAIL: MEMORY_FILE override did not create file"; exit 1; }
grep -qF "custom path learning" "$WORK/nested/custom-mem.md" || { echo "FAIL: learning not written to custom path"; exit 1; }

echo "PASS memory-append.test.sh"
