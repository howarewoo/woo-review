#!/usr/bin/env bash
# resolve-diff-line.sh — given a (file, source_line) pair, validate that the
# line is anchorable on the RIGHT side of the prefetched unified diff. Emits
# the validated RIGHT-side absolute line number to stdout, or the literal
# string `null` (newline-terminated) when the line cannot be resolved.
#
# Rationale: the GitHub Pull Request Review API rejects comments whose `line`
# does not correspond to a `+` (added) or ` ` (context) line on the RIGHT side
# of the diff. Findings posted with raw source-file lines that fall in a
# deletion-only region, or outside any hunk, return HTTP 422 "Line could not
# be resolved." Sub-agents call this helper before writing the `line` field on
# each finding; the merge step also runs a final-pass safety check.
#
# Usage:
#   bash resolve-diff-line.sh --file <path> --line <N> [--diff <path>]
#                              [--cache <path>] [--no-cache]
#
# Exit codes:
#   0  always (success). Output is the resolved line or `null`. Callers
#      branch on the stdout value, not the exit status, so a missing diff
#      file falls through to `null` without spurious failure annotations.
#
# Env / defaults:
#   OUTDIR=/tmp/pr-review
#   --diff defaults to "$OUTDIR/diff.filtered.txt" if present, else "$OUTDIR/diff.txt".
#   --cache defaults to "$OUTDIR/diff-line-cache.json" (a flat map keyed by
#   "<path>:<line>").

set -euo pipefail

# shellcheck source=skills/woo-review/scripts/resolve-outdir.sh
source "$(dirname "${BASH_SOURCE[0]}")/resolve-outdir.sh"
FILE=""
LINE=""
DIFF=""
CACHE=""
USE_CACHE=1

while [ $# -gt 0 ]; do
  case "$1" in
    --file)     FILE="$2"; shift 2 ;;
    --line)     LINE="$2"; shift 2 ;;
    --diff)     DIFF="$2"; shift 2 ;;
    --cache)    CACHE="$2"; shift 2 ;;
    --no-cache) USE_CACHE=0; shift ;;
    -h|--help)
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "::error::resolve-diff-line: unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$FILE" ] || [ -z "$LINE" ]; then
  echo "::error::resolve-diff-line: --file and --line are required" >&2
  exit 2
fi

# Default diff path: ignore-filtered when prefetch produced it, else the raw diff.
if [ -z "$DIFF" ]; then
  if [ -f "$OUTDIR/diff.filtered.txt" ]; then
    DIFF="$OUTDIR/diff.filtered.txt"
  else
    DIFF="$OUTDIR/diff.txt"
  fi
fi
if [ -z "$CACHE" ]; then
  CACHE="$OUTDIR/diff-line-cache.json"
fi

if [ ! -s "$DIFF" ]; then
  echo "null"
  exit 0
fi

# Python core — the bash side is just argv plumbing. Reads the cache, looks up
# (file, line), parses unified hunks on miss, writes the cache atomically.
python3 - "$FILE" "$LINE" "$DIFF" "$CACHE" "$USE_CACHE" <<'PY'
import json
import os
import re
import sys
import tempfile

file_arg, line_arg, diff_path, cache_path, use_cache_flag = sys.argv[1:6]
use_cache = use_cache_flag == "1"

# Defensive parse: LLMs occasionally emit decimal-string lines like "42.0".
try:
    target_line = int(str(line_arg).strip())
except (TypeError, ValueError):
    print("null")
    sys.exit(0)

if target_line <= 0:
    print("null")
    sys.exit(0)

cache_key = f"{file_arg}:{target_line}"
cache = {}
if use_cache and os.path.exists(cache_path):
    try:
        with open(cache_path, "r") as fh:
            cache = json.load(fh) or {}
    except (json.JSONDecodeError, OSError):
        cache = {}
    if cache_key in cache:
        print(cache[cache_key])
        sys.exit(0)


def emit(result):
    out = "null" if result is None else str(result)
    if use_cache:
        cache[cache_key] = out
        # Atomic write: tempfile in the same dir + rename. Avoids torn writes
        # when two angle workers race to memoize the same lookup.
        cache_dir = os.path.dirname(cache_path) or "."
        try:
            os.makedirs(cache_dir, exist_ok=True)
            fd, tmp = tempfile.mkstemp(prefix=".diff-line-cache.", dir=cache_dir)
            with os.fdopen(fd, "w") as fh:
                json.dump(cache, fh)
            os.replace(tmp, cache_path)
        except OSError:
            pass
    print(out)
    sys.exit(0)


# Parse unified diff. Track the RIGHT-side (post-patch) line counter per file.
# A line resolves only when target_line falls on a `+` (added) or ` ` (context)
# line within a hunk for the requested file. Deletion-only regions and
# out-of-hunk lines yield None.
file_header_re = re.compile(r"^diff --git a/(?P<a>.+?) b/(?P<b>.+?)$")
hunk_header_re = re.compile(r"^@@ -\d+(?:,\d+)? \+(?P<new_start>\d+)(?:,\d+)? @@")

current_file = None
right_line = None
in_target = False
resolved = None

try:
    with open(diff_path, "r", errors="replace") as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            m = file_header_re.match(line)
            if m:
                current_file = m.group("b")
                in_target = current_file == file_arg
                right_line = None
                continue
            # Per-file metadata lines we skip silently.
            if line.startswith("--- ") or line.startswith("+++ "):
                continue
            if not in_target:
                continue
            m = hunk_header_re.match(line)
            if m:
                right_line = int(m.group("new_start"))
                continue
            if right_line is None:
                continue
            # Hunk body classifier. `\` introduces "No newline at end of file"
            # metadata — does not advance the counter on either side.
            head = line[:1]
            if head == "+":
                if right_line == target_line:
                    resolved = right_line
                    break
                right_line += 1
            elif head == " ":
                if right_line == target_line:
                    resolved = right_line
                    break
                right_line += 1
            elif head == "-":
                # Deletion-only — RIGHT counter does not advance. A target_line
                # falling here cannot be anchored on RIGHT and stays unresolved.
                continue
            elif head == "\\":
                continue
            else:
                # Stray context (rare; non-hunk body line). Bail this hunk.
                right_line = None
except OSError:
    emit(None)

emit(resolved)
PY
