#!/usr/bin/env bash
# Loads .woo-review.yml from the consumer repo root and emits canonical JSON
# to /tmp/pr-review/config.json. Missing file -> empty {} (no regression).
# Invalid YAML or invalid schema -> loud GitHub-style ::error annotation and
# non-zero exit (per issue #11 acceptance bullet 4).
#
# Schema (all keys optional):
#   angles.force        list[str] subset of angle enum
#   angles.skip         list[str] subset of angle enum (bugs/security protected)
#   severity_floor      "low" | "medium" | "high" (case-insensitive)
#   ignore              list[str] (fnmatch globs)
#   project_rules       list[str] (fnmatch globs, relative to repo root)
#   authors_skip        list[str] (GitHub login strings)
#   models.fast         str
#   models.standard     str
#   models.deep         str
#   fix_commands        list[str]  (consumed by issue #15 --loop mode)

set -euo pipefail

OUTDIR="/tmp/pr-review"
mkdir -p "$OUTDIR"

ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
CFG_PATH="$ROOT/.woo-review.yml"

if [ ! -f "$CFG_PATH" ]; then
  echo '{}' > "$OUTDIR/config.json"
  echo "load-config: no .woo-review.yml at $CFG_PATH, using defaults"
  exit 0
fi

# Inline python3 parser. PyYAML ships in the GitHub-hosted runner image and
# on macOS (via the system Python or `pip install pyyaml`). On failure we
# emit `::error file=...,line=...,col=...::<msg>` so the GH annotation links
# straight to the offending line.
python3 - "$CFG_PATH" "$OUTDIR/config.json" <<'PY'
import json
import sys

try:
    import yaml
except ImportError as exc:
    sys.stderr.write(
        "::error file=.woo-review.yml::PyYAML not installed in this environment "
        "(pip install pyyaml). Cannot parse config: {}\n".format(exc)
    )
    sys.exit(2)

src, dst = sys.argv[1], sys.argv[2]

VALID_ANGLES = {"bugs", "security", "conventions", "seo", "aeo", "design", "react", "database"}
VALID_FLOORS = {"low", "medium", "high"}
TOP_KEYS = {
    "angles", "severity_floor", "ignore", "project_rules",
    "authors_skip", "models", "fix_commands",
}
MODEL_TIERS = {"fast", "standard", "deep"}


def loud(msg, mark=None):
    """Emit a GitHub-style error annotation and exit non-zero."""
    if mark is not None:
        line = getattr(mark, "line", 0) + 1
        col = getattr(mark, "column", 0) + 1
        sys.stderr.write(
            "::error file=.woo-review.yml,line={},col={}::{}\n".format(line, col, msg)
        )
    else:
        sys.stderr.write("::error file=.woo-review.yml::{}\n".format(msg))
    sys.exit(1)


def require_list_of_strings(node, key):
    if not isinstance(node, list):
        loud("`{}` must be a list, got {}".format(key, type(node).__name__))
    for i, item in enumerate(node):
        if not isinstance(item, str):
            loud("`{}[{}]` must be a string, got {}".format(key, i, type(item).__name__))


with open(src, "r") as fh:
    text = fh.read()

try:
    raw = yaml.safe_load(text)
except yaml.YAMLError as exc:
    mark = getattr(exc, "problem_mark", None) or getattr(exc, "context_mark", None)
    loud(str(exc).splitlines()[0], mark)

if raw is None:
    # Empty file is equivalent to defaults.
    with open(dst, "w") as fh:
        json.dump({}, fh)
    print("load-config: .woo-review.yml is empty, using defaults")
    sys.exit(0)

if not isinstance(raw, dict):
    loud("top-level YAML must be a mapping, got {}".format(type(raw).__name__))

unknown = sorted(set(raw.keys()) - TOP_KEYS)
if unknown:
    loud("unknown top-level key(s): {}".format(", ".join(unknown)))

out = {}

if "angles" in raw:
    angles = raw["angles"]
    if not isinstance(angles, dict):
        loud("`angles` must be a mapping with `force:` and/or `skip:` keys")
    bad = sorted(set(angles.keys()) - {"force", "skip"})
    if bad:
        loud("unknown angles sub-key(s): {}".format(", ".join(bad)))
    for sub in ("force", "skip"):
        if sub in angles:
            require_list_of_strings(angles[sub], "angles.{}".format(sub))
            bad_angles = [a for a in angles[sub] if a not in VALID_ANGLES]
            if bad_angles:
                loud(
                    "angles.{} contains unknown angle(s): {} (valid: {})".format(
                        sub, ", ".join(bad_angles), ", ".join(sorted(VALID_ANGLES))
                    )
                )
    out["angles"] = {k: list(angles[k]) for k in ("force", "skip") if k in angles}

if "severity_floor" in raw:
    sf = raw["severity_floor"]
    if not isinstance(sf, str):
        loud("`severity_floor` must be a string, got {}".format(type(sf).__name__))
    sf_lc = sf.strip().lower()
    if sf_lc not in VALID_FLOORS:
        loud("`severity_floor` must be one of: {} (got '{}')".format(", ".join(sorted(VALID_FLOORS)), sf))
    out["severity_floor"] = sf_lc

for key in ("ignore", "project_rules", "authors_skip", "fix_commands"):
    if key in raw:
        require_list_of_strings(raw[key], key)
        out[key] = list(raw[key])

if "models" in raw:
    models = raw["models"]
    if not isinstance(models, dict):
        loud("`models` must be a mapping with fast/standard/deep keys")
    bad = sorted(set(models.keys()) - MODEL_TIERS)
    if bad:
        loud("unknown models tier(s): {} (valid: {})".format(", ".join(bad), ", ".join(sorted(MODEL_TIERS))))
    for tier, slug in models.items():
        if not isinstance(slug, str) or not slug.strip():
            loud("models.{} must be a non-empty string".format(tier))
    out["models"] = {k: v.strip() for k, v in models.items()}

with open(dst, "w") as fh:
    json.dump(out, fh, indent=2, sort_keys=True)
    fh.write("\n")

print("load-config: parsed .woo-review.yml -> {} keys: {}".format(len(out), ", ".join(sorted(out.keys())) or "(empty)"))
PY
