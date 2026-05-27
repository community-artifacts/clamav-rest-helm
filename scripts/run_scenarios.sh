#!/usr/bin/env bash
# Run the chart against every scenario in tests/scenarios/.
#
# Two phases:
#   1. `helm template` — fast, no cluster needed. Catches schema / template
#      breakage across every supported value combination.
#   2. (Optional) `helm install` against the local minikube — for scenarios
#      listed in $INSTALL_SCENARIOS, install in a unique namespace,
#      `kubectl wait` for the rollout, then `helm uninstall`. Skips
#      automatically if KUBECONFIG isn't set or the API isn't reachable.
#
# Usage:
#     ./scripts/run_scenarios.sh                   # phase 1 only
#     INSTALL_SCENARIOS="01 04" ./scripts/run_scenarios.sh
#     INSTALL_SCENARIOS="all"   ./scripts/run_scenarios.sh
#     SCENARIOS="05 06"         ./scripts/run_scenarios.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
CHART="$REPO/charts/clamav-rest"
SCENARIOS_DIR="$REPO/tests/scenarios"

command -v helm    >/dev/null || { echo "helm not installed"    >&2; exit 1; }
command -v kubectl >/dev/null || { echo "kubectl not installed (phase 1 only needs helm; install kubectl for phase 2)" >&2; }

mapfile -t ALL_SCENARIOS < <(cd "$SCENARIOS_DIR" && ls *.values.yaml 2>/dev/null | sort)
if (( ${#ALL_SCENARIOS[@]} == 0 )); then
  echo "no scenarios in $SCENARIOS_DIR" >&2; exit 1
fi

SCENARIOS_FILTER="${SCENARIOS:-}"
INSTALL_FILTER="${INSTALL_SCENARIOS:-}"

scenario_id()    { basename "$1" | cut -d- -f1; }
scenario_short() { basename "$1" .values.yaml; }

scenario_selected() {
  local id="$1" filter="$2"
  [[ -z "$filter" ]] && return 0
  [[ "$filter" == "all" ]] && return 0
  for token in $filter; do
    [[ "$token" == "$id" ]] && return 0
  done
  return 1
}

is_negative() {
  case "$1" in
    99-must-fail) return 0 ;;
  esac
  return 1
}

PASS=0; FAIL=0; SKIP=0
FAILED_NAMES=()

echo "=================================================================="
echo "Phase 1 — helm template across ${#ALL_SCENARIOS[@]} scenarios"
echo "=================================================================="
for scenario in "${ALL_SCENARIOS[@]}"; do
  id=$(scenario_id "$scenario")
  short=$(scenario_short "$scenario")
  if ! scenario_selected "$id" "$SCENARIOS_FILTER"; then
    printf "  %-50s SKIP (not in SCENARIOS filter)\n" "$short"
    SKIP=$((SKIP + 1))
    continue
  fi
  if is_negative "$short"; then
    if helm template "test-$short" "$CHART" -f "$SCENARIOS_DIR/$scenario" 2>/dev/null 1>/dev/null; then
      printf "  %-50s FAIL (expected template to FAIL, but it succeeded)\n" "$short"
      FAIL=$((FAIL + 1)); FAILED_NAMES+=("$short (negative)")
    else
      printf "  %-50s PASS (template correctly failed)\n" "$short"
      PASS=$((PASS + 1))
    fi
    continue
  fi
  if helm template "test-$short" "$CHART" -f "$SCENARIOS_DIR/$scenario" 2>/tmp/scenario-$id.err 1>/tmp/scenario-$id.out; then
    docs=$(grep -c "^---" "/tmp/scenario-$id.out" || true)
    printf "  %-50s PASS (%d documents)\n" "$short" "$docs"
    PASS=$((PASS + 1))
  else
    printf "  %-50s FAIL\n" "$short"
    sed 's/^/      /' "/tmp/scenario-$id.err" | head -10
    FAIL=$((FAIL + 1)); FAILED_NAMES+=("$short")
  fi
done

if [[ -n "$INSTALL_FILTER" ]]; then
  if [[ -z "${KUBECONFIG:-}" ]]; then
    echo; echo "INSTALL_SCENARIOS is set but KUBECONFIG is not — skipping phase 2."
  elif ! kubectl --request-timeout=5s get nodes >/dev/null 2>&1; then
    echo; echo "KUBECONFIG points at ${KUBECONFIG} but the API is unreachable — skipping phase 2."
  else
    echo
    echo "=================================================================="
    echo "Phase 2 — helm install / wait / uninstall on $(kubectl config current-context)"
    echo "=================================================================="
    for scenario in "${ALL_SCENARIOS[@]}"; do
      id=$(scenario_id "$scenario")
      short=$(scenario_short "$scenario")
      scenario_selected "$id" "$INSTALL_FILTER" || continue
      is_negative "$short" && continue

      ns="clamav-rest-scenario-$id"
      release="t$id"
      printf "  %-50s installing into %s..." "$short" "$ns"
      kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
      if helm install "$release" "$CHART" --namespace "$ns" \
           -f "$SCENARIOS_DIR/$scenario" \
           --wait --timeout 10m \
           >/tmp/install-$id.log 2>&1; then
        echo " installed."
        helm uninstall "$release" -n "$ns" >/dev/null 2>&1 || true
        kubectl delete namespace "$ns" --wait=false >/dev/null 2>&1 || true
        PASS=$((PASS + 1))
      else
        echo " FAILED:"
        tail -20 /tmp/install-$id.log | sed 's/^/      /'
        helm uninstall "$release" -n "$ns" >/dev/null 2>&1 || true
        kubectl delete namespace "$ns" --wait=false >/dev/null 2>&1 || true
        FAIL=$((FAIL + 1)); FAILED_NAMES+=("$short (install)")
      fi
    done
  fi
fi

echo
echo "=================================================================="
printf "Summary: %d pass / %d fail / %d skip\n" "$PASS" "$FAIL" "$SKIP"
if (( ${#FAILED_NAMES[@]} > 0 )); then
  echo "Failed scenarios:"
  printf '  - %s\n' "${FAILED_NAMES[@]}"
fi
echo "=================================================================="
exit $(( FAIL > 0 ? 1 : 0 ))
