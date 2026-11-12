#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ks_config_load() {
  local file=${1:?config file required} line key value lineno=0
  [[ -r $file ]] || { ks_log ERROR "Cannot read config: $file"; return 2; }
  while IFS= read -r line || [[ -n $line ]]; do
    ((lineno+=1))
    [[ -z $line || $line =~ ^[[:space:]]*# ]] && continue
    [[ $line == *=* ]] || { ks_log ERROR "Invalid config line $lineno"; return 2; }
    key=${line%%=*}; value=${line#*=}
    case $key in
      CLUSTER_NAME|INSTALL_NODE_ADVERTISE_ADDR|ARTIFACT_HTTP_PORT|ARTIFACT_HTTP_ROOT|INSTALL_ROOT|REMOTE_INSTALL_ROOT|SSH_USER|SSH_PORT|SSH_CONNECT_TIMEOUT|SSH_RETRIES|SSH_BACKOFF_SECONDS|SSH_KNOWN_HOSTS_FILE|POD_CIDR|SERVICE_CIDR|CLUSTER_DNS|CLUSTER_DOMAIN|RUNTIME|KUBE_PROXY_MODE|IMAGE_MODE|ENABLE_HARBOR|ENABLE_FIREWALL_CONFIG|DISABLE_SELINUX|DRY_RUN|MASTERS|WORKERS|ETCD_NODES) ;;
      *) ks_log ERROR "Unknown config key at line $lineno: $key"; return 2 ;;
    esac
    [[ $value != *'$('* && $value != *$'\x60'* && $value != *';'* && $value != *'&'* && $value != *'|'* && $value != *'<'* && $value != *'>'* && $value != *$'\r'* ]] || { ks_log ERROR "Unsafe config value at line $lineno"; return 2; }
    printf -v "$key" '%s' "$value"
    export "$key=$value"
  done < "$file"
}
ks_config_validate() {
  local key node
  for key in CLUSTER_NAME INSTALL_NODE_ADVERTISE_ADDR ARTIFACT_HTTP_PORT SSH_USER SSH_PORT SSH_CONNECT_TIMEOUT SSH_RETRIES SSH_BACKOFF_SECONDS SSH_KNOWN_HOSTS_FILE POD_CIDR SERVICE_CIDR CLUSTER_DNS CLUSTER_DOMAIN RUNTIME KUBE_PROXY_MODE IMAGE_MODE ENABLE_HARBOR ENABLE_FIREWALL_CONFIG DISABLE_SELINUX MASTERS WORKERS ETCD_NODES; do
    [[ -n ${!key:-} ]] || { ks_log ERROR "Missing config key: $key"; return 2; }
  done
  [[ $ARTIFACT_HTTP_PORT =~ ^[0-9]+$ ]] && ((ARTIFACT_HTTP_PORT > 0 && ARTIFACT_HTTP_PORT < 65536)) || return 2
  [[ $SSH_PORT =~ ^[0-9]+$ ]] && ((SSH_PORT > 0 && SSH_PORT < 65536)) || return 2
  [[ $SSH_CONNECT_TIMEOUT =~ ^[0-9]+$ && $SSH_RETRIES =~ ^[0-9]+$ && $SSH_BACKOFF_SECONDS =~ ^[0-9]+$ ]] || return 2
  [[ $RUNTIME == containerd || $RUNTIME == cri-dockerd ]] || return 2
  [[ $KUBE_PROXY_MODE == nftables || $KUBE_PROXY_MODE == ipvs || $KUBE_PROXY_MODE == iptables ]] || return 2
  [[ $IMAGE_MODE == offline-harbor || $IMAGE_MODE == online || $IMAGE_MODE == local-import ]] || return 2
  [[ $ENABLE_HARBOR == true || $ENABLE_HARBOR == false ]] || return 2
  [[ $DISABLE_SELINUX == true || $DISABLE_SELINUX == false ]] || return 2
  [[ $ENABLE_FIREWALL_CONFIG == true || $ENABLE_FIREWALL_CONFIG == false ]] || return 2
  [[ $INSTALL_NODE_ADVERTISE_ADDR =~ ^[A-Za-z0-9.-]+$ ]] || return 2
  local -a nodes=()
  IFS=' ' read -r -a nodes <<< "${MASTERS//,/ } ${WORKERS//,/ } ${ETCD_NODES//,/ }"
  for node in "${nodes[@]}"; do
    [[ $node =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { ks_log ERROR "Invalid node identifier: $node"; return 2; }
  done
  [[ $POD_CIDR != "$SERVICE_CIDR" ]] || { ks_log ERROR 'Pod and Service CIDRs must differ'; return 2; }
}
