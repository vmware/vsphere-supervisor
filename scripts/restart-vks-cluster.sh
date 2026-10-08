#!/usr/bin/env bash
set -euo pipefail

# Undoes shutdown-vks-cluster.sh: powers on worker VMs, then the
# control-plane VM, clears the VM Operator admin pause (ExtraConfig key
# "vmservice.virtualmachine.pause") from all of them, unpauses the
# Cluster, and scales the control plane back up.
#
# After the control plane has scaled back up, all worker nodes are
# uncordoned.
#
# Required env vars:
#   KUBECONFIG          - path to kubeconfig for the Supervisor cluster
#                        (used for the Cluster/Machine/KubeadmControlPlane
#                        resources)
#   WORKLOAD_KUBECONFIG - path to kubeconfig for the workload cluster itself
#                        (used for uncordon, which acts on Node objects
#                        inside the workload cluster, not the Supervisor)
#   KUBENAMESPACE       - namespace the Cluster/Machines live in (Supervisor)
#   GOVC_URL / GOVC_USERNAME / GOVC_PASSWORD (and GOVC_INSECURE, if needed)
#     - standard govc connection env vars
#   GOVC_DATACENTER - required if the vCenter has more than one datacenter
#
# Usage: ./restart-vks-cluster.sh <cluster-name> <control-plane-replicas>
#   control-plane-replicas is the original number of control plane replicas.

CONTROL_PLANE_WAIT_TIMEOUT_SECS=600
CONTROL_PLANE_POLL_INTERVAL_SECS=10

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <cluster-name> <control-plane-replicas>" >&2
  exit 1
fi

CLUSTER_NAME="$1"
CONTROL_PLANE_REPLICAS="$2"

if [[ ! "$CONTROL_PLANE_REPLICAS" =~ ^[1-9][0-9]*$ ]]; then
  echo "control-plane-replicas must be a positive integer (got '${CONTROL_PLANE_REPLICAS}')" >&2
  exit 1
fi

# Verifies every required env var is set, and that it's actually usable
# (not just non-empty) - e.g. this is what catches a vCenter with multiple
# datacenters needing GOVC_DATACENTER, before any VM has been powered on.
# Unlike shutdown, this does NOT check live access to the workload
# cluster - it's expected to be down until this script powers it back up,
# so only its kubeconfig file's existence is checked here.
check_env() {
  local missing=0
  for var in KUBECONFIG WORKLOAD_KUBECONFIG KUBENAMESPACE GOVC_URL GOVC_USERNAME GOVC_PASSWORD; do
    if [[ -z "${!var:-}" ]]; then
      echo "Required environment variable ${var} is not set" >&2
      missing=1
    fi
  done
  if [[ "$missing" -eq 1 ]]; then
    exit 1
  fi

  if [[ ! -f "$WORKLOAD_KUBECONFIG" ]]; then
    echo "WORKLOAD_KUBECONFIG '${WORKLOAD_KUBECONFIG}' does not exist" >&2
    exit 1
  fi

  echo "Verifying access to the Supervisor cluster (\$KUBECONFIG)..."
  if ! kubectl get namespace "$KUBENAMESPACE" >/dev/null; then
    echo "Could not access namespace '${KUBENAMESPACE}' on the Supervisor cluster using \$KUBECONFIG" >&2
    exit 1
  fi

  echo "Verifying govc connectivity to vCenter..."
  if ! govc about >/dev/null; then
    echo "Could not connect to vCenter - check GOVC_URL, GOVC_USERNAME, GOVC_PASSWORD, GOVC_INSECURE" >&2
    exit 1
  fi

  local dc_err
  if ! dc_err=$(govc datacenter.info 2>&1 >/dev/null); then
    echo "Could not retrieve datacenters: ${dc_err}" >&2
    exit 1
  fi
  if [[ ( ! -v GOVC_DATACENTER ) && $(govc datacenter.info -json | jq '.datacenters | length') -gt 1 ]]; then
    echo "Multiple datacenters found, set GOVC_DATACENTER to one of the following" >&2
    govc datacenter.info -json | jq -r '.datacenters | map(.name) | .[]' >&2
    exit 1
  fi

}

