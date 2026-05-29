#!/usr/bin/env bash
# sidecar-write.sh
#
# Scans review threads resolved between last_sha..HEAD_SHA, appends them
# (idempotent on (pr_number, semantic_key, code_anchor); fallback
# (pr_number, file, line) for legacy placeholder rows) to one of 16
# hash-sharded JSONL files under .woo-review/dismissed-<0-f>.jsonl, then
# commits via the bot identity.
#
# Gated on:
#   - .woo-review.yml: enable_sidecar_write (default: true)
#   - env: WOO_REVIEW_DISABLE_GIT_WRITE=1 → skip (tests)
#
# Failures (no perm, push race, malformed) → log + exit 0. Never fail the run.
#
# Marker parse + sharded JSONL: see docs/superpowers/specs/2026-05-28-sidecar-scaling-design.html

set -euo pipefail

OUTDIR="${OUTDIR:-/tmp/pr-review}"

# Non-CI guard (local post-session Stop hook). The hook fires at the end of
# EVERY host session; act only when a local /woo-review run just posted a
# review (sentinel) AND we are standing in the repo that was reviewed. CI runs
# (GITHUB_ACTIONS=true) skip this entirely — the isolated job runs the script
# unconditionally with env state, preserving #33 parity.
#
# IMPORTANT: this block must run BEFORE any ENABLE/DISABLE gate so that the
# sentinel is consumed (trap registered) even when a later gate exits 0.
# Without this ordering the sentinel leaks and every future session prints
# "disabled" even when no review is pending.
if [ "${GITHUB_ACTIONS:-}" != "true" ]; then
  SENTINEL="$OUTDIR/sidecar-pending"
  if [ ! -f "$SENTINEL" ]; then
    echo "sidecar-write: no pending local review; skipping"
    exit 0
  fi
  # Consume the sentinel on every exit path from here on.
  trap 'rm -f "$SENTINEL"' EXIT
  CTX_PATH=$(jq -r '.repo_path // empty' "$OUTDIR/review-context.json" 2>/dev/null || echo)
  TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null || echo)
  # Safe default: only proceed when we can positively confirm the cwd repo IS
  # the reviewed repo. An empty CTX_PATH (context file missing/partial, or a
  # stale sentinel without a matching context) means we CANNOT confirm — skip
  # rather than risk committing to whatever repo the Stop hook fired in.
  if [ -z "$CTX_PATH" ] || [ "$CTX_PATH" != "$TOPLEVEL" ]; then
    echo "sidecar-write: cannot confirm reviewed repo (ctx=$CTX_PATH, cwd=$TOPLEVEL); skipping"
    exit 0
  fi
fi

# `if … == null` (not `//`) because jq's alternative operator treats `false`
# as "missing" — `false // true` evaluates to `true`, which would silently
# enable writes for users who explicitly set the flag to `false`.
ENABLE=$(jq -r 'if .enable_sidecar_write == null then true else .enable_sidecar_write end' \
           "$OUTDIR/config.json" 2>/dev/null || echo false)
if [ "$ENABLE" != "true" ]; then
  echo "sidecar-write: disabled (.woo-review.yml: enable_sidecar_write != true)"
  exit 0
fi
if [ "${WOO_REVIEW_DISABLE_GIT_WRITE:-0}" = "1" ]; then
  echo "sidecar-write: disabled via WOO_REVIEW_DISABLE_GIT_WRITE"
  exit 0
fi

# TTL is read from .woo-review.yml via the same config.json that prefetch.sh
# already loads. 0 (or null) → pruning disabled. Default 180 days.
TTL_DAYS=$(jq -r 'if .sidecar_ttl_days == null then 180 else .sidecar_ttl_days end' \
            "$OUTDIR/config.json" 2>/dev/null || echo 180)
case "$TTL_DAYS" in ''|*[!0-9]*) TTL_DAYS=180 ;; esac

ttl_cutoff() {
  local days="$1"
  # GNU date first, then BSD; on failure, echo empty so caller skips prune.
  date -u -d "$days days ago" +%FT%TZ 2>/dev/null \
    || date -u -v-"${days}"d +%FT%TZ 2>/dev/null \
    || true
}

