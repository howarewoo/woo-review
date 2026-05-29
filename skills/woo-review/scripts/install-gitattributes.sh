#!/usr/bin/env bash
# install-gitattributes.sh
#
# Idempotently ensures `.gitattributes` (in cwd) carries the merge=union rule
# for the sharded sidecar files. Pre-existing content is preserved.
#
# Called by sidecar-write.sh on first write. Safe to invoke on every write —
# the grep-guard makes repeats a no-op.

set -euo pipefail

LINE='.woo-review/dismissed-*.jsonl merge=union'

if [ -f .gitattributes ] && grep -qxF "$LINE" .gitattributes; then
  exit 0
fi

# Ensure the new line starts on its own line, even if the existing file lacks a
# trailing newline. `[ -s ]` is false for both missing and empty files.
if [ -s .gitattributes ] && [ "$(tail -c 1 .gitattributes | wc -l | tr -d ' ')" -eq 0 ]; then
  printf '\n' >> .gitattributes
fi

printf '%s\n' "$LINE" >> .gitattributes
