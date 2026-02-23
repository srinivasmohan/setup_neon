#!/usr/bin/env bash
# 02-create-aws-infra.sh — Create all AWS infrastructure for Neon:
#   EKS cluster, S3 bucket, VPC endpoint, IAM policy + IRSA, ECR repos.
# Writes all resource identifiers to .env for use by later scripts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

log()  { echo "==> [aws-infra] $*"; }
warn() { echo "==> [aws-infra] WARNING: $*" >&2; }
die()  { echo "==> [aws-infra] FATAL: $*" >&2; exit 1; }

# ── AWS credential check ─────────────────────────────────────────────────────
[[ -n "${AWS_ACCESS_KEY_ID:-}" ]]     || die "AWS_ACCESS_KEY_ID is not set"
[[ -n "${AWS_SECRET_ACCESS_KEY:-}" ]] || die "AWS_SECRET_ACCESS_KEY is not set"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-west-2}"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text) \
    || die "Failed to retrieve AWS account ID. Check your credentials."
log "AWS Account: ${ACCOUNT_ID}  Region: ${AWS_DEFAULT_REGION}"

# ── Constants ─────────────────────────────────────────────────────────────────
PREFIX="smohan-neon1"
CLUSTER_NAME="${PREFIX}-cluster"
S3_BUCKET="${PREFIX}-pageserver-data"
REGION="${AWS_DEFAULT_REGION}"
IAM_POLICY_NAME="${PREFIX}-pageserver-s3"
ECR_REPOS=("neon/pageserver" "neon/safekeeper" "neon/proxy" "neon/storage-broker")

# ── Helper: write/update .env ─────────────────────────────────────────────────
write_env() {
    local key="$1" val="$2"
    if [[ -f "${ENV_FILE}" ]] && grep -q "^${key}=" "${ENV_FILE}"; then
        sed -i "s|^${key}=.*|${key}=${val}|" "${ENV_FILE}"
    else
        echo "${key}=${val}" >> "${ENV_FILE}"
    fi
}

# Initialise .env
touch "${ENV_FILE}"
write_env "PREFIX"       "${PREFIX}"
write_env "REGION"       "${REGION}"
write_env "ACCOUNT_ID"   "${ACCOUNT_ID}"
write_env "CLUSTER_NAME" "${CLUSTER_NAME}"
write_env "S3_BUCKET"    "${S3_BUCKET}"

# ── 1. EKS Cluster ───────────────────────────────────────────────────────────
if aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${REGION}" &>/dev/null; then
    log "EKS cluster '${CLUSTER_NAME}' already exists — skipping creation."
else
    log "Creating EKS cluster '${CLUSTER_NAME}' (this takes 15-20 minutes)..."
    eksctl create cluster -f "${SCRIPT_DIR}/config/cluster-config.yaml"
    log "EKS cluster created."
fi

# Update kubeconfig
aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${REGION}"

# ── 2. S3 Bucket ─────────────────────────────────────────────────────────────
if aws s3api head-bucket --bucket "${S3_BUCKET}" 2>/dev/null; then
    log "S3 bucket '${S3_BUCKET}' already exists — skipping creation."
else
    log "Creating S3 bucket '${S3_BUCKET}'..."
    aws s3api create-bucket \
        --bucket "${S3_BUCKET}" \
        --region "${REGION}" \
        --create-bucket-configuration LocationConstraint="${REGION}"

    # Enable versioning
    aws s3api put-bucket-versioning \
        --bucket "${S3_BUCKET}" \
        --versioning-configuration Status=Enabled

    # Lifecycle policy: Intelligent Tiering after 30 days, expire non-current after 7 days
    aws s3api put-bucket-lifecycle-configuration \
        --bucket "${S3_BUCKET}" \
        --lifecycle-configuration '{
            "Rules": [
                {
                    "ID": "IntelligentTiering",
                    "Status": "Enabled",
                    "Filter": { "Prefix": "" },
                    "Transitions": [
                        {
                            "Days": 30,
                            "StorageClass": "INTELLIGENT_TIERING"
                        }
                    ],
                    "NoncurrentVersionExpiration": {
                        "NoncurrentDays": 7
                    }
                }
            ]
        }'
    log "S3 bucket created with versioning and lifecycle policy."
fi

# ── 3. VPC Endpoint for S3 ───────────────────────────────────────────────────
VPC_ID=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${REGION}" \
    --query "cluster.resourcesVpcConfig.vpcId" --output text)
write_env "VPC_ID" "${VPC_ID}"

# Get route table IDs for the VPC
ROUTE_TABLE_IDS=$(aws ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query "RouteTables[].RouteTableId" --output text | tr '\t' ',')

