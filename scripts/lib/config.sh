#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ks_ipv4_to_int() {
  local ip=${1:?IPv4 address required} part octet
  local -a octets=()
  [[ $ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 2
  IFS='.' read -r -a octets <<< "$ip"
  REPLY=0
  for part in "${octets[@]}"; do
    octet=$((10#$part)); ((octet <= 255)) || return 2
    REPLY=$(((REPLY << 8) | octet))
  done
}
ks_cidr_parse() {
  local cidr=${1:?CIDR required} ip prefix address mask
  [[ $cidr == */* && ${cidr#*/} != */* ]] || return 2
  ip=${cidr%/*}; prefix=${cidr#*/}
  [[ $prefix =~ ^[0-9]{1,2}$ ]] && ((10#$prefix <= 32)) || return 2
  ks_ipv4_to_int "$ip" || return 2
  address=$REPLY; prefix=$((10#$prefix))
  if ((prefix == 0)); then mask=0; else mask=$(((0xFFFFFFFF << (32-prefix)) & 0xFFFFFFFF)); fi
  REPLY=$((address & mask))
  KS_CIDR_END=$((REPLY + (1 << (32-prefix)) - 1))
}
ks_cidr_overlaps() {
  local first=$1 second=$2 first_start first_end second_start second_end
  ks_cidr_parse "$first" || return 2
  first_start=$REPLY; first_end=$KS_CIDR_END
  ks_cidr_parse "$second" || return 2
  second_start=$REPLY; second_end=$KS_CIDR_END
  ((first_start <= second_end && second_start <= first_end))
}
ks_ip_in_cidr() {
  local ip=$1 cidr=$2 address start end
  ks_ipv4_to_int "$ip" || return 2
  address=$REPLY
  ks_cidr_parse "$cidr" || return 2
  start=$REPLY; end=$KS_CIDR_END
  ((address >= start && address <= end))
}
ks_config_load() {
  local file=${1:?config file required} line key value lineno=0
  local -A seen=()
  [[ -r $file ]] || { ks_log ERROR "Cannot read config: $file"; return 2; }
  while IFS= read -r line || [[ -n $line ]]; do
    ((lineno+=1))
    [[ -z $line || $line =~ ^[[:space:]]*# ]] && continue
    [[ $line == *=* ]] || { ks_log ERROR "Invalid config line $lineno"; return 2; }
    key=${line%%=*}; value=${line#*=}
    case $key in
      CLUSTER_NAME|INSTALL_NODE_ADVERTISE_ADDR|ARTIFACT_HTTP_PORT|ARTIFACT_HTTP_ROOT|INSTALL_ROOT|REMOTE_INSTALL_ROOT|SSH_USER|SSH_PORT|SSH_CONNECT_TIMEOUT|SSH_RETRIES|SSH_BACKOFF_SECONDS|SSH_KNOWN_HOSTS_FILE|NODE_INVENTORY_FILE|POD_CIDR|SERVICE_CIDR|CLUSTER_DNS|CLUSTER_DOMAIN|RUNTIME|KUBE_PROXY_MODE|IMAGE_MODE|ENABLE_HARBOR|ENABLE_FIREWALL_CONFIG|DISABLE_SELINUX|DRY_RUN|MASTERS|WORKERS|ETCD_NODES) ;;
      *) ks_log ERROR "Unknown config key at line $lineno: $key"; return 2 ;;
    esac
    [[ -z ${seen[$key]+present} ]] || { ks_log ERROR "Duplicate config key at line $lineno: $key"; return 2; }
    seen[$key]=1
    [[ $value != *'$('* && $value != *'$'* && $value != *$'\x60'* && $value != *';'* && $value != *'&'* && $value != *'|'* && $value != *'<'* && $value != *'>'* && $value != *$'\r'* ]] || { ks_log ERROR "Unsafe config value at line $lineno"; return 2; }
    printf -v "$key" '%s' "$value"
    export "$key=$value"
  done < "$file"
  if [[ ${KS_DRY_RUN_OVERRIDE:-false} != true ]]; then export KS_DRY_RUN=$DRY_RUN; fi
}
ks_config_validate() {
  local key node
  local -a masters=() workers=() etcd=()
  local -A master_set=() worker_set=() etcd_set=()
  for key in CLUSTER_NAME INSTALL_NODE_ADVERTISE_ADDR ARTIFACT_HTTP_PORT SSH_USER SSH_PORT SSH_CONNECT_TIMEOUT SSH_RETRIES SSH_BACKOFF_SECONDS SSH_KNOWN_HOSTS_FILE NODE_INVENTORY_FILE POD_CIDR SERVICE_CIDR CLUSTER_DNS CLUSTER_DOMAIN RUNTIME KUBE_PROXY_MODE IMAGE_MODE ENABLE_HARBOR ENABLE_FIREWALL_CONFIG DISABLE_SELINUX DRY_RUN MASTERS WORKERS ETCD_NODES; do
    [[ -n ${!key:-} ]] || { ks_log ERROR "Missing config key: $key"; return 2; }
  done
  [[ $CLUSTER_NAME =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]] || { ks_log ERROR 'Invalid cluster name'; return 2; }
  [[ $ARTIFACT_HTTP_PORT =~ ^[0-9]{1,5}$ ]] && ((10#$ARTIFACT_HTTP_PORT > 0 && 10#$ARTIFACT_HTTP_PORT < 65536)) || return 2
  [[ $SSH_PORT =~ ^[0-9]{1,5}$ ]] && ((10#$SSH_PORT > 0 && 10#$SSH_PORT < 65536)) || return 2
  [[ $SSH_CONNECT_TIMEOUT =~ ^[0-9]+$ && $SSH_RETRIES =~ ^[0-9]+$ && $SSH_BACKOFF_SECONDS =~ ^[0-9]+$ ]] || return 2
  ((10#$SSH_CONNECT_TIMEOUT >= 1 && 10#$SSH_CONNECT_TIMEOUT <= 120 && 10#$SSH_RETRIES >= 1 && 10#$SSH_RETRIES <= 10 && 10#$SSH_BACKOFF_SECONDS <= 30)) || return 2
  [[ $SSH_USER =~ ^[a-z_][a-zA-Z0-9_-]*[$]?$ ]] || return 2
  [[ $RUNTIME == containerd || $RUNTIME == cri-dockerd ]] || return 2
  [[ $KUBE_PROXY_MODE == nftables || $KUBE_PROXY_MODE == ipvs || $KUBE_PROXY_MODE == iptables ]] || return 2
  [[ $IMAGE_MODE == offline-harbor || $IMAGE_MODE == online || $IMAGE_MODE == local-import ]] || return 2
  [[ $ENABLE_HARBOR == true || $ENABLE_HARBOR == false ]] || return 2
  [[ $DISABLE_SELINUX == true || $DISABLE_SELINUX == false ]] || return 2
  [[ $ENABLE_FIREWALL_CONFIG == true || $ENABLE_FIREWALL_CONFIG == false ]] || return 2
  [[ $DRY_RUN == true || $DRY_RUN == false ]] || return 2
  [[ $INSTALL_NODE_ADVERTISE_ADDR =~ ^[A-Za-z0-9.-]+$ && $CLUSTER_DOMAIN =~ ^[A-Za-z0-9.-]+$ ]] || return 2
  [[ $SSH_KNOWN_HOSTS_FILE != *[[:space:]]* && $NODE_INVENTORY_FILE != *[[:space:]]* && $ARTIFACT_HTTP_ROOT == /var/lib/k8s-deploy-shell/artifacts/* && $INSTALL_ROOT != *[[:space:]]* && $REMOTE_INSTALL_ROOT != *[[:space:]]* ]] || { ks_log ERROR "ARTIFACT_HTTP_ROOT must be under /var/lib/k8s-deploy-shell/artifacts"; return 2; }
  ks_cidr_parse "$POD_CIDR" || { ks_log ERROR "Invalid POD_CIDR: $POD_CIDR"; return 2; }
  ks_cidr_parse "$SERVICE_CIDR" || { ks_log ERROR "Invalid SERVICE_CIDR: $SERVICE_CIDR"; return 2; }
  if ks_cidr_overlaps "$POD_CIDR" "$SERVICE_CIDR"; then
    ks_log ERROR 'POD_CIDR overlaps SERVICE_CIDR'; return 2
  else
    local rc=$?; ((rc == 1)) || return "$rc"
  fi
  ks_ip_in_cidr "$CLUSTER_DNS" "$SERVICE_CIDR" || { ks_log ERROR 'CLUSTER_DNS must be a valid address inside SERVICE_CIDR'; return 2; }
  if [[ $INSTALL_NODE_ADVERTISE_ADDR =~ ^[0-9.]+$ ]]; then
    ks_ipv4_to_int "$INSTALL_NODE_ADVERTISE_ADDR" || { ks_log ERROR 'Invalid INSTALL_NODE_ADVERTISE_ADDR IPv4'; return 2; }
  fi
  IFS=$' ,\t' read -r -a masters <<< "$MASTERS"
  IFS=$' ,\t' read -r -a workers <<< "$WORKERS"
  IFS=$' ,\t' read -r -a etcd <<< "$ETCD_NODES"
  (("${#masters[@]}" > 0 && "${#etcd[@]}" > 0)) || return 2
  for node in "${masters[@]}"; do
    [[ $node =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 2
    [[ -z ${master_set[$node]+present} ]] || { ks_log ERROR "Duplicate master: $node"; return 2; }
    master_set[$node]=1
  done
  for node in "${workers[@]}"; do
    [[ $node =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 2
    [[ -z ${worker_set[$node]+present} ]] || { ks_log ERROR "Duplicate worker: $node"; return 2; }
    [[ -z ${master_set[$node]+present} ]] || { ks_log ERROR "Node has both Master and Worker roles: $node"; return 2; }
    worker_set[$node]=1
  done
  for node in "${etcd[@]}"; do
    [[ -n ${master_set[$node]+present} ]] || { ks_log ERROR "etcd node is not a Master: $node"; return 2; }
    [[ -z ${etcd_set[$node]+present} ]] || { ks_log ERROR "Duplicate etcd node: $node"; return 2; }
    etcd_set[$node]=1
  done
  (("${#etcd[@]}" % 2 == 1)) || { ks_log ERROR 'ETCD_NODES must contain an odd number of members'; return 2; }
}
