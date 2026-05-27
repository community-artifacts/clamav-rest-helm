#!/usr/bin/env bash
# Decide the next chart bump level from the *quantity* of change since the
# last major-version baseline, following the "Bumpy" SemVer strategy.
#
# Algorithm (in order):
#   1. Find the baseline = last `clamav-rest-<MAJOR>.0.0` tag. If none,
#      fall back to the chart's first commit.
#   2. Measure baseline_size = non-blank lines under `charts/clamav-rest/`
#      at the baseline (excluding Chart.lock and vendored subcharts/).
#   3. Diff `<baseline>..HEAD` over the same path filter; collect
#      added / removed line counts.
#   4. net%   = (added - removed) / baseline_size * 100
#      churn% = (added + removed) / baseline_size * 100.
#   5. Thresholds:
#        - High churn (> 10%) AND low net (< 5%) → PATCH (refactor).
#        - Net ≥ 15%  → MAJOR.
#        - Net ≥ 5%   → MINOR.
#        - else       → PATCH.
#   6. A `BREAKING CHANGE:` marker in any commit message raises the floor
#      to MAJOR.
#
# Unlike the n8n chart, clamav-rest's appVersion tracks a rolling image
# (`latest`), so there is no upstream binary MAJOR to pin to — MAJOR bumps
# are NOT capped here.
#
# Output (stdout, machine-parseable):
#   LEVEL=<patch|minor|major>
#   NET_PCT=<x.xx>
#   CHURN_PCT=<x.xx>
#   ADDED=<n>
#   REMOVED=<n>
#   BASELINE=<tag-or-sha>
#   BASELINE_SIZE=<lines>
#   BREAKING=<true|false>
#
# Flags:
#   --range <REV>..<REV>   Override the diff range (default: baseline..HEAD).
#   --json                 Emit the result as a single-line JSON object.

set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO"

CHART_DIR="charts/clamav-rest"

range_override=""
emit_json=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --range) range_override="$2"; shift 2 ;;
    --json)  emit_json=true; shift ;;
    -h|--help)
      sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 64 ;;
  esac
done

# --- 1. Baseline -------------------------------------------------------------
baseline=$(git tag --list 'clamav-rest-*.0.0' --sort=-v:refname | head -1 || true)
if [[ -z "$baseline" ]]; then
  baseline=$(git rev-list --reverse HEAD -- "$CHART_DIR" | head -1 || git rev-list --reverse HEAD | head -1)
fi
if [[ -z "$baseline" ]]; then
  echo "Cannot determine baseline (no clamav-rest-*.0.0 tag and no chart history)." >&2
  exit 1
fi

# --- 2. Baseline size --------------------------------------------------------
EXCLUDE_REGEX='(charts/clamav-rest/Chart\.lock$|charts/clamav-rest/charts/)'

count_lines_at() {
  local ref="$1"
  local files
  files=$(git ls-tree -r --name-only "$ref" -- "$CHART_DIR" 2>/dev/null \
            | grep -vE "$EXCLUDE_REGEX" || true)
  [[ -z "$files" ]] && { echo 0; return; }
  local total=0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    n=$(git show "$ref:$f" 2>/dev/null | grep -cE '^[[:space:]]*[^[:space:]]' || true)
    total=$((total + n))
  done <<< "$files"
  echo "$total"
}
baseline_size=$(count_lines_at "$baseline")
if (( baseline_size == 0 )); then
  baseline_size=1
fi

# --- 3. Diff range -----------------------------------------------------------
range="${range_override:-${baseline}..HEAD}"

DIFF_EXCLUDES=(
  ':!charts/clamav-rest/Chart.lock'
  ':!charts/clamav-rest/charts'
)

diff_stat=$(git diff --shortstat "$range" -- "$CHART_DIR" "${DIFF_EXCLUDES[@]}" 2>/dev/null || true)
added=$(  printf '%s\n' "$diff_stat" | grep -oE '[0-9]+ insertions?' | grep -oE '[0-9]+' || echo 0)
removed=$(printf '%s\n' "$diff_stat" | grep -oE '[0-9]+ deletions?'  | grep -oE '[0-9]+' || echo 0)
added=${added:-0}
removed=${removed:-0}

# --- 4. Percentages ----------------------------------------------------------
net_pct=$(awk -v a="$added" -v r="$removed" -v b="$baseline_size" 'BEGIN{ printf "%.2f", (a - r) / b * 100 }')
churn_pct=$(awk -v a="$added" -v r="$removed" -v b="$baseline_size" 'BEGIN{ printf "%.2f", (a + r) / b * 100 }')

ge() { awk -v x="$1" -v y="$2" 'BEGIN{ exit (x+0 >= y+0) ? 0 : 1 }'; }
lt() { awk -v x="$1" -v y="$2" 'BEGIN{ exit (x+0 <  y+0) ? 0 : 1 }'; }

# --- 5. Detect breaking-change marker ---------------------------------------
breaking="false"
if git log --format=%B "$range" -- "$CHART_DIR" 2>/dev/null | grep -qE '^BREAKING CHANGE:'; then
  breaking="true"
fi

# --- 6. Decide ---------------------------------------------------------------
level="patch"
if ge "$churn_pct" 10 && lt "$net_pct" 5; then
  level="patch"
elif [[ "$breaking" == "true" ]]; then
  level="major"
elif ge "$net_pct" 15; then
  level="major"
elif ge "$net_pct" 5; then
  level="minor"
fi

# --- 7. Emit -----------------------------------------------------------------
if $emit_json; then
  printf '{"level":"%s","net_pct":%s,"churn_pct":%s,"added":%d,"removed":%d,"baseline":"%s","baseline_size":%d,"breaking":%s}\n' \
    "$level" "$net_pct" "$churn_pct" "$added" "$removed" "$baseline" "$baseline_size" "$breaking"
else
  cat <<EOF
LEVEL=$level
NET_PCT=$net_pct
CHURN_PCT=$churn_pct
ADDED=$added
REMOVED=$removed
BASELINE=$baseline
BASELINE_SIZE=$baseline_size
BREAKING=$breaking
EOF
fi

{
  echo "=================================================================="
  echo "Bumpy decision:        ${level}"
  echo "Baseline:              $baseline ($baseline_size lines under $CHART_DIR)"
  echo "Range:                 $range"
  echo "Added / removed lines: $added / $removed"
  printf "Net change %%:          %s%%\n"   "$net_pct"
  printf "Churn %%:               %s%%\n"   "$churn_pct"
  echo "Thresholds:            patch < 5%% ≤ minor < 15%% ≤ major;"
  echo "                       refactor override: churn > 10%% AND net < 5%% → patch."
  echo "=================================================================="
} >&2
