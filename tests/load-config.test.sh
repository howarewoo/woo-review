#!/usr/bin/env bash
# Unit test for skills/woo-review/scripts/load-config.sh.
# Each case writes a fixture .woo-review.yml into a temp $GITHUB_WORKSPACE and
# asserts the produced /tmp/pr-review/config.json (or that the loader exits
# non-zero with a GitHub-Actions ::error annotation).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/woo-review/scripts/load-config.sh"
WORK="$(mktemp -d)"
PREFETCH="/tmp/pr-review"
mkdir -p "$PREFETCH"
trap 'rm -rf "$WORK" "$PREFETCH"' EXIT

export GITHUB_WORKSPACE="$WORK/workspace"
mkdir -p "$GITHUB_WORKSPACE"

fail=0

assert_json_eq() {
  local name="$1" jq_expr="$2" expected="$3"
  local actual
  actual=$(jq -r "$jq_expr" "$PREFETCH/config.json")
  if [ "$actual" != "$expected" ]; then
    echo "FAIL $name: jq '$jq_expr' expected '$expected', got '$actual'"
    fail=1
    return 1
  fi
  return 0
}

# ---------- Case 1: missing config -> empty {} JSON ----------
rm -f "$GITHUB_WORKSPACE/.woo-review.yml" "$PREFETCH/config.json"
bash "$SCRIPT" >/dev/null
if [ "$(jq -r 'keys | length' "$PREFETCH/config.json")" = "0" ]; then
  echo "ok   missing-config-yields-empty-json"
else
  echo "FAIL missing-config-yields-empty-json: expected {}, got $(cat "$PREFETCH/config.json")"
  fail=1
fi

# ---------- Case 2: valid full config round-trips ----------
cat > "$GITHUB_WORKSPACE/.woo-review.yml" <<'YAML'
angles:
  force: [database]
  skip:  [seo]
severity_floor: medium
ignore:
  - "**/*.generated.ts"
  - "migrations/*.sql"
project_rules:
  - constitution.md
authors_skip:
  - "dependabot[bot]"
models:
  deep: anthropic/claude-opus-4-7
  standard: openai/gpt-5
fix_commands:
  - pnpm lint:fix
YAML
bash "$SCRIPT" >/dev/null
ok=1
assert_json_eq "valid-full" '.angles.force | join(",")' "database" || ok=0
assert_json_eq "valid-full" '.angles.skip  | join(",")' "seo" || ok=0
assert_json_eq "valid-full" '.severity_floor' "medium" || ok=0
assert_json_eq "valid-full" '.ignore | length' "2" || ok=0
assert_json_eq "valid-full" '.project_rules | join(",")' "constitution.md" || ok=0
assert_json_eq "valid-full" '.authors_skip | join(",")' "dependabot[bot]" || ok=0
assert_json_eq "valid-full" '.models.deep' "anthropic/claude-opus-4-7" || ok=0
assert_json_eq "valid-full" '.models.standard' "openai/gpt-5" || ok=0
assert_json_eq "valid-full" '.fix_commands | join(",")' "pnpm lint:fix" || ok=0
[ $ok -eq 1 ] && echo "ok   valid-full-config-roundtrip"

