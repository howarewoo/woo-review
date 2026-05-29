# Addressing review threads (the `address` verb)

You are addressing the unresolved review threads on a pull request. The threads
are in `/tmp/pr-review/address-threads.json` (written by `fetch-threads.sh`),
each: `{ threadId, file, line, diffHunk, comments: [ { author, body } ] }`. The
team's accepted-design memory is in `/tmp/pr-review/memory.md` (may be absent).

Run **fully autonomously**: decide, fix, push back, reply, resolve, write memory,
then report. Do not ask the user between threads.

## Per-thread decision (do this for every thread)

1. **READ** the whole thread — the original finding and every reply.
2. **UNDERSTAND** — restate the ask in one sentence.
3. **VERIFY** against the actual codebase — open `file` near `line`; confirm the
   concern is real and still present.
4. **EVALUATE** for this stack/context, then choose ONE:
   - **FIX** — the suggestion is correct and improves the code.
   - **ACCEPT** — push back: the behavior is intentional / accepted-by-design
     (it breaks working behavior, violates YAGNI, conflicts with an
     architectural decision, or the reviewer lacks context).
   - **CLARIFY** — genuinely ambiguous; you cannot verify intent on your own.
5. **Never** use performative language ("You're absolutely right!", "Great
   point!"). Reply with the technical reasoning or the fix itself.

## Acting on the decision

- **FIX**: edit the working tree. Accumulate all fixes; do NOT commit per thread.
- **ACCEPT**: this is the issue-#53 step. First check `/tmp/pr-review/memory.md`
  (and the live `.woo-review/memory.md`): if an existing entry already covers
  this learning — even phrased differently or more broadly — do NOT add a
  duplicate; widen the existing entry instead. Only when the learning is
  genuinely new, record it as a **pattern, not an instance**:

  ```bash
  LEARNING="<general pattern>: <why it is accepted / what not to re-flag>" \
    bash "$WOO_REVIEW_ACTION_PATH/scripts/memory-append.sh"
  ```

  Only ACCEPT (accept-by-design) writes memory. A "won't-fix because transient
  / out-of-scope" is not a reusable rule — do not record it.
- **CLARIFY**: do not fix, do not write memory, do not resolve. Reply with a
  specific question (handled below with `RESOLVE=0`).

## After the loop

1. If any FIX edits were made, make ONE descriptive commit referencing the
   threads addressed, then push to the PR head branch. Capture the new `<sha>`.
   Never force-push.
2. For each handled thread, reply and resolve:

   ```bash
   # FIXED thread:
   THREAD_ID="<id>" REPLY_BODY="Fixed in <sha>." \
     bash "$WOO_REVIEW_ACTION_PATH/scripts/resolve-thread.sh"
   # ACCEPTED thread:
   THREAD_ID="<id>" REPLY_BODY="<technical reasoning for accepting as-is>" \
     bash "$WOO_REVIEW_ACTION_PATH/scripts/resolve-thread.sh"
   # CLARIFY thread (reply only, leave open):
   THREAD_ID="<id>" REPLY_BODY="<your specific question>" RESOLVE=0 \
     bash "$WOO_REVIEW_ACTION_PATH/scripts/resolve-thread.sh"
   ```

3. Print a summary table: thread → decision → action → memory-written?

## Guardrails

- A thread that errors (cannot verify, fix fails) is marked `errored` in the
  report and left open — never abort the whole run for one thread.
- If the push is rejected (remote ahead), stop: do NOT post "Fixed in <sha>"
  replies (the sha is not on the remote). Report which fixes are unpushed.
