#!/usr/bin/env bash
# Compute and apply the chart version bump for a develop → main release PR.
#
# Reads the last released tag (e.g. `clamav-rest-0.3.0`), walks the
# conventional commits since that tag that touched `charts/clamav-rest/`,
# picks the bump level, and writes the result into:
#   - charts/clamav-rest/Chart.yaml#version
#   - charts/clamav-rest/RELEASE-NOTES.md   (insert a `## <new-version>` stub)
#   - charts/clamav-rest/Chart.yaml#annotations.artifacthub.io/changes
#
# Idempotent: running twice with no new commits is a no-op.
#
# Outputs (stdout):
#   BUMP_LEVEL=<none|patch|minor|major>
#   PREVIOUS_VERSION=<x.y.z>
#   NEW_VERSION=<x.y.z>
#   CHANGED=<true|false>
#
# Flags:
#   --level <patch|minor|major>   Force the bump level (used by the
#                                 scheduled / hotfix workflows, which derive
#                                 the level from Bumpy). Changelog entries are
#                                 still regenerated from the commit log.

set -euo pipefail

force_level=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --level)
      force_level="$2"
      case "$force_level" in
        patch|minor|major) ;;
        *) echo "--level must be 'patch', 'minor' or 'major', got: $force_level" >&2; exit 64 ;;
      esac
      shift 2
      ;;
    -h|--help)
      sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2; exit 64
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
CHART_FILE="$REPO/charts/clamav-rest/Chart.yaml"
RELEASE_NOTES="$REPO/charts/clamav-rest/RELEASE-NOTES.md"
TAG_PREFIX="clamav-rest-"

command -v git     >/dev/null || { echo "git not installed"     >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 not installed"  >&2; exit 1; }

cd "$REPO"

# ---- 1. Baseline — last released tag, fall back to current Chart.yaml -----
last_tag=$(git tag --list "${TAG_PREFIX}*" --sort=-v:refname 2>/dev/null | head -1 || true)
if [[ -z "$last_tag" ]]; then
  last_ver=$(awk '/^version:/{print $2; exit}' "$CHART_FILE")
  echo "No release tag found; using current Chart.yaml version $last_ver as baseline." >&2
else
  last_ver=${last_tag#"$TAG_PREFIX"}
fi

if ! [[ "$last_ver" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo "Cannot parse SemVer from $last_ver (tag=$last_tag)" >&2; exit 1
fi
last_major=${BASH_REMATCH[1]}
last_minor=${BASH_REMATCH[2]}
last_patch=${BASH_REMATCH[3]}

# ---- 2. Walk conventional commits since the baseline ----------------------
range="${last_tag:-HEAD}..HEAD"
[[ -z "$last_tag" ]] && range="HEAD"

mapfile -t commit_subjects < <(
  git log --no-merges --pretty=format:'%H%x09%s%x09%b' "$range" -- charts/clamav-rest/ 2>/dev/null \
    | awk -F'\t' '{print $1"\t"$2}'
)

bump_level="none"
declare -a changelog_added=() changelog_fixed=() changelog_changed=()

# Bump-level precedence: none < patch < minor < major.
raise_level() {
  local want="$1"
  case "$bump_level" in
    none)  bump_level="$want" ;;
    patch) [[ "$want" == "minor" || "$want" == "major" ]] && bump_level="$want" ;;
    minor) [[ "$want" == "major" ]] && bump_level="$want" ;;
    major) ;;
  esac
}

classify() {
  local subj="$1"
  local desc
  desc=$(echo "$subj" | sed -E 's/^[a-zA-Z]+(\([^)]+\))?!?:[[:space:]]*//')

  case "$subj" in
    *"BREAKING CHANGE"*|feat!:*|feat\(*\)!:*|fix!:*|fix\(*\)!:*|refactor!:*|chore!:*)
      raise_level "major"
      changelog_changed+=("$desc")
      ;;
    feat:*|feat\(*\):*)
      raise_level "minor"
      changelog_added+=("$desc")
      ;;
    fix:*|fix\(*\):*)
      raise_level "patch"
      changelog_fixed+=("$desc")
      ;;
    refactor:*|refactor\(*\):*|perf:*|perf\(*\):*|chore:*|chore\(*\):*|ci:*|ci\(*\):*|docs:*|docs\(*\):*|test:*|test\(*\):*|style:*|style\(*\):*)
      raise_level "patch"
      changelog_changed+=("$desc")
      ;;
    *)
      raise_level "patch"
      changelog_changed+=("$desc")
      ;;
  esac
}

for line in "${commit_subjects[@]}"; do
  [[ -z "$line" ]] && continue
  IFS=$'\t' read -r _sha subject <<<"$line"
  [[ -z "$subject" ]] && continue
  [[ "$subject" == chore\(release\):* ]] && continue
  classify "$subject"
done

filter_empty() {
  local -n arr=$1
  local -a kept=()
  for x in "${arr[@]}"; do
    [[ -n "$x" ]] && kept+=("$x")
  done
  arr=("${kept[@]}")
}
filter_empty changelog_added
filter_empty changelog_fixed
filter_empty changelog_changed

