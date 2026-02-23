# Neon AWS EKS — Sizing & Cost Breakdown

**Profile:** Test / personal account (cheapskate mode)
**Region:** us-west-2
**Prefix:** smohan-neon1

---

## EKS Nodes (EC2 Hosts)

| Spec             | Per Node   | Total (2 nodes) |
|------------------|------------|------------------|
| Instance type    | t3.large   | —                |
| vCPUs            | 2          | 4                |
| RAM              | 8 GB       | 16 GB            |
| Root EBS         | 50 GB gp3  | 100 GB           |
| Network          | Up to 5 Gbps | —             |
| Autoscaling      | min 1 / desired 2 / max 3 | |

---

## Pod Workloads (7 pods across 2 nodes)

| Component        | Replicas | CPU req | CPU limit | Mem req | Mem limit | PVC (each) | Notes                        |
|------------------|----------|---------|-----------|---------|-----------|------------|------------------------------|
| Storage Broker   | 1        | 250m    | 1         | 256Mi   | 512Mi     | —          | gRPC coordinator             |
| Safekeeper       | 3        | 250m    | 1         | 512Mi   | 2Gi       | 10Gi gp3   | Paxos quorum (minimum 3)     |
| Pageserver       | 2        | 500m    | 2         | 1Gi     | 4Gi       | 20Gi gp3   | 1GB page cache, S3 backend   |
| Proxy            | 1        | 500m    | 2         | 512Mi   | 2Gi       | —          | LoadBalancer service          |
| **Totals (req)** | **7**    | **2.25**| —         | **4.25 GB** | —     | **70Gi**   |                              |

### Fit Check

| Resource     | Available (2x t3.large) | Requested (all pods) | Headroom |
|--------------|-------------------------|----------------------|----------|
| CPU          | 4 cores                 | 2.25 cores           | 1.75 cores |
| Memory       | 16 GB                   | 4.25 GB              | ~11 GB   |

> ~0.5 core and ~0.5 GB per node reserved for K8s system pods (kube-proxy, coredns, vpc-cni).

---

## Storage Summary

| Volume               | Count | Size Each | Total  | Type          |
|----------------------|-------|-----------|--------|---------------|
| Node root EBS        | 2     | 50 GB     | 100 GB | gp3           |
| Safekeeper PVCs      | 3     | 10 GB     | 30 GB  | gp3-encrypted |
| Pageserver PVCs      | 2     | 20 GB     | 40 GB  | gp3-encrypted |
| S3 bucket            | 1     | ~10 GB    | ~10 GB | S3 Standard   |
| **Total disk**       |       |           | **~180 GB** |          |

---

## Monthly Cost Estimate (us-west-2, on-demand)

| Resource                          | Qty / Size          | Unit Cost      | Monthly   |
|-----------------------------------|---------------------|----------------|-----------|
| EKS control plane                 | 1 cluster           | $75            | **$75**   |
| t3.large nodes                    | 2 instances         | ~$60/ea        | **$120**  |
| EBS — node root volumes           | 100 GB gp3          | $0.08/GB       | **$8**    |
| EBS — PVCs (safekeeper+pageserver)| 70 GB gp3           | $0.08/GB       | **$6**    |
| S3 storage                        | ~10 GB (test data)  | $0.023/GB      | **<$1**   |
| NAT Gateway                       | 1                   | $32 + data     | **~$35**  |
| Network Load Balancer (proxy)     | 1                   | $16 + data     | **~$18**  |
| **Total**                         |                     |                | **~$263/mo** |

### Cost Notes

- NAT Gateway is the hidden cost — required for private subnets to pull ECR images. Could be eliminated by using public subnets (less secure) or VPC endpoints for ECR.
- t3.large is burstable — sustained CPU above baseline (20%) will consume burst credits. Fine for testing; watch CloudWatch if running load tests.
- Teardown immediately with `./99-teardown.sh` when not in use to stop the meter.
- **Daily cost if left running: ~$8.75/day.**

---

## Comparison: Test vs Production Sizing

| Dimension          | Test (current)           | Production               |
|--------------------|--------------------------|--------------------------|
| Node type          | t3.large (2 vCPU/8GB)   | m7i.4xlarge (16 vCPU/64GB) |
| Node count         | 2                        | 3–5                      |
| Pageserver replicas| 2                        | 2–3                      |
| Pageserver cache   | 1 GB                     | 32–64 GB                 |
| Pageserver PVC     | 20 GB                    | 500 GB                   |
| Safekeeper PVC     | 10 GB                    | 100 GB                   |
| Proxy replicas     | 1                        | 2–3                      |
| Monthly cost       | ~$263                    | ~$2,500–3,500            |
