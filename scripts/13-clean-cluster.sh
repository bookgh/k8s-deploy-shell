#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$ROOT/scripts/lib/common.sh"
source "$ROOT/scripts/lib/config.sh"
source "$ROOT/scripts/lib/nodes.sh"
source "$ROOT/scripts/lib/ssh.sh"
CONFIG="$ROOT/cluster.env"
COMMAND=plan
APPLY=false
while (($#)); do
  case $1 in
    --config) CONFIG=$2; shift 2 ;;
    --apply) APPLY=true; shift ;;
    --dry-run) KS_DRY_RUN=true; KS_DRY_RUN_OVERRIDE=true; shift ;;
    plan|stop|delete-data) COMMAND=$1; shift ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
ks_config_load "$CONFIG"
ks_config_validate
ks_nodes_validate "$NODE_INVENTORY_FILE" "$MASTERS" "$WORKERS"
if [[ $COMMAND == delete-data ]]; then
  ks_log ERROR 'Data deletion is intentionally blocked; independent backup/restore verification and per-path approval are required'
  exit 78
fi
if [[ $COMMAND == plan || $APPLY != true || ${KS_DRY_RUN:-true} == true ]]; then
  printf 'Cleanup plan for cluster %s (no changes):\n' "$CLUSTER_NAME"
  printf 'Would stop kubelet.service and kube-proxy.service on all nodes.\n'
  printf 'Would stop k8s-api-proxy.service on Workers.\n'
  printf 'Would stop kube-apiserver, kube-controller-manager and kube-scheduler on Masters.\n'
  printf 'Would stop etcd.service on configured ETCD_NODES.\n'
  printf 'Data retained: %s ; %s ; %s ; %s ; %s\n' "$ETCD_DATA_DIR" "$CONTAINERD_ROOT_DIR" "$KUBELET_DATA_DIR" "$PKI_ROOT" "$OUTPUT_ROOT"
  printf 'No data, PKI, kubeconfig, Harbor or workload volume will be deleted.\n'
  exit 0
fi
[[ ${KS_DRY_RUN:-true} == false ]] || { ks_log ERROR 'Set DRY_RUN=false before --apply'; exit 2; }
[[ $SSH_KNOWN_HOSTS_FILE == /* ]] || SSH_KNOWN_HOSTS_FILE=$ROOT/$SSH_KNOWN_HOSTS_FILE
[[ $NODE_INVENTORY_FILE == /* ]] || NODE_INVENTORY_FILE=$ROOT/$NODE_INVENTORY_FILE
export SSH_KNOWN_HOSTS_FILE
IFS=', ' read -r -a etcd_nodes <<< "$ETCD_NODES"
while IFS=$'\t' read -r node role address user port || [[ -n ${node:-} ]]; do
  [[ -z ${node:-} || $node == node_id || $node == \#* ]] && continue
  SSH_USER=$user SSH_PORT=$port ks_ssh "$address" systemctl stop kubelet.service kube-proxy.service
  if [[ $role == worker ]]; then
    SSH_USER=$user SSH_PORT=$port ks_ssh "$address" systemctl stop k8s-api-proxy.service
  else
    SSH_USER=$user SSH_PORT=$port ks_ssh "$address" systemctl stop kube-apiserver.service kube-controller-manager.service kube-scheduler.service
  fi
  for etcd_node in "${etcd_nodes[@]}"; do
    if [[ $node == "$etcd_node" ]]; then SSH_USER=$user SSH_PORT=$port ks_ssh "$address" systemctl stop etcd.service; fi
  done
  ks_log INFO "Stopped Kubernetes services on $node; data retained"
done < "$NODE_INVENTORY_FILE"
