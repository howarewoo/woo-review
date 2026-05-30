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
#   tests     — test-file paths in diff: *.test.{ts,tsx,js,jsx,mjs,cjs},
#               *_test.{go,py}, *.spec.{ts,tsx,js,jsx}, *_spec.rb, and the
#               tests/, __tests__/, spec/ directory trees.
#   api       — OpenAPI / Swagger (openapi.{yaml,yml,json}, swagger.{...}),
#               GraphQL schema (*.graphql, *.gql, schema.gql), .proto, route
#               trees (pages/api/, app/api/, routes/, handlers/, controllers/),
#               OR diff body contains HTTP-verb route bindings (app.get(,
#               router.post(, @app.get, @router.delete), Fastify route(),
#               or GraphQL `extend type (Query|Mutation|Subscription)`.
#   infra     — .github/workflows/*.{yml,yaml}, Dockerfile*, docker-compose.*,
#               compose.{yml,yaml}, *.tf / *.tfvars, terraform/, pulumi.*,
#               cdk.*, k8s/, kubernetes/, helm/, .devcontainer/, ansible/,
#               playbook.{yml,yaml}, OR diff body contains apiVersion: apps/,
#               kind: (Deployment|Service|StatefulSet|DaemonSet),
#               resource "(aws|google|azurerm)_, or `FROM ` Docker directive.
#   observability — logging / error-handling tokens in diff body:
#               console.log/error, logger./log., print(, fmt.Println, Sentry.,
#               OpenTelemetry / span. / metrics., bare `catch {}` swallow,
#               `.catch(() => null|undefined)`.
#   types     — *.ts / *.tsx / *.cts / *.mts in diff. TypeScript-only.
#   i18n      — locales/, messages/, i18n/, translations/ directory trees,
#               *.po / *.pot files, or `i18n.t(` / `useTranslations(` /
#               `<Trans` / `FormattedMessage` tokens in the diff body.
#   docs      — README*, CHANGELOG*, docs/, *.md / *.mdx (excluding the rule
#               files consumed by the conventions angle: AGENTS.md, CLAUDE.md,
#               GEMINI.md, .cursorrules, .windsurfrules), .env.example,
#               openapi.{yaml,yml,json}.
#   deps      — dependency manifests / lockfiles: package.json, package-lock.json,
#               pnpm-lock.yaml, yarn.lock, bun.lockb, requirements.txt,
#               pyproject.toml, poetry.lock, uv.lock, go.mod, go.sum,
#               Cargo.toml, Cargo.lock, Gemfile(.lock), composer.{json,lock}.

set -euo pipefail

# shellcheck source=skills/woo-review/scripts/resolve-outdir.sh
source "$(dirname "${BASH_SOURCE[0]}")/resolve-outdir.sh"
META="$OUTDIR/meta.json"
DIFF="$OUTDIR/diff.txt"
CFG="$OUTDIR/config.json"

if [ ! -f "$META" ] || [ ! -f "$DIFF" ]; then
  echo "::error::prefetch artifacts missing — detect-angles.sh requires $META and $DIFF"
  exit 1
fi

# Prefer ignore-filtered artifacts when prefetch.sh produced them (.woo-review/config.json
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

has_tests_file() {
  echo "$CHANGED_PATHS" | grep -qE '\.(test|spec)\.(ts|tsx|js|jsx|mjs|cjs)$' && return 0
  echo "$CHANGED_PATHS" | grep -qE '_test\.(go|py)$' && return 0
  echo "$CHANGED_PATHS" | grep -qE '_spec\.rb$' && return 0
  echo "$CHANGED_PATHS" | grep -qE '(^|/)(tests|__tests__|spec)/' && return 0
  return 1
}

has_api_file() {
  echo "$CHANGED_PATHS" | grep -qE '(^|/)(openapi|swagger)\.(ya?ml|json)$' && return 0
  echo "$CHANGED_PATHS" | grep -qE '\.(graphql|gql|proto)$' && return 0
  echo "$CHANGED_PATHS" | grep -qE '(^|/)(pages/api|app/api|routes|handlers|controllers)/' && return 0
  return 1
}

