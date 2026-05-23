# Angle: Design

**Scope.** Review the visual / interaction-design quality of UI changes. Read `/tmp/pr-review/diff.txt` and the changed source files referenced in `/tmp/pr-review/meta.json`. Combine deterministic anti-pattern detection (Impeccable) with LLM critique.

## Step 1 — Run Impeccable detector

Run the [pbakaus/impeccable](https://github.com/pbakaus/impeccable) anti-pattern detector via npx:

```bash
IMPECCABLE_VERSION="${IMPECCABLE_VERSION:-latest}"
mkdir -p /tmp/pr-review
# Collect changed design-relevant files into a list
jq -r '.files[].path' /tmp/pr-review/meta.json \
  | grep -E '\.(tsx|jsx|vue|svelte|html|css|scss|sass|less|styl|astro)$' \
  > /tmp/pr-review/design-files.txt || true

if [ -s /tmp/pr-review/design-files.txt ]; then
  # Pass changed files to impeccable detect; --json output for parsing.
  xargs -a /tmp/pr-review/design-files.txt -r \
    npx -y "impeccable@${IMPECCABLE_VERSION}" detect --json \
    > /tmp/pr-review/impeccable.json 2>/tmp/pr-review/impeccable.err || \
    echo "impeccable detect exited non-zero — continuing with empty findings"
fi
```

Parse `/tmp/pr-review/impeccable.json` (if present and valid). Each item becomes a finding with the rule id as a quoted reference. If the JSON flag is unsupported by the installed version, fall back to plain stdout and best-effort parse line-by-line.

**Impeccable-derived findings:**

- Decorative glassmorphism, side-stripe borders, gradient text, hero-metric templates → `blocking: false`, `severity: MEDIUM`.
- Color-and-contrast violations (WCAG AA fail) → `blocking: true`, `severity: HIGH`.
- Hand-rolled colors instead of token references when the project uses tokens → `blocking: false`, `severity: LOW`.

## Step 2 — LLM critique

Review the diff with these lenses:

- **Color**: pure black or pure white when project hue is established; missing tint toward brand hue.
- **Typography**: more than 2 font families; line-height < 1.2 on body text; tracking conflicts with weight.
- **Spatial design**: arbitrary pixel values when a spacing scale exists; inconsistent padding across sibling components.
- **Layout**: components that ignore container width; nested flex/grid producing wonky alignment; modal-first UX where inline editing would work.
- **Interaction**: missing focus styles on interactive elements; click targets < 44px on mobile; no loading or empty states for new async UI.
- **Responsive design**: hard-coded widths; no mobile breakpoint coverage; layouts that overflow viewport.
- **Motion**: animation without `prefers-reduced-motion` respect; durations > 400ms on functional transitions; missing easing curves.

## Skip

- Static-analyzable warnings handled by linters (e.g. tailwind class ordering).
- Subjective taste calls without a rubric backing.
- Pre-existing design issues not touched by this PR.

## Severity rubric

- `HIGH` + `blocking: true` — accessibility violations (contrast, focus, target size); broken layouts at common breakpoints.
- `MEDIUM` + `blocking: false` — Impeccable anti-patterns, missing loading / empty states, weak hierarchy.
- `LOW` + `blocking: false` — token discipline, motion polish.

**Output.** Write findings as a JSON array to `/tmp/pr-review/findings.design.json` using the schema in `_header.md`. Each finding gets `"angle": "design"`.
