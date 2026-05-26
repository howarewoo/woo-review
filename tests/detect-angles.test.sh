#!/usr/bin/env bash
# Unit test for skills/woo-review/scripts/detect-angles.sh. Builds synthetic prefetch artifacts
# for three diff scenarios and asserts the emitted angles CSV.
#
# Exits non-zero on the first failure. Designed to run in CI without network.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/woo-review/scripts/detect-angles.sh"
WORK="$(mktemp -d)"
PREFETCH="/tmp/pr-review"
mkdir -p "$PREFETCH"

# Clean up scratch dirs on exit so consecutive runs (CI or local) start from a
# known state. WORK is mktemp-owned; PREFETCH is a fixed path the test creates.
trap 'rm -rf "$WORK" "$PREFETCH"' EXIT

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
run_case "react+seo+design" "bugs,security,seo,design,react"

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
run_case "design-only" "bugs,security,design"

# --- Case 4: disable_angles=design,react drops design from CSS PR -> bugs,security
INPUT_DISABLE_ANGLES="design,react" \
  bash "$SCRIPT" > /dev/null
actual=$(grep '^angles=' "$OUTPUT_FILE" | tail -n1 | cut -d= -f2-)
if [ "$actual" = "bugs,security" ]; then
  echo "ok   disable_angles=design,react -> $actual"
else
  echo "FAIL disable_angles: expected 'bugs,security', got '$actual'"
  fail=1
fi

# --- Case 5: disable_angles cannot drop bugs/security
: > "$OUTPUT_FILE"
INPUT_DISABLE_ANGLES="bugs,security,design" \
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
run_case "real-meta-robots-triggers-seo" "bugs,security,seo,design,react"

# --- Case 8: new llms.txt triggers aeo (and seo via robots-family fileset is unrelated).
cat > "$PREFETCH/meta.json" <<'JSON'
{
  "headRefOid": "11ff5b00",
  "baseRefName": "main",
  "title": "feat: ship llms.txt",
  "body": "",
  "files": [
    {"path": "public/llms.txt", "additions": 30, "deletions": 0}
  ]
}
JSON
cat > "$PREFETCH/diff.txt" <<'DIFF'
diff --git a/public/llms.txt b/public/llms.txt
+# Acme — context for AI assistants
+Acme is a SaaS product for X. See /pricing.md for tiers.
DIFF
: > "$OUTPUT_FILE"
run_case "llms-txt-triggers-aeo" "bugs,security,aeo"

# --- Case 9: AI crawler token in robots.txt triggers BOTH seo (robots.txt fileset) AND aeo.
cat > "$PREFETCH/meta.json" <<'JSON'
{
  "headRefOid": "b07b07ed",
  "baseRefName": "main",
  "title": "chore: block GPTBot",
  "body": "",
  "files": [
    {"path": "public/robots.txt", "additions": 2, "deletions": 0}
  ]
}
JSON
cat > "$PREFETCH/diff.txt" <<'DIFF'
diff --git a/public/robots.txt b/public/robots.txt
+User-agent: GPTBot
+Disallow: /
DIFF
: > "$OUTPUT_FILE"
run_case "robots-gptbot-triggers-seo-and-aeo" "bugs,security,seo,aeo"

# --- Case 10: JSON-LD FAQPage in a .mdx page triggers aeo.
cat > "$PREFETCH/meta.json" <<'JSON'
{
  "headRefOid": "facade01",
  "baseRefName": "main",
  "title": "docs: FAQ section",
  "body": "",
  "files": [
    {"path": "content/help/faq.mdx", "additions": 40, "deletions": 0}
  ]
}
JSON
cat > "$PREFETCH/diff.txt" <<'DIFF'
diff --git a/content/help/faq.mdx b/content/help/faq.mdx
+<script type="application/ld+json">{ "@type": "FAQPage", "mainEntity": [] }</script>
DIFF
: > "$OUTPUT_FILE"
run_case "faq-schema-mdx-triggers-aeo" "bugs,security,aeo"

