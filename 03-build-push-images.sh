#!/usr/bin/env bash
# 03-build-push-images.sh — Build Docker images from local Neon binaries and push to ECR.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

log()  { echo "==> [images] $*"; }
die()  { echo "==> [images] FATAL: $*" >&2; exit 1; }

# ── AWS credential check ─────────────────────────────────────────────────────
[[ -n "${AWS_ACCESS_KEY_ID:-}" ]]     || die "AWS_ACCESS_KEY_ID is not set"
[[ -n "${AWS_SECRET_ACCESS_KEY:-}" ]] || die "AWS_SECRET_ACCESS_KEY is not set"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-west-2}"

# ── Load .env ─────────────────────────────────────────────────────────────────
[[ -f "${ENV_FILE}" ]] || die ".env file not found. Run 02-create-aws-infra.sh first."
# shellcheck source=/dev/null
source "${ENV_FILE}"

[[ -n "${ECR_REGISTRY:-}" ]] || die "ECR_REGISTRY not set in .env"
[[ -n "${REGION:-}" ]]       || die "REGION not set in .env"

NEON_DIR="/home/srinivas/SourceCode/neon"

# ── Verify binaries exist ────────────────────────────────────────────────────
BINARIES=(pageserver safekeeper proxy storage_broker)
for bin in "${BINARIES[@]}"; do
    [[ -x "${NEON_DIR}/target/release/${bin}" ]] \
        || die "Binary not found: ${NEON_DIR}/target/release/${bin}. Run 01-build-neon.sh first."
done
log "All binaries verified."

# ── Stage binaries for Docker build context ─────────────────────────────────
STAGING="${SCRIPT_DIR}/.docker-staging"
rm -rf "${STAGING}"
mkdir -p "${STAGING}"
for bin in "${BINARIES[@]}"; do
    cp "${NEON_DIR}/target/release/${bin}" "${STAGING}/"
done
log "Binaries staged to ${STAGING}"

# ── ECR login ─────────────────────────────────────────────────────────────────
log "Logging in to ECR..."
aws ecr get-login-password --region "${REGION}" \
    | docker login --username AWS --password-stdin "${ECR_REGISTRY}"

# ── Build & push each image ──────────────────────────────────────────────────
IMAGE_TAG="latest"

declare -A IMAGES=(
    ["pageserver"]="Dockerfile.pageserver"
    ["safekeeper"]="Dockerfile.safekeeper"
    ["proxy"]="Dockerfile.proxy"
    ["storage-broker"]="Dockerfile.storage-broker"
)

for component in "${!IMAGES[@]}"; do
    DOCKERFILE="${SCRIPT_DIR}/dockerfiles/${IMAGES[$component]}"
    FULL_TAG="${ECR_REGISTRY}/neon/${component}:${IMAGE_TAG}"

    log "Building ${component}..."
    docker build \
        -t "${FULL_TAG}" \
        -f "${DOCKERFILE}" \
        "${SCRIPT_DIR}"

    log "Pushing ${component} → ${FULL_TAG}..."
    docker push "${FULL_TAG}"

    log "${component} pushed successfully."
done

# ── Cleanup staging ──────────────────────────────────────────────────────────
rm -rf "${STAGING}"

# ── Also tag with git SHA for traceability ────────────────────────────────────
if [[ -d "${NEON_DIR}/.git" ]]; then
    GIT_SHA=$(git -C "${NEON_DIR}" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    log "Tagging images with git SHA: ${GIT_SHA}"
    for component in "${!IMAGES[@]}"; do
        LATEST="${ECR_REGISTRY}/neon/${component}:${IMAGE_TAG}"
        SHA_TAG="${ECR_REGISTRY}/neon/${component}:${GIT_SHA}"
        docker tag "${LATEST}" "${SHA_TAG}"
        docker push "${SHA_TAG}"
    done
fi

# ── Summary ───────────────────────────────────────────────────────────────────
log ""
log "All images pushed to ECR:"
for component in "${!IMAGES[@]}"; do
    log "  ${ECR_REGISTRY}/neon/${component}:${IMAGE_TAG}"
done
log "Done."
