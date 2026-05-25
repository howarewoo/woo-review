#!/usr/bin/env bash
# Unit test for scripts/detect-angles.sh. Builds synthetic prefetch artifacts
# for three diff scenarios and asserts the emitted angles CSV.
#
# Exits non-zero on the first failure. Designed to run in CI without network.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/detect-angles.sh"
WORK="$(mktemp -d)"
PREFETCH="/tmp/pr-review"
mkdir -p "$PREFETCH"

# Mimic GITHUB_OUTPUT
OUTPUT_FILE="$WORK/output"
export GITHUB_OUTPUT="$OUTPUT_FILE"
export GITHUB_WORKSPACE="$WORK/workspace"
mkdir -p "$GITHUB_WORKSPACE"

fail=0

run_case() {
  local name="$1" expected_csv="$2"
  : > "$OUTPUT_FILE"
  bash "$SCRIPT"
  
  # Check CSV output
  local actual_csv
  actual_csv=$(grep '^angles=' "$OUTPUT_FILE" | head -n1 | cut -d= -f2-)
  if [ "$actual_csv" != "$expected_csv" ]; then
    echo "FAIL $name (csv): expected '$expected_csv', got '$actual_csv'"
    fail=1
    return
  fi

  # Check JSON output
  local actual_json
  actual_json=$(grep '^angles_json=' "$OUTPUT_FILE" | head -n1 | cut -d= -f2-)
  local expected_json
  expected_json=$(echo "$expected_csv" | tr ',' '\n' | jq -R . | jq -s -c .)
  if [ "$actual_json" != "$expected_json" ]; then
    echo "FAIL $name (json): expected '$expected_json', got '$actual_json'"
    fail=1
    return
  fi

  echo "ok   $name -> $actual_csv"
}

# --- Case 1: backend-only diff (Python + Go) -> bugs,security
cat > "$PREFETCH/meta.json" <<'JSON'
{
  "headRefOid": "deadbeef",
  "baseRefName": "main",
  "title": "feat: refactor auth",
  "body": "",
  "files": [
    {"path": "server/auth.py", "additions": 20, "deletions": 5},
    {"path": "cmd/api/main.go", "additions": 10, "deletions": 0}
  ]
}
JSON
cat > "$PREFETCH/diff.txt" <<'DIFF'
diff --git a/server/auth.py b/server/auth.py
+def login(user, password):
+    return bcrypt.check(password, user.hash)
DIFF
rm -f "$GITHUB_WORKSPACE/package.json"
run_case "backend-only" "bugs,security"

# --- Case 2: React app PR touching layout.tsx with metadata -> bugs,security,seo,design,react
cat > "$GITHUB_WORKSPACE/package.json" <<'PKG'
{
  "dependencies": { "react": "^18.0.0", "react-dom": "^18.0.0" }
}
PKG
cat > "$PREFETCH/meta.json" <<'JSON'
{
  "headRefOid": "feedface",
  "baseRefName": "main",
  "title": "feat: new product page",
  "body": "",
  "files": [
    {"path": "app/layout.tsx", "additions": 30, "deletions": 0},
    {"path": "app/page.tsx", "additions": 50, "deletions": 0},
    {"path": "app/globals.css", "additions": 10, "deletions": 0}
  ]
}
JSON
cat > "$PREFETCH/diff.txt" <<'DIFF'
diff --git a/app/layout.tsx b/app/layout.tsx
+export const metadata = {
+  title: 'Product',
+  openGraph: { 'og:title': 'Product' }
+};
DIFF
run_case "react+seo+design" "bugs,security,seo,design-audit,design-critique,react"

# --- Case 3: pure CSS change -> bugs,security,design
rm -f "$GITHUB_WORKSPACE/package.json"
cat > "$PREFETCH/meta.json" <<'JSON'
{
  "headRefOid": "cafebabe",
  "baseRefName": "main",
  "title": "style: tighten spacing",
  "body": "",
  "files": [
    {"path": "src/styles/main.css", "additions": 12, "deletions": 3}
  ]
}
JSON
cat > "$PREFETCH/diff.txt" <<'DIFF'
diff --git a/src/styles/main.css b/src/styles/main.css
+.card { padding: 12px; }
DIFF
run_case "design-only" "bugs,security,design-audit,design-critique"

# --- Case 4: disable_angles=design-audit,design-critique,react drops design from CSS PR -> bugs,security
INPUT_DISABLE_ANGLES="design-audit,design-critique,react" \
  bash "$SCRIPT" > /dev/null
actual=$(grep '^angles=' "$OUTPUT_FILE" | tail -n1 | cut -d= -f2-)
if [ "$actual" = "bugs,security" ]; then
  echo "ok   disable_angles=design-audit,design-critique,react -> $actual"
else
  echo "FAIL disable_angles: expected 'bugs,security', got '$actual'"
  fail=1
fi

# --- Case 5: disable_angles cannot drop bugs/security
: > "$OUTPUT_FILE"
INPUT_DISABLE_ANGLES="bugs,security,design-audit,design-critique" \
  bash "$SCRIPT" > /dev/null
actual=$(grep '^angles=' "$OUTPUT_FILE" | tail -n1 | cut -d= -f2-)
if [ "$actual" = "bugs,security" ]; then
  echo "ok   disable_angles refuses to drop bugs/security -> $actual"
else
  echo "FAIL disable_angles refusal: expected 'bugs,security', got '$actual'"
  fail=1
fi

# --- Case 6: bare "robots" / "sitemap" / "canonical" words in non-SEO diff
#            should NOT trigger seo (regex tightening regression guard).
rm -f "$GITHUB_WORKSPACE/package.json"
cat > "$PREFETCH/meta.json" <<'JSON'
{
  "headRefOid": "0badf00d",
  "baseRefName": "main",
  "title": "feat: crawler config",
  "body": "",
  "files": [
    {"path": "server/crawler.py", "additions": 20, "deletions": 0}
  ]
}
JSON
cat > "$PREFETCH/diff.txt" <<'DIFF'
diff --git a/server/crawler.py b/server/crawler.py
+def fetch_robots(url):
+    """Download the canonical robots.txt for the given site sitemap."""
+    return requests.get(url)
DIFF
unset INPUT_DISABLE_ANGLES
: > "$OUTPUT_FILE"
run_case "bare-words-no-seo-trigger" "bugs,security"

# --- Case 7: a real <meta name="robots"> in a non-SEO-filename diff SHOULD trigger seo.
cat > "$PREFETCH/meta.json" <<'JSON'
{
  "headRefOid": "fee15bad",
  "baseRefName": "main",
  "title": "feat: noindex marketing page",
  "body": "",
  "files": [
    {"path": "src/pages/marketing/Special.tsx", "additions": 5, "deletions": 0}
  ]
}
JSON
cat > "$PREFETCH/diff.txt" <<'DIFF'
diff --git a/src/pages/marketing/Special.tsx b/src/pages/marketing/Special.tsx
+<meta name="robots" content="noindex" />
DIFF
: > "$OUTPUT_FILE"
run_case "real-meta-robots-triggers-seo" "bugs,security,seo,design-audit,design-critique"

if [ $fail -ne 0 ]; then
  echo "TESTS FAILED"
  exit 1
fi
echo "All detect-angles tests passed."
