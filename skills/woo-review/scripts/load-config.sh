#!/usr/bin/env bash
# Loads .woo-review/config.yml from the consumer repo and emits canonical JSON
# to /tmp/pr-review/config.json. Missing file -> defaults (severity_floor=high).
# Invalid YAML or invalid schema -> loud GitHub-style ::error annotation and
# non-zero exit (per issue #11 acceptance bullet 4).
#
# Noise control: severity_floor defaults to "high" so only high-priority
# findings surface unless the consumer widens it (low | medium) in config.yml.
#
# Schema (all keys optional):
#   angles.force        list[str] subset of angle enum
#   angles.skip         list[str] subset of angle enum (bugs/security protected)
#   severity_floor      "low" | "medium" | "high" (case-insensitive)
#   ignore              list[str] (fnmatch globs)
#   project_rules       list[str] (fnmatch globs, relative to repo root)
#   authors_skip        list[str] (GitHub login strings; absent => default
#                                  [dependabot[bot], renovate[bot],
#                                  github-actions[bot]] applied at use-site
#                                  in prefetch.sh — explicit empty list opts
#                                  out)
#   release_rollup_pattern str    (Python regex; matched against PR title to
#                                  short-circuit mechanical release / rollup
#                                  PRs. Absent => default
#                                  `^(staging|release|chore\(release\))`
#                                  applied at use-site. Empty string opts
#                                  out entirely.)
#   models.fast         str
#   models.standard     str
#   models.deep         str
#   fix_commands        list[str]  (consumed by issue #15 --loop mode)
#   disable_adversarial bool       (cost-sensitive opt-out for issue #13's
#                                   prosecutor+defender pipeline; default false)
#   chunking.max_loc    int >= 0   (issue #14: diff split threshold; 0 disables
#                                   chunking entirely; absent => 4000 default
#                                   applied by chunk-diff.sh)

set -euo pipefail

OUTDIR="${OUTDIR:-/tmp/pr-review}"
mkdir -p "$OUTDIR"

ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
CFG_PATH="$ROOT/.woo-review/config.yml"

if [ ! -f "$CFG_PATH" ]; then
  echo '{"severity_floor":"high"}' > "$OUTDIR/config.json"
  echo "load-config: no .woo-review/config.yml at $CFG_PATH, using defaults (severity_floor=high)"
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
        "::error file=.woo-review/config.yml::PyYAML not installed in this environment "
        "(pip install pyyaml). Cannot parse config: {}\n".format(exc)
    )
    sys.exit(2)

src, dst = sys.argv[1], sys.argv[2]

VALID_ANGLES = {"bugs", "security", "conventions", "seo", "aeo", "design", "react", "database"}
VALID_FLOORS = {"low", "medium", "high"}
TOP_KEYS = {
    "angles", "severity_floor", "ignore", "project_rules",
    "authors_skip", "release_rollup_pattern", "models", "fix_commands",
    "disable_adversarial", "chunking",
}
MODEL_TIERS = {"fast", "standard", "deep"}


def loud(msg, mark=None):
    """Emit a GitHub-style error annotation and exit non-zero."""
    if mark is not None:
        line = getattr(mark, "line", 0) + 1
        col = getattr(mark, "column", 0) + 1
        sys.stderr.write(
            "::error file=.woo-review/config.yml,line={},col={}::{}\n".format(line, col, msg)
        )
    else:
        sys.stderr.write("::error file=.woo-review/config.yml::{}\n".format(msg))
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
        json.dump({"severity_floor": "high"}, fh)
    print("load-config: .woo-review/config.yml is empty, using defaults (severity_floor=high)")
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

if "release_rollup_pattern" in raw:
    pat = raw["release_rollup_pattern"]
    if not isinstance(pat, str):
        loud("`release_rollup_pattern` must be a string, got {}".format(type(pat).__name__))
    # Empty string is valid — explicit opt-out of the rollup-pattern check.
    if pat:
        import re as _re
        try:
            _re.compile(pat)
        except _re.error as exc:
            loud("`release_rollup_pattern` is not a valid regex: {}".format(exc))
    out["release_rollup_pattern"] = pat

if "disable_adversarial" in raw:
    val = raw["disable_adversarial"]
    if not isinstance(val, bool):
        loud("`disable_adversarial` must be a boolean (true/false), got {}".format(type(val).__name__))
    out["disable_adversarial"] = val

if "chunking" in raw:
    chunking = raw["chunking"]
    if not isinstance(chunking, dict):
        loud("`chunking` must be a mapping with `max_loc:` key")
    bad = sorted(set(chunking.keys()) - {"max_loc"})
    if bad:
        loud("unknown chunking sub-key(s): {} (valid: max_loc)".format(", ".join(bad)))
    if "max_loc" in chunking:
        v = chunking["max_loc"]
        if isinstance(v, bool) or not isinstance(v, int):
            loud("`chunking.max_loc` must be an integer, got {}".format(type(v).__name__))
        if v < 0:
            loud("`chunking.max_loc` must be >= 0 (got {})".format(v))
        out["chunking"] = {"max_loc": v}

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

# Noise control default: only high-priority findings surface unless the
# consumer explicitly widens the floor in config.yml.
out.setdefault("severity_floor", "high")

with open(dst, "w") as fh:
    json.dump(out, fh, indent=2, sort_keys=True)
    fh.write("\n")

print("load-config: parsed .woo-review/config.yml -> {} keys: {}".format(len(out), ", ".join(sorted(out.keys())) or "(empty)"))
PY