cap_entries() {
  local -n arr=$1
  if (( ${#arr[@]} > 20 )); then
    arr=("${arr[@]:0:20}")
  fi
}
cap_entries changelog_added
cap_entries changelog_fixed
cap_entries changelog_changed

# ---- 3. Compute target version --------------------------------------------
if [[ -n "$force_level" ]]; then
  bump_level="$force_level"
fi

case "$bump_level" in
  major) new_ver="$((last_major + 1)).0.0" ;;
  minor) new_ver="${last_major}.$((last_minor + 1)).0" ;;
  patch) new_ver="${last_major}.${last_minor}.$((last_patch + 1))" ;;
  none)
    echo "BUMP_LEVEL=none"
    echo "PREVIOUS_VERSION=$last_ver"
    echo "NEW_VERSION=$last_ver"
    echo "CHANGED=false"
    echo "No chart-touching commits since ${last_tag:-baseline}; nothing to bump." >&2
    exit 0
    ;;
esac

current_ver=$(awk '/^version:/{print $2; exit}' "$CHART_FILE")

ver_cmp() {
  local a b
  IFS=. read -ra a <<<"$1"; IFS=. read -ra b <<<"$2"
  for i in 0 1 2; do
    if (( ${a[i]:-0} < ${b[i]:-0} )); then echo -1; return; fi
    if (( ${a[i]:-0} > ${b[i]:-0} )); then echo 1; return; fi
  done
  echo 0
}

if [[ "$(ver_cmp "$new_ver" "$current_ver")" -lt 0 ]]; then
  echo "Computed bump ($new_ver) would downgrade current Chart.yaml ($current_ver); keeping current." >&2
  new_ver="$current_ver"
fi

if [[ "$current_ver" == "$new_ver" ]]; then
  echo "Chart.yaml already at $new_ver; refreshing changelog stubs only." >&2
fi

echo "BUMP_LEVEL=$bump_level"
echo "PREVIOUS_VERSION=$last_ver"
echo "NEW_VERSION=$new_ver"

# ---- 4. Apply the version bump --------------------------------------------
sed -i "s/^version: .*/version: $new_ver/" "$CHART_FILE"

if ! grep -qE "^## ${new_ver}(\b| )" "$RELEASE_NOTES"; then
  python3 - "$RELEASE_NOTES" "$new_ver" <<'PYEOF'
import sys, pathlib, re
path, new_ver = pathlib.Path(sys.argv[1]), sys.argv[2]
text = path.read_text()
heading = f"## {new_ver} (unreleased)\n\n<!-- TODO: replace this stub with the real changelog before merging the PR to main. Bullet style follows the existing entries (Added / Changed / Fixed / Removed). -->\n\n"
m = re.search(r"^## ", text, re.MULTILINE)
if m:
    text = text[:m.start()] + heading + text[m.start():]
else:
    text = text + "\n" + heading
path.write_text(text)
PYEOF
fi

python3 - "$CHART_FILE" "${changelog_added[@]:+--added}" "${changelog_added[@]}" \
                       "${changelog_fixed[@]:+--fixed}" "${changelog_fixed[@]}" \
                       "${changelog_changed[@]:+--changed}" "${changelog_changed[@]}" <<'PYEOF'
import sys, re, pathlib
args = sys.argv[2:]
buckets = {"added": [], "fixed": [], "changed": []}
current = None
for a in args:
    if a == "--added": current = "added"
    elif a == "--fixed": current = "fixed"
    elif a == "--changed": current = "changed"
    elif current is not None: buckets[current].append(a)

def yamlify(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'

lines = ["  artifacthub.io/changes: |"]
for kind in ("added", "changed", "fixed"):
    for desc in buckets[kind]:
        lines.append(f"    - kind: {kind}")
        lines.append(f"      description: {yamlify(desc)}")
if len(lines) == 1:
    lines.append('    - kind: changed')
    lines.append('      description: "Chart version bumped; see RELEASE-NOTES.md for details."')

new_block = "\n".join(lines) + "\n"

chart_path = pathlib.Path(sys.argv[1])
chart = chart_path.read_text()
pattern = re.compile(
    r"^  artifacthub\.io/changes:\s*\|[^\n]*\n(?:    [^\n]*\n)+",
    re.MULTILINE,
)
if pattern.search(chart):
    chart = pattern.sub(new_block, chart, count=1)
else:
    chart = chart.rstrip() + "\n" + new_block
chart_path.write_text(chart)
PYEOF

# ---- 5. Report changed status ---------------------------------------------
changed=false
if ! git diff --quiet -- "$CHART_FILE" "$RELEASE_NOTES"; then
  changed=true
fi
echo "CHANGED=$changed"

{
  echo
  echo "=================================================================="
  echo "Bump:               $bump_level"
  echo "Previous version:   $last_ver  ${last_tag:+(from tag $last_tag)}"
  echo "New version:        $new_ver"
  echo "Commits classified:"
  printf "  added:   %d\n" "${#changelog_added[@]}"
  printf "  fixed:   %d\n" "${#changelog_fixed[@]}"
  printf "  changed: %d\n" "${#changelog_changed[@]}"
  echo "=================================================================="
} >&2
