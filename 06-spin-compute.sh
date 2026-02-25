#!/usr/bin/env bash
# 06-spin-compute.sh — Create a tenant + timeline on pageserver, then deploy a
# compute pod (Postgres) connected to the Neon storage layer.
# Run after 05-deploy-neon.sh has the data plane running.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

log()  { echo "==> [compute] $*"; }
warn() { echo "==> [compute] WARNING: $*" >&2; }
die()  { echo "==> [compute] FATAL: $*" >&2; exit 1; }

# ── Load .env ─────────────────────────────────────────────────────────────────
[[ -f "${ENV_FILE}" ]] || die ".env file not found. Run 03-create-aws-infra.sh first."
# shellcheck source=/dev/null
source "${ENV_FILE}"

[[ -n "${ECR_REGISTRY:-}" ]] || die "ECR_REGISTRY not set in .env"
[[ -n "${CLUSTER_NAME:-}" ]] || die "CLUSTER_NAME not set in .env"
[[ -n "${REGION:-}" ]]       || die "REGION not set in .env"

# ── AWS credential check ─────────────────────────────────────────────────────
[[ -n "${AWS_ACCESS_KEY_ID:-}" ]]     || die "AWS_ACCESS_KEY_ID is not set"
[[ -n "${AWS_SECRET_ACCESS_KEY:-}" ]] || die "AWS_SECRET_ACCESS_KEY is not set"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-west-2}"

# ── Ensure kubeconfig is current ─────────────────────────────────────────────
aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${REGION}" >/dev/null 2>&1

# ── Verify data plane is running ─────────────────────────────────────────────
log "Checking data plane pods..."
for app in storage-broker safekeeper pageserver; do
    READY=$(kubectl get pods -n neon -l app="${app}" -o jsonpath='{.items[*].status.phase}' 2>/dev/null)
    if [[ -z "${READY}" ]] || echo "${READY}" | grep -qv Running; then
        die "${app} pods are not all Running. Deploy data plane first (05-deploy-neon.sh)."
    fi
done
log "Data plane is healthy."

# ── Generate tenant and timeline IDs ─────────────────────────────────────────
# Neon uses 32-char hex strings (128-bit) for tenant and timeline IDs.
gen_id() { python3 -c "import uuid; print(uuid.uuid4().hex)"; }

TENANT_ID=$(gen_id)
TIMELINE_ID=$(gen_id)
COMPUTE_ID="compute-${TENANT_ID:0:8}"

log "Tenant ID:   ${TENANT_ID}"
log "Timeline ID: ${TIMELINE_ID}"
log "Compute ID:  ${COMPUTE_ID}"

# ── Create tenant on pageserver ──────────────────────────────────────────────
log "Creating tenant on pageserver-0..."
TENANT_RESULT=$(kubectl exec -n neon pageserver-0 -- \
    curl -sf -X POST http://localhost:9898/v1/tenant \
        -H "Content-Type: application/json" \
        -d "{\"new_tenant_id\": \"${TENANT_ID}\"}" 2>&1) \
    || die "Failed to create tenant: ${TENANT_RESULT}"
log "Tenant created: ${TENANT_RESULT}"

# ── Create timeline on pageserver ────────────────────────────────────────────
log "Creating timeline on pageserver-0..."
TIMELINE_RESULT=$(kubectl exec -n neon pageserver-0 -- \
    curl -sf -X POST "http://localhost:9898/v1/tenant/${TENANT_ID}/timeline" \
        -H "Content-Type: application/json" \
        -d "{\"new_timeline_id\": \"${TIMELINE_ID}\", \"pg_version\": 17}" 2>&1) \
    || die "Failed to create timeline: ${TIMELINE_RESULT}"
log "Timeline created: ${TIMELINE_RESULT}"

# ── Internal DNS names ───────────────────────────────────────────────────────
PAGESERVER_HOST="pageserver-0.pageserver.neon.svc.cluster.local"
SAFEKEEPERS="safekeeper-0.safekeeper.neon.svc.cluster.local:5454,safekeeper-1.safekeeper.neon.svc.cluster.local:5454,safekeeper-2.safekeeper.neon.svc.cluster.local:5454"

