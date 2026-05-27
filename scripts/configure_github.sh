#!/usr/bin/env bash
# Apply the GitHub repo settings + branch protection rules the release
# flow assumes. Idempotent: running twice is a no-op except for tweaks
# you've made in between.
#
# What it does:
#   1. Repo flags
#        - Allow auto-merge (scheduled-release / hotfix-release call
#          `gh pr merge --auto`)
#        - Automatically delete head branches on merge
#        - Keep merge-commit AND squash-merge AND rebase-merge enabled
#        - squash_merge_commit_message=BLANK so `[skip ci]` markers in
#          bot bookkeeping commits don't leak into the squashed merge
#          commit on main and short-circuit Release Charts
#   2. Labels
#        - Create `bot/release` and `hotfix` if they don't exist
#   3. Branch protection on `main`
#        - Require PR (no direct push)
#        - Required status checks = the Validate Chart job names
#          (REQUIRED_CHECKS below — edit if you rename a job)
#        - Require linear history
#        - 1 approving review (set REQUIRED_REVIEWS_MAIN=0 to skip)
#        - No force push, no deletion
#   4. Branch protection on `develop`
#        - Soft: required status checks + no force push + no deletion,
#          but NO PR-required gate (so the bot bump workflows can push).
#          "develop is PR-only" is a social convention — see CONTRIBUTING.md.
#
# Requires: `gh` (authenticated, admin on the repo) + `jq`.
#
# Override knobs via env:
#   REPO=community-artifacts/clamav-rest-helm
#   REQUIRED_REVIEWS_MAIN=1
#   INCLUDE_MINIKUBE_CHECK=false
#   DRY_RUN=false
#
# Usage:
#     gh auth login --scopes 'repo,admin:repo_hook'   (one-time)
#     ./scripts/configure_github.sh
#     INCLUDE_MINIKUBE_CHECK=true ./scripts/configure_github.sh
#     DRY_RUN=true ./scripts/configure_github.sh

set -euo pipefail

# ---- config -----------------------------------------------------------------
REPO="${REPO:-community-artifacts/clamav-rest-helm}"
REQUIRED_REVIEWS_MAIN="${REQUIRED_REVIEWS_MAIN:-1}"
INCLUDE_MINIKUBE_CHECK="${INCLUDE_MINIKUBE_CHECK:-false}"
DRY_RUN="${DRY_RUN:-false}"

# Exact job names emitted by .github/workflows/validate.yml. GitHub's
# required-status-check matching is literal string equality, so any
# rename in validate.yml has to be mirrored here.
REQUIRED_CHECKS=(
  "helm lint"
  "Render scenario matrix (helm template)"
  "values.schema.json well-formed"
  "kubeconform (validate rendered manifests vs Kubernetes API)"
)
if [[ "$INCLUDE_MINIKUBE_CHECK" == "true" ]]; then
  REQUIRED_CHECKS+=("minikube install (representative scenarios)")
fi

