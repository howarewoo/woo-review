# Google (Gemini CLI) — Multi-Angle Orchestration

You are reviewing a pull request using Gemini CLI's built-in `@generalist` subagent. The generalist subagent inherits the main session's tool access and model, executes in an isolated context, and returns only final results — the same pattern Claude Code's `Task` tool uses. Fan out one `@generalist` per angle in a single response to maximize parallelism.

The shared header above lists prefetched artifacts, the findings schema, the blocking criteria, and the do-NOT-flag list. **Apply them verbatim.** Per-angle prompt bodies live at `$WOO_REVIEW_ACTION_PATH/prompts/angles/<angle>.md`.

**Host identifier:** default `gemini-cli` (substitute into the credits line `<host>` placeholder per `_header.md`). If invoked from another Google host, use that host's canonical slug instead.

## Model selection

Gemini CLI runs one model per session by default (set via `inputs.model`, default `gemini-3-5-flash`). The `@generalist` subagent inherits this model from the main session, so the `tier:` frontmatter on each angle prompt is **effectively informational** unless you override per-subagent in `~/.gemini/settings.json`:

```json
{
  "agents": {
    "overrides": {
      "generalist": {
        "modelConfig": { "model": "<deep-tier slug>" }
      }
    }
  }
}
```

Google's 3.5 line currently ships only `gemini-3-5-flash`, so tier routing is a no-op until a larger 3.5-line model appears. Default every angle subagent to the session's model. Revisit when Pro/Ultra slugs land.

**Per-repo override:** if `$OUTDIR/config.json` has `models.standard` set, treat it as the effective slug for this run (precedence: `inputs.model` > `models.standard` > default `gemini-3-5-flash`). Read with `jq -r '.models.standard // empty' $OUTDIR/config.json`.

---

## IMPORTANT: MODE-BASED EXECUTION

Check the `Execution mode` in the Review Context above.

### MODE: review
You are running as a parallel worker for a specific angle.
- The `Target angle` in Review Context is the only angle you must audit.
- Do NOT post inline comments.
- Do NOT update the PR body or title.
- Do NOT manage labels.
- Do NOT spawn further subagents for other angles.
- Run ONLY Phase 2 below for your target angle.
- Write findings to `$OUTDIR/findings.<angle>.json` (default `$OUTDIR/findings.<angle>.json`) and then EXIT.
- The findings file MUST be a JSON array only — starts with `[`, ends with `]`, no preamble, no markdown fences, no commentary. See *Output Discipline* in `_header.md`. Validate every `line` via `scripts/resolve-diff-line.sh` and drop findings the helper rejects.

### MODE: validate
You are running as the final aggregator.
- Read all `$OUTDIR/findings.<angle>.json` files from the disk.
- Perform Phase 3 (Adversarial Validation) below.
- Perform Phase 4 (Submit Native PR Review) below.
- Do NOT modify the PR title, PR description, or PR labels.
- Exit.

### MODE: full (or detect)
Perform all phases (1 through 4) as the main orchestrator.

---

