#!/usr/bin/env bash
# Tests for resolve-outdir.sh — per-project OUTDIR derivation (issue: parallel runs).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$SCRIPT_DIR/skills/woo-review/scripts/resolve-outdir.sh"

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
assert_eq()  { local l="$1" g="$2" w="$3"; if [ "$g" = "$w" ]; then pass "$l"; else fail "$l (got '$g' want '$w')"; fi; }
assert_ne()  { local l="$1" a="$2" b="$3"; if [ "$a" != "$b" ]; then pass "$l"; else fail "$l (both '$a')"; fi; }
assert_match() { local l="$1" g="$2" re="$3"; if printf '%s' "$g" | grep -Eq "$re"; then pass "$l"; else fail "$l (got '$g' !~ $re)"; fi; }

trap 'rm -rf "${REPO_A:-}" "${REPO_B:-}" "${NONREPO:-}" "${OUT_A:-}"' EXIT

# Resolve OUTDIR by sourcing the helper inside a subshell, optionally cd'd into DIR
# and with OUTDIR pre-set. Echoes the resolved value.
resolve() { # args: [cd_dir] [preset_outdir]
  local dir="${1:-}" preset="${2:-}"
  (
    [ -n "$dir" ] && cd "$dir"
    if [ -n "$preset" ]; then OUTDIR="$preset"; else unset OUTDIR; fi
    # shellcheck source=/dev/null
    source "$HELPER"
    printf '%s' "$OUTDIR"
  )
}

# Case 1: explicit override is respected verbatim
assert_eq "override respected" "$(resolve "" "/custom/dir")" "/custom/dir"

# Case 2: unset inside a git repo -> /tmp/pr-review-<12hex>
REPO_A="$(mktemp -d "${TMPDIR:-/tmp}/ro-repoA.XXXXXX")"
( cd "$REPO_A" && git init -q )
OUT_A="$(resolve "$REPO_A" "")"
assert_match "git repo derived shape" "$OUT_A" '^/tmp/pr-review-[0-9a-f]{12}$'

# Case 3: same repo from a subdir -> identical path
mkdir -p "$REPO_A/sub/deep"
OUT_A_SUB="$(resolve "$REPO_A/sub/deep" "")"
assert_eq "subdir identical" "$OUT_A_SUB" "$OUT_A"

# Case 4: a different repo root -> different path
REPO_B="$(mktemp -d "${TMPDIR:-/tmp}/ro-repoB.XXXXXX")"
( cd "$REPO_B" && git init -q )
OUT_B="$(resolve "$REPO_B" "")"
assert_ne "different repos differ" "$OUT_A" "$OUT_B"

# Case 5: non-repo dir falls back to CWD hash (still derived shape, stable)
NONREPO="$(mktemp -d "${TMPDIR:-/tmp}/ro-nonrepo.XXXXXX")"
OUT_N1="$(resolve "$NONREPO" "")"
OUT_N2="$(resolve "$NONREPO" "")"
assert_match "non-repo derived shape" "$OUT_N1" '^/tmp/pr-review-[0-9a-f]{12}$'
assert_eq "non-repo stable" "$OUT_N1" "$OUT_N2"

# Case 6: cross-project isolation reproduction — wiping repo B's tree must NOT
# touch repo A's tree (today both default to /tmp/pr-review and B's rm -rf kills A).
mkdir -p "$OUT_A" "$OUT_B"
echo "A-sentinel" > "$OUT_A/findings.bugs.json"
rm -rf "$OUT_B"          # simulate prefetch B's atomic wipe
if [ -f "$OUT_A/findings.bugs.json" ]; then pass "cross-project wipe isolated"; else fail "cross-project wipe isolated (A clobbered)"; fi

rm -rf "$REPO_A" "$REPO_B" "$NONREPO" "$OUT_A"
echo
echo "resolve-outdir: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
