#!/bin/bash
# =============================================================================
# NiFi Cluster Scaling & Data Integrity Test Suite
#
# Each test creates data, performs a scale operation, then verifies integrity.
#
# Prerequisites:
#   - kubectl configured with cluster access
#   - helm installed
#   - NiFi cluster running in 'nifi' namespace with 1 node (id: 0)
#
# Usage: bash k8s/test-nifi-scaling.sh
# =============================================================================

set -euo pipefail

NAMESPACE="nifi"
CHART_PATH="./k8s/nifi-cluster"
VALUES_OVERRIDE="./k8s/nifi-cluster/values-override.yaml"
TIMEOUT_READY=300
TIMEOUT_API=180

# Detect Python binary (Windows may not have python3 in PATH)
PYTHON=""
for p in python3 python "/c/Users/${USER:-${USERNAME:-HungPhung}}/AppData/Local/Programs/Python/Python313/python.exe"; do
  if command -v "$p" &>/dev/null && "$p" -c "print(1)" &>/dev/null; then
    PYTHON="$p"; break
  fi
done
if [ -z "$PYTHON" ]; then
  echo "ERROR: Python not found. Install Python 3 or add it to PATH."
  exit 1
fi
PASSED=0
FAILED=0
TOTAL=5

# --- Helpers ---

log()    { echo -e "\n[$(date +%H:%M:%S)] $*"; }
pass()   { PASSED=$((PASSED + 1)); echo "  ✓ PASS: $1"; }
fail()   { FAILED=$((FAILED + 1)); echo "  ✗ FAIL: $1 — $2"; }

get_pod_name() {
  kubectl get pods -n "$NAMESPACE" -l app=nifi --no-headers 2>/dev/null \
    | grep "nifi-cluster-${1}-node" | awk '{print $1}' | head -1
}

get_base_url() {
  local pod; pod=$(get_pod_name "$1")
  local hn; hn=$(kubectl exec -n "$NAMESPACE" "$pod" -- bash -c 'hostname -f' 2>/dev/null)
  echo "http://${hn}:8080/nifi-api"
}

nifi_curl() {
  local nid=$1; shift
  local pod; pod=$(get_pod_name "$nid")
  kubectl exec -n "$NAMESPACE" "$pod" -- bash -c "curl -s $*" 2>/dev/null
}

