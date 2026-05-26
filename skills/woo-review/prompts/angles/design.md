---
tier: standard
---

# Angle: Design

**Scope.** Combined design review of UI changes. Runs the Impeccable detector once, emits a deterministic quantitative pass, then a focused qualitative critique scoped to files the detector flagged. Read `/tmp/pr-review/diff.txt` and the changed source files referenced in `/tmp/pr-review/meta.json`.

## Step 1 — Run Impeccable detect (once)

```bash
IMPECCABLE_VERSION="${IMPECCABLE_VERSION:-latest}"
mkdir -p /tmp/pr-review
jq -r '.files[].path' /tmp/pr-review/meta.json \
  | grep -E '\.(tsx|jsx|vue|svelte|html|css|scss|sass|less|styl|astro)$' \
  > /tmp/pr-review/design-files.txt || true

if [ -s /tmp/pr-review/design-files.txt ]; then
  xargs -a /tmp/pr-review/design-files.txt -r \
    npx -y "impeccable@${IMPECCABLE_VERSION}" detect --json \
    > /tmp/pr-review/impeccable-detect.json 2>/tmp/pr-review/impeccable-detect.err || \
    echo "impeccable detect exited non-zero — falling back to LLM-only critique"
fi
```

If `impeccable detect` fails or returns no data, skip Step 2 and proceed to Step 3 LLM-only.

## Step 2 — Quantitative pass (parse Impeccable JSON)

Parse `/tmp/pr-review/impeccable-detect.json`. Emit one finding per Impeccable issue across these dimensions:

1. Performance
2. Accessibility
3. Best Practices
4. PWA

**Skip the SEO dimension** — handled by the dedicated `seo` angle.

**Severity mapping:**
- P0 (Critical) → `blocking: true`, `severity: HIGH`
- P1 (High) → `blocking: true`, `severity: HIGH`
- P2 (Medium) → `blocking: false`, `severity: MEDIUM`
- P3 (Low) → `blocking: false`, `severity: LOW`

Append findings to the output array.

## Step 3 — Qualitative critique (LLM, scoped)

Determine the file set:
- If Impeccable produced findings, restrict critique to files with ≥1 Impeccable hit.
- If Impeccable produced nothing (or failed), critique all changed design files.

For each file in scope, review diff hunks using Nielsen's 10 Usability Heuristics + cognitive load:

- **Visibility of system status**: Missing loading/empty states for async UI.
- **Match between system and real world**: Unintuitive icons or terminology.
- **User control and freedom**: Missing "undo" or "cancel" for destructive actions.
- **Consistency and standards**: Arbitrary pixel values vs spacing scale; inconsistent padding.
- **Error prevention**: Fragile input fields; missing validation feedback.
- **Recognition rather than recall**: Complex forms with hidden instructions.
- **Flexibility and efficiency of use**: Modal-first UX where inline editing works better.
- **Aesthetic and minimalist design**: Cluttered layouts; decorative glassmorphism/gradients that distract.
- **Help users recognize, diagnose, and recover from errors**: Vague error messages.
- **Help and documentation**: Missing focus styles. (Click-target sizing handled by Impeccable A11y pass — do not duplicate.)

**Severity rubric:**
- `HIGH` + `blocking: true` — Major usability blocks, broken user flows.
- `MEDIUM` + `blocking: false` — Heuristic violations, weak visual hierarchy.
- `LOW` + `blocking: false` — Polish, alignment nits.

## Output

Write all findings (quantitative + qualitative) as a single JSON array to `/tmp/pr-review/findings.design.json` using the schema in `_header.md`. Each finding gets `"angle": "design"` and MUST populate `title` (bold headline ≤60 chars), `description` (the issue only — no fix), `fix` (recommended change in prose), and `fix_type`. Set `fix_type: "suggestion"` only when a ≤10-line single-file drop-in replacement at `line` is safe — and populate `suggestion` accordingly. Otherwise set `fix_type: "prose"` with `suggestion: null`. See `_header.md` for the full rule.