**OUTDIR handoff.** `$OUTDIR` defaults to a per-project `/tmp/pr-review-<hash>` (derived from the repo's git toplevel by `scripts/resolve-outdir.sh`) so concurrent reviews of different repos on one machine never share a tree. Resolve it ONCE in the orchestrator — `source "$WOO_REVIEW_ACTION_PATH/scripts/resolve-outdir.sh"` sets and exports `OUTDIR` — then export `OUTDIR` to **every** sub-agent you spawn. Sub-agents prefer the inherited `$OUTDIR`; if it is unset they re-derive via the same helper. Never fall back to a bare `/tmp/pr-review`.

## Phase 1 — Context + summary (single `@generalist` subagent; full mode only)

Spawn one `@generalist` with this brief:

- Read `$OUTDIR/diff.txt`, `$OUTDIR/meta.json`, and `$OUTDIR/angles.txt`.
- Produce a 1–2 sentence summary, a bullet list of changes, files grouped by category, optional manual test plan. All destined for the **Review body** in Phase 4 — never written to PR title or description.
- Return: summary, bullets, files-by-category, test plan, enabled angles list.

Do NOT call `gh pr edit`. The PR title and description are immutable for this action.

## Phase 2 — Parallel angle audits (one `@generalist` per enabled angle, × chunk if chunked)

Read `$OUTDIR/angles.txt`. Check `$OUTDIR/chunks.txt`:

- **Unchunked** (file absent): invoke **one `@generalist` per enabled angle in the same response** so Gemini CLI can dispatch them concurrently. The parallelism behavior of multiple `@<agent>` invocations in one turn is not formally documented today, but the tool-call shape matches Claude Code's `Task` fan-out — treat it as best-effort parallel and rely on isolation for token economy.
- **Chunked** (file present, issue #14): invoke **one `@generalist` per `(angle, chunk_id)` pair**, again in the same response. Pass the chunk id explicitly in the subagent brief and tell it to read `$OUTDIR/diff.chunk-<id>.txt` and write `$OUTDIR/findings.<angle>.chunk-<id>.json`.

Each `@generalist` subagent receives this brief:

```
You are the <angle> reviewer for this PR. Read:
  - $WOO_REVIEW_ACTION_PATH/prompts/_header.md   (shared contract)
  - $WOO_REVIEW_ACTION_PATH/prompts/angles/<angle>.md   (your scope)
  - $OUTDIR/diff.txt (or diff.chunk-<id>.txt when chunked)
  - $OUTDIR/meta.json

For `react` first run `npx -y react-doctor@$REACT_DOCTOR_VERSION --diff $BASE_REF --offline`.

Write findings as a JSON array to $OUTDIR/findings.<angle>.json
(or .<angle>.<chunk_id>.json when chunked) per the schema in _header.md.
The file MUST start with `[` and end with `]` — no preamble, no commentary,
no markdown fences. Before writing each finding's `line` field, validate it
via `bash $WOO_REVIEW_ACTION_PATH/scripts/resolve-diff-line.sh --file <p>
--line <N>` and drop the finding when the helper prints `null`.

Write `[]` to your findings path FIRST so a crash leaves an empty array,
not a missing file. Replace with the final array before EXIT.

EXIT when done. Do NOT post comments, edit the PR, or touch other angles.
```

After every subagent has finished, run `bash $WOO_REVIEW_ACTION_PATH/scripts/merge-findings.sh` — it concatenates every `findings.<angle>*.json` into `raw_findings.json` and applies within-angle dedup so duplicates across chunks collapse to a single entry before validation.

**Retry-once recovery.** `@generalist` calls can die mid-run (model stream errors, turn-limit interrupts) and leave no findings file. Before invoking `merge-findings.sh`, scan `$OUTDIR/angles.txt` (× `chunks.txt` when chunked) and check that each expected `findings.<angle>.json` (or `findings.<angle>.<chunk_id>.json`) exists and parses as a JSON array via `jq -e 'type == "array"'`. For any path that fails the check, re-spawn THAT `(angle, chunk)` subagent ONCE with the same brief. Cap is one retry per pair — if the retry also fails, leave the file as-is and proceed. The merge step recovers malformed JSON; missing files just mean the angle produced no findings.

## Phase 3 — Adversarial validation (sequential `@generalist` × 2)

Skip if every per-angle file is empty / missing; status is `APPROVED`.

Otherwise run TWO sequential `@generalist` subagents with opposing biases, then a deterministic intersection (issue #13). Read `disable_adversarial` first:

```bash
DISABLE_ADV="$(jq -r '.disable_adversarial // false' $OUTDIR/config.json 2>/dev/null || echo false)"
```

### Phase 3a — Prosecutor pass (skip if `DISABLE_ADV == true`)

Spawn one `@generalist` with `$WOO_REVIEW_ACTION_PATH/prompts/validator-prosecutor.md` as its brief. It assumes each finding is real and drops only the clearly-wrong ones. It writes `$OUTDIR/findings.prosecutor.json` and EXITS — it MUST NOT post a review.

### Phase 3b — Defender pass

Spawn one `@generalist` with `$WOO_REVIEW_ACTION_PATH/prompts/validator.md` as its brief. It applies the strict "defense attorney" filter — drops pedantic / lint-catchable / maybe-issues / placeholder-suggestion findings — and writes `$OUTDIR/findings.defender.json`. It writes `$OUTDIR/findings.defender.json` and EXITs — it does NOT run the intersect script or post (the orchestrator does that next). Apply only `validator.md`'s validation/filter rules (its Steps 1–2) to produce `findings.defender.json`; IGNORE validator.md's Step 3/3b/4 and its STOP-GATE — the orchestrator runs the intersect itself in the next phase.

The two passes MUST be sequential — the prosecutor's file must already exist before the defender runs when adversarial mode is on.

### Phase 3c — Intersect (orchestrator)

After both validator subagents finish, the orchestrator (this session) runs:

```bash
bash "$WOO_REVIEW_ACTION_PATH/scripts/intersect-findings.sh"
```

This produces the final `$OUTDIR/findings.json` (intersection of prosecutor + defender; when adversarial is disabled or the prosecutor file is absent, defender output is copied verbatim). Per-pass and disagreement counts land in `$OUTDIR/validator-metrics.json`.

## Phase 4 — Submit native PR Review

Compute counts. Build `STATUS_LINE`. Follow `_header.md` exactly: submit one batched `gh api repos/<repo>/pulls/<PR>/reviews` POST whose `body` carries the summary + `STATUS_LINE` and whose `comments[]` carries every finding as an inline comment. The review `event` is computed by the `_header.md` payload-builder (do not duplicate the logic here): `REQUEST_CHANGES` when any new finding is `blocking: true` OR when `$OUTDIR/prior-findings.json` is non-empty, `COMMENT` when only non-blocking new findings exist and no unresolved priors, `APPROVE` only when both new findings and prior unresolved threads are empty. The payload-builder also handles the self-PR API restriction — when reviewer login matches PR author login, REQUEST_CHANGES/APPROVE downgrade to COMMENT.

Do NOT call `gh pr edit`. Do NOT add, remove, or mutate PR labels. The PR title, PR description, and PR labels stay untouched.

## Rules

- Execute autonomously — never request user confirmation.
- Use the `gh` CLI for GitHub access.
- Trust prefetched artifacts.
- Parallel angle subagents in Phase 2 must complete before Phase 3.
- Each subagent stays within its angle scope; do not duplicate findings across angles (the validator dedupes).
- `findings.json` is the single source of truth for Phase 4.
