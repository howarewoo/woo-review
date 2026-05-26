#!/usr/bin/env bash
# Detects which review angles to enable based on the prefetched diff.
# Inputs (env): GITHUB_WORKSPACE, INPUT_DISABLE_ANGLES (csv).
# Outputs: angles=<csv> to $GITHUB_OUTPUT.
# Side effects: writes /tmp/pr-review/angles.txt (one angle per line).
#
# Angle gating:
#   bugs      — always on
#   security  — always on
#   seo       — *.html, head.{ts,tsx}, layout.{ts,tsx}, robots.txt, sitemap.{xml,ts},
#               next.config.{js,ts,mjs}, app/manifest.{ts,json}, OR diff body
#               contains <meta / og: / twitter: / canonical / robots / sitemap
#   aeo       — robots.txt, llms.txt, pricing.{md,txt}, *.{md,mdx,html}, OR diff
#               body contains AI-crawler tokens (GPTBot / PerplexityBot /
#               ClaudeBot / Google-Extended / anthropic-ai) or JSON-LD schema
#               types (FAQPage / HowTo / Article / Product / ItemList)
#   design    — *.{tsx,jsx,vue,svelte,html,css,scss,sass,less,styl,astro}
#   react     — *.{tsx,jsx} in the diff. The angle handles non-React .tsx
#               (e.g. Solid, Preact-only) gracefully, so a package.json check is
#               unnecessary and breaks monorepos where react lives in workspace
#               packages, not the root manifest.
#   database  — *.sql, migrations/ trees (db/supabase/prisma), prisma/schema.prisma,
#               drizzle.config.{ts,js,mjs}, drizzle/, knexfile.{ts,js},
#               supabase/(config.toml|seed.sql), OR diff body contains SQL DDL
#               (CREATE/ALTER/DROP TABLE|INDEX|POLICY|FUNCTION|TRIGGER|SCHEMA|TYPE),
#               RLS tokens (CREATE POLICY, ENABLE ROW LEVEL SECURITY, SECURITY
#               DEFINER, auth.uid()/auth.jwt()), Supabase client construction, or
#               ORM raw-SQL call sites (.raw(, sql`, db.query(, pool.query()
#   conventions — gated on prefetch having produced /tmp/pr-review/rules.md
#               (i.e. the repo carries AGENTS.md / CLAUDE.md / .cursorrules /
#               .windsurfrules / GEMINI.md somewhere along the changed paths).

set -euo pipefail

OUTDIR="/tmp/pr-review"
META="$OUTDIR/meta.json"
DIFF="$OUTDIR/diff.txt"
CFG="$OUTDIR/config.json"

if [ ! -f "$META" ] || [ ! -f "$DIFF" ]; then
  echo "::error::prefetch artifacts missing — detect-angles.sh requires $META and $DIFF"
  exit 1
fi

# Prefer ignore-filtered artifacts when prefetch.sh produced them (.woo-review.yml
# ignore[] was set). Falls back to the unfiltered originals.
if [ -f "$OUTDIR/diff.filtered.txt" ]; then
  DIFF="$OUTDIR/diff.filtered.txt"
fi
if [ -f "$OUTDIR/changed-paths.filtered.txt" ]; then
  CHANGED_PATHS=$(cat "$OUTDIR/changed-paths.filtered.txt")
else
  CHANGED_PATHS=$(jq -r '.files[].path' "$META")
fi

has_seo_file() {
  echo "$CHANGED_PATHS" | grep -qE '(^|/)(robots\.txt|sitemap\.(xml|ts)|next\.config\.(js|ts|mjs))$' && return 0
  echo "$CHANGED_PATHS" | grep -qE '\.html$' && return 0
  echo "$CHANGED_PATHS" | grep -qE '(^|/)(head|layout)\.(ts|tsx|js|jsx)$' && return 0
  echo "$CHANGED_PATHS" | grep -qE '(^|/)app/manifest\.(ts|json)$' && return 0
  return 1
}

has_seo_diff_token() {
  # Anchored to reduce false positives in docs/comments/JSON keys.
  # Matches: meta tags, og:/twitter: prefixed props, rel=canonical, name=robots,
  # <loc> sitemap entries, Sitemap: directive.
  grep -qE "</?meta\b|\bog:[a-z_-]+|\btwitter:[a-z_-]+|rel=[\"']canonical|name=[\"']robots|<loc>|(^|[[:space:]])Sitemap:" "$DIFF"
}

has_aeo_file() {
  echo "$CHANGED_PATHS" | grep -qE '(^|/)(robots\.txt|llms\.txt|pricing\.(md|txt))$' && return 0
  echo "$CHANGED_PATHS" | grep -qE '\.(md|mdx|html)$' && return 0
  return 1
}

has_aeo_diff_token() {
  # AI-crawler bot tokens or JSON-LD schema types relevant to AEO.
  grep -qE "GPTBot|ChatGPT-User|PerplexityBot|ClaudeBot|anthropic-ai|Google-Extended|\"@type\"[[:space:]]*:[[:space:]]*\"(FAQPage|HowTo|Article|BlogPosting|Product|ItemList|Review|AggregateRating)\"" "$DIFF"
}

