#!/usr/bin/env bash
# 99-teardown.sh — Destroy ALL AWS resources created by the setup scripts.
# Reads .env to identify resources. Confirms before proceeding.
# Designed to be re-runnable: skips resources that no longer exist.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

log()  { echo "==> [teardown] $*"; }
warn() { echo "==> [teardown] WARNING: $*" >&2; }
die()  { echo "==> [teardown] FATAL: $*" >&2; exit 1; }

# ── AWS credential check ─────────────────────────────────────────────────────
[[ -n "${AWS_ACCESS_KEY_ID:-}" ]]     || die "AWS_ACCESS_KEY_ID is not set"
[[ -n "${AWS_SECRET_ACCESS_KEY:-}" ]] || die "AWS_SECRET_ACCESS_KEY is not set"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-west-2}"

# ── Load .env ─────────────────────────────────────────────────────────────────
if [[ ! -f "${ENV_FILE}" ]]; then
    die ".env file not found at ${ENV_FILE}. Nothing to tear down (or already cleaned up)."
fi
# shellcheck source=/dev/null
source "${ENV_FILE}"

CLUSTER_NAME="${CLUSTER_NAME:-smohan-neon1-cluster}"
S3_BUCKET="${S3_BUCKET:-smohan-neon1-pageserver-data}"
REGION="${REGION:-us-west-2}"
VPC_ENDPOINT_ID="${VPC_ENDPOINT_ID:-}"
IAM_POLICY_ARN="${IAM_POLICY_ARN:-}"
ECR_REGISTRY="${ECR_REGISTRY:-}"
ACCOUNT_ID="${ACCOUNT_ID:-}"
STORAGE_BACKEND="${STORAGE_BACKEND:-aws-s3}"
ECR_REPOS=("neon/pageserver" "neon/safekeeper" "neon/proxy" "neon/storage-broker" "neon/storage-controller" "neon/compute")

# ── Confirmation ──────────────────────────────────────────────────────────────
echo ""
echo "!! TEARDOWN — This will PERMANENTLY DELETE the following AWS resources !!"
echo ""
echo "  Storage Backend: ${STORAGE_BACKEND}"
echo "  EKS Cluster:     ${CLUSTER_NAME}"
if [[ "${STORAGE_BACKEND}" == "aws-s3" ]]; then
    echo "  S3 Bucket:       ${S3_BUCKET}  (all objects force-deleted)"
    echo "  VPC Endpoint:    ${VPC_ENDPOINT_ID:-<not set>}"
    echo "  IAM Policy:      ${IAM_POLICY_ARN:-<not set>}"
else
    echo "  MinIO:           destroyed with namespace"
fi
echo "  ECR Repos:       ${ECR_REPOS[*]}"
echo "  Region:          ${REGION}"
echo ""
read -rp "Type 'yes' to confirm destruction: " CONFIRM
if [[ "${CONFIRM}" != "yes" ]]; then
    echo "Aborted."
    exit 0
fi

echo ""

# ── 1. Delete Kubernetes namespace (cascades to all workloads) ────────────────
log "Step 1/8: Deleting Kubernetes namespace 'neon'..."
if kubectl get namespace neon &>/dev/null 2>&1; then
    kubectl delete namespace neon --timeout=120s || warn "Namespace deletion timed out; it may still be terminating."
    log "Namespace deleted."
else
    log "Namespace 'neon' not found — skipping."
fi

# ── 1b. Delete CNPG operator ────────────────────────────────────────────────
CNPG_VERSION="1.25.1"
CNPG_RELEASE_URL="https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.25/releases/cnpg-${CNPG_VERSION}.yaml"

log "Deleting CNPG operator (if installed)..."
if kubectl get namespace cnpg-system &>/dev/null; then
    kubectl delete -f "${CNPG_RELEASE_URL}" --ignore-not-found --timeout=60s \
        || warn "CNPG operator deletion returned an error."
else
    log "CNPG operator not found — skipping."
fi

# ── 2. Delete IRSA service account (aws-s3 only) ────────────────────────────
if [[ "${STORAGE_BACKEND}" == "aws-s3" ]]; then
    log "Step 2/8: Deleting IRSA service account..."
    if eksctl get iamserviceaccount --cluster "${CLUSTER_NAME}" --region "${REGION}" --namespace neon --name pageserver-sa &>/dev/null 2>&1; then
        eksctl delete iamserviceaccount \
            --cluster "${CLUSTER_NAME}" \
            --region "${REGION}" \
            --namespace neon \
            --name pageserver-sa \
            || warn "IRSA deletion returned an error (may already be gone)."
        log "IRSA service account deleted."
    else
        log "IRSA service account not found — skipping."
    fi
else
    log "Step 2/8: MinIO mode — no IRSA to delete."
fi

# ── 3. Delete VPC Endpoint (aws-s3 only) ─────────────────────────────────────
if [[ "${STORAGE_BACKEND}" == "aws-s3" ]]; then
    log "Step 3/8: Deleting VPC endpoint..."
    if [[ -n "${VPC_ENDPOINT_ID}" ]]; then
        if aws ec2 describe-vpc-endpoints --vpc-endpoint-ids "${VPC_ENDPOINT_ID}" --region "${REGION}" &>/dev/null; then
            aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "${VPC_ENDPOINT_ID}" --region "${REGION}"
            log "VPC endpoint ${VPC_ENDPOINT_ID} deleted."
        else
            log "VPC endpoint ${VPC_ENDPOINT_ID} not found — skipping."
        fi
    else
        log "No VPC_ENDPOINT_ID in .env — skipping."
    fi