EXISTING_VPCE=$(aws ec2 describe-vpc-endpoints \
    --filters "Name=service-name,Values=com.amazonaws.${REGION}.s3" \
              "Name=vpc-id,Values=${VPC_ID}" \
    --query "VpcEndpoints[?VpcEndpointType=='Gateway'].VpcEndpointId" --output text)

if [[ -n "${EXISTING_VPCE}" ]]; then
    log "S3 VPC endpoint already exists: ${EXISTING_VPCE}"
    VPC_ENDPOINT_ID="${EXISTING_VPCE}"
else
    log "Creating S3 VPC gateway endpoint..."
    VPC_ENDPOINT_ID=$(aws ec2 create-vpc-endpoint \
        --vpc-id "${VPC_ID}" \
        --service-name "com.amazonaws.${REGION}.s3" \
        --route-table-ids ${ROUTE_TABLE_IDS//,/ } \
        --query "VpcEndpoint.VpcEndpointId" --output text)
    log "VPC endpoint created: ${VPC_ENDPOINT_ID}"
fi
write_env "VPC_ENDPOINT_ID" "${VPC_ENDPOINT_ID}"

# ── 4. IAM Policy for Pageserver S3 Access ────────────────────────────────────
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${IAM_POLICY_NAME}"

if aws iam get-policy --policy-arn "${POLICY_ARN}" &>/dev/null; then
    log "IAM policy '${IAM_POLICY_NAME}' already exists."
else
    log "Creating IAM policy '${IAM_POLICY_NAME}'..."
    aws iam create-policy \
        --policy-name "${IAM_POLICY_NAME}" \
        --policy-document '{
            "Version": "2012-10-17",
            "Statement": [
                {
                    "Effect": "Allow",
                    "Action": [
                        "s3:GetObject",
                        "s3:PutObject",
                        "s3:DeleteObject",
                        "s3:ListBucket",
                        "s3:GetBucketLocation"
                    ],
                    "Resource": [
                        "arn:aws:s3:::'"${S3_BUCKET}"'",
                        "arn:aws:s3:::'"${S3_BUCKET}"'/*"
                    ]
                }
            ]
        }'
    log "IAM policy created: ${POLICY_ARN}"
fi
write_env "IAM_POLICY_ARN" "${POLICY_ARN}"

# ── 5. IRSA (IAM Role for Service Account) ───────────────────────────────────
OIDC_PROVIDER=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${REGION}" \
    --query "cluster.identity.oidc.issuer" --output text | sed 's|https://||')
write_env "OIDC_PROVIDER" "${OIDC_PROVIDER}"

# Create the Kubernetes namespace first so eksctl can create the SA
kubectl create namespace neon --dry-run=client -o yaml | kubectl apply -f -

SA_CHECK=$(eksctl get iamserviceaccount --cluster "${CLUSTER_NAME}" --region "${REGION}" \
    --namespace neon --name pageserver-sa -o json 2>/dev/null || echo "[]")

if [[ "${SA_CHECK}" != "[]" ]] && echo "${SA_CHECK}" | jq -e 'length > 0' &>/dev/null; then
    log "IRSA service account 'pageserver-sa' already exists."
else
    log "Creating IRSA service account 'pageserver-sa'..."
    eksctl create iamserviceaccount \
        --cluster "${CLUSTER_NAME}" \
        --region "${REGION}" \
        --namespace neon \
        --name pageserver-sa \
        --attach-policy-arn "${POLICY_ARN}" \
        --approve \
        --override-existing-serviceaccounts
    log "IRSA service account created."
fi

# ── 6. ECR Repositories ──────────────────────────────────────────────────────
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
write_env "ECR_REGISTRY" "${ECR_REGISTRY}"

for repo in "${ECR_REPOS[@]}"; do
    if aws ecr describe-repositories --repository-names "${repo}" --region "${REGION}" &>/dev/null; then
        log "ECR repo '${repo}' already exists."
    else
        log "Creating ECR repo '${repo}'..."
        aws ecr create-repository \
            --repository-name "${repo}" \
            --region "${REGION}" \
            --image-scanning-configuration scanOnPush=true
    fi
done

# ── 7. Storage Classes ───────────────────────────────────────────────────────
log "Applying gp3-encrypted StorageClass..."
kubectl apply -f "${SCRIPT_DIR}/manifests/storage-classes.yaml"

# ── Summary ───────────────────────────────────────────────────────────────────
log ""
log "AWS infrastructure ready. Resources:"
log "  EKS Cluster:    ${CLUSTER_NAME}"
log "  S3 Bucket:      ${S3_BUCKET}"
log "  VPC Endpoint:   ${VPC_ENDPOINT_ID}"
log "  IAM Policy:     ${POLICY_ARN}"
log "  ECR Registry:   ${ECR_REGISTRY}"
log "  OIDC Provider:  ${OIDC_PROVIDER}"
log ""
log "State saved to ${ENV_FILE}"
log "Done."
