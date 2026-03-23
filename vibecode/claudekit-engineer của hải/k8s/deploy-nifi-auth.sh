#!/bin/bash
# Deploy NiFi with single-user authentication (HTTPS + username/password)
# Run this script from the repo root when connected to the K8s cluster.
#
# Prerequisites:
#   - kubectl configured with cluster access
#   - helm 3 installed
#   - openssl installed
#   - TLS certs already generated at /tmp/nifi-certs/ (or regenerate below)
#
# Usage: bash k8s/deploy-nifi-auth.sh

set -euo pipefail

NAMESPACE="nifi"
CERT_DIR="$SCRIPT_DIR/.certs"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== Phase 1: Create K8s Secrets ==="

# Generate certs if not already present
if [ ! -f "$CERT_DIR/server.crt" ]; then
  echo "Generating TLS certificates..."
  mkdir -p "$CERT_DIR"
  cd "$CERT_DIR"

  openssl genrsa -out ca.key 4096
  openssl req -x509 -new -nodes -key ca.key -sha256 -days 900 \
    -out ca.crt -subj "/CN=NiFi-POC-CA"

  cat > san.cnf <<'EOF'
[req]
distinguished_name = req_dn
req_extensions = v3_req
[req_dn]
CN = nifi
[v3_req]
subjectAltName = @alt_names
[alt_names]
DNS.1 = *.nifi-cluster-headless.nifi.svc.cluster.local
DNS.2 = *.nifi.svc.cluster.local
DNS.3 = nifi-cluster-headless.nifi.svc.cluster.local
DNS.4 = localhost
IP.1 = 127.0.0.1
EOF

  openssl genrsa -out server.key 4096
  openssl req -new -key server.key -out server.csr \
    -subj "/CN=nifi" -config san.cnf
  openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key \
    -CAcreateserial -out server.crt -days 900 -sha256 \
    -extfile san.cnf -extensions v3_req

  cd "$REPO_ROOT"
  echo "Certs generated at $CERT_DIR"
else
  echo "Using existing certs at $CERT_DIR"
fi

# Create TLS secret
kubectl delete secret nifi-cluster-tls -n "$NAMESPACE" 2>/dev/null || true
kubectl create secret generic nifi-cluster-tls \
  --from-file=ca.crt="$CERT_DIR/ca.crt" \
  --from-file=tls.crt="$CERT_DIR/server.crt" \
  --from-file=tls.key="$CERT_DIR/server.key" \
  -n "$NAMESPACE"
echo "✓ TLS secret created"

# Create single-user credentials secret
kubectl delete secret single-user-credentials -n "$NAMESPACE" 2>/dev/null || true
kubectl create secret generic single-user-credentials \
  --from-literal=username=admin \
  --from-literal=password='NiFi-P0C-2026!' \
  -n "$NAMESPACE"
echo "✓ Credentials secret created (admin / NiFi-P0C-2026!)"

echo ""
echo "=== Phase 3: Helm Upgrade ==="

helm upgrade nifi-cluster "$SCRIPT_DIR/nifi-cluster" \
  -f "$SCRIPT_DIR/nifi-cluster/values-override.yaml" \
  -n "$NAMESPACE"

echo "✓ Helm upgrade complete"
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