prune_shard() {
  local shard_file="$1" cutoff="$2"
  [ -z "$cutoff" ] && return 0
  [ -f "$shard_file" ] || return 0
  local tmp="$shard_file.tmp.$$"
  # Keep only lines that parse AND are >= cutoff. Drop malformed lines silently.
  awk 'NF' "$shard_file" | while IFS= read -r LN; do
    KEEP=$(printf '%s' "$LN" | jq -r --arg c "$cutoff" 'if .resolved_at >= $c then "k" else "" end' 2>/dev/null) || continue
    [ "$KEEP" = "k" ] && printf '%s\n' "$LN"
  done > "$tmp"
  mv "$tmp" "$shard_file"
}

# State resolution: env wins (CI), else fall back to the handoff file the
# skill session left in $OUTDIR (local post-session Stop hook path).
CTX="$OUTDIR/review-context.json"
PR_NUMBER="${PR_NUMBER:-$(jq -r '.pr_number // empty' "$CTX" 2>/dev/null || echo)}"
HEAD_SHA="${HEAD_SHA:-$(jq -r '.head_sha // empty' "$CTX" 2>/dev/null || echo)}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-$(jq -r '.repo // empty' "$CTX" 2>/dev/null || echo)}"
export GITHUB_REPOSITORY

shard_for() { printf '%s' "$1" | shasum -a 1 | cut -c1; }

migrate_legacy() {
  local legacy=".woo-review/dismissed.json"
  [ -f "$legacy" ] || return 0
  if ! jq empty "$legacy" 2>/dev/null; then
    echo "sidecar-write: legacy $legacy malformed; leaving in place"
    return 0
  fi
  echo "sidecar-write: migrating $legacy → sharded JSONL"
  jq -c '.[]' "$legacy" | while IFS= read -r LN; do
    [ -z "$LN" ] && continue
    F=$(printf '%s' "$LN" | jq -r '.file // empty')
    if [ -z "$F" ]; then
      # Surface dropped entries so operators can recover them from the
      # legacy file (kept in git history) before it is `git rm`'d below.
      echo "sidecar-write: migrate: skipping entry without file field: $LN" >&2
      continue
    fi
    SH=$(shard_for "$F")
    printf '%s\n' "$LN" >> ".woo-review/dismissed-$SH.jsonl"
  done
  git rm -q "$legacy" 2>/dev/null || rm -f "$legacy"
}

if [ -z "$PR_NUMBER" ] || [ -z "$HEAD_SHA" ]; then
  echo "sidecar-write: PR_NUMBER or HEAD_SHA missing; skipping"
  exit 0
fi

if [ -n "${WOO_REVIEW_FAKE_RESOLVED_THREADS_JSON:-}" ]; then
  RESOLVED="$WOO_REVIEW_FAKE_RESOLVED_THREADS_JSON"