has_api_diff_token() {
  # HTTP-verb route bindings + Fastify factory + GraphQL extend type.
  # Anchored to avoid hits on docs mentioning "get the user".
  grep -qE "\b(app|router|api|server)\.(get|post|put|patch|delete|options|head)\(|@(app|router)\.(get|post|put|patch|delete)\b|\bfastify\.(get|post|put|patch|delete)\(|\bextend[[:space:]]+type[[:space:]]+(Query|Mutation|Subscription)\b|@(Get|Post|Put|Patch|Delete)\(" "$DIFF"
}

has_infra_file() {
  echo "$CHANGED_PATHS" | grep -qE '(^|/)\.github/workflows/[^/]+\.ya?ml$' && return 0
  echo "$CHANGED_PATHS" | grep -qE '(^|/)Dockerfile([._-][^/]*)?$' && return 0
  echo "$CHANGED_PATHS" | grep -qE '(^|/)(docker-compose|compose)(\.[a-zA-Z0-9_-]+)*\.(ya?ml)$' && return 0
  echo "$CHANGED_PATHS" | grep -qE '\.(tf|tfvars)$' && return 0
  echo "$CHANGED_PATHS" | grep -qE '(^|/)(terraform|pulumi|cdk|k8s|kubernetes|helm|ansible|\.devcontainer)/' && return 0
  echo "$CHANGED_PATHS" | grep -qE '(^|/)Pulumi(\.[a-zA-Z0-9_-]+)?\.ya?ml$' && return 0
  echo "$CHANGED_PATHS" | grep -qE '(^|/)cdk(\.context)?\.json$' && return 0
  echo "$CHANGED_PATHS" | grep -qE '(^|/)playbook\.(ya?ml)$' && return 0
  return 1
}

has_infra_diff_token() {
  grep -qE "^\+apiVersion:[[:space:]]+(apps|batch|networking|policy|rbac|autoscaling)/|^\+kind:[[:space:]]+(Deployment|Service|StatefulSet|DaemonSet|Job|CronJob|Ingress|ConfigMap|Secret)\b|\bresource[[:space:]]+\"(aws|google|azurerm|kubernetes)_|^\+FROM[[:space:]]+[a-z0-9._/-]+" "$DIFF"
}

has_observability_diff_token() {
  # Logging / error-handling tokens. Anchored to plus-lines so unchanged context
  # doesn't fire the angle.
  grep -qE "^\+.*\b(console\.(log|warn|error|info|debug)|logger\.|log\.(info|warn|error|debug|trace)|fmt\.(Println|Printf|Fprintln)|Sentry\.|OpenTelemetry|otel\.|opentelemetry|tracer\.startSpan|span\.(end|recordException)|metrics\.(counter|histogram|gauge)|\.catch\([[:space:]]*\([^)]*\)[[:space:]]*=>[[:space:]]*(null|undefined))" "$DIFF" && return 0
  grep -qE "^\+[[:space:]]*}[[:space:]]*catch[[:space:]]*(\([^)]*\))?[[:space:]]*\{[[:space:]]*\}" "$DIFF" && return 0
  return 1
}

has_types_signal() {
  echo "$CHANGED_PATHS" | grep -qE '\.(ts|tsx|cts|mts)$'
}

has_i18n_file() {
  echo "$CHANGED_PATHS" | grep -qE '(^|/)(locales|messages|i18n|translations)/' && return 0
  echo "$CHANGED_PATHS" | grep -qE '\.(po|pot)$' && return 0
  return 1
}

has_i18n_diff_token() {
  grep -qE "\bi18n\.t\(|\buseTranslations\(|\buseTranslation\(|<Trans\b|<FormattedMessage\b|\b\\\$t\(|\bt\([\"']" "$DIFF"
}