has_design_file() {
  echo "$CHANGED_PATHS" | grep -qE '\.(tsx|jsx|vue|svelte|html|css|scss|sass|less|styl|astro)$'
}

has_react_signal() {
  echo "$CHANGED_PATHS" | grep -qE '\.(tsx|jsx)$'
}

has_database_file() {
  echo "$CHANGED_PATHS" | grep -qE '\.sql$' && return 0
  echo "$CHANGED_PATHS" | grep -qE '(^|/)(db/migrations|supabase/migrations|prisma/migrations|migrations)/' && return 0
  echo "$CHANGED_PATHS" | grep -qE '(^|/)supabase/(config\.toml|seed\.sql)$' && return 0
  echo "$CHANGED_PATHS" | grep -qE '(^|/)prisma/schema\.prisma$' && return 0
  echo "$CHANGED_PATHS" | grep -qE '(^|/)drizzle\.config\.(ts|js|mjs)$' && return 0
  echo "$CHANGED_PATHS" | grep -qE '(^|/)drizzle/' && return 0
  echo "$CHANGED_PATHS" | grep -qE '(^|/)knexfile\.(ts|js)$' && return 0
  return 1
}

has_database_diff_token() {
  # SQL DDL, RLS tokens, Supabase client, and ORM raw-SQL call sites.
  # Anchored to reduce false-fires on plain English ("create a table") in docs.
  grep -qE "\b(CREATE|ALTER|DROP)[[:space:]]+(TABLE|INDEX|POLICY|FUNCTION|TRIGGER|SCHEMA|TYPE|VIEW|MATERIALIZED)\b|\bENABLE[[:space:]]+ROW[[:space:]]+LEVEL[[:space:]]+SECURITY\b|\bSECURITY[[:space:]]+DEFINER\b|\bauth\.(uid|jwt|role)\(\)|createClient\([^)]*supabase|\.raw\(|\bsql\`|\bdb\.query\(|\bpool\.query\(" "$DIFF"
}

ANGLES=("bugs" "security")

if [ -f "$OUTDIR/rules.md" ]; then
  ANGLES+=("conventions")
fi

if has_seo_file || has_seo_diff_token; then
  ANGLES+=("seo")
fi

if has_aeo_file || has_aeo_diff_token; then
  ANGLES+=("aeo")
fi

if has_design_file; then
  ANGLES+=("design")
fi

if has_react_signal; then
  ANGLES+=("react")
fi

if has_database_file || has_database_diff_token; then
  ANGLES+=("database")
fi

# Merge config.angles.skip into the disable CSV. Config-driven and input-driven
# disables stack; bugs/security remain protected below.
DISABLE="${INPUT_DISABLE_ANGLES:-}"
if [ -f "$CFG" ] && jq -e '.angles.skip // empty' "$CFG" >/dev/null 2>&1; then
  CFG_SKIP=$(jq -r '.angles.skip | join(",")' "$CFG")
  if [ -n "$CFG_SKIP" ]; then
    if [ -n "$DISABLE" ]; then
      DISABLE="$DISABLE,$CFG_SKIP"
    else
      DISABLE="$CFG_SKIP"
    fi
  fi
fi

# Apply disable list. bugs + security cannot be disabled.
if [ -n "$DISABLE" ]; then
  IFS=',' read -ra DIS_ARRAY <<< "$DISABLE"
  FILTERED=()
  for a in "${ANGLES[@]}"; do
    keep=1
    for d in "${DIS_ARRAY[@]}"; do
      d_trim=$(echo "$d" | xargs)
      if [ "$a" = "$d_trim" ] && [ "$a" != "bugs" ] && [ "$a" != "security" ]; then
        keep=0
        break
      fi
    done
    [ $keep -eq 1 ] && FILTERED+=("$a")
  done
  # ${arr[@]+...} guards empty-array expansion under `set -u` on Bash 3.2 (macOS).
  ANGLES=("${FILTERED[@]+"${FILTERED[@]}"}")
fi

# Apply config.angles.force AFTER the skip pass — force trumps skip per #11.
if [ -f "$CFG" ] && jq -e '.angles.force // empty' "$CFG" >/dev/null 2>&1; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    already=0
    for a in "${ANGLES[@]+"${ANGLES[@]}"}"; do
      [ "$a" = "$f" ] && already=1 && break
    done
    [ $already -eq 0 ] && ANGLES+=("$f")
  done < <(jq -r '.angles.force[]?' "$CFG")
fi

CSV=$(IFS=,; echo "${ANGLES[*]}")
JSON_ARRAY=$(printf '%s\n' "${ANGLES[@]}" | jq -R . | jq -s -c .)

printf '%s\n' "${ANGLES[@]}" > "$OUTDIR/angles.txt"
echo "angles=$CSV" >> "$GITHUB_OUTPUT"
echo "angles_json=$JSON_ARRAY" >> "$GITHUB_OUTPUT"
echo "Enabled review angles: $CSV"
