# Anthropic (Claude Code) — Multi-Angle Orchestration

You are reviewing a pull request using Claude Code's `Task` tool. Every tool call must serve a clear purpose. Create a todo list before starting.

The shared header above lists prefetched artifacts, the findings schema, the blocking criteria, and the do-NOT-flag list. **Apply them verbatim.** Per-angle prompt bodies live at `$WOO_REVIEW_ACTION_PATH/prompts/angles/<angle>.md`.

**Host identifier:** default `claude-code` (substitute into the credits line `<host>` placeholder per `_header.md`). If this orchestrator was selected from a different Anthropic host (e.g. Cursor, Zed), use that host's canonical slug instead.

---

## IMPORTANT: MODE-BASED EXECUTION

Check the `Execution mode` in the Review Context above.

### MODE: review
You are running as a parallel worker for a specific angle.
- The `Target angle` in Review Context is the only angle you must audit.
- Do NOT post inline comments.
- Do NOT update the PR body or title.
- Do NOT manage labels.
- Do NOT launch subagents for other angles.
- Run ONLY the logic for your target angle (loading its prompt from `$WOO_REVIEW_ACTION_PATH/prompts/angles/<angle>.md`).
- Write your findings to `$OUTDIR/findings.<angle>.json` (default `$OUTDIR/findings.<angle>.json`) and then EXIT.
- The findings file MUST be a JSON array only — starts with `[`, ends with `]`, no preamble, no markdown fences, no commentary. See *Output Discipline* in `_header.md`. Validate every `line` via `scripts/resolve-diff-line.sh` and drop findings the helper rejects.

### MODE: validate
You are running as the final aggregator.
- Read all `$OUTDIR/findings.<angle>.json` files from the disk.
- Perform the validation step (Step 3 below).
- Perform the final output step (Step 4 below): submit one batched native PR Review. The review `event` (APPROVE / COMMENT / REQUEST_CHANGES) is the blocking gate.
- Do NOT modify the PR title, PR description, or PR labels.
- Exit.

### MODE: full (or detect)
Perform all steps (1 through 4) as the main orchestrator.

---

## Model routing (token optimization)

Claude Code's `Task` tool supports per-subagent model routing. Read each angle prompt's `tier:` frontmatter and resolve via the **Model Tiers** table in `_header.md`:

| Tier | Anthropic model | Used for |
|---|---|---|
| `fast` | `claude-haiku-4-5` | context+summary, `seo`, `aeo`, `observability`, `types`, `i18n`, `docs`, `deps` |
| `standard` | `claude-sonnet-4-6` | `bugs`, `security`, `design`, `react`, `database`, `tests`, `api`, `infra` |
| `deep` | `claude-opus-4-7` | skeptical validator |

**Every Task/Agent spawn MUST pass `model:` explicitly.** Omitting it makes the subagent inherit the parent session's model — typically Opus — which silently defeats tier routing and burns ~5x the tokens on rubric angles. The `tier:` frontmatter is informational unless the spawning call passes the resolved slug.

Concrete invocation (Claude Code `Task` / `Agent` tool):

```
Task({
  subagent_type: "general-purpose",
  model: "claude-sonnet-4-6",   // resolved from angle's `tier: standard`
  description: "bugs angle audit",
  prompt: "<angle prompt body + Review Context>"
})
```

Resolution rule per spawn:
1. Read the angle file's frontmatter `tier:` value.
2. Look up the Anthropic column in the tier table above.
3. **Per-repo override**: check `$OUTDIR/config.json` for `models.<tier>` (e.g. `jq -r '.models.standard // empty' $OUTDIR/config.json`). If non-empty, use that slug instead of the table value.
4. Pass the resolved slug as `model:` on the Task call.

Do not default the validator to Sonnet — pass `model: "claude-opus-4-7"` explicitly. Opus's stricter false-positive filter pays for itself in review quality.