check_env

# shellcheck disable=SC2034  # out_ref is a nameref: assignment writes to the caller's array
get_provider_ids_array() {
  local selector="$1"
  local -n out_ref=$2
  local raw

  if ! raw=$(
    kubectl get machines -n "$KUBENAMESPACE" \
      -l "$selector" \
      -o jsonpath='{range .items[*]}{.spec.providerID}{"\n"}{end}'
  ); then
    echo "Failed to query machines with selector '${selector}'" >&2
    exit 1
  fi

  out_ref=()
  if [[ -n "$raw" ]]; then
    mapfile -t out_ref <<< "$raw"
  fi
}

power_on_vms() {
  local -n ids_ref=$1

  for provider_id in "${ids_ref[@]}"; do
    if [[ -z "$provider_id" ]]; then
      echo "Skipping machine with empty providerID" >&2
      continue
    fi

    uuid="${provider_id#vsphere://}"
    echo "Powering on VM with UUID ${uuid}..."
    govc vm.power -on -vm.uuid="$uuid"
  done
}

clear_pause_vms() {
  local -n ids_ref=$1

  for provider_id in "${ids_ref[@]}"; do
    if [[ -z "$provider_id" ]]; then
      continue
    fi

    uuid="${provider_id#vsphere://}"
    echo "Clearing pause for VM with UUID ${uuid}..."
    govc vm.change -vm.uuid="$uuid" -e vmservice.virtualmachine.pause=false
  done
}

wait_for_poweron() {
  local -n ids_ref=$1

  for provider_id in "${ids_ref[@]}"; do
    if [[ -z "$provider_id" ]]; then
      continue
    fi

    uuid="${provider_id#vsphere://}"
    echo "Waiting for VM with UUID ${uuid} to report poweredOn..."
    local elapsed=0
    while true; do
      local state
      state=$(govc vm.info -vm.uuid="$uuid" -json | jq -r '.virtualMachines[0].runtime.powerState')

      if [[ "$state" == "poweredOn" ]]; then
        break
      fi

      if (( elapsed >= CONTROL_PLANE_WAIT_TIMEOUT_SECS )); then
        echo "Timed out waiting for VM with UUID ${uuid} to power on (state: ${state})" >&2
        exit 1
      fi

      sleep "$CONTROL_PLANE_POLL_INTERVAL_SECS"
      elapsed=$(( elapsed + CONTROL_PLANE_POLL_INTERVAL_SECS ))
    done
  done
}

get_provider_ids_array \
  "cluster.x-k8s.io/cluster-name=${CLUSTER_NAME},!cluster.x-k8s.io/control-plane" \
  WORKER_PROVIDER_IDS
get_provider_ids_array \
  "cluster.x-k8s.io/cluster-name=${CLUSTER_NAME},cluster.x-k8s.io/control-plane" \
  CONTROL_PLANE_PROVIDER_IDS

