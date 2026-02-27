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

# Storage backend: "aws-s3" (default) or "minio"
STORAGE_BACKEND="${STORAGE_BACKEND:-aws-s3}"

[[ -n "${ECR_REGISTRY:-}" ]]   || die "ECR_REGISTRY not set in .env"
[[ -n "${CLUSTER_NAME:-}" ]]   || die "CLUSTER_NAME not set in .env"
[[ -n "${REGION:-}" ]]         || die "REGION not set in .env"

if [[ "${STORAGE_BACKEND}" == "aws-s3" ]]; then
    [[ -n "${S3_BUCKET:-}" ]]      || die "S3_BUCKET not set in .env"
    [[ -n "${IAM_POLICY_ARN:-}" ]] || die "IAM_POLICY_ARN not set in .env"
else
    S3_BUCKET="minio-s3-neon-pageserver"
fi

log "Storage backend: ${STORAGE_BACKEND}"

# ── Ensure kubeconfig is current ─────────────────────────────────────────────
log "Updating kubeconfig for cluster '${CLUSTER_NAME}'..."
aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${REGION}"

# ── Helper: apply a manifest with placeholder substitution ────────────────────
apply_manifest() {
    local file="$1"
    local extra_sed=()
    if [[ "${STORAGE_BACKEND}" == "minio" ]]; then
        extra_sed=(-e 's|PLACEHOLDER_REMOTE_STORAGE_EXTRA|endpoint = "http://minio.neon.svc.cluster.local:9000"|')
    else
        extra_sed=(-e '/PLACEHOLDER_REMOTE_STORAGE_EXTRA/d')
    fi
    sed \
        -e "s|PLACEHOLDER_ECR_REGISTRY|${ECR_REGISTRY}|g" \
        -e "s|PLACEHOLDER_S3_BUCKET|${S3_BUCKET}|g" \
        "${extra_sed[@]}" \
        "${file}" | kubectl apply -f -
}

# ── 1. Namespace ──────────────────────────────────────────────────────────────
log "Creating namespace..."
kubectl apply -f "${SCRIPT_DIR}/manifests/namespace.yaml"

# ── 2. Storage classes ────────────────────────────────────────────────────────
log "Applying storage classes..."
kubectl apply -f "${SCRIPT_DIR}/manifests/storage-classes.yaml"

# ── 2b. MinIO (if STORAGE_BACKEND=minio) ─────────────────────────────────────
if [[ "${STORAGE_BACKEND}" == "minio" ]]; then
    log "Deploying MinIO..."
    kubectl apply -f "${SCRIPT_DIR}/manifests/minio/statefulset.yaml"

    log "Waiting for MinIO to be ready..."
    kubectl rollout status statefulset/minio -n neon --timeout=120s

    log "Creating MinIO bucket '${S3_BUCKET}'..."
    kubectl run minio-init --rm --restart=Never -i \
        --image=minio/mc --namespace=neon \
        --command -- sh -c "mc alias set local http://minio:9000 minioadmin minioadmin && mc mb --ignore-existing local/${S3_BUCKET}" \
        || warn "MinIO bucket creation returned an error (may already exist)"
    log "MinIO ready."
fi

# ── 3. CNPG Operator ────────────────────────────────────────────────────────
CNPG_VERSION="1.25.1"
CNPG_RELEASE_URL="https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.25/releases/cnpg-${CNPG_VERSION}.yaml"

log "Installing CloudNativePG operator v${CNPG_VERSION}..."
kubectl apply --server-side -f "${CNPG_RELEASE_URL}"

log "Waiting for CNPG controller-manager to be ready..."
kubectl rollout status deployment/cnpg-controller-manager -n cnpg-system --timeout=120s

# ── 4. CNPG PostgreSQL Cluster ──────────────────────────────────────────────
log "Deploying CNPG PostgreSQL cluster for storage controller..."
kubectl apply -f "${SCRIPT_DIR}/manifests/cnpg/cluster.yaml"

