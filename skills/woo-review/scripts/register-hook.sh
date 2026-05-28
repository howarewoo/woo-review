#!/usr/bin/env bash
# register-hook.sh — wire the post-session sidecar write into the host.
#
# Registers a Claude Code `Stop` hook in the CURRENT repo's
# .claude/settings.local.json (per-developer, gitignored) pointing at
# sidecar-write.sh. Idempotent. Other hosts (opencode, Gemini CLI) get a
# printed snippet to wire manually.
#
# The Stop hook runs OUTSIDE the LLM tool scope — this is what keeps local
# /woo-review compliant with PR #33 ("the LLM step MUST NOT have repo-write").
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Quote the path inside the stored command so the Stop hook still resolves when
# the skill lives under a path containing spaces or shell metacharacters.
HOOK_CMD="bash \"${SCRIPT_DIR}/sidecar-write.sh\""
SETTINGS=".claude/settings.local.json"

mkdir -p .claude
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

# Dedup by sidecar-write.sh suffix so a reinstall to a new path removes the stale
# old entry rather than appending a second broken one alongside the new one.
TMP="$(mktemp)"
jq --arg c "$HOOK_CMD" '
  .hooks.Stop = (
    [ (.hooks.Stop // [])[]
      | .hooks = [ .hooks[]? | select((.command // "") | test("/sidecar-write\\.sh\"?$") | not) ]
      | select((.hooks | length) > 0)
    ]
    + [ { hooks: [ { type: "command", command: $c } ] } ]
  )
' "$SETTINGS" > "$TMP" && mv "$TMP" "$SETTINGS"
echo "✅ Registered post-session sidecar Stop hook in $SETTINGS"

# Per-developer settings must not be committed.
if [ -f .gitignore ]; then
  grep -qxF '.claude/settings.local.json' .gitignore || \
    printf '\n.claude/settings.local.json\n' >> .gitignore
else
  printf '.claude/settings.local.json\n' > .gitignore
fi

echo "ℹ️  Non-Claude hosts (opencode, Gemini CLI): wire this as a post-session hook:"
echo "      $HOOK_CMD"