else
    log "Step 3/8: MinIO mode — no VPC endpoint to delete."
fi

# ── 4. Delete EKS Cluster ───────────────────────────────────────────────────
log "Step 4/8: Deleting EKS cluster '${CLUSTER_NAME}' (this takes 10-15 minutes)..."
if aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${REGION}" &>/dev/null; then
    eksctl delete cluster --name "${CLUSTER_NAME}" --region "${REGION}" --wait
    log "EKS cluster deleted."
else
    log "EKS cluster '${CLUSTER_NAME}' not found — skipping."
fi

# ── 5. Delete ECR Repositories ───────────────────────────────────────────────
log "Step 5/8: Deleting ECR repositories..."
for repo in "${ECR_REPOS[@]}"; do
    if aws ecr describe-repositories --repository-names "${repo}" --region "${REGION}" &>/dev/null; then
        aws ecr delete-repository --repository-name "${repo}" --region "${REGION}" --force
        log "  Deleted ECR repo: ${repo}"
    else
        log "  ECR repo '${repo}' not found — skipping."
    fi
done

# ── 6. Delete S3 Bucket (aws-s3 only, force empty first) ─────────────────────
if [[ "${STORAGE_BACKEND}" == "aws-s3" ]]; then
    log "Step 6/8: Deleting S3 bucket '${S3_BUCKET}'..."
    if aws s3api head-bucket --bucket "${S3_BUCKET}" 2>/dev/null; then
        log "  Emptying bucket (all versions + delete markers)..."

        # Delete all object versions
        aws s3api list-object-versions \
            --bucket "${S3_BUCKET}" \
            --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
            --output json 2>/dev/null | \
        jq -c 'select(.Objects != null) | {Objects: .Objects, Quiet: true}' | \
        while IFS= read -r batch; do
            [[ "${batch}" == "null" || -z "${batch}" ]] && continue
            aws s3api delete-objects --bucket "${S3_BUCKET}" --delete "${batch}" >/dev/null 2>&1 || true
        done

        # Delete all delete markers
        aws s3api list-object-versions \
            --bucket "${S3_BUCKET}" \
            --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' \
            --output json 2>/dev/null | \
        jq -c 'select(.Objects != null) | {Objects: .Objects, Quiet: true}' | \
        while IFS= read -r batch; do
            [[ "${batch}" == "null" || -z "${batch}" ]] && continue
            aws s3api delete-objects --bucket "${S3_BUCKET}" --delete "${batch}" >/dev/null 2>&1 || true
        done

        # Delete the bucket itself
        aws s3api delete-bucket --bucket "${S3_BUCKET}" --region "${REGION}"
        log "  S3 bucket deleted."
    else
        log "S3 bucket '${S3_BUCKET}' not found — skipping."
    fi
else
    log "Step 6/8: MinIO mode — S3 bucket deleted with namespace (step 1)."
fi

# ── 7. Delete IAM Policy (aws-s3 only) ──────────────────────────────────────
if [[ "${STORAGE_BACKEND}" == "aws-s3" ]]; then
    log "Step 7/8: Deleting IAM policy..."
    if [[ -n "${IAM_POLICY_ARN}" ]]; then
        if aws iam get-policy --policy-arn "${IAM_POLICY_ARN}" &>/dev/null; then
            # Detach from all roles first
            ATTACHED_ROLES=$(aws iam list-entities-for-policy --policy-arn "${IAM_POLICY_ARN}" \
                --query "PolicyRoles[].RoleName" --output text 2>/dev/null || echo "")
            for role in ${ATTACHED_ROLES}; do
                log "  Detaching policy from role: ${role}"
                aws iam detach-role-policy --role-name "${role}" --policy-arn "${IAM_POLICY_ARN}" || true
            done

            # Delete non-default policy versions
            VERSIONS=$(aws iam list-policy-versions --policy-arn "${IAM_POLICY_ARN}" \
                --query "Versions[?IsDefaultVersion==\`false\`].VersionId" --output text 2>/dev/null || echo "")
            for ver in ${VERSIONS}; do
                aws iam delete-policy-version --policy-arn "${IAM_POLICY_ARN}" --version-id "${ver}" || true
            done

            aws iam delete-policy --policy-arn "${IAM_POLICY_ARN}"
            log "  IAM policy deleted."
        else
            log "IAM policy not found — skipping."
        fi
    else
        log "No IAM_POLICY_ARN in .env — skipping."
    fi
else
    log "Step 7/8: MinIO mode — no IAM policy to delete."
fi

# ── Cleanup .env ──────────────────────────────────────────────────────────────
log ""
log "Teardown complete. Removing .env..."
rm -f "${ENV_FILE}"

echo ""
echo "========================================"
echo "  All resources destroyed."
echo "========================================"
echo ""
echo "Verify with:"
echo "  aws eks list-clusters --region ${REGION}"
echo "  aws s3 ls 2>&1 | grep smohan-neon1"
echo "  aws ecr describe-repositories --region ${REGION}"
echo ""