wait_for_pod_ready() {
  local elapsed=0
  log "Waiting for node $1 pod Ready..."
  while [ $elapsed -lt $TIMEOUT_READY ]; do
    local pod; pod=$(get_pod_name "$1")
    if [ -n "$pod" ]; then
      local r; r=$(kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
      [ "$r" = "True" ] && { log "Node $1 Ready."; return 0; }
    fi
    sleep 5; elapsed=$((elapsed + 5))
  done
  return 1
}

wait_for_api() {
  local elapsed=0
  log "Waiting for NiFi API on node $1..."
  while [ $elapsed -lt $TIMEOUT_API ]; do
    local pod; pod=$(get_pod_name "$1")
    if [ -n "$pod" ]; then
      local hn; hn=$(kubectl exec -n "$NAMESPACE" "$pod" -- bash -c 'hostname -f' 2>/dev/null || true)
      if [ -n "$hn" ]; then
        local c; c=$(kubectl exec -n "$NAMESPACE" "$pod" -- bash -c "curl -s -o /dev/null -w '%{http_code}' http://${hn}:8080/nifi-api/flow/current-user" 2>/dev/null || echo "000")
        [ "$c" = "200" ] && { log "Node $1 API healthy."; return 0; }
      fi
    fi
    sleep 10; elapsed=$((elapsed + 10))
  done
  return 1
}

helm_set_nodes() {
  local yaml="cluster:\n  nodes:"
  for id in "$@"; do yaml="${yaml}\n    - id: ${id}\n      nodeConfigGroup: \"default_group\""; done
  local f; f=$(mktemp /tmp/nifi-nodes-XXXXXX.yaml)
  echo -e "$yaml" > "$f"
  helm upgrade nifi-cluster "$CHART_PATH" -f "$VALUES_OVERRIDE" -f "$f" -n "$NAMESPACE" --wait=false 2>&1
  rm -f "$f"
}

wait_for_node1_gone() {
  local elapsed=0
  while [ $elapsed -lt 480 ]; do
    [ -z "$(get_pod_name 1)" ] && { log "Node 1 removed."; return 0; }
    sleep 10; elapsed=$((elapsed + 10))
  done
  return 1
}

get_root_pg_id() {
  local base_url; base_url=$(get_base_url "$1")
  nifi_curl "$1" "${base_url}/flow/process-groups/root" \
    | $PYTHON -c "import sys,json; print(json.load(sys.stdin)['processGroupFlow']['id'])" 2>/dev/null
}

# Create a process group, return its ID
create_pg() {
  local nid=$1 name=$2
  local base_url; base_url=$(get_base_url "$nid")
  local root; root=$(get_root_pg_id "$nid")
  nifi_curl "$nid" "-X POST -H 'Content-Type: application/json' \
    -d '{\"revision\":{\"version\":0},\"component\":{\"name\":\"${name}\",\"position\":{\"x\":100,\"y\":100}}}' \
    ${base_url}/process-groups/${root}/process-groups" \
    | $PYTHON -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null
}

# Create a processor, return its ID
create_processor() {
  local nid=$1 name=$2
  local base_url; base_url=$(get_base_url "$nid")
  local root; root=$(get_root_pg_id "$nid")
  nifi_curl "$nid" "-X POST -H 'Content-Type: application/json' \
    -d '{\"revision\":{\"version\":0},\"component\":{\"type\":\"org.apache.nifi.processors.standard.GenerateFlowFile\",\"name\":\"${name}\",\"position\":{\"x\":300,\"y\":100}}}' \
    ${base_url}/process-groups/${root}/processors" \
    | $PYTHON -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null
}

# Create a controller service, return its ID
create_cs() {
  local nid=$1 name=$2
  local base_url; base_url=$(get_base_url "$nid")
  local root; root=$(get_root_pg_id "$nid")
  nifi_curl "$nid" "-X POST -H 'Content-Type: application/json' \
    -d '{\"revision\":{\"version\":0},\"component\":{\"type\":\"org.apache.nifi.schemaregistry.services.AvroSchemaRegistry\",\"name\":\"${name}\"}}' \
    ${base_url}/process-groups/${root}/controller-services" \
    | $PYTHON -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null
}

# Check a component exists on a node by ID, return its name
check_component() {
  local nid=$1 endpoint=$2 comp_id=$3
  local base_url; base_url=$(get_base_url "$nid")
  nifi_curl "$nid" "${base_url}/${endpoint}/${comp_id}" \
    | $PYTHON -c "import sys,json; print(json.load(sys.stdin)['component']['name'])" 2>/dev/null || echo ""
}

# =============================================================================
# TC1: Scale up — create data on 1 node, scale to 2, verify on both nodes
# =============================================================================
test_1_scale_up_integrity() {
  log "=== TC1: Scale up — data replicated to new node ==="
  wait_for_pod_ready 0 || { fail "TC1" "node 0 not ready"; return; }
  wait_for_api 0 || { fail "TC1" "node 0 API not ready"; return; }

  # Create data on single node
  local ts; ts=$(date +%s)
  local pg_name="tc1-pg-${ts}"
  local proc_name="tc1-proc-${ts}"
  local pg_id; pg_id=$(create_pg 0 "$pg_name")
  local proc_id; proc_id=$(create_processor 0 "$proc_name")

  if [ -z "$pg_id" ] || [ -z "$proc_id" ]; then
    fail "TC1" "failed to create test data"
    return
  fi
  log "Created: PG '$pg_name', processor '$proc_name'"

  # Scale up to 2
  helm_set_nodes 0 1
  wait_for_pod_ready 1 || { fail "TC1" "node 1 not ready after scale-up"; return; }
  wait_for_api 1 || { fail "TC1" "node 1 API not ready"; return; }

  # Verify data on BOTH nodes
  local pg_on_0; pg_on_0=$(check_component 0 "process-groups" "$pg_id")
  local pg_on_1; pg_on_1=$(check_component 1 "process-groups" "$pg_id")
  local proc_on_0; proc_on_0=$(check_component 0 "processors" "$proc_id")
  local proc_on_1; proc_on_1=$(check_component 1 "processors" "$proc_id")

  if [ "$pg_on_0" = "$pg_name" ] && [ "$pg_on_1" = "$pg_name" ] \
     && [ "$proc_on_0" = "$proc_name" ] && [ "$proc_on_1" = "$proc_name" ]; then
    pass "TC1: Data created on 1 node → replicated to new node after scale-up"
  else
    fail "TC1" "node0=[pg=$pg_on_0,proc=$proc_on_0] node1=[pg=$pg_on_1,proc=$proc_on_1]"
  fi
}

# =============================================================================
# TC2: Scale down — create data on 2 nodes, scale to 1, verify on remaining
# =============================================================================
test_2_scale_down_integrity() {
  log "=== TC2: Scale down — data survives node removal ==="

  # Ensure 2 nodes running (from TC1)
  wait_for_api 0 || { fail "TC2" "node 0 not ready"; return; }
  wait_for_api 1 || { fail "TC2" "node 1 not ready"; return; }

  # Create data on 2-node cluster
  local ts; ts=$(date +%s)
  local pg_name="tc2-pg-${ts}"
  local cs_name="tc2-cs-${ts}"
  local pg_id; pg_id=$(create_pg 0 "$pg_name")
  local cs_id; cs_id=$(create_cs 0 "$cs_name")

  if [ -z "$pg_id" ] || [ -z "$cs_id" ]; then
    fail "TC2" "failed to create test data"
    return
  fi
  log "Created on 2-node cluster: PG '$pg_name', CS '$cs_name'"

  # Scale down to 1
  helm_set_nodes 0
  if ! wait_for_node1_gone; then
    fail "TC2" "node 1 not removed — NiFiKop scale-down failed"
    return
  fi
  wait_for_api 0 || { fail "TC2" "node 0 API not responding after scale-down"; return; }

  # Verify data on remaining node
  local pg_check; pg_check=$(check_component 0 "process-groups" "$pg_id")
  local cs_check; cs_check=$(check_component 0 "controller-services" "$cs_id")

  if [ "$pg_check" = "$pg_name" ] && [ "$cs_check" = "$cs_name" ]; then
    pass "TC2: Data created on 2-node cluster → intact after scale-down to 1"
  else
    fail "TC2" "pg=$pg_check (expected $pg_name), cs=$cs_check (expected $cs_name)"
  fi
}

# =============================================================================
# TC3: Full cycle — create data, scale 1→2→1, verify integrity throughout
# =============================================================================
test_3_full_cycle_integrity() {
  log "=== TC3: Full cycle 1→2→1 — data integrity throughout ==="
  wait_for_api 0 || { fail "TC3" "node 0 not ready"; return; }

  # Create data on 1-node cluster
  local ts; ts=$(date +%s)
  local pg_name="tc3-pg-${ts}"
  local proc_name="tc3-proc-${ts}"
  local cs_name="tc3-cs-${ts}"
  local pg_id; pg_id=$(create_pg 0 "$pg_name")
  local proc_id; proc_id=$(create_processor 0 "$proc_name")
  local cs_id; cs_id=$(create_cs 0 "$cs_name")

  if [ -z "$pg_id" ] || [ -z "$proc_id" ] || [ -z "$cs_id" ]; then
    fail "TC3" "failed to create test data"
    return
  fi
  log "Created: PG '$pg_name', proc '$proc_name', CS '$cs_name'"

  # Scale up to 2
  log "Scaling 1→2..."
  helm_set_nodes 0 1
  wait_for_pod_ready 1 || { fail "TC3" "node 1 not ready"; return; }
  wait_for_api 1 || { fail "TC3" "node 1 API not ready"; return; }

  # Check data on node 1 (mid-cycle)
  local mid_pg; mid_pg=$(check_component 1 "process-groups" "$pg_id")
  local mid_proc; mid_proc=$(check_component 1 "processors" "$proc_id")
  local mid_cs; mid_cs=$(check_component 1 "controller-services" "$cs_id")
  log "Mid-cycle check on node 1: pg=$mid_pg, proc=$mid_proc, cs=$mid_cs"

  # Scale back down to 1
  log "Scaling 2→1..."
  helm_set_nodes 0
  if ! wait_for_node1_gone; then
    fail "TC3" "node 1 not removed"
    return
  fi
  wait_for_api 0 || { fail "TC3" "node 0 API not responding"; return; }

  # Verify all data on remaining node
  local final_pg; final_pg=$(check_component 0 "process-groups" "$pg_id")
  local final_proc; final_proc=$(check_component 0 "processors" "$proc_id")
  local final_cs; final_cs=$(check_component 0 "controller-services" "$cs_id")

  if [ "$final_pg" = "$pg_name" ] && [ "$final_proc" = "$proc_name" ] && [ "$final_cs" = "$cs_name" ] \
     && [ "$mid_pg" = "$pg_name" ] && [ "$mid_proc" = "$proc_name" ] && [ "$mid_cs" = "$cs_name" ]; then
    pass "TC3: Full cycle 1→2→1 — all 3 components intact at every stage"
  else
    fail "TC3" "mid=[pg=$mid_pg,proc=$mid_proc,cs=$mid_cs] final=[pg=$final_pg,proc=$final_proc,cs=$final_cs]"
  fi
}

# =============================================================================
# TC4: Pod restart — create data, kill pod, verify data survives PVC reattach
# =============================================================================
test_4_restart_integrity() {
  log "=== TC4: Pod restart — data survives PVC reattach ==="
  wait_for_api 0 || { fail "TC4" "node 0 not ready"; return; }

  # Create data
  local ts; ts=$(date +%s)
  local pg_name="tc4-pg-${ts}"
  local proc_name="tc4-proc-${ts}"
  local pg_id; pg_id=$(create_pg 0 "$pg_name")
  local proc_id; proc_id=$(create_processor 0 "$proc_name")

  if [ -z "$pg_id" ] || [ -z "$proc_id" ]; then
    fail "TC4" "failed to create test data"
    return
  fi
  log "Created: PG '$pg_name', proc '$proc_name'"

  # Kill pod
  local pod0; pod0=$(get_pod_name 0)
  log "Deleting pod $pod0..."
  kubectl delete pod "$pod0" -n "$NAMESPACE"
  wait_for_pod_ready 0 || { fail "TC4" "node 0 not ready after restart"; return; }
  wait_for_api 0 || { fail "TC4" "API not responding after restart"; return; }

  # Verify
  local pg_check; pg_check=$(check_component 0 "process-groups" "$pg_id")
  local proc_check; proc_check=$(check_component 0 "processors" "$proc_id")

  if [ "$pg_check" = "$pg_name" ] && [ "$proc_check" = "$proc_name" ]; then
    pass "TC4: Data created → pod killed → PVC reattached → data intact"
  else
    fail "TC4" "pg=$pg_check (expected $pg_name), proc=$proc_check (expected $proc_name)"
  fi
}

# =============================================================================
# TC5: API health — no Invalid State after all scale operations
# =============================================================================
test_5_api_health() {
  log "=== TC5: API health after all operations ==="

  local base_url; base_url=$(get_base_url 0)

  local response
  response=$(nifi_curl 0 "-w '\n%{http_code}' ${base_url}/flow/current-user")
  local code; code=$(echo "$response" | tail -1 | tr -d "'")
  local body; body=$(echo "$response" | sed '$d')

  local has_identity
  has_identity=$(echo "$body" | $PYTHON -c "import sys,json; print('identity' in json.load(sys.stdin))" 2>/dev/null || echo "False")

  local summary_code
  summary_code=$(nifi_curl 0 "-o /dev/null -w '%{http_code}' ${base_url}/flow/cluster/summary" | tr -d "'")

  # Verify node reports FQDN (not 0.0.0.0)
  local bad_addr
  bad_addr=$(nifi_curl 0 "${base_url}/controller/cluster" \
    | $PYTHON -c "import sys,json; print(sum(1 for n in json.load(sys.stdin)['cluster']['nodes'] if n['address']=='0.0.0.0'))" 2>/dev/null || echo "-1")

  if [ "$code" = "200" ] && [ "$has_identity" = "True" ] && [ "$summary_code" = "200" ] && [ "$bad_addr" = "0" ]; then
    pass "TC5: API healthy — no Invalid State, FQDN hostnames, cluster OK"
  else
    fail "TC5" "code=$code identity=$has_identity summary=$summary_code bad_addr=$bad_addr"
  fi
}

# =============================================================================
# Main
# =============================================================================
echo "============================================="
echo " NiFi Scaling & Data Integrity Test Suite"
echo " Namespace: $NAMESPACE"
echo "============================================="

test_1_scale_up_integrity
test_2_scale_down_integrity
test_3_full_cycle_integrity
test_4_restart_integrity
test_5_api_health

echo ""
echo "============================================="
echo " Results: $PASSED/$TOTAL passed, $FAILED/$TOTAL failed"
echo "============================================="

[ "$FAILED" -eq 0 ] && exit 0 || exit 1
