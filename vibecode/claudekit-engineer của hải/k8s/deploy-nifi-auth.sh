#!/bin/bash
# Deploy NiFi with single-user authentication (HTTPS + username/password)
# TLS is managed by the NiFiKop operator (cert-manager PKI).
# Credentials secret is managed by the Helm chart.
#
# Prerequisites:
#   - kubectl configured with cluster access
#   - helm 3 installed
#   - NiFiKop operator installed (helm install nifikop k8s/nifikop/nifikop -n nifi)
#
# Usage: bash k8s/deploy-nifi-auth.sh

set -euo pipefail

NAMESPACE="nifi"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Ensure namespace exists
kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE"

# Clean up stale secrets from previous installs that block operator reconciliation
kubectl delete secret nifi-cluster-tls -n "$NAMESPACE" 2>/dev/null || true
kubectl delete secret nifi-cluster-controller -n "$NAMESPACE" 2>/dev/null || true

echo "=== Helm Install/Upgrade ==="

helm upgrade --install nifi-cluster "$SCRIPT_DIR/nifi-cluster" \
  -f "$SCRIPT_DIR/nifi-cluster/values-override.yaml" \
  -n "$NAMESPACE"

echo "✓ Helm install/upgrade complete"
echo ""
echo "=== Waiting for pod to be ready ==="
kubectl rollout status statefulset -n "$NAMESPACE" --timeout=300s 2>/dev/null || \
  echo "Waiting for NiFi pod... check with: kubectl get pods -n $NAMESPACE -w"

echo ""
echo "=== Access NiFi ==="
echo "Run:  kubectl port-forward svc/nifi-cluster-ip 8443:8443 -n $NAMESPACE"
echo "Open: https://localhost:8443/nifi"
echo "Login: admin / NiFi-P0C-2026!"
echo "(Accept the self-signed certificate warning in your browser)"
