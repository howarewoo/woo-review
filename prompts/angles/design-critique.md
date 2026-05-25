# Angle: Design Critique

**Scope.** Perform a qualitative critique of UI changes based on design heuristics and cognitive load. Read `/tmp/pr-review/diff.txt` and the changed source files referenced in `/tmp/pr-review/meta.json`.

## Step 1 — Run Impeccable detect

Try running the Impeccable detection tool:

```bash
IMPECCABLE_VERSION="${IMPECCABLE_VERSION:-latest}"
mkdir -p /tmp/pr-review
jq -r '.files[].path' /tmp/pr-review/meta.json \
  | grep -E '\.(tsx|jsx|vue|svelte|html|css|scss|sass|less|styl|astro)$' \
  > /tmp/pr-review/design-critique-files.txt || true

if [ -s /tmp/pr-review/design-critique-files.txt ]; then
  xargs -a /tmp/pr-review/design-critique-files.txt -r \
    npx -y "impeccable@${IMPECCABLE_VERSION}" detect --json \
    > /tmp/pr-review/impeccable-detect.json 2>/tmp/pr-review/impeccable-detect.err || \
    echo "impeccable detect exited non-zero — falling back to LLM-only critique"
fi
```

If `impeccable detect` fails or returns no data, proceed with LLM-only critique.

## Step 2 — LLM critique

Review the diff using Nielsen's 10 Usability Heuristics and cognitive load analysis:

- **Visibility of system status**: Missing loading/empty states for async UI.
- **Match between system and real world**: Unintuitive icons or terminology.
- **User control and freedom**: Missing "undo" or "cancel" for destructive actions.
- **Consistency and standards**: Arbitrary pixel values vs spacing scale; inconsistent padding.
- **Error prevention**: Fragile input fields; missing validation feedback.
- **Recognition rather than recall**: Complex forms with hidden instructions.
- **Flexibility and efficiency of use**: Modal-first UX where inline editing works better.
- **Aesthetic and minimalist design**: Cluttered layouts; decorative glassmorphism/gradients that distract.
- **Help users recognize, diagnose, and recover from errors**: Vague error messages.
- **Help and documentation**: Missing focus styles; click targets < 44px.

## Severity rubric

- `HIGH` + `blocking: true` — Major usability blocks, broken user flows.
- `MEDIUM` + `blocking: false` — Heuristic violations, weak visual hierarchy.
- `LOW` + `blocking: false` — Polish, alignment nits.

## Output

Write findings as a JSON array to `/tmp/pr-review/findings.design-critique.json` using the schema in `_header.md`. Each finding gets `"angle": "design-critique"`.
