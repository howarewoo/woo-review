#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HEADER="$REPO_ROOT/skills/woo-review/prompts/_header.md"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
expect() { local n="$1" c="$2"; if eval "$c"; then echo "PASS $n"; pass=$((pass+1)); else echo "FAIL $n (cond: $c)"; fail=$((fail+1)); fi }

# Static check: marker emission code present in the renderer.
expect "marker assembly present" \
  "grep -q 'woo-review:sk=' '$HEADER'"
expect "sk whitelist regex present" \
  "grep -qE 're\\.fullmatch\\(r\"\\[a-z0-9/_-\\]\\{1,40\\}\"' '$HEADER'"
expect "ca whitelist regex present" \
  "grep -qE 're\\.fullmatch\\(r\"\\[a-f0-9\\]\\{12\\}\"' '$HEADER'"

# Runtime check: extract the python block under '# 2. Prepare the review payload'
# and re-execute it against synthetic findings, then assert the marker rendering.
mkdir -p "$WORK/pr-review"
cat > "$WORK/pr-review/findings.deduped.json" <<JSON
[
  {"file":"src/a.ts","line":1,"title":"T1","description":"D","fix":"F","fix_type":"prose",
   "angle":"bugs","severity":"HIGH","blocking":false,
   "semantic_key":"bugs/off-by-one","code_anchor":"a1b2c3d4e5f6"},
  {"file":"src/b.ts","line":2,"title":"T2","description":"D","fix":"F","fix_type":"prose",
   "angle":"bugs","severity":"LOW","blocking":false,
   "semantic_key":"bugs/<script>","code_anchor":"a1b2c3d4e5f6"},
  {"file":"src/c.ts","line":3,"title":"T3","description":"D","fix":"F","fix_type":"prose",
   "angle":"bugs","severity":"LOW","blocking":false,
   "semantic_key":"bugs/x","code_anchor":"NOTHEX"}
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
src = src.replace("/tmp/pr-review/findings.deduped.json", f"{work}/pr-review/findings.deduped.json")
src = src.replace("/tmp/pr-review/findings.json",        f"{work}/pr-review/findings.json")
src = src.replace("/tmp/pr-review/prior-findings.json",  f"{work}/pr-review/prior-findings.json")
src = src.replace("/tmp/pr_review_body.txt",             f"{work}/pr_review_body.txt")
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
expect "well-formed marker rendered" \
  "jq -e '.comments[0].body | test(\"<!-- woo-review:sk=bugs/off-by-one ca=a1b2c3d4e5f6 -->\")' '$PAYLOAD' >/dev/null"
expect "injection in sk omits marker" \
  "jq -e '.comments[1].body | test(\"woo-review:sk=\") | not' '$PAYLOAD' >/dev/null"
expect "non-hex ca omits marker" \
  "jq -e '.comments[2].body | test(\"woo-review:sk=\") | not' '$PAYLOAD' >/dev/null"

echo "----"
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
