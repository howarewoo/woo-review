# Google (Gemini CLI) — Tool-Loop Multi-Angle Review

The Gemini CLI runs an agentic tool loop with access to `bash` and `gh`. Use the same structured-pass approach as Codex; Gemini has no native subagent primitive.

The shared header above lists prefetched artifacts, findings schema, blocking criteria, and the do-NOT-flag list. **Apply them verbatim.** Per-angle prompt bodies live at `$WOO_REVIEW_ACTION_PATH/prompts/angles/<angle>.md` in the bundled action repo.

## Model selection

Gemini CLI runs one model per job (set via `inputs.model`, default `gemini-3-5-flash`). Per-call routing is not possible, so the `tier:` frontmatter is **informational only** under this provider. Google's 3.5 line currently exposes only `gemini-3-5-flash` — no Pro/Ultra/Thinking variant exists yet — so tier routing is a no-op on Gemini today. Use `gemini-3-5-flash` for all runs until Google releases a larger 3.5-line model; revisit this prompt when one ships.

**Per-repo override:** if `/tmp/pr-review/config.json` has `models.standard` set, treat it as the effective slug for this run (precedence: `inputs.model` > `models.standard` > default `gemini-3-5-flash`). Read with `jq -r '.models.standard // empty' /tmp/pr-review/config.json`.

---

## IMPORTANT: MODE-BASED EXECUTION

Check the `Execution mode` in the Review Context above.

### MODE: review
You are running as a parallel worker for a specific angle.
- The `Target angle` in Review Context is the only angle you must audit.
- Do NOT post inline comments.
- Do NOT update the PR body or title.
- Do NOT manage labels.
- Run ONLY Phase 2 below for your target angle.
- Write findings to `/tmp/pr-review/findings.<angle>.json` and then EXIT.

### MODE: validate
You are running as the final aggregator.
- Read all `/tmp/pr-review/findings.<angle>.json` files from the disk.
- Perform Phase 3 (Self-Validation) below.
- Perform Phase 4 (Submit Native PR Review) below.
- Do NOT modify the PR title, PR description, or PR labels.
- Exit.

### MODE: full (or detect)
Perform all phases (1 through 4) sequentially.

---

## Phase 1 — Read artifacts + draft summary

Read `/tmp/pr-review/diff.txt`, `/tmp/pr-review/meta.json`, `/tmp/pr-review/angles.txt`. Draft a 1–2 sentence summary, change bullets, files-by-category, optional manual test plan — all destined for the **Review body** in Phase 4. Do NOT call `gh pr edit`; the PR title and description must remain untouched.

## Phase 2 — Per-Angle Audit (sequential loop)

For each angle listed in `/tmp/pr-review/angles.txt`, in order:

1. Read `$WOO_REVIEW_ACTION_PATH/prompts/angles/<angle>.md`.
2. Execute the angle prompt. For `react` run `npx -y react-doctor@$REACT_DOCTOR_VERSION --diff $BASE_REF --offline`.
3. Write findings to `/tmp/pr-review/findings.<angle>.json` (JSON array conforming to `_header.md` schema).

Stay within each angle's scope.

## Phase 3 — Adversarial Validation (prosecutor + defender, sequential)

Merge all `findings.<angle>.json` arrays into `/tmp/pr-review/raw_findings.json` via `$WOO_REVIEW_ACTION_PATH/scripts/merge-findings.sh`.

Then run TWO opposing-bias validation passes plus a deterministic intersection (issue #13). Gemini CLI has no subagent primitive, so this is sequenced inside the single agentic loop. Read `disable_adversarial` first:

```bash
DISABLE_ADV="$(jq -r '.disable_adversarial // false' /tmp/pr-review/config.json 2>/dev/null || echo false)"
```

### Phase 3a — Prosecutor pass (skip if `DISABLE_ADV == true`)

Apply `$WOO_REVIEW_ACTION_PATH/prompts/validator-prosecutor.md` against `raw_findings.json`. Bias: assume each finding is real; drop only the demonstrably wrong. Write surviving findings to `/tmp/pr-review/findings.prosecutor.json`.

### Phase 3b — Defender pass

Apply `$WOO_REVIEW_ACTION_PATH/prompts/validator.md` against `raw_findings.json`. Bias: try to prove each finding wrong; drop pedantic / lint-catchable / "maybe" findings. Write surviving findings to `/tmp/pr-review/findings.defender.json`.

### Phase 3c — Intersect

```bash
bash "$WOO_REVIEW_ACTION_PATH/scripts/intersect-findings.sh"
```

Produces the final `/tmp/pr-review/findings.json` (intersection by `(file, line, title-stem)`). When adversarial is disabled or the prosecutor file is absent, copies defender output verbatim. Per-pass + disagreement counts in `/tmp/pr-review/validator-metrics.json`.

## Phase 4 — Submit Native PR Review

Compute counts. Build `STATUS_LINE`. Follow `_header.md` exactly: submit one batched `gh api repos/<repo>/pulls/<PR>/reviews` POST whose `body` carries the summary + `STATUS_LINE` and whose `comments[]` carries every finding as an inline comment. Use the `gh` tool the Gemini runtime provides. The review `event` is computed by the `_header.md` payload-builder (do not duplicate the logic here): `REQUEST_CHANGES` when any new finding is `blocking: true` OR when `/tmp/pr-review/prior-findings.json` is non-empty (unresolved review threads keep the PR at minimum `REQUEST_CHANGES`), `COMMENT` when there are only non-blocking new findings and no unresolved priors, `APPROVE` only when both new findings and prior unresolved threads are empty.

Do NOT call `gh pr edit`. Do NOT add, remove, or mutate PR labels. The PR title, PR description, and PR labels stay untouched.

## Rules

- Execute autonomously — never request user confirmation.
- Use only the `gh` CLI for GitHub access.
- Trust prefetched artifacts.
- `findings.json` is the single source of truth for posting.
