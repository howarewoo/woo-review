#!/usr/bin/env bash
# Asserts the /woo-review workflow in SKILL.md contains a numbered Stage 6
# for sidecar-write, so host agents cannot skip the resolved-thread recording
# step. Guards against regression of issue #37.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$REPO_ROOT/skills/woo-review/SKILL.md"

fail=0

# 1. Stage 6 heading must exist (em-dash, not hyphen — matches Stage 0..5 style).
if ! grep -qF '### Stage 6 — Sidecar Write' "$SKILL"; then
  echo "FAIL: $SKILL missing '### Stage 6 — Sidecar Write' heading (issue #37)"
  fail=1
fi

# 2. Stage 6 section must invoke sidecar-write.sh in a bash block.
#    awk extracts everything between the Stage 6 heading and the next '### '
#    heading (or EOF), then we grep for the script invocation.
STAGE6=$(awk '
  /^### Stage 6 — Sidecar Write/ { capture=1; next }
  /^### / && capture { exit }
  capture { print }
' "$SKILL")

if [ -z "$STAGE6" ]; then
  echo "FAIL: Stage 6 section is empty"
  fail=1
elif ! printf '%s\n' "$STAGE6" | grep -q 'scripts/sidecar-write.sh'; then
  echo "FAIL: Stage 6 body does not invoke scripts/sidecar-write.sh"
  fail=1
fi

# 3. Stage 6 must reference the enable_sidecar_write gate so readers know
#    the script may exit early in default config.
if ! printf '%s\n' "$STAGE6" | grep -q 'enable_sidecar_write'; then
  echo "FAIL: Stage 6 body does not mention enable_sidecar_write gate"
  fail=1
fi

[ "$fail" -eq 0 ] && echo "All skill-stages tests passed."
exit "$fail"
