#!/usr/bin/env bash
# 06-teardown-compute.sh — Tear down one or all compute pods.
#
# Usage:
#   ./06-teardown-compute.sh compute-a1b2c3d4     # Tear down a specific compute
#   ./06-teardown-compute.sh --all                 # Tear down ALL compute pods
#   ./06-teardown-compute.sh --list                # List running compute pods
set -euo pipefail

log()  { echo "==> [compute-teardown] $*"; }
die()  { echo "==> [compute-teardown] FATAL: $*" >&2; exit 1; }

usage() {
    echo "Usage:"
    echo "  $0 <compute-id>    Tear down a specific compute (pod + service + configmap)"
    echo "  $0 --all           Tear down ALL compute pods"
    echo "  $0 --list          List running compute pods"
    exit 1
}

[[ $# -ge 1 ]] || usage

# ── List mode ────────────────────────────────────────────────────────────────
if [[ "$1" == "--list" ]]; then
    log "Compute pods in namespace 'neon':"
    kubectl get pods -n neon -l app=compute \
        -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,AGE:.metadata.creationTimestamp,TENANT:.metadata.labels.tenant' \
        2>/dev/null || log "  (none found)"
    echo ""
    log "Compute services:"
    kubectl get svc -n neon -l app=compute \
        -o custom-columns='NAME:.metadata.name,CLUSTER-IP:.spec.clusterIP,PORT:.spec.ports[0].port' \
        2>/dev/null || log "  (none found)"
    exit 0
fi

# ── Tear down all ────────────────────────────────────────────────────────────
if [[ "$1" == "--all" ]]; then
    PODS=$(kubectl get pods -n neon -l app=compute -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    if [[ -z "${PODS}" ]]; then
        log "No compute pods found."
        exit 0
    fi

    log "Found compute pods: ${PODS}"
    read -r -p "==> [compute-teardown] Delete ALL compute pods, services, and configmaps? [y/N] " confirm
    [[ "${confirm}" =~ ^[Yy]$ ]] || { log "Aborted."; exit 0; }

    for pod in ${PODS}; do
        log "Deleting ${pod}..."
        kubectl delete pod/"${pod}" svc/"${pod}" configmap/"${pod}-spec" -n neon --ignore-not-found
    done
    log "All compute resources deleted."
    exit 0
fi

# ── Tear down specific compute ───────────────────────────────────────────────
COMPUTE_ID="$1"

if ! kubectl get pod "${COMPUTE_ID}" -n neon &>/dev/null; then
    die "Pod '${COMPUTE_ID}' not found in namespace 'neon'."
fi

log "Tearing down compute: ${COMPUTE_ID}"
kubectl delete pod/"${COMPUTE_ID}" svc/"${COMPUTE_ID}" configmap/"${COMPUTE_ID}-spec" \
    -n neon --ignore-not-found

log "Done. Tenant/timeline data remains on pageserver — only the compute pod was removed."