# ---------- Case 3: invalid YAML -> exit 1 + ::error with line= ----------
cat > "$GITHUB_WORKSPACE/.woo-review.yml" <<'YAML'
angles:
  force: [database
YAML
err_out="$WORK/err.txt"
if bash "$SCRIPT" 2>"$err_out" >/dev/null; then
  echo "FAIL invalid-yaml-exits-nonzero-with-line: loader exited 0"
  fail=1
else
  if grep -qE '^::error file=\.woo-review\.yml,line=[0-9]+' "$err_out"; then
    echo "ok   invalid-yaml-exits-nonzero-with-line"
  else
    echo "FAIL invalid-yaml-exits-nonzero-with-line: annotation not found in stderr"
    cat "$err_out"
    fail=1
  fi
fi

# ---------- Case 4: unknown top-level key rejected ----------
cat > "$GITHUB_WORKSPACE/.woo-review.yml" <<'YAML'
bogus_key: 1
YAML
err_out="$WORK/err.txt"
if bash "$SCRIPT" 2>"$err_out" >/dev/null; then
  echo "FAIL unknown-key-rejected: loader exited 0"
  fail=1
else
  if grep -q 'unknown top-level key' "$err_out"; then
    echo "ok   unknown-key-rejected"
  else
    echo "FAIL unknown-key-rejected: wrong error message"
    cat "$err_out"
    fail=1
  fi
fi

# ---------- Case 5: unknown angle rejected ----------
cat > "$GITHUB_WORKSPACE/.woo-review.yml" <<'YAML'
angles:
  force: [made_up_angle]
YAML
err_out="$WORK/err.txt"
if bash "$SCRIPT" 2>"$err_out" >/dev/null; then
  echo "FAIL unknown-angle-rejected: loader exited 0"
  fail=1
else
  if grep -q 'unknown angle' "$err_out"; then
    echo "ok   unknown-angle-rejected"
  else
    echo "FAIL unknown-angle-rejected: wrong error message"
    cat "$err_out"
    fail=1
  fi
fi

# ---------- Case 6: severity_floor case-insensitive ----------
cat > "$GITHUB_WORKSPACE/.woo-review.yml" <<'YAML'
severity_floor: HIGH
YAML
bash "$SCRIPT" >/dev/null
if [ "$(jq -r '.severity_floor' "$PREFETCH/config.json")" = "high" ]; then
  echo "ok   severity-floor-case-insensitive"
else
  echo "FAIL severity-floor-case-insensitive: expected 'high', got '$(jq -r '.severity_floor' "$PREFETCH/config.json")'"
  fail=1
fi

# ---------- Case 7: invalid severity_floor rejected ----------
cat > "$GITHUB_WORKSPACE/.woo-review.yml" <<'YAML'
severity_floor: critical
YAML
err_out="$WORK/err.txt"
if bash "$SCRIPT" 2>"$err_out" >/dev/null; then
  echo "FAIL invalid-severity-floor: loader exited 0"
  fail=1
else
  if grep -q 'severity_floor' "$err_out"; then
    echo "ok   invalid-severity-floor-rejected"
  else
    echo "FAIL invalid-severity-floor: wrong error"
    cat "$err_out"
    fail=1
  fi
fi

# ---------- Case 8: models passthrough preserves slug strings exactly ----------
cat > "$GITHUB_WORKSPACE/.woo-review.yml" <<'YAML'
models:
  fast: openrouter/anthropic/claude-haiku-4-5
  standard: openai/gpt-5
  deep: anthropic/claude-opus-4-7
YAML
bash "$SCRIPT" >/dev/null
ok=1
assert_json_eq "models-passthrough" '.models.fast' "openrouter/anthropic/claude-haiku-4-5" || ok=0
assert_json_eq "models-passthrough" '.models.standard' "openai/gpt-5" || ok=0
assert_json_eq "models-passthrough" '.models.deep' "anthropic/claude-opus-4-7" || ok=0
[ $ok -eq 1 ] && echo "ok   models-passthrough"

# ---------- Case 9a: disable_adversarial bool round-trips ----------
cat > "$GITHUB_WORKSPACE/.woo-review.yml" <<'YAML'
disable_adversarial: true
YAML
bash "$SCRIPT" >/dev/null
if [ "$(jq -r '.disable_adversarial' "$PREFETCH/config.json")" = "true" ]; then
  echo "ok   disable-adversarial-bool-roundtrip"
else
  echo "FAIL disable-adversarial-bool-roundtrip: got $(jq -r '.disable_adversarial' "$PREFETCH/config.json")"
  fail=1
fi

# ---------- Case 9b: disable_adversarial non-bool rejected ----------
cat > "$GITHUB_WORKSPACE/.woo-review.yml" <<'YAML'
disable_adversarial: "yes"
YAML
err_out="$WORK/err.txt"
if bash "$SCRIPT" 2>"$err_out" >/dev/null; then
  echo "FAIL disable-adversarial-non-bool: loader exited 0"
  fail=1
else
  if grep -q 'disable_adversarial' "$err_out" && grep -q 'must be a boolean' "$err_out"; then
    echo "ok   disable-adversarial-non-bool-rejected"
  else
    echo "FAIL disable-adversarial-non-bool: wrong error"
    cat "$err_out"
    fail=1
  fi
fi

# ---------- Case 10: empty file -> empty {} JSON ----------
: > "$GITHUB_WORKSPACE/.woo-review.yml"
bash "$SCRIPT" >/dev/null
if [ "$(jq -r 'keys | length' "$PREFETCH/config.json")" = "0" ]; then
  echo "ok   empty-file-yields-empty-json"
else
  echo "FAIL empty-file-yields-empty-json: got $(cat "$PREFETCH/config.json")"
  fail=1
fi

if [ $fail -ne 0 ]; then
  echo "TESTS FAILED"
  exit 1
fi
echo "All load-config tests passed."
