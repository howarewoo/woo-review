#!/usr/bin/env bash
# metrics-fold.sh — fold one run's per-angle metrics into the consumer repo's
# rolling aggregate (issue #41). LOCAL ONLY: invoked by SKILL.md Stage 6.5.
#
# Reads:
#   $OUTDIR/config.json             resolved config; .metrics gates this step
#   $OUTDIR/findings.metrics.json   per-run per-angle record (intersect-findings.sh)
#   <repo>/.woo-review/metrics.json  existing rolling aggregate (optional)
# Writes:
#   <repo>/.woo-review/metrics.json  updated running totals (per-clone, gitignored)
#   <repo>/.gitignore                appends `.woo-review/metrics.json` if absent
#
# No-op (exit 0) when metrics is off or the per-run record is missing/empty.
set -euo pipefail

# shellcheck source=skills/woo-review/scripts/resolve-outdir.sh
source "$(dirname "${BASH_SOURCE[0]}")/resolve-outdir.sh"
CONFIG="$OUTDIR/config.json"
PER_RUN="$OUTDIR/findings.metrics.json"
ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
ROLLING="$ROOT/.woo-review/metrics.json"
GITIGNORE="$ROOT/.gitignore"
SCHEMA_VERSION=1

# Gate: metrics opt-in (default off).
metrics_enabled="false"
if [ -f "$CONFIG" ]; then
  v="$(jq -r '.metrics // false' "$CONFIG" 2>/dev/null || echo false)"
  case "$v" in true) metrics_enabled="true" ;; esac
fi
if [ "$metrics_enabled" != "true" ]; then
  echo "metrics-fold: metrics disabled in config, skipping"
  exit 0
fi

if [ ! -s "$PER_RUN" ]; then
  echo "metrics-fold: no $PER_RUN, skipping"
  exit 0
fi

mkdir -p "$ROOT/.woo-review"

# Ensure the rolling file is gitignored (per-clone local data, never committed).
if ! { [ -f "$GITIGNORE" ] && grep -qxF '.woo-review/metrics.json' "$GITIGNORE"; }; then
  printf '%s\n' '.woo-review/metrics.json' >> "$GITIGNORE"
  echo "metrics-fold: added .woo-review/metrics.json to .gitignore"
fi

python3 - "$PER_RUN" "$ROLLING" "$SCHEMA_VERSION" <<'PY'
import json, os, sys

per_run_p, rolling_p, schema_version = sys.argv[1], sys.argv[2], int(sys.argv[3])

with open(per_run_p) as fh:
    run = json.load(fh)

def fresh():
    return {"schema_version": schema_version, "runs": 0, "angles": {}}

def backup(path):
    try:
        os.replace(path, path + ".bak")
    except OSError:
        pass

agg = fresh()
try:
    with open(rolling_p) as fh:
        existing = json.load(fh)
    ok = (isinstance(existing, dict)
          and existing.get("schema_version") == schema_version
          and isinstance(existing.get("angles"), dict)
          and isinstance(existing.get("runs"), int))
    if ok:
        agg = existing
    else:
        backup(rolling_p)
        sys.stderr.write("metrics-fold: aggregate unreadable/old version — backed up to .bak, reseeding\n")
except FileNotFoundError:
    pass
except (ValueError, OSError):
    backup(rolling_p)
    sys.stderr.write("metrics-fold: aggregate corrupt — backed up to .bak, reseeding\n")

SEVS = ("HIGH", "MEDIUM", "LOW")

def num(v):
    return v if isinstance(v, int) else 0

agg["schema_version"] = schema_version
agg["runs"] = num(agg.get("runs")) + 1

for angle, rec in (run.get("angles") or {}).items():
    slot = agg["angles"].setdefault(angle, {
        "runs_present": 0,
        "raw_total": 0,
        "kept_total": 0,
        "dropped_by_defender_total": 0,
        "dropped_by_prosecutor_total": 0,
        "blocking_total": 0,
        "severity_total": {s: 0 for s in SEVS},
    })
    slot["runs_present"] += 1
    slot["raw_total"]  += num(rec.get("raw_count"))
    slot["kept_total"] += num(rec.get("kept"))
    slot["dropped_by_defender_total"]   += num(rec.get("dropped_by_defender"))
    slot["dropped_by_prosecutor_total"] += num(rec.get("dropped_by_prosecutor"))
    slot["blocking_total"] += num(rec.get("blocking_count"))
    sev = rec.get("severity") or {}
    for s in SEVS:
        slot["severity_total"][s] += num(sev.get(s))

# Atomic write: a mid-write crash leaves the prior aggregate intact rather
# than a truncated file (the reseed path would recover either way, but this
# avoids losing accumulated history to a single interrupted run).
tmp_p = rolling_p + ".tmp"
with open(tmp_p, "w") as fh:
    json.dump(agg, fh, indent=2, sort_keys=True)
    fh.write("\n")
os.replace(tmp_p, rolling_p)

print("metrics-fold: folded run -> {} ({} runs total)".format(rolling_p, agg["runs"]))
PY
