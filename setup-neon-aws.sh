#!/usr/bin/env bash
# setup-neon-aws.sh — Master orchestrator. Runs scripts 00 through 04 in sequence.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { echo ""; echo "========================================"; echo "  $*"; echo "========================================"; echo ""; }
die()  { echo "FATAL: $*" >&2; exit 1; }

# ── AWS credential check ─────────────────────────────────────────────────────
[[ -n "${AWS_ACCESS_KEY_ID:-}" ]]     || die "AWS_ACCESS_KEY_ID is not set. Export it before running this script."
[[ -n "${AWS_SECRET_ACCESS_KEY:-}" ]] || die "AWS_SECRET_ACCESS_KEY is not set. Export it before running this script."
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-west-2}"

# ── Confirmation ──────────────────────────────────────────────────────────────
echo ""
echo "Neon Self-Hosted AWS Deployment"
echo "================================"
echo ""
echo "This script will:"
echo "  1. Install prerequisites (Fedora packages, Rust, Docker, AWS CLI, kubectl, eksctl)"
echo "  2. Build Neon from source"
echo "  3. Build Docker images locally"
echo "  4. Create AWS infrastructure (EKS, S3, IAM, ECR)"
echo "  5. Push Docker images to ECR"
echo "  6. Deploy Neon to EKS"
echo ""
echo "Region:  ${AWS_DEFAULT_REGION}"
echo "Prefix:  smohan-neon1"
echo ""

# Verify identity
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) \
    || die "Cannot reach AWS. Check credentials and network."
echo "AWS Account: ${ACCOUNT_ID}"
echo ""

read -rp "Proceed? (yes/no): " CONFIRM
if [[ "${CONFIRM}" != "yes" ]]; then
    echo "Aborted."
    exit 0
fi

# ── Make scripts executable ───────────────────────────────────────────────────
chmod +x "${SCRIPT_DIR}"/0*.sh "${SCRIPT_DIR}"/99-teardown.sh 2>/dev/null || true

# ── Run each phase ────────────────────────────────────────────────────────────
SECONDS=0

log "Phase 0/5: Prerequisites"
"${SCRIPT_DIR}/00-prerequisites.sh"

log "Phase 1/5: Building Neon"
"${SCRIPT_DIR}/01-build-neon.sh"

log "Phase 2/5: Building Docker Images"
"${SCRIPT_DIR}/02-build-images.sh"

log "Phase 3/5: Creating AWS Infrastructure"
"${SCRIPT_DIR}/03-create-aws-infra.sh"

log "Phase 4/5: Pushing Docker Images to ECR"
"${SCRIPT_DIR}/04-push-images.sh"

log "Phase 5/5: Deploying to EKS"
"${SCRIPT_DIR}/05-deploy-neon.sh"

# ── Done ──────────────────────────────────────────────────────────────────────
ELAPSED=$((SECONDS / 60))
echo ""
echo "========================================"
echo "  Deployment complete! (${ELAPSED} minutes)"
echo "========================================"
echo ""
echo "Verifying deployment..."
kubectl get pods -n neon
echo ""
echo "To tear down everything:"
echo "  ./99-teardown.sh"
echo ""
