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
#   design-audit, design-critique — *.{tsx,jsx,vue,svelte,html,css,scss,sass,less,styl,astro}
#   react     — *.{tsx,jsx} AND consumer repo's package.json declares react dep

set -euo pipefail

OUTDIR="/tmp/pr-review"
META="$OUTDIR/meta.json"
DIFF="$OUTDIR/diff.txt"

if [ ! -f "$META" ] || [ ! -f "$DIFF" ]; then
  echo "::error::prefetch artifacts missing — detect-angles.sh requires $META and $DIFF"
  exit 1
fi

CHANGED_PATHS=$(jq -r '.files[].path' "$META")

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

has_design_file() {
  echo "$CHANGED_PATHS" | grep -qE '\.(tsx|jsx|vue|svelte|html|css|scss|sass|less|styl|astro)$'
}

has_react_signal() {
  echo "$CHANGED_PATHS" | grep -qE '\.(tsx|jsx)$' || return 1
  local pkg="${GITHUB_WORKSPACE:-.}/package.json"
  [ -f "$pkg" ] || return 1
  jq -e '(.dependencies // {}) + (.devDependencies // {}) | has("react")' "$pkg" >/dev/null 2>&1
}

ANGLES=("bugs" "security")

if has_seo_file || has_seo_diff_token; then
  ANGLES+=("seo")
fi

if has_design_file; then
  ANGLES+=("design-audit" "design-critique")
fi

if has_react_signal; then
  ANGLES+=("react")
fi

# Apply disable list. bugs + security cannot be disabled.
DISABLE="${INPUT_DISABLE_ANGLES:-}"
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

CSV=$(IFS=,; echo "${ANGLES[*]}")
JSON_ARRAY=$(printf '%s\n' "${ANGLES[@]}" | jq -R . | jq -s -c .)

printf '%s\n' "${ANGLES[@]}" > "$OUTDIR/angles.txt"
echo "angles=$CSV" >> "$GITHUB_OUTPUT"
echo "angles_json=$JSON_ARRAY" >> "$GITHUB_OUTPUT"
echo "Enabled review angles: $CSV"
