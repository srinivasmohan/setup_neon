#!/usr/bin/env bash
# 02-build-images.sh — Build Docker images locally from Neon binaries.
# No AWS credentials needed. Run after 01-build-neon.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NEON_DIR="/home/srinivas/SourceCode/neon"

log()  { echo "==> [images] $*"; }
die()  { echo "==> [images] FATAL: $*" >&2; exit 1; }

# ── Verify binaries exist ────────────────────────────────────────────────────
BINARIES=(pageserver safekeeper proxy storage_broker storage_controller compute_ctl)
for bin in "${BINARIES[@]}"; do
    [[ -x "${NEON_DIR}/target/release/${bin}" ]] \
        || die "Binary not found: ${NEON_DIR}/target/release/${bin}. Run 01-build-neon.sh first."
done
[[ -x "${NEON_DIR}/pg_install/v17/bin/postgres" ]] \
    || die "PostgreSQL v17 not found at ${NEON_DIR}/pg_install/v17/. Run 01-build-neon.sh first."
[[ -f "${NEON_DIR}/pg_install/v17/lib/postgresql/neon.so" ]] \
    || die "Neon extensions not found. Run 01-build-neon.sh first."
log "All binaries verified."

# ── Stage binaries for Docker build context ─────────────────────────────────
STAGING="${SCRIPT_DIR}/.docker-staging"
rm -rf "${STAGING}"
mkdir -p "${STAGING}"
for bin in "${BINARIES[@]}"; do
    cp "${NEON_DIR}/target/release/${bin}" "${STAGING}/"
done

# Stage PostgreSQL v17 + Neon extensions for compute image
log "Staging PostgreSQL v17 + Neon extensions for compute image..."
cp -a "${NEON_DIR}/pg_install/v17" "${STAGING}/pg_install"
log "Binaries staged to ${STAGING}"

# ── Build each image ────────────────────────────────────────────────────────
declare -A IMAGES=(
    ["pageserver"]="Dockerfile.pageserver"
    ["safekeeper"]="Dockerfile.safekeeper"
    ["proxy"]="Dockerfile.proxy"
    ["storage-broker"]="Dockerfile.storage-broker"
    ["storage-controller"]="Dockerfile.storage-controller"
    ["compute"]="Dockerfile.compute"
)

for component in "${!IMAGES[@]}"; do
    DOCKERFILE="${SCRIPT_DIR}/dockerfiles/${IMAGES[$component]}"
    TAG="neon/${component}:latest"

    log "Building ${component}..."
    docker build \
        -t "${TAG}" \
        -f "${DOCKERFILE}" \
        "${SCRIPT_DIR}"

    log "  ${TAG} built."
done

# ── Summary ───────────────────────────────────────────────────────────────────
log ""
log "All images built locally:"
for component in "${!IMAGES[@]}"; do
    log "  neon/${component}:latest"
done
log "Done. Run 03-create-aws-infra.sh next, then 04-push-images.sh to push to ECR."
