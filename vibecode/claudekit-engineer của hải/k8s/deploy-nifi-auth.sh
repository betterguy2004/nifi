#!/bin/bash
# Deploy NiFi with single-user authentication (HTTPS + username/password)
# TLS bootstrap cert is generated here; operator manages certs after first boot.
# Credentials secret is managed by the Helm chart.
#
# Prerequisites:
#   - kubectl, helm 3, openssl, keytool (JDK)
#   - NiFiKop operator watching this namespace
#
# Usage:
#   bash k8s/deploy-nifi-auth.sh          # deploys to "nifi" namespace
#   bash k8s/deploy-nifi-auth.sh nifi-1   # deploys to "nifi-1" namespace

set -euo pipefail

NAMESPACE="${1:-nifi}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CERT_DIR="${LOCALAPPDATA:-${TMPDIR:-/tmp}}/Temp/nifi-certs-$NAMESPACE"

# Prevent Git Bash from mangling /CN= paths
export MSYS_NO_PATHCONV=1

# Locate keytool (may not be in PATH on Windows)
KEYTOOL="$(command -v keytool 2>/dev/null || find "/c/Program Files/Java" -name "keytool.exe" 2>/dev/null | head -1 || true)"
if [ -z "$KEYTOOL" ]; then echo "ERROR: keytool not found. Install JDK." && exit 1; fi

echo "Deploying NiFi to namespace: $NAMESPACE"

# Ensure namespace exists
kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE"

# Clean up stale secrets from previous installs that block operator reconciliation
kubectl delete secret nifi-cluster-tls -n "$NAMESPACE" 2>/dev/null || true
kubectl delete secret nifi-cluster-controller -n "$NAMESPACE" 2>/dev/null || true
kubectl delete secret nifi-cluster-0-server-certificate -n "$NAMESPACE" 2>/dev/null || true

echo "=== Phase 1: Bootstrap TLS ==="

# Generate bootstrap certs for the operator's initial reconciliation
rm -rf "$CERT_DIR"
mkdir -p "$CERT_DIR"

# Generate CA
openssl genrsa -out "$CERT_DIR/ca.key" 4096
openssl req -x509 -new -nodes -key "$CERT_DIR/ca.key" -sha256 -days 900 \
  -out "$CERT_DIR/ca.crt" -subj "/CN=NiFi-CA-${NAMESPACE}"

# Generate server cert with SANs for this namespace
cat > "$CERT_DIR/san.cnf" <<SANEOF
[req]
distinguished_name = req_dn
req_extensions = v3_req
[req_dn]
CN = nifi
[v3_req]
subjectAltName = @alt_names
[alt_names]
DNS.1 = *.nifi-cluster-headless.${NAMESPACE}.svc.cluster.local
DNS.2 = *.${NAMESPACE}.svc.cluster.local
DNS.3 = nifi-cluster-headless.${NAMESPACE}.svc.cluster.local
DNS.4 = localhost
IP.1 = 127.0.0.1
SANEOF

openssl genrsa -out "$CERT_DIR/server.key" 4096
openssl req -new -key "$CERT_DIR/server.key" -out "$CERT_DIR/server.csr" \
  -subj "/CN=nifi" -config "$CERT_DIR/san.cnf"
openssl x509 -req -in "$CERT_DIR/server.csr" -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" \
  -CAcreateserial -out "$CERT_DIR/server.crt" -days 900 -sha256 \
  -extfile "$CERT_DIR/san.cnf" -extensions v3_req

# Create bootstrap TLS secret (operator reads this on first reconciliation)
kubectl create secret generic nifi-cluster-tls \
  --from-file=ca.crt="$CERT_DIR/ca.crt" \
  --from-file=tls.crt="$CERT_DIR/server.crt" \
  --from-file=tls.key="$CERT_DIR/server.key" \
  -n "$NAMESPACE"
echo "✓ Bootstrap TLS secret created"

# Generate JKS keystores for per-node server certificate
JKS_PASS="$(openssl rand -hex 16)"
openssl pkcs12 -export -in "$CERT_DIR/server.crt" -inkey "$CERT_DIR/server.key" \
  -certfile "$CERT_DIR/ca.crt" -out "$CERT_DIR/keystore.p12" -password "pass:$JKS_PASS"
"$KEYTOOL" -importkeystore -srckeystore "$CERT_DIR/keystore.p12" -srcstoretype PKCS12 \
  -srcstorepass "$JKS_PASS" -destkeystore "$CERT_DIR/keystore.jks" -deststoretype JKS \
  -deststorepass "$JKS_PASS" -noprompt 2>/dev/null
"$KEYTOOL" -importcert -file "$CERT_DIR/ca.crt" -keystore "$CERT_DIR/truststore.jks" \
  -storepass "$JKS_PASS" -alias ca -noprompt 2>/dev/null

# Create per-node server certificate secret (prevents operator PEM decode race condition)
kubectl create secret generic nifi-cluster-0-server-certificate \
  --from-file=ca.crt="$CERT_DIR/ca.crt" \
  --from-file=tls.crt="$CERT_DIR/server.crt" \
  --from-file=tls.key="$CERT_DIR/server.key" \
  --from-file=keystore.jks="$CERT_DIR/keystore.jks" \
  --from-file=truststore.jks="$CERT_DIR/truststore.jks" \
  --from-literal=password="$JKS_PASS" \
  -n "$NAMESPACE"
echo "✓ Per-node server certificate created"

echo ""
echo "=== Phase 2: Helm Install/Upgrade ==="

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
