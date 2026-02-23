# Self-Hosted Neon Database - Complete Setup Guide

**Date:** February 21, 2026  
**Context:** Technical discussion on deploying Neon (serverless Postgres fork) in self-hosted environment

---

## Table of Contents

1. [Project Overview](#project-overview)
2. [Goals & Context](#goals--context)
3. [Neon Architecture](#neon-architecture)
4. [Build Process](#build-process)
5. [AWS Infrastructure](#aws-infrastructure)
6. [Deployment Scripts](#deployment-scripts)
7. [Control Plane Challenge](#control-plane-challenge)
8. [Next Steps](#next-steps)
9. [Quick Reference Commands](#quick-reference-commands)

---

## Project Overview

Setting up Neon (https://github.com/neondatabase/neon) in a self-hosted environment, starting with AWS EKS for learning, then migrating to corporate Kubernetes for production.

**Neon Capabilities:**
- Instant database branching (copy-on-write)
- Point-in-time recovery
- Serverless compute (auto-suspend/resume)
- Separation of storage and compute
- S3-backed storage with local caching

**The Challenge:**
Neon's data plane is open source, but the control plane (tenant management, branch provisioning, compute orchestration) is proprietary. We need to build this ourselves.

---

## Goals & Context

### Primary Goals
1. Better understanding and experimentation with Neon architecture
2. Run an HA-ready setup suitable for production workloads
3. Eventually migrate to corporate Kubernetes (non-AWS) for production
4. Understand and replicate the proprietary control plane functionality

### Technical Environment
- **Development OS:** Fedora Linux
- **Preferred Languages:** Rust, C++, Python
- **Expertise:** MySQL/databases, low-level optimization, performance
- **Hardware:** 10GbE networking, 256GB RAM, high-speed NVMe flash
- **Storage Backend:** Ceph or S3-compatible object storage (AWS S3 for initial setup)

### Philosophy
- Build locally on Fedora, deploy to cloud
- Use Rust for control plane (aligns with expertise)
- Kubernetes-native approach for portability
- No "just code it" - discuss architecture first

---

## Neon Architecture

### Core Components (All Open Source)

1. **Pageserver** (Rust)
   - Storage layer that handles Write-Ahead Log (WAL)
   - Serves pages to compute nodes
   - Stores data in S3/Ceph with local caching
   - HTTP API on port 9898 for management
   - Postgres protocol on port 6400 for compute nodes

2. **Safekeeper** (Rust)
   - WAL acceptor/proposer using Paxos-based consensus
   - Requires 3+ nodes for HA quorum
   - Stores WAL segments with durability guarantees
   - Ports: 5454 (Postgres protocol), 7676 (HTTP)

3. **Compute Node** (Modified Postgres)
   - Standard Postgres with Neon's storage manager
   - Reads from Pageserver instead of local disk
   - Can be dynamically created/destroyed
   - Supports all standard Postgres features

4. **Proxy** (Rust)
   - Connection pooler and router
   - Directs traffic to appropriate compute nodes
   - Handles authentication and connection limits
   - Port 4432 for client connections

5. **Storage Broker** (Rust)
   - Coordinates communication between safekeepers
   - Manages safekeeper discovery and health
   - gRPC on port 50051

### What's Proprietary (NOT in Repository)

- Control plane API for creating tenants, timelines, branches, compute endpoints
- Web console and UI
- Autoscaling and compute lifecycle management
- Multi-tenancy orchestration at scale
- Monitoring and observability integration

### Data Flow

```
Client Connection
    ↓
Proxy (routes to compute)
    ↓
Compute Node (Postgres)
    ↓ (page requests)
Pageserver
    ↓ (WAL writes)
Safekeeper Quorum (3+ nodes)
    ↓ (durable storage)
S3/Ceph Object Storage
```

---

## Build Process

### Prerequisites Installation (Fedora)

**Package Manager Differences:**
- Debian/Ubuntu: `apt-get install package-dev`
- Fedora/RHEL: `dnf install package-devel`

**Complete Prerequisites:**

```bash
# Update system
sudo dnf update -y

# Development Tools (equivalent to build-essential)
sudo dnf groupinstall -y "Development Tools"

# Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"

# PostgreSQL build dependencies
sudo dnf install -y \
    readline-devel \
    zlib-devel \
    flex \
    bison \
    libxml2-devel \
    libxslt-devel \
    openssl-devel \
    libicu-devel \
    systemd-devel \
    pkg-config

# Protocol Buffers
sudo dnf install -y protobuf-compiler protobuf-devel

# Docker
sudo dnf install -y dnf-plugins-core
sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin
sudo systemctl start docker
sudo systemctl enable docker
sudo usermod -aG docker $USER

# AWS CLI v2
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
rm -rf aws awscliv2.zip

# kubectl
KUBECTL_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)
curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/

# eksctl
PLATFORM=$(uname -s)_amd64
curl -sLO "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_${PLATFORM}.tar.gz"
tar -xzf eksctl_${PLATFORM}.tar.gz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin
rm eksctl_${PLATFORM}.tar.gz

# jq (JSON processor)
sudo dnf install -y jq
```

### Building Neon Binaries

**Clone and Build:**

```bash
# Clone repository
git clone https://github.com/neondatabase/neon.git
cd neon
git submodule update --init --recursive

# Build all Rust binaries (20-30 minutes first time)
cargo build --release

# Binaries are in target/release/:
# - pageserver
# - safekeeper
# - proxy
# - storage_broker
# - compute_ctl
# - neonctl
```

**Build Strategy:**
- Build locally on Fedora for full control
- Docker images just copy pre-built binaries (faster, simpler)
- Postgres is built as part of Docker image creation

**No Changes to Cargo Build:**
The Rust build process is identical across distributions. Only system dependencies differ.

---

## AWS Infrastructure

### Components Created

1. **EKS Cluster**
   - Managed Kubernetes 1.28
   - 3x m7i.4xlarge nodes (16 vCPU, 64GB RAM each)
   - Auto-scaling enabled
   - OIDC provider for IRSA

2. **S3 Bucket**
   - Versioning enabled
   - Lifecycle policy: Move to Intelligent Tiering after 30 days
   - Non-current version expiration: 7 days

3. **VPC Endpoint**
   - S3 gateway endpoint (no egress charges)
   - Attached to all route tables

4. **IAM Infrastructure**
   - Policy: NeonPageserverS3Access (S3 read/write permissions)
   - Service Account: pageserver-sa with IRSA
   - No hardcoded credentials needed

5. **ECR Repositories**
   - neon/pageserver
   - neon/safekeeper
   - neon/proxy
   - neon/storage-broker
   - neon/compute

6. **Storage Classes**
   - gp3-encrypted: General purpose SSD with 16,000 IOPS
   - For production: io2 with up to 64,000 IOPS

### Cost Estimates

**Minimal Setup (~$350/month):**
- EKS cluster: $75/month
- 3x t3.large nodes: $150/month
- EBS volumes: $100/month
- S3 storage: $23/month (1TB)

**Production-Ready (~$2,000-2,500/month):**
- EKS cluster: $75/month
- 3x i4i.4xlarge (16 vCPU, 128GB RAM, 3.75TB NVMe): $1,800/month
- EBS volumes: $50/month
- S3 storage: Variable
- Data transfer: Variable

### AWS vs Corporate K8s Trade-offs

**AWS Advantages:**
- Managed Kubernetes (EKS) - no control plane management
- Native S3 - exactly what Neon is designed for
- IRSA - no credential management
- Better instance types (i4i with local NVMe)
- Easier to get started

**Corporate K8s Advantages:**
- No egress costs (AWS charges for data transfer out)
- Full control over network topology
- Potentially cheaper for long-term production
- Data sovereignty if required

---

## Deployment Scripts

Complete automation in 5 scripts. Total deployment time: ~60-75 minutes from scratch.

### Script Structure

```
neon-aws-deploy/
├── 00-prerequisites.sh       # Install tools (10 min)
├── 01-build-neon.sh          # Build binaries (20-30 min)
├── 02-create-aws-infra.sh    # AWS resources (15-20 min)
├── 03-build-push-images.sh   # Docker images (5-10 min)
├── 04-deploy-neon.sh         # K8s deployment (5 min)
├── setup-neon-aws.sh         # Master script (runs all)
├── .env                      # Generated config
├── config/
│   ├── cluster-config.yaml
│   └── pageserver.toml
├── dockerfiles/
│   ├── Dockerfile.pageserver
│   ├── Dockerfile.safekeeper
│   ├── Dockerfile.proxy
│   └── Dockerfile.storage-broker
└── manifests/
    ├── namespace.yaml
    ├── storage-classes.yaml
    ├── pageserver/
    ├── safekeeper/
    ├── storage-broker/
    └── proxy/
```

### Key Scripts Overview

**00-prerequisites.sh:**
- Detects Fedora
- Installs all build tools, Docker, AWS CLI, kubectl, eksctl
- Adds user to docker group
- Verifies installations

**01-build-neon.sh:**
- Clones Neon repository
- Updates submodules
- Builds all Rust binaries with `cargo build --release`
- Optional Postgres build

**02-create-aws-infra.sh:**
- Creates EKS cluster with eksctl
- Creates S3 bucket with lifecycle policies
- Sets up VPC endpoint for S3
- Creates IAM policy and service account
- Creates ECR repositories
- Saves config to `.env` file

**03-build-push-images.sh:**
- Logs into ECR
- Builds Docker images from local binaries
- Pushes to ECR
- Images: pageserver, safekeeper, proxy, storage-broker

**04-deploy-neon.sh:**
- Configures kubectl
- Creates namespace
- Deploys storage classes
- Deploys storage-broker (Deployment)
- Deploys safekeepers (StatefulSet, 3 replicas)
- Deploys pageserver (StatefulSet, 2 replicas)
- Waits for pods to be ready

### Running the Setup

```bash
# Quick start - run everything
chmod +x setup-neon-aws.sh
./setup-neon-aws.sh

# Or step-by-step
chmod +x *.sh
./00-prerequisites.sh
aws configure  # Set up AWS credentials
./01-build-neon.sh
./02-create-aws-infra.sh
./03-build-push-images.sh
./04-deploy-neon.sh
```

### Verification Commands

```bash
# Check pods
kubectl get pods -n neon

# Check logs
kubectl logs -f safekeeper-0 -n neon
kubectl logs -f pageserver-0 -n neon

# Access pageserver API
kubectl port-forward -n neon svc/pageserver 9898:9898
curl http://localhost:9898/v1/status
```

---

## Control Plane Challenge

### The Branch Provisioning Problem

In managed Neon:
```bash
neondb create-branch --name dev-feature --parent main
# Returns: postgres://user:pass@ep-shiny-frog-12345.region.aws.neon.tech/dbname
```

This "magic" requires:

1. **Timeline Creation** (Easy - Open Source)
   - Pageserver has HTTP API: `POST /v1/tenant/{tenant_id}/timeline`
   - Creates new timeline (branch) from parent at specific LSN
   - Copy-on-write, instant operation

2. **Compute Provisioning** (Hard - Proprietary)
   - Dynamically create Postgres pod for new timeline
   - Configure pod with tenant_id and timeline_id
   - Create Kubernetes Service for networking
   - Return connection string to user

3. **Connection String Management**
   - Generate unique endpoint name
   - Setup DNS/routing
   - Handle compute lifecycle (suspend/resume)

### Implementation Options

**Option A: Static Compute Pools**
- Pre-create pool of Postgres pods
- Assign to timelines via ConfigMap
- Simple but wasteful
- Connection: `compute-branch-name.neon.svc.cluster.local:5432`

**Option B: Dynamic Compute with Operator (RECOMMENDED)**
- Build Rust Kubernetes operator
- Define CRD: `NeonCompute`
- Operator watches CRD, creates Pods/Services dynamically
- Full lifecycle management

**Option C: Proxy-Based Routing**
- Single entry point with routing table
- Proxy manages compute lifecycle
- Closest to managed Neon behavior
- Most complex

### Recommended Solution: Rust Operator

**Architecture:**
```
User Request: "Create branch 'dev-feature' from 'main'"
    ↓
Control Plane API (Rust):
    1. Call Pageserver API → create timeline
    2. Generate unique compute endpoint ID
    3. Create K8s Pod (NeonCompute CRD)
    4. Create K8s Service
    5. Return connection string
```

**Custom Resource Definition:**
```yaml
apiVersion: neon.io/v1
kind: NeonCompute
metadata:
  name: dev-feature-compute
  namespace: neon
spec:
  tenantId: tenant_abc123
  timelineId: timeline_xyz789
  pageserver: pageserver-0.pageserver.neon.svc.cluster.local:6400
  resources:
    memory: "4Gi"
    cpu: "2"
  suspend:
    enabled: true
    idleTimeout: 300  # seconds
```

**Operator Logic (Rust with kube-rs):**
```rust
use kube::{Api, Client, ResourceExt};
use kube::runtime::controller::{Action, Controller};

async fn reconcile(compute: Arc<NeonCompute>, ctx: Arc<Context>) -> Result<Action> {
    // 1. Check if Pod exists for this compute
    // 2. If not, create Pod with:
    //    - env vars: NEON_TENANT_ID, NEON_TIMELINE_ID, NEON_PAGESERVER
    //    - image: ECR compute image
    // 3. Create Service for networking
    // 4. Update NeonCompute status with connection string
    
    Ok(Action::requeue(Duration::from_secs(300)))
}
```

### Implementation Phases

**Phase 1 - Manual Testing:**
- Deploy compute pod manually
- Verify connection to Pageserver
- Test queries work
- Understand startup process

**Phase 2 - Basic Rust Operator:**
- CRD for `NeonCompute` resources
- Operator creates Pod + Service when CRD applied
- Manual timeline creation via pageserver API

**Phase 3 - Full Control Plane API:**
- REST API for branch creation
- Automatically creates timeline + compute
- Returns connection strings

**Phase 4 - Advanced Features:**
- Auto-suspend/resume idle computes
- Compute pooling
- Proxy-based routing
- Monitoring integration

---

## Next Steps

### Immediate (Day 1-2)
1. Run `00-prerequisites.sh` on Fedora box
2. Configure AWS credentials: `aws configure`
3. Run `setup-neon-aws.sh` to deploy infrastructure
4. Verify all pods are running

### Short Term (Week 1)
5. Create Dockerfile for compute node
6. Test manual compute deployment
7. Create first tenant via pageserver API
8. Run test queries

### Medium Term (Week 2-3)
9. Design NeonCompute CRD
10. Build basic Rust operator skeleton
11. Implement compute provisioning
12. Test branch creation workflow

### Long Term (Month 1-2)
13. Add auto-suspend/resume
14. Build REST API layer
15. Setup monitoring (Prometheus/Grafana)
16. Production hardening
17. Migrate to corporate K8s

---

## Quick Reference Commands

### Kubernetes

```bash
# Get all resources
kubectl get all -n neon

# Check specific pods
kubectl get pods -n neon
kubectl describe pod pageserver-0 -n neon

# Logs
kubectl logs -f pageserver-0 -n neon
kubectl logs -f safekeeper-0 -n neon

# Port forwarding
kubectl port-forward -n neon svc/pageserver 9898:9898

# Execute in pod
kubectl exec -it pageserver-0 -n neon -- /bin/bash

# Delete and recreate
kubectl delete pod pageserver-0 -n neon  # StatefulSet recreates it
kubectl delete -f manifests/pageserver/  # Remove everything
```

### Pageserver API

```bash
# Status
curl http://localhost:9898/v1/status

# Create tenant
curl -X POST http://localhost:9898/v1/tenant \
  -H "Content-Type: application/json" \
  -d '{"tenant_id": "de200bd42b49cc1814412c7e592dd6e9"}'

# Create timeline (branch)
TENANT_ID="de200bd42b49cc1814412c7e592dd6e9"
TIMELINE_ID="b3b845107e58ea5e3c0a67ef3fe24da2"

curl -X POST http://localhost:9898/v1/tenant/$TENANT_ID/timeline \
  -H "Content-Type: application/json" \
  -d '{
    "new_timeline_id": "'$TIMELINE_ID'",
    "ancestor_timeline_id": null
  }'

# List timelines
curl http://localhost:9898/v1/tenant/$TENANT_ID/timeline
```

### Docker

```bash
# List images
docker images | grep neon

# Remove old images
docker rmi $(docker images -q neon/*)

# Build locally
docker build -t neon/pageserver:latest -f Dockerfile.pageserver .

# ECR login
aws ecr get-login-password --region us-west-2 | \
  docker login --username AWS --password-stdin $ECR_REGISTRY
```

### AWS

```bash
# Check EKS cluster
aws eks describe-cluster --name neon-cluster --region us-west-2

# List S3 buckets
aws s3 ls

# Check S3 contents
aws s3 ls s3://neon-pageserver-data/ --recursive

# ECR repositories
aws ecr describe-repositories --region us-west-2

# Get kubeconfig
aws eks update-kubeconfig --name neon-cluster --region us-west-2
```

### Cargo/Rust

```bash
# Build specific component
cargo build --release -p pageserver

# Run tests
cargo test -p pageserver

# Check for updates
cargo update

# Clean build artifacts
cargo clean
```

---

## Important Technical Notes

### Kubernetes Manifests Explained

Manifests are YAML files that declaratively describe desired state. Kubernetes continuously reconciles actual state to match desired state.

**Key Resource Types:**

1. **Namespace** - Logical isolation
2. **ConfigMap** - Non-sensitive configuration (pageserver.toml)
3. **Secret** - Sensitive data (Ceph credentials)
4. **Service** - Stable network endpoint (DNS names)
5. **Deployment** - Stateless applications (proxy, storage-broker)
6. **StatefulSet** - Stateful applications (pageserver, safekeeper)
   - Stable pod identities: `safekeeper-0`, `safekeeper-1`, `safekeeper-2`
   - Persistent volumes per pod
   - Ordered startup/shutdown
7. **PersistentVolumeClaim** - Storage request

**Why StatefulSets for Neon:**
- Safekeepers need stable identities for Paxos consensus
- Pageservers need persistent local cache
- Both require volumes that survive pod restarts

### Storage Considerations

**Pageserver Storage:**
- **Local (EBS/NVMe):** Hot cache for frequently accessed pages
- **Remote (S3/Ceph):** Long-term durable storage
- Ratio: ~500GB local cache, unlimited S3 storage

**Safekeeper Storage:**
- **Local (EBS):** WAL segments before upload to pageserver
- Size: 100GB typically sufficient
- Needs low-latency, durable storage (gp3 or io2)

### Network Architecture

**Internal (within K8s):**
- Storage Broker: `storage-broker.neon.svc.cluster.local:50051`
- Pageserver-0: `pageserver-0.pageserver.neon.svc.cluster.local:6400`
- Safekeeper-0: `safekeeper-0.safekeeper.neon.svc.cluster.local:5454`

**External (from outside cluster):**
- Use LoadBalancer Service or Ingress
- Proxy should be the only external entry point
- Example: `postgres://user:pass@neon-lb.example.com:5432/dbname`

### Performance Tuning

**For 256GB RAM / 10GbE / NVMe hardware:**

1. **Pageserver:**
   - Increase cache size to 32-64GB
   - Tune `max_file_descriptors`
   - Consider memory-mapped files for hot data

2. **Safekeeper:**
   - Adjust WAL segment retention
   - Tune fsync settings (async vs sync)

3. **Network:**
   - Set TCP window scaling
   - Enable jumbo frames if supported
   - Tune connection pool sizes

4. **Kubernetes:**
   - Use `nodeSelector` to pin to specific hardware
   - Set CPU/memory requests = limits (guaranteed QoS)
   - Use `priorityClass` for critical components

---

## Troubleshooting

### Common Issues

**Pods not starting:**
```bash
kubectl describe pod pageserver-0 -n neon
# Check Events section for errors
# Common: Image pull errors, resource constraints
```

**Can't reach Pageserver API:**
```bash
# Check if service exists
kubectl get svc -n neon

# Port forward to access
kubectl port-forward -n neon svc/pageserver 9898:9898

# Test connectivity from within cluster
kubectl run -it --rm debug --image=alpine --restart=Never -n neon -- sh
apk add curl
curl http://pageserver-0.pageserver.neon.svc.cluster.local:9898/v1/status
```

**S3 access denied:**
```bash
# Check IRSA setup
kubectl describe sa pageserver-sa -n neon
# Should have annotation: eks.amazonaws.com/role-arn

# Check IAM role
aws iam get-role --role-name <role-name-from-annotation>

# Test from pod
kubectl exec -it pageserver-0 -n neon -- sh
env | grep AWS  # Should see AWS_ROLE_ARN, AWS_WEB_IDENTITY_TOKEN_FILE
```

**Safekeeper quorum issues:**
```bash
# Check all safekeepers running
kubectl get pods -n neon -l app=safekeeper

# Check logs for consensus errors
kubectl logs safekeeper-0 -n neon | grep -i error

# Verify storage broker connectivity
kubectl logs storage-broker-xxx -n neon
```

---

## Resources

### Official Documentation
- Neon GitHub: https://github.com/neondatabase/neon
- Neon Architecture: https://neon.tech/docs/introduction/architecture
- Neon API: In-code documentation in pageserver/safekeeper

### Kubernetes
- kube-rs (Rust K8s client): https://github.com/kube-rs/kube
- Kubernetes Operators: https://kubernetes.io/docs/concepts/extend-kubernetes/operator/
- Custom Resources: https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/

### AWS
- EKS Best Practices: https://aws.github.io/aws-eks-best-practices/
- IRSA Documentation: https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html
- S3 Performance: https://docs.aws.amazon.com/AmazonS3/latest/userguide/optimizing-performance.html

---

## Conversation Export Info

**Original Conversation:** claude.ai web interface  
**Export Date:** February 21, 2026  
**Topics Covered:**
- Neon architecture and components
- Build process on Fedora
- AWS infrastructure setup with EKS
- Kubernetes deployment strategies
- Control plane design for branch provisioning
- Rust operator development approach