# --- Case 11: Supabase migration *.sql triggers database (and aeo via .mdx fileset is unrelated).
cat > "$PREFETCH/meta.json" <<'JSON'
{
  "headRefOid": "5060da7a",
  "baseRefName": "main",
  "title": "feat(db): add posts table with RLS",
  "body": "",
  "files": [
    {"path": "supabase/migrations/20260520_posts.sql", "additions": 30, "deletions": 0}
  ]
}
JSON
cat > "$PREFETCH/diff.txt" <<'DIFF'
diff --git a/supabase/migrations/20260520_posts.sql b/supabase/migrations/20260520_posts.sql
+CREATE TABLE posts (id uuid primary key, author_id uuid references users(id));
+ALTER TABLE posts ENABLE ROW LEVEL SECURITY;
+CREATE POLICY "own posts" ON posts USING (author_id = auth.uid());
DIFF
: > "$OUTPUT_FILE"
run_case "supabase-migration-triggers-database" "bugs,security,database"

# --- Case 12: prisma/schema.prisma change triggers database (no SQL body needed — path alone).
cat > "$PREFETCH/meta.json" <<'JSON'
{
  "headRefOid": "9123aabb",
  "baseRefName": "main",
  "title": "feat(prisma): add Order model",
  "body": "",
  "files": [
    {"path": "prisma/schema.prisma", "additions": 12, "deletions": 0}
  ]
}
JSON
cat > "$PREFETCH/diff.txt" <<'DIFF'
diff --git a/prisma/schema.prisma b/prisma/schema.prisma
+model Order {
+  id     String @id @default(uuid())
+  userId String
+}
DIFF
: > "$OUTPUT_FILE"
run_case "prisma-schema-triggers-database" "bugs,security,database"

# --- Case 13: TS file with db.query template literal triggers database (ORM call site).
cat > "$PREFETCH/meta.json" <<'JSON'
{
  "headRefOid": "abc01234",
  "baseRefName": "main",
  "title": "feat(api): add lookup query",
  "body": "",
  "files": [
    {"path": "src/server/lookup.ts", "additions": 8, "deletions": 0}
  ]
}
JSON
cat > "$PREFETCH/diff.txt" <<'DIFF'
diff --git a/src/server/lookup.ts b/src/server/lookup.ts
+export async function lookup(id: string) {
+  return db.query("SELECT id, name FROM users WHERE id = $1", [id]);
+}
DIFF
: > "$OUTPUT_FILE"
run_case "db-query-token-triggers-database" "bugs,security,database"

# --- Case 14: docs prose mentioning "table" / "index" must NOT trigger database (regression guard).
cat > "$PREFETCH/meta.json" <<'JSON'
{
  "headRefOid": "deadc0de",
  "baseRefName": "main",
  "title": "docs: update README",
  "body": "",
  "files": [
    {"path": "docs/intro.md", "additions": 4, "deletions": 0}
  ]
}
JSON
cat > "$PREFETCH/diff.txt" <<'DIFF'
diff --git a/docs/intro.md b/docs/intro.md
+You can see the table of contents below.
+The index lists every page in alphabetical order.
DIFF
: > "$OUTPUT_FILE"
run_case "docs-prose-no-database-trigger" "bugs,security,aeo"

# --- Case 15: rules.md present -> conventions enabled.
cat > "$PREFETCH/meta.json" <<'JSON'
{
  "headRefOid": "ru1e5abc",
  "baseRefName": "main",
  "title": "feat: small backend tweak",
  "body": "",
  "files": [
    {"path": "server/handler.py", "additions": 6, "deletions": 0}
  ]
}
JSON
cat > "$PREFETCH/diff.txt" <<'DIFF'
diff --git a/server/handler.py b/server/handler.py
+def handle(req):
+    return ok()
DIFF
cat > "$PREFETCH/rules.md" <<'RULES'
## SOURCE: AGENTS.md
All handlers MUST return typed responses.
RULES
: > "$OUTPUT_FILE"
run_case "rules-md-present-triggers-conventions" "bugs,security,conventions"

# --- Case 16: rules.md absent -> conventions NOT enabled.
rm -f "$PREFETCH/rules.md"
: > "$OUTPUT_FILE"
run_case "rules-md-absent-no-conventions" "bugs,security"

# --- Case 17: rules.md + disable_angles=conventions -> conventions dropped.
cat > "$PREFETCH/rules.md" <<'RULES'
## SOURCE: AGENTS.md
All handlers MUST return typed responses.
RULES
: > "$OUTPUT_FILE"
INPUT_DISABLE_ANGLES="conventions" \
  bash "$SCRIPT" > /dev/null