log "Waiting for CNPG cluster to reach 3/3 ready instances (up to 5 min)..."
CNPG_TIMEOUT=300
CNPG_INTERVAL=10
CNPG_ELAPSED=0
while true; do
    READY=$(kubectl get cluster storage-controller-pg-cluster -n neon \
        -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo "0")
    if [[ "${READY}" == "3" ]]; then
        log "CNPG cluster ready (${READY}/3 instances)."
        break
    fi
    if (( CNPG_ELAPSED >= CNPG_TIMEOUT )); then
        die "CNPG cluster not ready after ${CNPG_TIMEOUT}s (${READY}/3 instances)."
    fi
    log "  CNPG cluster: ${READY}/3 ready — waiting ${CNPG_INTERVAL}s..."
    sleep "${CNPG_INTERVAL}"
    (( CNPG_ELAPSED += CNPG_INTERVAL ))
done

# ── 5. Storage Controller ──────────────────────────────────────────────────
log "Deploying storage-controller..."
apply_manifest "${SCRIPT_DIR}/manifests/storage-controller/deployment.yaml"

log "Waiting for storage-controller to be ready..."
kubectl rollout status deployment/storage-controller -n neon --timeout=120s

# ── 6. Storage Broker ────────────────────────────────────────────────────────
log "Deploying storage-broker..."
apply_manifest "${SCRIPT_DIR}/manifests/storage-broker/deployment.yaml"

log "Waiting for storage-broker to be ready..."
kubectl rollout status deployment/storage-broker -n neon --timeout=120s

# ── 7. Safekeepers ───────────────────────────────────────────────────────────
log "Deploying safekeepers (3 replicas)..."
apply_manifest "${SCRIPT_DIR}/manifests/safekeeper/statefulset.yaml"

log "Waiting for safekeepers..."
kubectl rollout status statefulset/safekeeper -n neon --timeout=300s

# ── 8. Pageserver ────────────────────────────────────────────────────────────
log "Deploying pageserver (2 replicas)..."

if [[ "${STORAGE_BACKEND}" == "aws-s3" ]]; then
    # Patch the IRSA annotation onto the ServiceAccount
    # The manifest defines the SA without the annotation; we add it here from .env
    IRSA_ROLE_ARN=$(kubectl get sa pageserver-sa -n neon -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || echo "")
    if [[ -z "${IRSA_ROLE_ARN}" ]]; then
        # The SA was already created by eksctl in 02-create-aws-infra.sh with the correct annotation.
        # Just apply the rest of the manifest (ConfigMap, StatefulSet, Service) — skip SA recreation.
        log "ServiceAccount pageserver-sa managed by eksctl; applying remaining resources..."
    fi
else
    log "MinIO mode — pageserver gets S3 credentials from minio-credentials Secret."
fi
apply_manifest "${SCRIPT_DIR}/manifests/pageserver/statefulset.yaml"

log "Waiting for pageservers..."
kubectl rollout status statefulset/pageserver -n neon --timeout=300s

# ── 8b. Register pageserver nodes with storage controller ────────────────────
log "Registering pageserver nodes with storage controller..."
STORCON_URL="http://storage-controller.neon.svc.cluster.local:1234"
REPLICAS=$(kubectl get statefulset pageserver -n neon -o jsonpath='{.spec.replicas}')
for (( i=0; i<REPLICAS; i++ )); do
    PS_ID=$(( i + 1 ))
    PS_HOST="pageserver-${i}.pageserver.neon.svc.cluster.local"
    log "  Registering node ${PS_ID} (${PS_HOST})..."
    kubectl exec -n neon pageserver-0 -- \
        curl -sf -X POST "${STORCON_URL}/control/v1/node" \
            -H "Content-Type: application/json" \
            -d "{
                \"node_id\": ${PS_ID},
                \"listen_pg_addr\": \"${PS_HOST}\",
                \"listen_pg_port\": 6400,
                \"listen_http_addr\": \"${PS_HOST}\",
                \"listen_http_port\": 9898,
                \"availability_zone_id\": \"az-${i}\"
            }" \
        || warn "Failed to register node ${PS_ID} (may already be registered)"
done
log "Pageserver nodes registered."

# ── 9. Proxy ─────────────────────────────────────────────────────────────────
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
