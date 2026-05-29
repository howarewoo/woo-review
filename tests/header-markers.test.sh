#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HEADER="$REPO_ROOT/skills/woo-review/prompts/_header.md"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
expect() { local n="$1" c="$2"; if eval "$c"; then echo "PASS $n"; pass=$((pass+1)); else echo "FAIL $n (cond: $c)"; fail=$((fail+1)); fi }

# Static check: the SHA watermark (the only state persisted across runs) is emitted.
expect "sha watermark present" \
  "grep -q 'woo-review:sha=' '$HEADER'"

# Static check: the removed cross-PR-dedup marker must NOT come back.
expect "no sidecar sk/ca marker" \
  "! grep -q 'woo-review:sk=' '$HEADER'"

# Static check: degraded-mode surfacing present (issue #47).
expect "degraded surface block present" \
  "grep -q 'validator-metrics.json' '$HEADER' && grep -q 'Adversarial prosecutor pass was unavailable' '$HEADER'"

# Static check: meta.json fallback to gh pr view present (issue #48).
expect "HEAD_SHA gh fallback present" \
  "grep -q 'gh pr view \"\$PR_NUMBER\" --json headRefOid' '$HEADER'"
expect "PR_AUTHOR gh fallback present" \
  "grep -q 'gh pr view \"\$PR_NUMBER\" --json author' '$HEADER'"

# Runtime check: extract the python block under '# 2. Prepare the review payload'
# and re-execute it against synthetic findings, then assert the comment rendering.
mkdir -p "$WORK/pr-review"
cat > "$WORK/pr-review/findings.json" <<JSON
[
  {"file":"src/a.ts","line":1,"title":"T1","description":"D","fix":"F","fix_type":"prose",
   "angle":"bugs","severity":"HIGH","blocking":true},
  {"file":"src/b.ts","line":2,"title":"T2","description":"D","fix":"F","fix_type":"prose",
   "angle":"bugs","severity":"LOW","blocking":false}
]
JSON
echo '[]' > "$WORK/pr-review/prior-findings.json"
echo "## body" > "$WORK/pr_review_body.txt"

# Extract the python snippet between the opening "python3 -c '" and the matching
# closing "' > /tmp/pr_review_payload.json", redirect paths to fixtures, exec it.
python3 - "$HEADER" "$WORK" <<'PY'
import re, sys, os, pathlib
header = pathlib.Path(sys.argv[1]).read_text()
work   = sys.argv[2]
m = re.search(r"python3 -c '(.*?)' > /tmp/pr_review_payload\.json", header, re.S)
if not m: sys.exit("renderer python block not found in _header.md")
src = m.group(1)
src = src.replace("/tmp/pr-review/findings.json",       f"{work}/pr-review/findings.json")
src = src.replace("/tmp/pr-review/prior-findings.json", f"{work}/pr-review/prior-findings.json")
src = src.replace("/tmp/pr_review_body.txt",            f"{work}/pr_review_body.txt")
os.environ["HEAD_SHA"]  = "deadbeef"
os.environ["AUTH_LOGIN"] = ""
os.environ["PR_AUTHOR"]  = ""
import io, contextlib
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    exec(compile(src, "<header-renderer>", "exec"), {"__name__": "__main__"})
pathlib.Path(f"{work}/payload.json").write_text(buf.getvalue())
PY

PAYLOAD="$WORK/payload.json"
expect "two comments rendered" \
  "jq -e '.comments | length == 2' '$PAYLOAD' >/dev/null"
expect "blocking finding -> REQUEST_CHANGES" \
  "jq -e '.event == \"REQUEST_CHANGES\"' '$PAYLOAD' >/dev/null"
expect "severity footer rendered" \
  "jq -e '.comments[0].body | test(\"HIGH . BLOCKING\")' '$PAYLOAD' >/dev/null"
expect "no leftover sk/ca marker in comment" \
  "jq -e '.comments[0].body | test(\"woo-review:sk=\") | not' '$PAYLOAD' >/dev/null"

echo "----"
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