actual=$(grep '^angles=' "$OUTPUT_FILE" | tail -n1 | cut -d= -f2-)
if [ "$actual" = "bugs,security" ]; then
  echo "ok   disable_angles=conventions drops conventions -> $actual"
else
  echo "FAIL disable_angles=conventions: expected 'bugs,security', got '$actual'"
  fail=1
fi
unset INPUT_DISABLE_ANGLES
rm -f "$PREFETCH/rules.md"

# --- Case 18: config.angles.force adds an angle that wasn't auto-detected.
rm -f "$PREFETCH/changed-paths.filtered.txt" "$PREFETCH/diff.filtered.txt"
cat > "$PREFETCH/meta.json" <<'JSON'
{
  "headRefOid": "c0c0c0c0",
  "baseRefName": "main",
  "title": "feat: backend tweak",
  "body": "",
  "files": [
    {"path": "server/auth.py", "additions": 6, "deletions": 0}
  ]
}
JSON
cat > "$PREFETCH/diff.txt" <<'DIFF'
diff --git a/server/auth.py b/server/auth.py
+def f(): return 1
DIFF
cat > "$PREFETCH/config.json" <<'CFG'
{"angles": {"force": ["database"]}}
CFG
: > "$OUTPUT_FILE"
run_case "config-force-adds-database" "bugs,security,database"
rm -f "$PREFETCH/config.json"

# --- Case 19: config.angles.skip removes an auto-detected angle.
cat > "$GITHUB_WORKSPACE/package.json" <<'PKG'
{"dependencies": {"react": "^18.0.0"}}
PKG
cat > "$PREFETCH/meta.json" <<'JSON'
{
  "headRefOid": "5101599a",
  "baseRefName": "main",
  "title": "feat: product",
  "body": "",
  "files": [
    {"path": "app/layout.tsx", "additions": 30, "deletions": 0},
    {"path": "app/globals.css", "additions": 5, "deletions": 0}
  ]
}
JSON
cat > "$PREFETCH/diff.txt" <<'DIFF'
diff --git a/app/layout.tsx b/app/layout.tsx
+<meta name="robots" content="noindex" />
DIFF
cat > "$PREFETCH/config.json" <<'CFG'
{"angles": {"skip": ["seo"]}}
CFG
: > "$OUTPUT_FILE"
run_case "config-skip-removes-seo" "bugs,security,design,react"
rm -f "$PREFETCH/config.json" "$GITHUB_WORKSPACE/package.json"

# --- Case 20: force trumps skip when the same angle is listed in both.
cat > "$PREFETCH/meta.json" <<'JSON'
{
  "headRefOid": "f0f0f0f0",
  "baseRefName": "main",
  "title": "feat: marketing",
  "body": "",
  "files": [
    {"path": "src/pages/landing.tsx", "additions": 5, "deletions": 0}
  ]
}
JSON
cat > "$PREFETCH/diff.txt" <<'DIFF'
diff --git a/src/pages/landing.tsx b/src/pages/landing.tsx
+<meta name="robots" content="noindex" />
DIFF
cat > "$PREFETCH/config.json" <<'CFG'
{"angles": {"force": ["seo"], "skip": ["seo"]}}
CFG
: > "$OUTPUT_FILE"
run_case "config-force-overrides-skip" "bugs,security,design,react,seo"
rm -f "$PREFETCH/config.json"

