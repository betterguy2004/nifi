# Kubernetes Manifests — NiFi on K8s with NiFiKop

Deploys Apache NiFi 2.6.0 on Kubernetes using the [NiFiKop](https://github.com/konpyutaika/nifikop) operator.

## Directory Structure

```
k8s/
├── nifikop/                    # NiFiKop operator
│   └── nifikop/                # Helm chart (v1.16.0)
│       ├── values-override.yaml  # Operator overrides
│       └── ...
├── nifi-cluster/               # NiFi cluster Helm chart (v1.16.0)
│   ├── values-override.yaml    # POC overrides for NiFi 2.6.0
│   ├── Chart.yaml
│   ├── templates/
│   └── ...
└── README.md                   # This file
```

## Prerequisites

- Kubernetes cluster (EKS, GKE, k3s, etc.)
- `kubectl` configured with cluster access
- `helm` v3+
- `nifi` namespace: `kubectl create namespace nifi`

## 1. Install NiFiKop Operator

```bash
helm install nifikop ./k8s/nifikop/nifikop \
  -f ./k8s/nifikop/nifikop/values-override.yaml \
  -n nifi --create-namespace

# Verify operator is running
kubectl get pods -n nifi -l app.kubernetes.io/name=nifikop
```

## 2. Install NiFi Cluster

```bash
helm install nifi-cluster ./k8s/nifi-cluster \
  -f ./k8s/nifi-cluster/values-override.yaml \
  -n nifi

# Wait for pod to be ready (~2-3 min for NAR expansion)
kubectl get pods -n nifi -l app=nifi -w
```

## 3. Access NiFi UI

```bash
# Access NiFi UI
kubectl port-forward svc/nifi-cluster-ip 8080:8080 -n nifi
# Open http://localhost:8080/nifi
```

## Upgrade

```bash
# Upgrade operator
helm upgrade nifikop ./k8s/nifikop/nifikop \
  -f ./k8s/nifikop/nifikop/values-override.yaml \
  -n nifi

# Upgrade NiFi cluster
helm upgrade nifi-cluster ./k8s/nifi-cluster \
  -f ./k8s/nifi-cluster/values-override.yaml \
  -n nifi
```

## Uninstall

Order matters — uninstall cluster before operator.

```bash
# 1. Uninstall NiFi cluster
helm uninstall nifi-cluster -n nifi

# 2. Wait for NifiCluster CR and pods to be removed
kubectl get pods -n nifi -l app=nifi -w

# 3. Uninstall NiFiKop operator
helm uninstall nifikop -n nifi

# 4. (Optional) Delete namespace and PVCs
kubectl delete pvc --all -n nifi
kubectl delete namespace nifi
```

## Scaling

### Add NiFi Nodes

Edit `nifi-cluster/values-override.yaml` and add node entries:

```yaml
cluster:
  nodes:
    - id: 0
      nodeConfigGroup: "default_group"
    - id: 1
      nodeConfigGroup: "default_group"
```

Then upgrade:

```bash
helm upgrade nifi-cluster ./k8s/nifi-cluster \
  -f ./k8s/nifi-cluster/values-override.yaml \
  -n nifi
```

### Remove NiFi Nodes

Remove the node entry from `values-override.yaml` and upgrade. The operator performs graceful downscale (drains flows before removing).

### Scale Operator Replicas

```bash
kubectl scale deployment nifikop -n nifi --replicas=<N>
```

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Pod CrashLoopBackOff with 403 leases | Wrong ServiceAccount | Ensure `serviceAccountName: "nifi-cluster"` in values |
| Pod restart loop | Operator can't reach NiFi API | Check headless service DNS, add `tolerate-unready-endpoints` annotation |
| Helm dependency error | Missing zookeeper chart | Run `helm dependency build ./k8s/nifi-cluster` |
| NiFi slow to start | NAR expansion (~2-3 min) | Increase `retryDurationMinutes` (default: 15) |

## Configuration Reference

### Operator Overrides (`nifikop/nifikop/values-override.yaml`)

| Key | Value | Purpose |
|-----|-------|---------|
| `image.tag` | `v1.16.0-release` | Operator version |
| `namespaces` | `[nifi]` | Watched namespaces |
| `certManager.enabled` | `false` | No cert-manager (POC) |
| `webhook.enabled` | `false` | No admission webhook (POC) |

### Cluster Overrides (`nifi-cluster/values-override.yaml`)

| Key | Value | Purpose |
|-----|-------|---------|
| `cluster.manager` | `kubernetes` | K8s leader election (NiFi 2.x) |
| `cluster.image.tag` | `2.6.0` | NiFi version |
| `cluster.retryDurationMinutes` | `15` | Startup tolerance |
| `cluster.service.annotations` | `tolerate-unready-endpoints` | DNS during startup |
| `zookeeper.enabled` | `false` | Not needed for NiFi 2.x |