# ---- helpers ----------------------------------------------------------------
command -v gh >/dev/null || { echo "gh CLI not installed"   >&2; exit 1; }
command -v jq >/dev/null || { echo "jq not installed"       >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh not authenticated; run 'gh auth login'" >&2; exit 1; }

run() {
  echo "  $ $*"
  if [[ "$DRY_RUN" != "true" ]]; then
    "$@"
  fi
}

contexts_json() {
  printf '%s\n' "${REQUIRED_CHECKS[@]}" | jq -R . | jq -s .
}

echo "============================================================"
echo "Target repo:              $REPO"
echo "Required reviews on main: $REQUIRED_REVIEWS_MAIN"
echo "Gate main on minikube:    $INCLUDE_MINIKUBE_CHECK"
echo "Dry run:                  $DRY_RUN"
echo "============================================================"

# ---- 1. Repo flags ----------------------------------------------------------
echo
echo "==> Repo flags"
run gh api -X PATCH "repos/$REPO" \
  -F allow_auto_merge=true \
  -F delete_branch_on_merge=true \
  -F allow_merge_commit=true \
  -F allow_squash_merge=true \
  -F allow_rebase_merge=true \
  -F squash_merge_commit_message=BLANK \
  -F squash_merge_commit_title=PR_TITLE

# ---- 2. Labels --------------------------------------------------------------
echo
echo "==> Labels"
ensure_label() {
  local name="$1" color="$2" desc="$3"
  if gh api "repos/$REPO/labels/${name//\//%2F}" >/dev/null 2>&1; then
    echo "  · $name exists; leaving as-is."
  else
    run gh api -X POST "repos/$REPO/labels" \
      -f name="$name" -f color="$color" -f description="$desc"
  fi
}
ensure_label "bot/release" "fbca04" "Release PR opened by an automated workflow; version-bump.yml no-ops on it."
ensure_label "hotfix"      "b60205" "Hotfix release — fast-tracked by hotfix-release.yml."

# ---- 3. Branch protection on main ------------------------------------------
echo
echo "==> Branch protection: main"
contexts=$(contexts_json)
main_payload=$(jq -n \
  --argjson contexts "$contexts" \
  --argjson reviews "$REQUIRED_REVIEWS_MAIN" \
  '{
    required_status_checks: { strict: true, contexts: $contexts },
    enforce_admins: false,
    required_pull_request_reviews: (
      if $reviews > 0 then {
        required_approving_review_count: $reviews,
        dismiss_stale_reviews: true,
        require_code_owner_reviews: false
      } else {
        required_approving_review_count: 0,
        dismiss_stale_reviews: false,
        require_code_owner_reviews: false
      } end
    ),
    restrictions: null,
    required_linear_history: true,
    allow_force_pushes: false,
    allow_deletions: false,
    required_conversation_resolution: true,
    block_creations: false
  }'
)
if [[ "$DRY_RUN" == "true" ]]; then
  echo "  $ gh api -X PUT repos/$REPO/branches/main/protection (payload below)"
  echo "$main_payload" | jq .
else
  echo "$main_payload" | gh api -X PUT "repos/$REPO/branches/main/protection" \
    -H "Accept: application/vnd.github+json" --input - >/dev/null
  echo "  · main protection applied."
fi

# ---- 4. Branch protection on develop ---------------------------------------
echo
echo "==> Branch protection: develop"
develop_payload=$(jq -n \
  --argjson contexts "$contexts" \
  '{
    required_status_checks: { strict: false, contexts: $contexts },
    enforce_admins: false,
    required_pull_request_reviews: null,
    restrictions: null,
    required_linear_history: false,
    allow_force_pushes: false,
    allow_deletions: false,
    required_conversation_resolution: false,
    block_creations: false
  }'
)
if [[ "$DRY_RUN" == "true" ]]; then
  echo "  $ gh api -X PUT repos/$REPO/branches/develop/protection (payload below)"
  echo "$develop_payload" | jq .
else
  if ! gh api "repos/$REPO/branches/develop" >/dev/null 2>&1; then
    echo "  · develop branch doesn't exist yet on the remote — skipping. Push it first."
  else
    echo "$develop_payload" | gh api -X PUT "repos/$REPO/branches/develop/protection" \
      -H "Accept: application/vnd.github+json" --input - >/dev/null
    echo "  · develop protection applied (soft: required Validate Chart checks +"
    echo "    no force push + no deletion; PR-required gate left OFF so the bot"
    echo "    workflows can push their bump commits)."
  fi
fi

# ---- 5. Verify --------------------------------------------------------------
if [[ "$DRY_RUN" != "true" ]]; then
  echo
  echo "==> Verification"
  for br in main develop; do
    state=$(gh api "repos/$REPO/branches/$br/protection" 2>/dev/null | jq -r '
      "PR required: \(.required_pull_request_reviews != null)" +
      " | linear history: \(.required_linear_history.enabled // false)" +
      " | force push: \(.allow_force_pushes.enabled // false)" +
      " | required checks: \(.required_status_checks.contexts | length)"
    ' || echo "(not protected)")
    printf "  · %-7s → %s\n" "$br" "$state"
  done
fi

cat <<EOF

============================================================
Done. Remaining manual steps that aren't safe to script blindly:
  - GitHub Pages: enable Pages from the gh-pages branch (Settings →
    Pages, or via API) once the first Release Charts run has created it.
  - To change the default branch to develop (so PRs default-target
    develop), do it in Settings → General → Default branch.
============================================================
EOF