**OUTDIR handoff.** `$OUTDIR` defaults to a per-project `/tmp/pr-review-<hash>` (derived from the repo's git toplevel by `scripts/resolve-outdir.sh`) so concurrent reviews of different repos on one machine never share a tree. Resolve it ONCE in the orchestrator — `source "$WOO_REVIEW_ACTION_PATH/scripts/resolve-outdir.sh"` sets and exports `OUTDIR` — then export `OUTDIR` to **every** sub-agent you spawn. Sub-agents prefer the inherited `$OUTDIR`; if it is unset they re-derive via the same helper. Never fall back to a bare `/tmp/pr-review`.

## Step 1 — Context + Summary (single `fast`-tier subagent; full mode only)

Launch one `claude-haiku-4-5` (fast tier) subagent. Task:

- Read `$OUTDIR/diff.txt`, `$OUTDIR/meta.json`, and `$OUTDIR/angles.txt`.
- Produce a 1–2 sentence summary, a bullet list of changes, and files grouped by category. These feed the **Review body** in Step 4 only — they are never written to the PR title or PR description.
- If the diff has functional changes (business logic, UI, API, data mutations), produce a manual test plan as a Markdown checklist for inclusion in the Review body.
- Return: summary, bullets, files-by-category, test plan, **enabled angles list**.

Do NOT call `gh pr edit`. The PR title and description are immutable for this action.

## Step 2 — Parallel Angle Audits (one subagent per enabled angle, × chunk if chunked)

Read `$OUTDIR/angles.txt`. Check `$OUTDIR/chunks.txt`:

- **Unchunked** (file absent): launch **one subagent per enabled angle in the same response** to maximize parallelism.
- **Chunked** (file present, issue #14): launch **one subagent per `(angle, chunk_id)` pair**, again in the same response. Pass the chunk id explicitly in the subagent prompt and instruct it to read `$OUTDIR/diff.chunk-<id>.txt` and write `$OUTDIR/findings.<angle>.chunk-<id>.json`.

Each subagent:

- Loads its angle prompt: `$WOO_REVIEW_ACTION_PATH/prompts/angles/<angle>.md`.
- Runs on the Anthropic model resolved from that prompt's `tier:` frontmatter via the table above (Sonnet for `bugs`/`security`/`design`/`react`/`database`/`tests`/`api`/`infra`, Haiku for `seo`/`aeo`/`observability`/`types`/`i18n`/`docs`/`deps`). The spawning Task call MUST pass `model:` explicitly — see Model Routing section above.
- Reads its assigned diff (`$OUTDIR/diff.txt` for the unchunked case, `$OUTDIR/diff.chunk-<id>.txt` for chunked).
- For `react`: runs `npx -y react-doctor@$REACT_DOCTOR_VERSION --diff $BASE_REF --offline`, parses output, then performs LLM review per the react prompt.
- Returns its findings list AND writes them to `$OUTDIR/findings.<angle>.json` (unchunked) or `$OUTDIR/findings.<angle>.<chunk_id>.json` (chunked).

If the Task tool caps practical parallelism below the angle count, spawn in waves of ≤4 subagents. Do not skip any enabled angle.

**Retry-once recovery.** Sub-agents can die mid-run (model stream errors, turn-limit interrupts) and leave no findings file. After the swarm reports done, before invoking `merge-findings.sh`, scan `$OUTDIR/angles.txt` and check each angle's expected output:

- Unchunked: `$OUTDIR/findings.<angle>.json`
- Chunked: every `$OUTDIR/findings.<angle>.<chunk_id>.json` for each chunk id in `chunks.txt`

For any path that (a) does not exist, OR (b) does not parse as a JSON array (`jq -e 'type == "array"'` returns non-zero), re-launch THAT subagent ONCE with an identical brief and `model:` slug. Cap is one retry total per `(angle, chunk)` pair — if the retry also fails, leave the file missing/malformed and proceed to merge. The merge step's recovery handles malformed files; missing files simply count as "this angle produced no findings."

After recovery, run `bash $WOO_REVIEW_ACTION_PATH/scripts/merge-findings.sh` — it concatenates every `findings.<angle>*.json` into `raw_findings.json` and applies within-angle dedup so duplicates across chunks collapse to a single entry before validation.

## Step 3 — Adversarial Validation (Opus 4.7, prosecutor + defender)

Skip if every per-angle file is empty / missing; status is `APPROVED`.

Otherwise this step runs **two** sequential `claude-opus-4-7` validator subagents with opposing biases, then a deterministic intersection (issue #13). The intersection is the high-confidence set of findings the author sees.

Read `disable_adversarial` from `$OUTDIR/config.json`:

```bash
DISABLE_ADV="$(jq -r '.disable_adversarial // false' $OUTDIR/config.json 2>/dev/null || echo false)"
```

### Step 3a — Prosecutor pass (skip if `DISABLE_ADV == true`)

Launch one `claude-opus-4-7` subagent with `$WOO_REVIEW_ACTION_PATH/prompts/validator-prosecutor.md` as its prompt. It assumes each finding is real and only drops the clearly-wrong ones. It writes `$OUTDIR/findings.prosecutor.json` and EXITS — it MUST NOT post a review.

### Step 3b — Defender pass

Launch one `claude-opus-4-7` subagent with `$WOO_REVIEW_ACTION_PATH/prompts/validator.md` as its prompt. It applies the strict "defense attorney" filter — drops pedantic / lint-catchable / maybe-issues / placeholder-suggestion findings — and writes `$OUTDIR/findings.defender.json`. It writes `$OUTDIR/findings.defender.json` and EXITs — it does NOT run the intersect script or post (the orchestrator does that next). Apply only `validator.md`'s validation/filter rules (its Steps 1–2) to produce `findings.defender.json`; IGNORE validator.md's Step 3/3b/4 and its STOP-GATE — the orchestrator runs the intersect itself in the next step.

The two passes MUST be sequential — the prosecutor's file must already exist before the defender runs when adversarial mode is on.

### Step 3c — Intersect (orchestrator)

After both validator subagents finish, the orchestrator (this session) runs:

```bash
bash "$WOO_REVIEW_ACTION_PATH/scripts/intersect-findings.sh"
```

This produces the final `$OUTDIR/findings.json` (intersection of prosecutor + defender; when adversarial is disabled or the prosecutor file is absent, defender output is copied verbatim). Per-pass and disagreement counts land in `$OUTDIR/validator-metrics.json` for downstream telemetry.

## Step 4 — Submit Native PR Review

Follow `_header.md` exactly. Compute `BLOCKING_COUNT`, `NONBLOCKING_COUNT`, `HIGH_COUNT`, `MEDIUM_COUNT`, `LOW_COUNT`. Build `STATUS_LINE`. Submit a single batched `gh api repos/<repo>/pulls/<PR>/reviews` POST containing all inline comments + the summary + the `STATUS_LINE` in the review body. The review `event` is computed by the `_header.md` payload-builder (do not duplicate the logic here): `REQUEST_CHANGES` when any new finding is `blocking: true` OR when `$OUTDIR/prior-findings.json` is non-empty (unresolved review threads keep the PR at minimum `REQUEST_CHANGES`), `COMMENT` when there are only non-blocking new findings and no unresolved priors, `APPROVE` only when both new findings and prior unresolved threads are empty.

Do NOT call `gh pr edit`. Do NOT add, remove, or mutate PR labels. The PR title, PR description, and PR labels must remain untouched.

## Rules

- Execute every step autonomously — no confirmation prompts.
- Trust prefetched artifacts. Do NOT re-run `gh pr diff`.
- Parallel angle subagents in Step 2 must complete before Step 3.
- Each subagent stays within its angle scope; do not duplicate findings across angles (validator dedupes).
- `findings.json` is the single source of truth for Step 4.