# --- Case 21: detect-angles prefers ignore-filtered changed-paths file when
#              present. Originally meta.json includes a .sql file (would
#              trigger `database`), but the filtered list omits it.
cat > "$PREFETCH/meta.json" <<'JSON'
{
  "headRefOid": "16110160",
  "baseRefName": "main",
  "title": "feat: backend + migration",
  "body": "",
  "files": [
    {"path": "server/auth.py", "additions": 6, "deletions": 0},
    {"path": "migrations/0042_users.sql", "additions": 5, "deletions": 0}
  ]
}
JSON
cat > "$PREFETCH/diff.txt" <<'DIFF'
diff --git a/server/auth.py b/server/auth.py
+def f(): return 1
diff --git a/migrations/0042_users.sql b/migrations/0042_users.sql
+CREATE TABLE users (id uuid primary key);
DIFF
# Simulated prefetch.sh output after ignore: ["migrations/*.sql"]
cat > "$PREFETCH/changed-paths.filtered.txt" <<'PATHS'
server/auth.py
PATHS
cat > "$PREFETCH/diff.filtered.txt" <<'DIFF'
diff --git a/server/auth.py b/server/auth.py
+def f(): return 1
DIFF
: > "$OUTPUT_FILE"
run_case "config-ignore-strips-paths-and-diff" "bugs,security"
rm -f "$PREFETCH/changed-paths.filtered.txt" "$PREFETCH/diff.filtered.txt"

# --- Case 22: with filtered diff present but original diff carrying a SQL
#              token, the filtered version wins -> no `database` angle.
cat > "$PREFETCH/meta.json" <<'JSON'
{
  "headRefOid": "16110161",
  "baseRefName": "main",
  "title": "feat: pure TS",
  "body": "",
  "files": [
    {"path": "src/server/route.ts", "additions": 4, "deletions": 0}
  ]
}
JSON
# Original diff contains a SQL DDL token that WOULD trigger database.
cat > "$PREFETCH/diff.txt" <<'DIFF'
diff --git a/src/server/route.ts b/src/server/route.ts
+// CREATE TABLE foo (id int);  -- inherited from generated.ts originally
DIFF
# But the filtered view doesn't include that token (e.g. ignored file).
cat > "$PREFETCH/changed-paths.filtered.txt" <<'PATHS'
src/server/route.ts
PATHS
cat > "$PREFETCH/diff.filtered.txt" <<'DIFF'
diff --git a/src/server/route.ts b/src/server/route.ts
+const x = 1;
DIFF
: > "$OUTPUT_FILE"
run_case "config-ignore-suppresses-diff-trigger" "bugs,security"
rm -f "$PREFETCH/changed-paths.filtered.txt" "$PREFETCH/diff.filtered.txt"

# --- Case 23: monorepo with workspace-scoped react dep (root package.json
#              declares only build tools) still triggers `react` for .tsx diffs.
#              Regression guard for #20: previously the angle was silently
#              skipped when react wasn't in the root manifest.
cat > "$GITHUB_WORKSPACE/package.json" <<'PKG'
{
  "name": "monorepo-root",
  "devDependencies": {
    "turbo": "^2.0.0",
    "typescript": "^5.0.0",
    "@biomejs/biome": "^1.0.0"
  }
}
PKG
cat > "$PREFETCH/meta.json" <<'JSON'
{
  "headRefOid": "20202020",
  "baseRefName": "main",
  "title": "feat(web): tweak hero",
  "body": "",
  "files": [
    {"path": "apps/web/src/components/Hero.tsx", "additions": 12, "deletions": 3}
  ]
}
JSON
cat > "$PREFETCH/diff.txt" <<'DIFF'
diff --git a/apps/web/src/components/Hero.tsx b/apps/web/src/components/Hero.tsx
+export function Hero() { return <h1>hi</h1>; }
DIFF
: > "$OUTPUT_FILE"
run_case "monorepo-workspace-react-still-triggers-react" "bugs,security,design,react"
rm -f "$GITHUB_WORKSPACE/package.json"

# --- Case 24: .tsx diff with NO package.json anywhere still triggers react.
#              The angle handles non-React .tsx gracefully, so a missing
#              manifest is not a reason to skip it.
cat > "$PREFETCH/meta.json" <<'JSON'
{
  "headRefOid": "24242424",
  "baseRefName": "main",
  "title": "feat: add component",
  "body": "",
  "files": [
    {"path": "src/Widget.tsx", "additions": 5, "deletions": 0}
  ]
}
JSON
cat > "$PREFETCH/diff.txt" <<'DIFF'
diff --git a/src/Widget.tsx b/src/Widget.tsx
+export const Widget = () => null;
DIFF
: > "$OUTPUT_FILE"
run_case "tsx-without-package-json-triggers-react" "bugs,security,design,react"

if [ $fail -ne 0 ]; then
  echo "TESTS FAILED"
  exit 1
fi
echo "All detect-angles tests passed."
