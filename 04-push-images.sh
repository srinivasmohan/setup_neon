#!/usr/bin/env bash
# 04-push-images.sh — Tag and push locally-built Docker images to ECR.
# Run after 02-build-images.sh and 03-create-aws-infra.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
NEON_DIR="/home/srinivas/SourceCode/neon"

log()  { echo "==> [push] $*"; }
die()  { echo "==> [push] FATAL: $*" >&2; exit 1; }

# ── AWS credential check ─────────────────────────────────────────────────────
[[ -n "${AWS_ACCESS_KEY_ID:-}" ]]     || die "AWS_ACCESS_KEY_ID is not set"
[[ -n "${AWS_SECRET_ACCESS_KEY:-}" ]] || die "AWS_SECRET_ACCESS_KEY is not set"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-west-2}"

# ── Load .env ─────────────────────────────────────────────────────────────────
[[ -f "${ENV_FILE}" ]] || die ".env file not found. Run 03-create-aws-infra.sh first."
# shellcheck source=/dev/null
source "${ENV_FILE}"

[[ -n "${ECR_REGISTRY:-}" ]] || die "ECR_REGISTRY not set in .env"
[[ -n "${REGION:-}" ]]       || die "REGION not set in .env"

# ── ECR login ─────────────────────────────────────────────────────────────────
log "Logging in to ECR..."
aws ecr get-login-password --region "${REGION}" \
    | docker login --username AWS --password-stdin "${ECR_REGISTRY}"

# ── Tag & push each image ────────────────────────────────────────────────────
IMAGE_TAG="latest"
COMPONENTS=(pageserver safekeeper proxy storage-broker storage-controller compute)

for component in "${COMPONENTS[@]}"; do
    LOCAL_TAG="neon/${component}:latest"
    ECR_TAG="${ECR_REGISTRY}/neon/${component}:${IMAGE_TAG}"

    docker image inspect "${LOCAL_TAG}" &>/dev/null \
        || die "Local image not found: ${LOCAL_TAG}. Run 02-build-images.sh first."

    log "Tagging ${component} → ${ECR_TAG}"
    docker tag "${LOCAL_TAG}" "${ECR_TAG}"

    log "Pushing ${component}..."
    docker push "${ECR_TAG}"
done

# ── Also tag with git SHA for traceability ────────────────────────────────────
if [[ -d "${NEON_DIR}/.git" ]]; then
    GIT_SHA=$(git -C "${NEON_DIR}" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    log "Tagging images with git SHA: ${GIT_SHA}"
    for component in "${COMPONENTS[@]}"; do
        LATEST="${ECR_REGISTRY}/neon/${component}:${IMAGE_TAG}"
        SHA_TAG="${ECR_REGISTRY}/neon/${component}:${GIT_SHA}"
        docker tag "${LATEST}" "${SHA_TAG}"
        docker push "${SHA_TAG}"
    done
fi

# ── Summary ───────────────────────────────────────────────────────────────────
log ""
log "All images pushed to ECR:"
for component in "${COMPONENTS[@]}"; do
    log "  ${ECR_REGISTRY}/neon/${component}:${IMAGE_TAG}"
done
log "Done. Run 05-deploy-neon.sh next."
