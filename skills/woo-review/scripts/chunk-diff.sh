#!/usr/bin/env bash
# chunk-diff.sh — issue #14: split large diffs into chunks for parallel review.
#
# Inputs (in $OUTDIR, defaults to /tmp/pr-review):
#   diff.txt        the prefetched diff (full or incremental)
#   config.json     reads .chunking.max_loc (default 4000; 0 disables chunking)
#
# Outputs (only when LOC > threshold):
#   chunks.txt          one chunk id per line, e.g. `chunk-0`
#   chunks.json         manifest: [{id, files, loc, diff_path, boundary}]
#   diff.chunk-N.txt    per-chunk diff body (valid `diff --git` stream)
#
# When LOC <= threshold OR threshold == 0, exits 0 with no output (zero overhead
# under the threshold — per issue #14 acceptance bullet 2).
#
# Boundary precedence (issue #14 acceptance bullet 3):
#   1. pnpm/yarn workspace roots — packages/<name>/, apps/<name>/,
#      services/<name>/, libs/<name>/
#   2. Top-level directory of each changed path
#   3. File-count balanced groups (when a single boundary group itself
#      exceeds max_loc, its sections are bin-packed by LOC across sub-chunks)

set -euo pipefail

# shellcheck source=skills/woo-review/scripts/resolve-outdir.sh
source "$(dirname "${BASH_SOURCE[0]}")/resolve-outdir.sh"
# Prefer the ignore-filtered diff when prefetch.sh produced one — the same
# preference detect-angles.sh uses, so chunks reflect the post-ignore worker view.
if [ -s "$OUTDIR/diff.filtered.txt" ]; then
  DIFF="$OUTDIR/diff.filtered.txt"
else
  DIFF="$OUTDIR/diff.txt"
fi
CFG="$OUTDIR/config.json"

if [ ! -s "$DIFF" ]; then
  echo "chunk-diff: $DIFF missing or empty — nothing to chunk"
  exit 0
fi

MAX_LOC="4000"
if [ -f "$CFG" ]; then
  raw="$(jq -r '.chunking.max_loc // 4000' "$CFG" 2>/dev/null || echo 4000)"
  case "$raw" in
    ''|*[!0-9]*) MAX_LOC="4000" ;;
    *) MAX_LOC="$raw" ;;
  esac
fi

# Always clear any stale chunk artifacts from a prior run — keeps detect-angles
# from picking up ghost chunks when chunking is now disabled or under threshold.
rm -f "$OUTDIR"/chunks.txt "$OUTDIR"/chunks.json "$OUTDIR"/diff.chunk-*.txt 2>/dev/null || true

if [ "$MAX_LOC" -eq 0 ]; then
  echo "chunk-diff: chunking disabled (max_loc=0)"
  exit 0
fi

LOC="$(grep -cE '^[+-][^+-]' "$DIFF" || true)"
if [ "$LOC" -le "$MAX_LOC" ]; then
  echo "chunk-diff: $LOC LOC <= $MAX_LOC threshold — no chunking"
  exit 0
fi

echo "chunk-diff: $LOC LOC > $MAX_LOC threshold — splitting"

python3 - "$DIFF" "$OUTDIR" "$MAX_LOC" <<'PY'
import json
import os
import re
import sys

diff_path, outdir, max_loc_str = sys.argv[1], sys.argv[2], sys.argv[3]
MAX_LOC = int(max_loc_str)

WS_RE = re.compile(r"^(packages|apps|services|libs)/([^/]+)/")

with open(diff_path, "r", errors="replace") as fh:
    text = fh.read()

sections = []
current = None
for line in text.splitlines(keepends=True):
    if line.startswith("diff --git "):
        if current is not None:
            sections.append(current)
        m = re.match(r"diff --git a/(\S+) b/(\S+)", line)
        path = m.group(2) if m else ""
        current = {"path": path, "body": line, "loc": 0}
        continue
    if current is None:
        continue
    current["body"] += line
    stripped = line.rstrip("\n").rstrip("\r")
    if len(stripped) >= 2 and stripped[0] in "+-" and stripped[1] not in "+-":
        current["loc"] += 1
if current is not None:
    sections.append(current)

if not sections:
    print("chunk-diff: no per-file sections parsed; skipping")
    sys.exit(0)

def boundary_for(path):
    m = WS_RE.match(path)
    if m:
        return ("ws", "{}/{}".format(m.group(1), m.group(2)))
    seg = path.split("/", 1)[0] if "/" in path else "."
    return ("td", seg)

groups = {}
for s in sections:
    kind, label = boundary_for(s["path"])
    key = "{}:{}".format(kind, label)
    g = groups.setdefault(key, {"kind": kind, "label": label, "sections": [], "loc": 0})
    g["sections"].append(s)
    g["loc"] += s["loc"]

# First-fit-decreasing bin pack. Within-budget groups try to share a chunk; an
# oversized group gets split by file LOC across sub-chunks (balanced packing).
group_list = sorted(groups.values(), key=lambda g: -g["loc"])
chunks = []

def new_chunk(boundary):
    chunks.append({"sections": [], "loc": 0, "boundary": boundary})
    return chunks[-1]

for g in group_list:
    label_full = "{}:{}".format(g["kind"], g["label"])
    if g["loc"] <= MAX_LOC:
        placed = False
        for c in chunks:
            if c["loc"] + g["loc"] <= MAX_LOC:
                c["sections"].extend(g["sections"])
                c["loc"] += g["loc"]
                if c["boundary"] != label_full:
                    c["boundary"] = "mixed"
                placed = True
                break
        if not placed:
            c = new_chunk(label_full)
            c["sections"].extend(g["sections"])
            c["loc"] += g["loc"]
        continue
    # Oversized group — bin-pack its sections into ceil(loc/max) bins, longest-first.
    n = max(1, (g["loc"] + MAX_LOC - 1) // MAX_LOC)
    bins = [[] for _ in range(n)]
    bin_loc = [0] * n
    for s in sorted(g["sections"], key=lambda s: -s["loc"]):
        idx = min(range(n), key=lambda i: bin_loc[i])
        bins[idx].append(s)
        bin_loc[idx] += s["loc"]
    for i, b in enumerate(bins):
        if not b:
            continue
        c = new_chunk("{}#part{}".format(label_full, i + 1))
        c["sections"].extend(b)
        c["loc"] += sum(s["loc"] for s in b)

# Stable IDs by descending LOC — keeps chunk-0 the heaviest worker.
chunks.sort(key=lambda c: -c["loc"])

manifest = []
ids_lines = []
for i, c in enumerate(chunks):
    cid = "chunk-{}".format(i)
    out_path = os.path.join(outdir, "diff.{}.txt".format(cid))
    with open(out_path, "w") as fh:
        for s in c["sections"]:
            fh.write(s["body"])
            if not s["body"].endswith("\n"):
                fh.write("\n")
    manifest.append({
        "id": cid,
        "files": [s["path"] for s in c["sections"]],
        "loc": c["loc"],
        "diff_path": out_path,
        "boundary": c["boundary"],
    })
    ids_lines.append(cid)

with open(os.path.join(outdir, "chunks.json"), "w") as fh:
    json.dump(manifest, fh, indent=2)
    fh.write("\n")
with open(os.path.join(outdir, "chunks.txt"), "w") as fh:
    for cid in ids_lines:
        fh.write(cid + "\n")

print("chunk-diff: produced {} chunk(s) covering {} file section(s)".format(
    len(chunks), sum(len(c["sections"]) for c in chunks)))
PY
