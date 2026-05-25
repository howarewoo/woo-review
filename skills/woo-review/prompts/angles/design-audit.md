# Angle: Design Audit

**Scope.** Perform a structured, quantitative audit of UI changes using the Impeccable tool. Read `/tmp/pr-review/diff.txt` and the changed source files referenced in `/tmp/pr-review/meta.json`.

## Step 1 — Run Impeccable detect

Run the [pbakaus/impeccable](https://github.com/pbakaus/impeccable) detection tool via npx:

```bash
IMPECCABLE_VERSION="${IMPECCABLE_VERSION:-latest}"
mkdir -p /tmp/pr-review
# Collect changed design-relevant files into a list
jq -r '.files[].path' /tmp/pr-review/meta.json \
  | grep -E '\.(tsx|jsx|vue|svelte|html|css|scss|sass|less|styl|astro)$' \
  > /tmp/pr-review/design-audit-files.txt || true

if [ -s /tmp/pr-review/design-audit-files.txt ]; then
  # Pass changed files to impeccable detect; --json output for parsing.
  xargs -a /tmp/pr-review/design-audit-files.txt -r \
    npx -y "impeccable@${IMPECCABLE_VERSION}" detect --json \
    > /tmp/pr-review/impeccable-detect.json 2>/tmp/pr-review/impeccable-detect.err || \
    echo "impeccable detect exited non-zero — continuing with empty findings"
fi
```

Parse `/tmp/pr-review/impeccable-detect.json`. Focus on structured scoring across 5 dimensions:
1. Performance
2. Accessibility
3. Best Practices
4. SEO
5. PWA

**Severity mapping:**
- P0 (Critical) → `blocking: true`, `severity: HIGH`.
- P1 (High) → `blocking: true`, `severity: HIGH`.
- P2 (Medium) → `blocking: false`, `severity: MEDIUM`.
- P3 (Low) → `blocking: false`, `severity: LOW`.

## Skip

- Non-design files.
- Qualitative critique (handled by design-critique).

## Output

Write findings as a JSON array to `/tmp/pr-review/findings.design-audit.json` using the schema in `_header.md`. Each finding gets `"angle": "design-audit"`.