has_docs_file() {
  # docs paths excluding rule files consumed by the conventions angle.
  echo "$CHANGED_PATHS" | grep -qE '(^|/)README(\.[a-zA-Z0-9_-]+)*(\.(md|mdx|rst|txt))?$' && return 0
  echo "$CHANGED_PATHS" | grep -qE '(^|/)CHANGELOG(\.(md|mdx|txt))?$' && return 0
  echo "$CHANGED_PATHS" | grep -qE '(^|/)docs/' && return 0
  echo "$CHANGED_PATHS" | grep -qE '(^|/)\.env\.example$' && return 0
  echo "$CHANGED_PATHS" | grep -qE '(^|/)(openapi|swagger)\.(ya?ml|json)$' && return 0
  # *.md / *.mdx anywhere — except rule files that the conventions angle owns.
  echo "$CHANGED_PATHS" \
    | grep -vE '(^|/)(AGENTS|CLAUDE|GEMINI)\.md$' \
    | grep -vE '(^|/)\.(cursorrules|windsurfrules)$' \
    | grep -qE '\.(md|mdx)$' && return 0
  return 1
}

has_deps_file() {
  echo "$CHANGED_PATHS" | grep -qE '(^|/)(package\.json|package-lock\.json|pnpm-lock\.yaml|yarn\.lock|bun\.lockb)$' && return 0
  echo "$CHANGED_PATHS" | grep -qE '(^|/)(requirements(-[a-zA-Z0-9_-]+)?\.txt|pyproject\.toml|poetry\.lock|uv\.lock|Pipfile(\.lock)?)$' && return 0
  echo "$CHANGED_PATHS" | grep -qE '(^|/)(go\.mod|go\.sum)$' && return 0
  echo "$CHANGED_PATHS" | grep -qE '(^|/)(Cargo\.toml|Cargo\.lock)$' && return 0
  echo "$CHANGED_PATHS" | grep -qE '(^|/)(Gemfile|Gemfile\.lock)$' && return 0
  echo "$CHANGED_PATHS" | grep -qE '(^|/)(composer\.(json|lock))$' && return 0
  return 1
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

if has_tests_file; then
  ANGLES+=("tests")
fi

if has_api_file || has_api_diff_token; then
  ANGLES+=("api")
fi

if has_infra_file || has_infra_diff_token; then
  ANGLES+=("infra")
fi

if has_observability_diff_token; then
  ANGLES+=("observability")
fi

if has_types_signal; then
  ANGLES+=("types")
fi

if has_i18n_file || has_i18n_diff_token; then
  ANGLES+=("i18n")
fi

if has_docs_file; then
  ANGLES+=("docs")
fi

if has_deps_file; then
  ANGLES+=("deps")
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
# JSON fallback artifact for non-GHA hosts (Gemini CLI, opencode, local skill
# invocation) that have no $GITHUB_OUTPUT to read.
printf '%s\n' "$JSON_ARRAY" > "$OUTDIR/angles.json"

# $GITHUB_OUTPUT is GHA-only. Without the guard, `echo >> ""` under `set -u`
# crashes immediately when run outside Actions.
emit_kv() {
  local key="$1" value="$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$key" "$value" >> "$GITHUB_OUTPUT"
  fi
  printf '%s=%s\n' "$key" "$value"
}
emit_kv angles "$CSV"
emit_kv angles_json "$JSON_ARRAY"
echo "Enabled review angles: $CSV"

# Issue #14: chunks_json output drives the second dimension of the GHA matrix.
# When chunks.txt is absent (sub-threshold diff), emit `[""]` — one job per
# angle, no chunking. When present, emit the chunk IDs verbatim so the matrix
# fans out as angles × chunks.
if [ -f "$OUTDIR/chunks.txt" ] && [ -s "$OUTDIR/chunks.txt" ]; then
  CHUNKS_JSON=$(jq -R . "$OUTDIR/chunks.txt" | jq -s -c .)
  emit_kv chunks_json "$CHUNKS_JSON"
  printf '%s\n' "$CHUNKS_JSON" > "$OUTDIR/chunks-matrix.json"
  echo "Chunked review: $(jq 'length' <<<"$CHUNKS_JSON") chunk(s) × ${#ANGLES[@]} angle(s) = $(( $(jq 'length' <<<"$CHUNKS_JSON") * ${#ANGLES[@]} )) job(s)"
else
  emit_kv chunks_json '[""]'
  printf '%s\n' '[""]' > "$OUTDIR/chunks-matrix.json"
fi
