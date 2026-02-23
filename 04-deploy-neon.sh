#!/usr/bin/env bash
# 04-deploy-neon.sh — Deploy Neon components to EKS.
# Patches manifest placeholders with real values from .env, then applies them.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

log()  { echo "==> [deploy] $*"; }
warn() { echo "==> [deploy] WARNING: $*" >&2; }
die()  { echo "==> [deploy] FATAL: $*" >&2; exit 1; }

# ── AWS credential check ─────────────────────────────────────────────────────
[[ -n "${AWS_ACCESS_KEY_ID:-}" ]]     || die "AWS_ACCESS_KEY_ID is not set"
[[ -n "${AWS_SECRET_ACCESS_KEY:-}" ]] || die "AWS_SECRET_ACCESS_KEY is not set"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-west-2}"

# ── Load .env ─────────────────────────────────────────────────────────────────
[[ -f "${ENV_FILE}" ]] || die ".env file not found. Run 02-create-aws-infra.sh first."
# shellcheck source=/dev/null
source "${ENV_FILE}"

[[ -n "${ECR_REGISTRY:-}" ]]   || die "ECR_REGISTRY not set in .env"
[[ -n "${S3_BUCKET:-}" ]]      || die "S3_BUCKET not set in .env"
[[ -n "${CLUSTER_NAME:-}" ]]   || die "CLUSTER_NAME not set in .env"
[[ -n "${REGION:-}" ]]         || die "REGION not set in .env"
[[ -n "${IAM_POLICY_ARN:-}" ]] || die "IAM_POLICY_ARN not set in .env"

# ── Ensure kubeconfig is current ─────────────────────────────────────────────
log "Updating kubeconfig for cluster '${CLUSTER_NAME}'..."
aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${REGION}"

# ── Helper: apply a manifest with placeholder substitution ────────────────────
apply_manifest() {
    local file="$1"
    sed \
        -e "s|PLACEHOLDER_ECR_REGISTRY|${ECR_REGISTRY}|g" \
        -e "s|PLACEHOLDER_S3_BUCKET|${S3_BUCKET}|g" \
        "${file}" | kubectl apply -f -
}

# ── 1. Namespace ──────────────────────────────────────────────────────────────
log "Creating namespace..."
kubectl apply -f "${SCRIPT_DIR}/manifests/namespace.yaml"

# ── 2. Storage classes ────────────────────────────────────────────────────────
log "Applying storage classes..."
kubectl apply -f "${SCRIPT_DIR}/manifests/storage-classes.yaml"

# ── 3. Storage Broker ────────────────────────────────────────────────────────
log "Deploying storage-broker..."
apply_manifest "${SCRIPT_DIR}/manifests/storage-broker/deployment.yaml"

log "Waiting for storage-broker to be ready..."
kubectl rollout status deployment/storage-broker -n neon --timeout=120s

# ── 4. Safekeepers ───────────────────────────────────────────────────────────
log "Deploying safekeepers (3 replicas)..."
apply_manifest "${SCRIPT_DIR}/manifests/safekeeper/statefulset.yaml"

log "Waiting for safekeepers..."
kubectl rollout status statefulset/safekeeper -n neon --timeout=300s

# ── 5. Pageserver ────────────────────────────────────────────────────────────
log "Deploying pageserver (2 replicas)..."

# Patch the IRSA annotation onto the ServiceAccount
# The manifest defines the SA without the annotation; we add it here from .env
IRSA_ROLE_ARN=$(kubectl get sa pageserver-sa -n neon -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || echo "")
if [[ -z "${IRSA_ROLE_ARN}" ]]; then
    # The SA was already created by eksctl in 02-create-aws-infra.sh with the correct annotation.
    # Just apply the rest of the manifest (ConfigMap, StatefulSet, Service) — skip SA recreation.
    log "ServiceAccount pageserver-sa managed by eksctl; applying remaining resources..."
fi
apply_manifest "${SCRIPT_DIR}/manifests/pageserver/statefulset.yaml"

log "Waiting for pageservers..."
kubectl rollout status statefulset/pageserver -n neon --timeout=300s

# ── 6. Proxy ─────────────────────────────────────────────────────────────────
log "Deploying proxy..."
apply_manifest "${SCRIPT_DIR}/manifests/proxy/deployment.yaml"

log "Waiting for proxy to be ready..."
kubectl rollout status deployment/proxy -n neon --timeout=120s

# ── Summary ───────────────────────────────────────────────────────────────────
log ""
log "Neon deployment complete. Pods:"
kubectl get pods -n neon -o wide
log ""
log "Services:"
kubectl get svc -n neon
log ""

# Show proxy external endpoint if available
PROXY_LB=$(kubectl get svc proxy -n neon -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
if [[ -n "${PROXY_LB}" ]]; then
    log "Proxy external endpoint: ${PROXY_LB}:5432"
else
    log "Proxy LoadBalancer is provisioning — run 'kubectl get svc proxy -n neon' to check."
fi

log ""
log "Verification:"
log "  kubectl get pods -n neon"
log "  kubectl port-forward -n neon svc/pageserver 9898:9898"
log "  curl http://localhost:9898/v1/status"
log ""
log "Done."
