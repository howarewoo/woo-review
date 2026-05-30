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

trap 'rm -rf "${REPO_A:-}" "${REPO_B:-}" "${NONREPO:-}" "${OUT_A:-}" "${OUT_A2:-}" "${OUT_B2:-}" "${SHARED:-}"' EXIT

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

# Case 6: cross-project isolation — the regression this helper exists to prevent.
# The hazard: prefetch.sh runs `rm -rf "$OUTDIR"`. If two repos resolve to the
# SAME dir, reviewing repo B destroys repo A's in-flight artifacts.
#
# (a) The hazard is real: when two runs share one dir, the wipe IS destructive.
SHARED="$(mktemp -d "${TMPDIR:-/tmp}/ro-shared.XXXXXX")"
echo "A-sentinel" > "$SHARED/findings.bugs.json"   # repo A's in-flight artifact
rm -rf "$SHARED"                                     # repo B's prefetch wipe (same dir)
if [ ! -e "$SHARED/findings.bugs.json" ]; then pass "shared-dir wipe is destructive (hazard real)"; else fail "shared-dir wipe is destructive (hazard real)"; fi
#
# (b) The fix holds: with NEITHER repo setting OUTDIR, the helper derives DISTINCT
# per-project dirs, so repo B's wipe cannot reach repo A. This is tied to the real
# helper output — a regression to a constant default makes the two dirs equal and
# FAILS this assertion (so the case is independently falsifiable, not tautological).
OUT_A2="$(resolve "$REPO_A" "")"
OUT_B2="$(resolve "$REPO_B" "")"
mkdir -p "$OUT_A2" "$OUT_B2"
echo "A-sentinel" > "$OUT_A2/findings.bugs.json"
rm -rf "$OUT_B2"                                     # repo B's prefetch wipe (its own dir)
if [ -f "$OUT_A2/findings.bugs.json" ]; then pass "per-project derivation isolates the wipe"; else fail "per-project derivation isolates the wipe (A clobbered — helper not per-project?)"; fi

rm -rf "$REPO_A" "$REPO_B" "$NONREPO" "$OUT_A"
echo
echo "resolve-outdir: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