# ── Generate compute spec JSON ───────────────────────────────────────────────
SPEC_JSON=$(cat <<EOF
{
  "format_version": 1.0,
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)",
  "operation_uuid": "$(gen_id)",
  "cluster": {
    "cluster_id": "${COMPUTE_ID}",
    "name": "${COMPUTE_ID}",
    "roles": [
      {
        "name": "postgres",
        "encrypted_password": null,
        "options": null
      }
    ],
    "databases": [
      {
        "name": "postgres",
        "owner": "postgres"
      }
    ],
    "settings": [
      {"name": "port", "value": "5432", "vartype": "integer"},
      {"name": "listen_addresses", "value": "0.0.0.0", "vartype": "string"},
      {"name": "max_connections", "value": "100", "vartype": "integer"},
      {"name": "shared_buffers", "value": "131072", "vartype": "integer"},
      {"name": "fsync", "value": "off", "vartype": "bool"},
      {"name": "wal_level", "value": "logical", "vartype": "enum"},
      {"name": "hot_standby", "value": "on", "vartype": "bool"},
      {"name": "shared_preload_libraries", "value": "neon", "vartype": "string"},
      {"name": "synchronous_standby_names", "value": "walproposer", "vartype": "string"},
      {"name": "neon.tenant_id", "value": "${TENANT_ID}", "vartype": "string"},
      {"name": "neon.timeline_id", "value": "${TIMELINE_ID}", "vartype": "string"},
      {"name": "neon.pageserver_connstring", "value": "host=${PAGESERVER_HOST} port=6400", "vartype": "string"},
      {"name": "neon.safekeepers", "value": "${SAFEKEEPERS}", "vartype": "string"},
      {"name": "max_wal_senders", "value": "10", "vartype": "integer"},
      {"name": "max_replication_slots", "value": "10", "vartype": "integer"},
      {"name": "wal_sender_timeout", "value": "0", "vartype": "integer"},
      {"name": "password_encryption", "value": "md5", "vartype": "enum"},
      {"name": "log_connections", "value": "on", "vartype": "bool"}
    ]
  },
  "delta_operations": [],
  "tenant_id": "${TENANT_ID}",
  "timeline_id": "${TIMELINE_ID}",
  "pageserver_connstring": "host=${PAGESERVER_HOST} port=6400",
  "safekeeper_connstrings": [
    "safekeeper-0.safekeeper.neon.svc.cluster.local:5454",
    "safekeeper-1.safekeeper.neon.svc.cluster.local:5454",
    "safekeeper-2.safekeeper.neon.svc.cluster.local:5454"
  ],
  "mode": "Primary",
  "skip_pg_catalog_updates": false
}
EOF
)

# ── Deploy compute to Kubernetes ─────────────────────────────────────────────
log "Creating ConfigMap with compute spec..."
kubectl create configmap "${COMPUTE_ID}-spec" \
    --namespace neon \
    --from-literal=spec.json="${SPEC_JSON}" \
    --dry-run=client -o yaml | kubectl apply -f -

log "Deploying compute pod..."
cat <<EOF | sed "s|PLACEHOLDER_ECR_REGISTRY|${ECR_REGISTRY}|g" | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${COMPUTE_ID}
  namespace: neon
  labels:
    app: compute
    tenant: "${TENANT_ID:0:8}"
spec:
  containers:
    - name: postgres
      image: PLACEHOLDER_ECR_REGISTRY/neon/compute:latest
      args:
        - "--pgdata"
        - "/data/pgdata"
        - "--connstr"
        - "postgresql://postgres@localhost:5432/postgres"
        - "--pgbin"
        - "/usr/local/pgsql/bin/postgres"
        - "--compute-id"
        - "${COMPUTE_ID}"
        - "--config"
        - "/config/spec.json"
        - "--dev"
      ports:
        - containerPort: 5432
          name: postgres
        - containerPort: 3080
          name: http
      volumeMounts:
        - name: compute-spec
          mountPath: /config
          readOnly: true
        - name: pgdata
          mountPath: /data
      resources:
        requests:
          cpu: "250m"
          memory: "512Mi"
        limits:
          cpu: "1"
          memory: "1Gi"
      readinessProbe:
        httpGet:
          path: /status
          port: 3080
        initialDelaySeconds: 5
        periodSeconds: 10
      livenessProbe:
        httpGet:
          path: /status
          port: 3080
        initialDelaySeconds: 15
        periodSeconds: 20
  volumes:
    - name: compute-spec
      configMap:
        name: ${COMPUTE_ID}-spec
    - name: pgdata
      emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: ${COMPUTE_ID}
  namespace: neon
  labels:
    app: compute
    tenant: "${TENANT_ID:0:8}"
spec:
  selector:
    app: compute
    tenant: "${TENANT_ID:0:8}"
  ports:
    - name: postgres
      port: 5432
      targetPort: 5432
    - name: http
      port: 3080
      targetPort: 3080
  type: ClusterIP
EOF

# ── Wait for pod to be ready ─────────────────────────────────────────────────
log "Waiting for compute pod to start..."
kubectl wait --for=condition=Ready pod/"${COMPUTE_ID}" -n neon --timeout=120s \
    || warn "Pod did not become Ready within 120s. Check: kubectl describe pod ${COMPUTE_ID} -n neon"

# ── Summary ───────────────────────────────────────────────────────────────────
log ""
log "Compute node deployed:"
log "  Pod:         ${COMPUTE_ID}"
log "  Tenant ID:   ${TENANT_ID}"
log "  Timeline ID: ${TIMELINE_ID}"
log "  Service:     ${COMPUTE_ID}.neon.svc.cluster.local:5432"
log ""
log "Connect from your machine:"
log "  kubectl port-forward -n neon pod/${COMPUTE_ID} 5432:5432"
log "  psql postgresql://postgres@localhost:5432/postgres"
log ""
log "Or connect from within the cluster:"
log "  psql postgresql://postgres@${COMPUTE_ID}.neon.svc.cluster.local:5432/postgres"
log ""
log "Logs:"
log "  kubectl logs -f ${COMPUTE_ID} -n neon"
log ""
log "Teardown this compute:"
log "  kubectl delete pod/${COMPUTE_ID} svc/${COMPUTE_ID} configmap/${COMPUTE_ID}-spec -n neon"
log ""
log "Done."
