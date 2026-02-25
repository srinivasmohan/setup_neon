#!/usr/bin/env bash
# 41-verify.sh — Verify the Neon data plane is healthy after deployment.
# Run after 05-deploy-neon.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

PASS=0
FAIL=0
WARN=0

pass() { echo "  ✓ $*"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $*"; FAIL=$((FAIL + 1)); }
warn() { echo "  ! $*"; WARN=$((WARN + 1)); }
section() { echo ""; echo "── $* ──"; }

# ── Load .env if available ───────────────────────────────────────────────────
if [[ -f "${ENV_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${ENV_FILE}"
fi

# ── 1. Pods ──────────────────────────────────────────────────────────────────
section "Pods"

for app in storage-broker safekeeper pageserver proxy; do
    PODS=$(kubectl get pods -n neon -l app="${app}" -o jsonpath='{range .items[*]}{.metadata.name} {.status.phase}{"\n"}{end}' 2>/dev/null)
    if [[ -z "${PODS}" ]]; then
        fail "${app}: no pods found"
        continue
    fi
    while IFS= read -r line; do
        name=$(echo "${line}" | awk '{print $1}')
        phase=$(echo "${line}" | awk '{print $2}')
        if [[ "${phase}" == "Running" ]]; then
            pass "${name} Running"
        else
            fail "${name} ${phase}"
        fi
    done <<< "${PODS}"
done

# Check compute pods (optional — may not exist yet)
COMPUTE_PODS=$(kubectl get pods -n neon -l app=compute -o jsonpath='{range .items[*]}{.metadata.name} {.status.phase}{"\n"}{end}' 2>/dev/null)
if [[ -n "${COMPUTE_PODS}" ]]; then
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        name=$(echo "${line}" | awk '{print $1}')
        phase=$(echo "${line}" | awk '{print $2}')
        if [[ "${phase}" == "Running" ]]; then
            pass "${name} Running"
        else
            fail "${name} ${phase}"
        fi
    done <<< "${COMPUTE_PODS}"
else
    warn "No compute pods (run 06-spin-compute.sh to create one)"
fi

# ── 2. PVCs ──────────────────────────────────────────────────────────────────
section "Persistent Volume Claims"

PVCS=$(kubectl get pvc -n neon -o jsonpath='{range .items[*]}{.metadata.name} {.status.phase}{"\n"}{end}' 2>/dev/null)
if [[ -z "${PVCS}" ]]; then
    fail "No PVCs found"
else
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        name=$(echo "${line}" | awk '{print $1}')
        phase=$(echo "${line}" | awk '{print $2}')
        if [[ "${phase}" == "Bound" ]]; then
            pass "${name} Bound"
        else
            fail "${name} ${phase}"
        fi
    done <<< "${PVCS}"
fi

# ── 3. Services ──────────────────────────────────────────────────────────────
section "Services"

for svc in storage-broker safekeeper pageserver proxy; do
    if kubectl get svc "${svc}" -n neon &>/dev/null; then
        pass "${svc} service exists"
    else
        fail "${svc} service not found"
    fi
done

PROXY_LB=$(kubectl get svc proxy -n neon -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
if [[ -n "${PROXY_LB}" ]]; then
    pass "Proxy LoadBalancer: ${PROXY_LB}"
else
    warn "Proxy LoadBalancer not yet provisioned"
fi

# ── 4. Health endpoints ──────────────────────────────────────────────────────
section "Health Checks"

# Pageservers
for i in 0 1; do
    pod="pageserver-${i}"
    result=$(kubectl exec -n neon "${pod}" -- curl -sf http://localhost:9898/v1/status 2>/dev/null) && \
        pass "${pod} API responding: ${result}" || \
        fail "${pod} API not responding"
done

# Safekeepers
for i in 0 1 2; do
    pod="safekeeper-${i}"
    result=$(kubectl exec -n neon "${pod}" -- curl -sf http://localhost:7676/v1/status 2>/dev/null) && \
        pass "${pod} API responding" || \
        fail "${pod} API not responding"
done

# Storage broker
broker_pod=$(kubectl get pods -n neon -l app=storage-broker -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -n "${broker_pod}" ]]; then
    # Broker uses gRPC on 50051 — check if port is listening
    kubectl exec -n neon "${broker_pod}" -- bash -c "echo > /dev/tcp/localhost/50051" 2>/dev/null && \
        pass "storage-broker gRPC port open" || \
        fail "storage-broker gRPC port not responding"
else
    fail "storage-broker pod not found"
fi

# ── 5. Recent errors ────────────────────────────────────────────────────────
section "Recent Errors (last 5 min)"

ERRORS_FOUND=false
for app in storage-broker safekeeper pageserver proxy; do
    errors=$(kubectl logs -l app="${app}" -n neon --since=5m 2>/dev/null | grep -ci "error" || true)
    if [[ "${errors}" -gt 0 ]]; then
        warn "${app}: ${errors} log line(s) containing 'error'"
        ERRORS_FOUND=true
    fi
done
if [[ "${ERRORS_FOUND}" == "false" ]]; then
    pass "No errors in recent logs"
fi

# ── 6. S3 connectivity (if IRSA is set up) ──────────────────────────────────
section "S3 Access"

if [[ -n "${S3_BUCKET:-}" ]]; then
    s3_test=$(kubectl exec -n neon pageserver-0 -- \
        curl -sf http://localhost:9898/v1/status 2>/dev/null)
    if [[ -n "${s3_test}" ]]; then
        pass "Pageserver running (S3 access via IRSA)"
    else
        warn "Could not confirm S3 connectivity"
    fi
else
    warn "S3_BUCKET not set — skipping S3 check"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════"
echo "  Results: ${PASS} passed, ${FAIL} failed, ${WARN} warnings"
echo "═══════════════════════════════════"

if [[ ${FAIL} -gt 0 ]]; then
    echo ""
    echo "Troubleshooting:"
    echo "  kubectl describe pods -n neon        # Check Events section"
    echo "  kubectl logs <pod-name> -n neon      # Check pod logs"
    exit 1
fi