else
  OWNER="${GITHUB_REPOSITORY%/*}"
  REPO="${GITHUB_REPOSITORY#*/}"
  RESOLVED=$(gh api graphql -F owner="$OWNER" -F repo="$REPO" -F pr="$PR_NUMBER" -f query='
    query($owner:String!,$repo:String!,$pr:Int!){
      repository(owner:$owner,name:$repo){
        pullRequest(number:$pr){
          reviewThreads(first:100){
            nodes{
              isResolved
              path line
              comments(first:1){nodes{body author{login}}}
            }
          }
        }
      }
    }' 2>/dev/null || echo '{}')
fi

NOW=$(date -u +%FT%TZ)
# Mirror prefetch.sh's BOT_NAME_PATTERN. The marker is only honoured when the
# comment that carries it was authored by a recognised bot — a non-bot
# collaborator could otherwise pre-compute a `code_anchor` for code they plan
# to push, post a crafted marker on an unrelated thread, resolve it, and
# silently poison the dedup index for a future PR.
BOT_NAME_PATTERN="${WOO_REVIEW_BOT_NAME_PATTERN:-claude|openai|gemini|opencode|woo-review|github-actions}"
NEW_ENTRIES=$(printf '%s' "$RESOLVED" | jq -c \
  --arg pr "$PR_NUMBER" --arg now "$NOW" --arg botpat "$BOT_NAME_PATTERN" '
  # Marker format: <!-- woo-review:sk=<sk> ca=<ca> -->
  # sk whitelist: [a-z0-9/_-]{1,40}; ca whitelist: [a-f0-9]{12}.
  # Both must match in a single capture — partial/malformed → drop the marker
  # entirely so we fall through to placeholder values. Mirrors the renderer in
  # prompts/_header.md, which also validates as a single unit.
  # capture returns a single object on first match, errors on no-match. `?`
  # swallows the error → null; the `// {…}` fallback supplies the placeholder pair.
  def parse_marker(body):
    ((body // "")
     | capture("<!-- woo-review:sk=(?<sk>[a-z0-9/_-]{1,40}) ca=(?<ca>[a-f0-9]{12}) -->")?)
    // {sk: "unknown/unknown", ca: "unknown000000"};
  [ .data.repository.pullRequest.reviewThreads.nodes[]?
    | select(.isResolved == true)
    | select(.path != null)
    | (.comments.nodes[0].body // "") as $b
    | (.comments.nodes[0].author.login // "") as $author
    | (if ($author | test("^(" + $botpat + ")"; "i")) then parse_marker($b)
       else {sk: "unknown/unknown", ca: "unknown000000"} end) as $m
    | { file: .path,
        line: (.line // 1),
        title: (($b | split("\n")[0])[0:60]),
        semantic_key: ($m.sk // "unknown/unknown"),
        code_anchor:  ($m.ca // "unknown000000"),
        resolved_at: $now,
        pr_number: ($pr | tonumber)
      } ]')

NEW_COUNT=$(printf '%s' "$NEW_ENTRIES" | jq length)
mkdir -p .woo-review
migrate_legacy
if [ "$NEW_COUNT" -eq 0 ]; then
  echo "sidecar-write: no newly-resolved threads"
  # Migration may have produced changes even with zero new entries — flush.
  # Check BOTH unstaged (new shards written to worktree) and staged (legacy
  # `git rm` of an empty `[]` dismissed.json produces no JSONL files but does
  # stage a deletion). Unstaged-only would skip the commit on staged-only diffs.
  if ! git diff --quiet -- .woo-review/ 2>/dev/null \
     || ! git diff --cached --quiet -- .woo-review/ 2>/dev/null; then
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    bash "$SCRIPT_DIR/install-gitattributes.sh" || echo "sidecar-write: .gitattributes install failed; continuing"
    git config --local user.name  "${WOO_REVIEW_BOT_NAME:-woo-review[bot]}"
    git config --local user.email "${WOO_REVIEW_BOT_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"
    git add .gitattributes 2>/dev/null || true
    git add .woo-review/ || true
    git commit -m "chore(woo-review): migrate legacy sidecar to sharded JSONL" \
      && (git push || (git pull --rebase && git push) || echo "sidecar-write: migration push failed; skipping") \
      || echo "sidecar-write: migration commit failed; skipping"
  fi
  exit 0
fi

# --- group by shard and append (with in-shard dedup) ----------------------
WRITTEN=0

# Unique shard letters covered by this batch.
SHARDS=$(printf '%s' "$NEW_ENTRIES" | jq -r '.[].file' \
          | while read -r FILE; do shard_for "$FILE"; done | sort -u)

for SH in $SHARDS; do
  SHARD_FILE=".woo-review/dismissed-$SH.jsonl"
  [ -f "$SHARD_FILE" ] || : > "$SHARD_FILE"

  # Iterate every candidate entry; keep only the ones that route to this shard
  # AND survive dedup. The redirect at the loop tail uses process substitution
  # so the running WRITTEN counter is not lost to a subshell.
  while IFS= read -r ENTRY; do
    F=$(printf '%s' "$ENTRY" | jq -r '.file')
    [ "$(shard_for "$F")" = "$SH" ] || continue

    # Dedup: skip if (pr, sk, ca) matches an existing line, or — for legacy
    # placeholder rows where sk/ca are both "unknown*" — fall back to
    # (pr, file, line). The fallback fires only when AT LEAST ONE of the two
    # rows carries placeholder keys; otherwise two distinct findings anchored
    # to the same (file, line) (e.g. `bugs/null-deref` and `security/xss` both
    # on line 42) would silently drop the second one.
    KEY=$(printf '%s'    "$ENTRY" | jq -c '[.pr_number,.semantic_key,.code_anchor]')
    KEY_FB=$(printf '%s' "$ENTRY" | jq -c '[.pr_number,.file,.line]')
    ENTRY_PLACEHOLDER=$(printf '%s' "$ENTRY" \
      | jq -r 'if .semantic_key=="unknown/unknown" and .code_anchor=="unknown000000" then "1" else "" end')

    HIT=""
    while IFS= read -r LN; do
      [ -z "$LN" ] && continue
      VK=$(printf '%s' "$LN" | jq -c '[.pr_number,.semantic_key,.code_anchor]' 2>/dev/null) || continue
      if [ "$VK" = "$KEY" ]; then HIT=1; break; fi
      LN_PLACEHOLDER=$(printf '%s' "$LN" \
        | jq -r 'if .semantic_key=="unknown/unknown" and .code_anchor=="unknown000000" then "1" else "" end' 2>/dev/null) \
        || LN_PLACEHOLDER=""
      if [ -n "$ENTRY_PLACEHOLDER" ] || [ -n "$LN_PLACEHOLDER" ]; then
        VKFB=$(printf '%s' "$LN" | jq -c '[.pr_number,.file,.line]' 2>/dev/null) || continue
        if [ "$VKFB" = "$KEY_FB" ]; then HIT=1; break; fi
      fi
    done < "$SHARD_FILE"
    [ -n "$HIT" ] && continue

    printf '%s\n' "$ENTRY" >> "$SHARD_FILE"
    WRITTEN=$((WRITTEN + 1))
  done < <(printf '%s' "$NEW_ENTRIES" | jq -c '.[]')
done

# Opportunistic TTL prune — only on shards we wrote to. Cold shards untouched.
if [ "$TTL_DAYS" -gt 0 ]; then
  CUTOFF=$(ttl_cutoff "$TTL_DAYS")
  if [ -n "$CUTOFF" ]; then
    for SH in $SHARDS; do
      prune_shard ".woo-review/dismissed-$SH.jsonl" "$CUTOFF"
    done
  else
    echo "sidecar-write: TTL date arithmetic unavailable; skipping prune"
  fi
fi

if [ "$WRITTEN" -eq 0 ]; then
  echo "sidecar-write: all $NEW_COUNT entries already present"; exit 0
fi

# --- commit + push --------------------------------------------------------
git config --local user.name  "${WOO_REVIEW_BOT_NAME:-woo-review[bot]}"
git config --local user.email "${WOO_REVIEW_BOT_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
bash "$SCRIPT_DIR/install-gitattributes.sh" || echo "sidecar-write: .gitattributes install failed; continuing"
git add .gitattributes 2>/dev/null || true
git add .woo-review/dismissed-*.jsonl || { echo "sidecar-write: git add failed; skipping"; exit 0; }
if git diff --cached --quiet; then
  echo "sidecar-write: nothing new to commit"; exit 0
fi

git commit -m "chore(woo-review): record $WRITTEN dismissed finding(s)" || {
  echo "sidecar-write: commit failed; skipping"; exit 0; }

if ! git push; then
  echo "sidecar-write: push failed; trying rebase + push once"
  git pull --rebase || { echo "sidecar-write: rebase failed; skipping"; exit 0; }
  git push || { echo "sidecar-write: push still failing; skipping"; exit 0; }
fi
echo "sidecar-write: appended $WRITTEN entries across sharded JSONL"
