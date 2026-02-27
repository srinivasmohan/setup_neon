#!/usr/bin/env bash
# 08-clear-tenants.sh — Delete all tenants from the storage controller.
#
# Use this before switching storage backends (e.g. AWS S3 → MinIO) to ensure
# the storage controller metadata is in sync with the (empty) new backend.
# Tenants are deleted via the storage controller API, which cleans up both
# controller metadata and pageserver state.
#
# Usage:
#   ./08-clear-tenants.sh            # List all tenants (default)
#   ./08-clear-tenants.sh --delete   # List tenants, confirm, then delete all
set -euo pipefail

log()  { echo "==> [clear-tenants] $*"; }
warn() { echo "==> [clear-tenants] WARNING: $*" >&2; }
die()  { echo "==> [clear-tenants] FATAL: $*" >&2; exit 1; }

STORCON_URL="http://storage-controller.neon.svc.cluster.local:1234"

# Pick a pod to exec curl from (any neon pod with curl will do)
EXEC_POD=$(kubectl get pods -n neon -l app=pageserver -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) \
    || die "No pageserver pod found. Is the deployment running?"

# ── List tenants ──────────────────────────────────────────────────────────────
# List endpoint: GET /control/v1/tenant
# Delete endpoint: DELETE /v1/tenant/:tenant_id
TENANT_JSON=$(kubectl exec -n neon "${EXEC_POD}" -- \
    curl -sf "${STORCON_URL}/control/v1/tenant" 2>/dev/null) \
    || die "Failed to list tenants from storage controller."

TENANT_IDS=$(echo "${TENANT_JSON}" | jq -r '.[].tenant_id // empty')

if [[ -z "${TENANT_IDS}" ]]; then
    log "No tenants found. Nothing to do."
    exit 0
fi

TENANT_COUNT=$(echo "${TENANT_IDS}" | wc -l)
log "Found ${TENANT_COUNT} tenant(s):"
echo "${TENANT_IDS}" | while read -r tid; do
    echo "  ${tid}"
done

if [[ "${1:-}" != "--delete" ]]; then
    exit 0
fi

# ── Confirm deletion ─────────────────────────────────────────────────────────
echo ""
read -r -p "==> [clear-tenants] Delete ALL ${TENANT_COUNT} tenant(s)? This removes controller metadata and pageserver state. [y/N] " confirm
[[ "${confirm}" =~ ^[Yy]$ ]] || { log "Aborted."; exit 0; }

# ── Delete each tenant ───────────────────────────────────────────────────────
FAILED=0
while read -r tid; do
    log "Deleting tenant ${tid}..."
    kubectl exec -n neon "${EXEC_POD}" -- \
        curl -sf -X DELETE "${STORCON_URL}/v1/tenant/${tid}" \
        || { warn "Failed to delete tenant ${tid}"; FAILED=1; }
done <<< "${TENANT_IDS}"

if [[ "${FAILED}" -ne 0 ]]; then
    warn "Some tenants failed to delete. Re-run to retry."
else
    log "All tenants deleted. Storage controller metadata is clean."
fi
