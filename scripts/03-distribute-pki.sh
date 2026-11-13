#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$ROOT/scripts/lib/common.sh"
source "$ROOT/scripts/lib/config.sh"
source "$ROOT/scripts/lib/nodes.sh"
source "$ROOT/scripts/lib/ssh.sh"

CONFIG="$ROOT/cluster.env"
APPLY=false
FORCE_DRY_RUN=false
while (($#)); do
  case $1 in
    --config) (($# >= 2)) || exit 2; CONFIG=$2; shift 2 ;;
    --apply) APPLY=true; shift ;;
    --dry-run) FORCE_DRY_RUN=true; shift ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

ks_config_load "$CONFIG"
ks_config_validate
ks_nodes_validate "$NODE_INVENTORY_FILE" "$MASTERS" "$WORKERS"
if [[ $SSH_KNOWN_HOSTS_FILE != /* ]]; then SSH_KNOWN_HOSTS_FILE=$ROOT/$SSH_KNOWN_HOSTS_FILE; fi
export SSH_KNOWN_HOSTS_FILE
if [[ $PKI_ROOT == /* ]]; then PKI_PATH=$(realpath -m -- "$PKI_ROOT"); else PKI_PATH=$(realpath -m -- "$ROOT/$PKI_ROOT"); fi
[[ -d $PKI_PATH && ! -L $PKI_PATH ]] || { ks_log ERROR "PKI root is missing or is a symlink: $PKI_PATH"; exit 2; }

ks_require_pki_file() {
  local file=$1 mode=$2 actual
  [[ -f $file && ! -L $file && -r $file ]] || { ks_log ERROR "Required PKI file missing or unsafe: $file"; return 2; }
  actual=$(stat -c '%a' "$file")
  if [[ $mode == 0600 && $actual != 600 && $actual != 400 ]]; then
    ks_log ERROR "Private key must be mode 0600/0400: $file"
    return 2
  fi
}
ks_push_file() {
  local address=$1 user=$2 port=$3 source=$4 destination=$5 mode=$6
  SSH_USER="$user" SSH_PORT="$port" ks_ssh_install_file "$address" "$source" "$destination" "$mode"
}
ks_push_pair() {
  local address=$1 user=$2 port=$3 cert=$4 key=$5 cert_dest=$6 key_dest=$7
  ks_push_file "$address" "$user" "$port" "$cert" "$cert_dest" 0644
  ks_push_file "$address" "$user" "$port" "$key" "$key_dest" 0600
}
ks_validate_pki_material() {
  local node file etcd_node
  local node_file=$NODE_INVENTORY_FILE
  local -a required=() etcd_nodes=()
  [[ $node_file == /* ]] || node_file=$ROOT/$node_file
  required=(
    "$PKI_PATH/kubernetes/ca.pem"
    "$PKI_PATH/kubernetes/apiserver/apiserver.pem" "$PKI_PATH/kubernetes/apiserver/apiserver-key.pem"
    "$PKI_PATH/kubernetes/apiserver-kubelet-client/apiserver-kubelet-client.pem" "$PKI_PATH/kubernetes/apiserver-kubelet-client/apiserver-kubelet-client-key.pem"
    "$PKI_PATH/kubernetes/controller-manager/controller-manager.pem" "$PKI_PATH/kubernetes/controller-manager/controller-manager-key.pem"
    "$PKI_PATH/kubernetes/scheduler/scheduler.pem" "$PKI_PATH/kubernetes/scheduler/scheduler-key.pem"
    "$PKI_PATH/kubernetes/kube-proxy/kube-proxy.pem" "$PKI_PATH/kubernetes/kube-proxy/kube-proxy-key.pem"
    "$PKI_PATH/front-proxy/ca.pem" "$PKI_PATH/front-proxy/client/front-proxy-client.pem" "$PKI_PATH/front-proxy/client/front-proxy-client-key.pem"
    "$PKI_PATH/etcd/ca.pem" "$PKI_PATH/etcd/clients/apiserver-etcd-client.pem" "$PKI_PATH/etcd/clients/apiserver-etcd-client-key.pem"
    "$PKI_PATH/etcd/clients/healthcheck-client.pem" "$PKI_PATH/etcd/clients/healthcheck-client-key.pem"
    "$PKI_PATH/service-account/sa.key" "$PKI_PATH/service-account/sa.pub"
  )
  for file in "${required[@]}"; do
    if [[ $file == *-key.pem || $file == *.key ]]; then ks_require_pki_file "$file" 0600; else ks_require_pki_file "$file" 0644; fi
  done
  while IFS=$'\t' read -r node _ _ _ _ || [[ -n ${node:-} ]]; do
    [[ -z ${node:-} || $node == node_id || $node == \#* ]] && continue
    ks_require_pki_file "$PKI_PATH/kubernetes/kubelet/$node/$node-client.pem" 0644
    ks_require_pki_file "$PKI_PATH/kubernetes/kubelet/$node/$node-client-key.pem" 0600
    ks_require_pki_file "$PKI_PATH/kubernetes/kubelet/$node/$node-serving.pem" 0644
    ks_require_pki_file "$PKI_PATH/kubernetes/kubelet/$node/$node-serving-key.pem" 0600
  done < "$node_file"
  IFS=' ' read -r -a etcd_nodes <<< "${ETCD_NODES//,/ }"
  for etcd_node in "${etcd_nodes[@]}"; do
    ks_require_pki_file "$PKI_PATH/etcd/members/$etcd_node/server.pem" 0644
    ks_require_pki_file "$PKI_PATH/etcd/members/$etcd_node/server-key.pem" 0600
    ks_require_pki_file "$PKI_PATH/etcd/members/$etcd_node/peer.pem" 0644
    ks_require_pki_file "$PKI_PATH/etcd/members/$etcd_node/peer-key.pem" 0600
  done
}

ks_ssh_root() {
  local address=$1 user=$2 port=$3
  shift 3
  if [[ $user == root ]]; then
    SSH_USER="$user" SSH_PORT="$port" ks_ssh "$address" "$@"
  else
    SSH_USER="$user" SSH_PORT="$port" ks_ssh "$address" sudo -n "$@"
  fi
}

ks_validate_pki_material
if [[ $APPLY != true || $FORCE_DRY_RUN == true || ${KS_DRY_RUN:-true} == true ]]; then
  KS_DRY_RUN=true
  ks_log INFO 'PKI distribution preview; no SSH connections or remote file changes will occur'
else
  ks_log WARN 'Distributing private keys over authenticated SSH; Caddy HTTP is not used for sensitive material'
fi

node_file=$NODE_INVENTORY_FILE
[[ $node_file == /* ]] || node_file=$ROOT/$node_file
etcd_node_list=()
IFS=' ' read -r -a etcd_node_list <<< "${ETCD_NODES//,/ }"
while IFS=$'\t' read -r node role address user port || [[ -n ${node:-} ]]; do
  [[ -z ${node:-} || $node == node_id || $node == \#* ]] && continue
  ks_log INFO "Distributing Kubernetes node credentials: $node ($role)"
  ks_push_file "$address" "$user" "$port" "$PKI_PATH/kubernetes/ca.pem" /etc/kubernetes/pki/ca.crt 0644
  ks_push_pair "$address" "$user" "$port" "$PKI_PATH/kubernetes/kube-proxy/kube-proxy.pem" "$PKI_PATH/kubernetes/kube-proxy/kube-proxy-key.pem" /etc/kubernetes/pki/kube-proxy.crt /etc/kubernetes/pki/kube-proxy.key
  ks_push_pair "$address" "$user" "$port" "$PKI_PATH/kubernetes/kubelet/$node/$node-client.pem" "$PKI_PATH/kubernetes/kubelet/$node/$node-client-key.pem" /var/lib/kubelet/pki/kubelet-client.crt /var/lib/kubelet/pki/kubelet-client.key
  ks_push_pair "$address" "$user" "$port" "$PKI_PATH/kubernetes/kubelet/$node/$node-serving.pem" "$PKI_PATH/kubernetes/kubelet/$node/$node-serving-key.pem" /var/lib/kubelet/pki/kubelet-serving.crt /var/lib/kubelet/pki/kubelet-serving.key

  if [[ $role == master ]]; then
    ks_log INFO "Distributing control-plane credentials: $node"
    ks_push_pair "$address" "$user" "$port" "$PKI_PATH/kubernetes/apiserver/apiserver.pem" "$PKI_PATH/kubernetes/apiserver/apiserver-key.pem" /etc/kubernetes/pki/apiserver.crt /etc/kubernetes/pki/apiserver.key
    ks_push_pair "$address" "$user" "$port" "$PKI_PATH/kubernetes/apiserver-kubelet-client/apiserver-kubelet-client.pem" "$PKI_PATH/kubernetes/apiserver-kubelet-client/apiserver-kubelet-client-key.pem" /etc/kubernetes/pki/apiserver-kubelet-client.crt /etc/kubernetes/pki/apiserver-kubelet-client.key
    ks_push_pair "$address" "$user" "$port" "$PKI_PATH/kubernetes/controller-manager/controller-manager.pem" "$PKI_PATH/kubernetes/controller-manager/controller-manager-key.pem" /etc/kubernetes/pki/controller-manager.crt /etc/kubernetes/pki/controller-manager.key
    ks_push_pair "$address" "$user" "$port" "$PKI_PATH/kubernetes/scheduler/scheduler.pem" "$PKI_PATH/kubernetes/scheduler/scheduler-key.pem" /etc/kubernetes/pki/scheduler.crt /etc/kubernetes/pki/scheduler.key
    ks_push_file "$address" "$user" "$port" "$PKI_PATH/front-proxy/ca.pem" /etc/kubernetes/pki/front-proxy-ca.crt 0644
    ks_push_pair "$address" "$user" "$port" "$PKI_PATH/front-proxy/client/front-proxy-client.pem" "$PKI_PATH/front-proxy/client/front-proxy-client-key.pem" /etc/kubernetes/pki/front-proxy-client.crt /etc/kubernetes/pki/front-proxy-client.key
    ks_push_file "$address" "$user" "$port" "$PKI_PATH/etcd/ca.pem" /etc/kubernetes/pki/etcd/ca.crt 0644
    ks_push_pair "$address" "$user" "$port" "$PKI_PATH/etcd/clients/apiserver-etcd-client.pem" "$PKI_PATH/etcd/clients/apiserver-etcd-client-key.pem" /etc/kubernetes/pki/apiserver-etcd-client.crt /etc/kubernetes/pki/apiserver-etcd-client.key
    ks_push_file "$address" "$user" "$port" "$PKI_PATH/service-account/sa.key" /etc/kubernetes/pki/sa.key 0600
    ks_push_file "$address" "$user" "$port" "$PKI_PATH/service-account/sa.pub" /etc/kubernetes/pki/sa.pub 0644
    for etcd_node in "${etcd_node_list[@]}"; do
      if [[ $node == "$etcd_node" ]]; then
        ks_log INFO "Distributing etcd member credentials: $node"
        if ! ks_ssh_root "$address" "$user" "$port" getent group etcd; then
          ks_ssh_root "$address" "$user" "$port" groupadd --system etcd
        fi
        if ! ks_ssh_root "$address" "$user" "$port" id etcd; then
          ks_ssh_root "$address" "$user" "$port" useradd --system --gid etcd --home-dir "$ETCD_DATA_DIR" --create-home --shell /sbin/nologin etcd
        fi
        ks_push_file "$address" "$user" "$port" "$PKI_PATH/etcd/ca.pem" "$ETCD_CONFIG_DIR/pki/ca.crt" 0644
        ks_push_pair "$address" "$user" "$port" "$PKI_PATH/etcd/members/$node/server.pem" "$PKI_PATH/etcd/members/$node/server-key.pem" "$ETCD_CONFIG_DIR/pki/server.crt" "$ETCD_CONFIG_DIR/pki/server.key"
        ks_push_pair "$address" "$user" "$port" "$PKI_PATH/etcd/members/$node/peer.pem" "$PKI_PATH/etcd/members/$node/peer-key.pem" "$ETCD_CONFIG_DIR/pki/peer.crt" "$ETCD_CONFIG_DIR/pki/peer.key"
        ks_push_pair "$address" "$user" "$port" "$PKI_PATH/etcd/clients/healthcheck-client.pem" "$PKI_PATH/etcd/clients/healthcheck-client-key.pem" "$ETCD_CONFIG_DIR/pki/healthcheck-client.crt" "$ETCD_CONFIG_DIR/pki/healthcheck-client.key"
        ks_ssh_root "$address" "$user" "$port" chown root:etcd "$ETCD_CONFIG_DIR" "$ETCD_CONFIG_DIR/pki"
        ks_ssh_root "$address" "$user" "$port" chmod 0750 "$ETCD_CONFIG_DIR" "$ETCD_CONFIG_DIR/pki"
        ks_ssh_root "$address" "$user" "$port" chown etcd:etcd "$ETCD_CONFIG_DIR/pki/server.key" "$ETCD_CONFIG_DIR/pki/peer.key" "$ETCD_CONFIG_DIR/pki/healthcheck-client.key"
        ks_ssh_root "$address" "$user" "$port" chmod 0600 "$ETCD_CONFIG_DIR/pki/server.key" "$ETCD_CONFIG_DIR/pki/peer.key" "$ETCD_CONFIG_DIR/pki/healthcheck-client.key"
      fi
    done
  fi
done < "$node_file"

ks_log INFO 'PKI distribution completed; root CA private keys and admin credentials remain on the installation node'
