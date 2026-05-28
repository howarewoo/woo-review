#!/usr/bin/env bash
# Tests register-hook.sh: idempotent Stop-hook registration in a consumer repo's
# .claude/settings.local.json, plus gitignore wiring. No network.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/woo-review/scripts/register-hook.sh"
SIDECAR="$REPO_ROOT/skills/woo-review/scripts/sidecar-write.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
expect() { local n="$1" c="$2"; if eval "$c"; then echo "PASS $n"; pass=$((pass+1));
           else echo "FAIL $n (cond: $c)"; fail=$((fail+1)); fi; }

cd "$WORK"
SETTINGS=".claude/settings.local.json"
# Path is quoted in the stored command (handles spaces / shell metacharacters).
HOOK_CMD="bash \"$SIDECAR\""

# Run twice — must be idempotent.
bash "$SCRIPT"
bash "$SCRIPT"

expect "settings file is valid JSON" 'jq empty "$SETTINGS"'
expect "exactly one Stop hook entry for our command" \
  '[ "$(jq --arg c "$HOOK_CMD" "[.hooks.Stop[]?.hooks[]? | select(.command==\$c)] | length" "$SETTINGS")" -eq 1 ]'
expect "command points at sidecar-write.sh" \
  '[ "$(jq -r --arg c "$HOOK_CMD" "[.hooks.Stop[]?.hooks[]?.command] | index(\$c) != null" "$SETTINGS")" = "true" ]'
expect "settings.local.json is gitignored" \
  'grep -qxF ".claude/settings.local.json" .gitignore'

# Pre-existing unrelated Stop hook must be preserved.
rm -rf "$WORK/.claude" "$WORK/.gitignore"
mkdir -p .claude
echo '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo keep-me"}]}]}}' > "$SETTINGS"
bash "$SCRIPT"
expect "pre-existing hook preserved" \
  '[ "$(jq -r "[.hooks.Stop[]?.hooks[]?.command] | index(\"echo keep-me\") != null" "$SETTINGS")" = "true" ]'

# ---- stale-path entry is replaced, not duplicated (reinstall scenario)
rm -rf "$WORK/.claude" "$WORK/.gitignore"
mkdir -p .claude
cat > "$SETTINGS" <<JSON
{"hooks":{"Stop":[
  {"hooks":[{"type":"command","command":"bash /old/install/path/sidecar-write.sh"}]},
  {"hooks":[{"type":"command","command":"echo keep-me"}]}
]}}
JSON
bash "$SCRIPT"
expect "stale sidecar-write entry removed" \
  '[ "$(jq -r "[.hooks.Stop[]?.hooks[]?.command] | map(select(contains(\"sidecar-write.sh\"))) | length" "$SETTINGS")" -eq 1 ]'
expect "current command is the live path" \
  '[ "$(jq -r --arg c "$HOOK_CMD" "[.hooks.Stop[]?.hooks[]?.command] | index(\$c) != null" "$SETTINGS")" = "true" ]'
expect "unrelated keep-me hook survived dedup" \
  '[ "$(jq -r "[.hooks.Stop[]?.hooks[]?.command] | index(\"echo keep-me\") != null" "$SETTINGS")" = "true" ]'

# ---- path containing a space: stored command must be quoted so it stays one arg
SPACED="$WORK/dir with space/scripts"
mkdir -p "$SPACED"
cp "$REPO_ROOT/skills/woo-review/scripts/register-hook.sh" \
   "$REPO_ROOT/skills/woo-review/scripts/sidecar-write.sh" "$SPACED/"
rm -rf "$WORK/.claude" "$WORK/.gitignore"
( cd "$WORK" && bash "$SPACED/register-hook.sh" >/dev/null )
expect "spaced install path is quoted in stored command" \
  '[ "$(jq -r ".hooks.Stop[-1].hooks[0].command" "$SETTINGS")" = "bash \"$SPACED/sidecar-write.sh\"" ]'

echo "----"; echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