if [[ ${#WORKER_PROVIDER_IDS[@]} -eq 0 && ${#CONTROL_PLANE_PROVIDER_IDS[@]} -eq 0 ]]; then
  echo "No machines found for cluster '${CLUSTER_NAME}' in namespace '${KUBENAMESPACE}'" >&2
  exit 1
fi

echo "Powering on worker VMs..."
power_on_vms WORKER_PROVIDER_IDS
clear_pause_vms WORKER_PROVIDER_IDS
wait_for_poweron WORKER_PROVIDER_IDS

echo "Powering on control-plane VM(s)..."
power_on_vms CONTROL_PLANE_PROVIDER_IDS
clear_pause_vms CONTROL_PLANE_PROVIDER_IDS
wait_for_poweron CONTROL_PLANE_PROVIDER_IDS

echo "Waiting for the Kubernetes API server to come online..."
elapsed=0
while ! KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl get --raw='/readyz' >/dev/null 2>&1; do
  if (( elapsed >= CONTROL_PLANE_WAIT_TIMEOUT_SECS )); then
    echo "Timed out waiting for the Kubernetes API server to come online" >&2
    exit 1
  fi

  sleep "$CONTROL_PLANE_POLL_INTERVAL_SECS"
  elapsed=$(( elapsed + CONTROL_PLANE_POLL_INTERVAL_SECS ))
done

echo "Waiting for all nodes to report Ready..."
KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl wait --for=condition=Ready node --all --timeout="${CONTROL_PLANE_WAIT_TIMEOUT_SECS}s"

echo "Unpausing cluster ${CLUSTER_NAME}..."
kubectl patch cluster "$CLUSTER_NAME" -n "$KUBENAMESPACE" \
  --type='json' -p='[{"op": "replace", "path": "/spec/paused", "value": false}]'

echo "Scaling control plane for ${CLUSTER_NAME} to ${CONTROL_PLANE_REPLICAS} replica(s)..."
kubectl patch cluster "$CLUSTER_NAME" -n "$KUBENAMESPACE" \
  --type='json' -p="[{\"op\": \"replace\", \"path\": \"/spec/topology/controlPlane/replicas\", \"value\": ${CONTROL_PLANE_REPLICAS}}]"

KCP_NAME=$(
  kubectl get kubeadmcontrolplane -n "$KUBENAMESPACE" \
    -l "cluster.x-k8s.io/cluster-name=${CLUSTER_NAME}" \
    -o jsonpath='{.items[0].metadata.name}'
)

if [[ -z "$KCP_NAME" ]]; then
  echo "Could not find KubeadmControlPlane for cluster '${CLUSTER_NAME}' in namespace '${KUBENAMESPACE}'" >&2
  exit 1
fi

echo "Waiting for KubeadmControlPlane ${KCP_NAME} to reach ${CONTROL_PLANE_REPLICAS} healthy replica(s)..."
elapsed=0
while true; do
  current_ready=$(
    kubectl get kubeadmcontrolplane "$KCP_NAME" -n "$KUBENAMESPACE" \
      -o jsonpath='{.status.readyReplicas}'
  )

  if [[ "$current_ready" == "$CONTROL_PLANE_REPLICAS" ]]; then
    echo "Control plane scaled up to ${CONTROL_PLANE_REPLICAS} healthy replica(s)."
    break
  fi

  if (( elapsed >= CONTROL_PLANE_WAIT_TIMEOUT_SECS )); then
    echo "Timed out waiting for control plane to scale up (current ready replicas: ${current_ready})" >&2
    exit 1
  fi

  sleep "$CONTROL_PLANE_POLL_INTERVAL_SECS"
  elapsed=$(( elapsed + CONTROL_PLANE_POLL_INTERVAL_SECS ))
done

echo "Uncordoning all worker nodes for ${CLUSTER_NAME}..."
worker_nodes=$(KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o name)

if [[ -z "$worker_nodes" ]]; then
  echo "No worker nodes found to uncordon" >&2
else
  # shellcheck disable=SC2086
  KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl uncordon $worker_nodes
fi

# No timeout here by design - CAPI's own Cluster/KubeadmControlPlane status
# (checked above) doesn't cover addon/workload pods (CSI, CNI, etc.), which
# can take a variable amount of time to finish registering after a restart.
# Rather than guess a timeout, just report status and let whoever is
# running this decide how long they're willing to wait (Ctrl-C to give up).
echo "Waiting for all pods across all namespaces to be healthy (no timeout - Ctrl-C to stop waiting)..."
while true; do
  # grep -v exits 1 (no non-matching lines) when every pod is healthy -
  # that's the success case, not an error, so `|| true` keeps set -e from
  # treating it as one.
  bad_pods=$(KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl get pods -A --no-headers 2>/dev/null | grep -viE "running|completed" || true)

  if [[ -z "$bad_pods" ]]; then
    echo "All pods are healthy."
    break
  fi

  echo "$(date -u +%H:%M:%S) - still waiting on unhealthy pods:"
  echo "$bad_pods"
  sleep 10
done
