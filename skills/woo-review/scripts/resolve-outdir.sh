#!/usr/bin/env bash
# Single source of truth for the default OUTDIR.
#
# Sourced (not executed) by every woo-review script. Respect an explicit
# OUTDIR override (host sandbox dirs, the GitHub Action's pin, tests); otherwise
# derive a per-project path so concurrent reviews of different repos on one
# machine do not share — and clobber — the same /tmp/pr-review tree.
#
# Derivation: hash the git toplevel (stable across subdirs of one repo); fall
# back to the current directory when not in a git repo. Two distinct repo roots
# hash to two distinct dirs; the same repo always resolves to the same dir.
#
# NOTE: per-project granularity only. Two concurrent runs of the SAME repo still
# share one dir (rare; accepted). For full per-run isolation, set OUTDIR yourself.
if [ -z "${OUTDIR:-}" ]; then
  _wr_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  _wr_hash="$(printf '%s' "$_wr_root" | { sha1sum 2>/dev/null || shasum; } | cut -c1-12)"
  OUTDIR="/tmp/pr-review-${_wr_hash}"
  unset _wr_root _wr_hash
fi
export OUTDIR
