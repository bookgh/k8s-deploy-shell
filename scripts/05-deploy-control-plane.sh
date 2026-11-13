#!/usr/bin/env bash
# shellcheck disable=SC2154 # ks_manifest_get populates the named globals via printf -v.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$ROOT/scripts/lib/common.sh"
source "$ROOT/scripts/lib/config.sh"
source "$ROOT/scripts/lib/nodes.sh"
source "$ROOT/scripts/lib/manifest.sh"
source "$ROOT/scripts/lib/ssh.sh"

CONFIG="$ROOT/cluster.env"
COMMAND=
APPLY=false
while (($#)); do
  case $1 in
    --config) (($# >= 2)) || exit 2; CONFIG=$2; shift 2 ;;
    --apply) APPLY=true; shift ;;
    --dry-run) KS_DRY_RUN=true; KS_DRY_RUN_OVERRIDE=true; shift ;;
    --help|-h) printf 'Usage: %s [--config FILE] [--dry-run] [--apply] deploy|health\n' "$0"; exit 0 ;;
    deploy|health) [[ -z $COMMAND ]] || exit 2; COMMAND=$1; shift ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
[[ -n $COMMAND ]] || { ks_log ERROR 'Command required'; exit 2; }
ks_config_load "$CONFIG"
ks_config_validate
ks_nodes_validate "$NODE_INVENTORY_FILE" "$MASTERS" "$WORKERS"
[[ $SSH_KNOWN_HOSTS_FILE == /* ]] || SSH_KNOWN_HOSTS_FILE=$ROOT/$SSH_KNOWN_HOSTS_FILE
export SSH_KNOWN_HOSTS_FILE
[[ $NODE_INVENTORY_FILE == /* ]] || NODE_INVENTORY_FILE=$ROOT/$NODE_INVENTORY_FILE
if [[ $PKI_ROOT == /* ]]; then PKI_PATH=$(realpath -m -- "$PKI_ROOT"); else PKI_PATH=$(realpath -m -- "$ROOT/$PKI_ROOT"); fi
if [[ $ARTIFACT_HTTP_ROOT == /* ]]; then CACHE_ROOT=$(realpath -m -- "$ARTIFACT_HTTP_ROOT"); else CACHE_ROOT=$(realpath -m -- "$ROOT/$ARTIFACT_HTTP_ROOT"); fi
if [[ $OUTPUT_ROOT == /* ]]; then OUTPUT_PATH=$(realpath -m -- "$OUTPUT_ROOT"); else OUTPUT_PATH=$(realpath -m -- "$ROOT/$OUTPUT_ROOT"); fi

ks_ssh_root() {
  local address=$1 user=$2 port=$3
  shift 3
  if [[ $user == root ]]; then
    SSH_USER="$user" SSH_PORT="$port" ks_ssh "$address" "$@"
  else
    SSH_USER="$user" SSH_PORT="$port" ks_ssh "$address" sudo -n "$@"
  fi
}

ks_etcd_endpoint_list() {
  local node role address result=''
  local -a members=()
  IFS=$' ,\t' read -r -a members <<< "$ETCD_NODES"
  for node in "${members[@]}"; do
    IFS=$'\t' read -r role address _ _ < <(ks_node_lookup "$NODE_INVENTORY_FILE" "$node")
    [[ $role == master ]] || { ks_log ERROR "etcd node is not a Master: $node"; return 2; }
    [[ -z $result ]] || result+=,
    result+="https://$address:$ETCD_CLIENT_PORT"
  done
  REPLY=$result
}

ks_etcd_health() {
  local node role address user port endpoints
  local -a members=()
  IFS=$' ,\t' read -r -a members <<< "$ETCD_NODES"
  node=${members[0]}
  IFS=$'\t' read -r role address user port < <(ks_node_lookup "$NODE_INVENTORY_FILE" "$node")
  [[ $role == master ]] || return 2
  ks_etcd_endpoint_list
  endpoints=$REPLY
  ks_ssh_root "$address" "$user" "$port" env ETCDCTL_API=3 etcdctl "--endpoints=$endpoints" "--cacert=$ETCD_CONFIG_DIR/pki/ca.crt" "--cert=$ETCD_CONFIG_DIR/pki/healthcheck-client.crt" "--key=$ETCD_CONFIG_DIR/pki/healthcheck-client.key" endpoint health --cluster
}

ks_manifest_get() {
  local name=$1 file sha version arch url prefix
  IFS=$'\t' read -r file sha version arch url < <(ks_manifest_lookup "$ROOT/artifacts/manifest.tsv" "$name")
  [[ $arch == amd64 && $file == "$name-$version-linux-amd64" && $url == "https://dl.k8s.io/release/$version/bin/linux/amd64/$name" && $sha =~ ^[a-fA-F0-9]{64}$ ]] || { ks_log ERROR "Untrusted Kubernetes manifest entry: $name"; return 2; }
  prefix=${name//-/_}
  printf -v "${prefix}_FILE" '%s' "$file"
  printf -v "${prefix}_SHA" '%s' "$sha"
  printf -v "${prefix}_VERSION" '%s' "$version"
  printf -v "${prefix}_URL" '%s' "$url"
}

ks_validate_pki() {
  local file
  local -a required=(
    "$PKI_PATH/kubernetes/ca.pem"
    "$PKI_PATH/kubernetes/admin/admin.pem" "$PKI_PATH/kubernetes/admin/admin-key.pem"
    "$PKI_PATH/kubernetes/controller-manager/controller-manager.pem" "$PKI_PATH/kubernetes/controller-manager/controller-manager-key.pem"
    "$PKI_PATH/kubernetes/scheduler/scheduler.pem" "$PKI_PATH/kubernetes/scheduler/scheduler-key.pem"
  )
  for file in "${required[@]}"; do
    [[ -f $file && ! -L $file ]] || { ks_log ERROR "Missing PKI file: $file"; return 2; }
  done
  for file in "$PKI_PATH/kubernetes/admin/admin-key.pem" "$PKI_PATH/kubernetes/controller-manager/controller-manager-key.pem" "$PKI_PATH/kubernetes/scheduler/scheduler-key.pem"; do
    [[ $(stat -c '%a' "$file") == 600 ]] || { ks_log ERROR "Private key mode must be 0600: $file"; return 2; }
  done
}

ks_prepare_kubectl() {
  local source=$CACHE_ROOT/$kubectl_FILE target=$OUTPUT_PATH/bin/kubectl
  ks_verify_sha256 "$source" "$kubectl_SHA"
  install -d -m 0700 "$OUTPUT_PATH" "$OUTPUT_PATH/bin"
  if [[ -e $target ]]; then
    [[ -f $target && ! -L $target ]] || { ks_log ERROR "Unsafe existing kubectl path: $target"; return 2; }
    cmp -s "$source" "$target" || { ks_log ERROR "Existing kubectl differs from pinned artifact: $target"; return 2; }
  else
    install -m 0755 "$source" "$target"
  fi
  KUBECTL_BIN=$target
  "$KUBECTL_BIN" version --client --output=yaml | grep -Fq "gitVersion: $K8S_VERSION"
}

ks_kubeconfig_generate() {
  local target=$1 server=$2 username=$3 cert=$4 key=$5 context=$6 temp
  install -d -m 0700 "$(dirname -- "$target")"
  temp=$(mktemp "$(dirname -- "$target")/.kubeconfig.XXXXXX")
  "$KUBECTL_BIN" config set-cluster "$CLUSTER_NAME" --certificate-authority="$PKI_PATH/kubernetes/ca.pem" --embed-certs=true --server="$server" --kubeconfig="$temp" >/dev/null
  "$KUBECTL_BIN" config set-credentials "$username" --client-certificate="$cert" --client-key="$key" --embed-certs=true --kubeconfig="$temp" >/dev/null
  "$KUBECTL_BIN" config set-context "$context" --cluster="$CLUSTER_NAME" --user="$username" --kubeconfig="$temp" >/dev/null
  "$KUBECTL_BIN" config use-context "$context" --kubeconfig="$temp" >/dev/null
  chmod 0600 "$temp"
  if [[ -e $target ]]; then
    [[ -f $target && ! -L $target ]] || { rm -f "$temp"; ks_log ERROR "Unsafe existing kubeconfig: $target"; return 2; }
    cmp -s "$temp" "$target" || { rm -f "$temp"; ks_log ERROR "Refusing to overwrite different kubeconfig: $target"; return 2; }
    rm -f -- "$temp"
  else
    mv -f -- "$temp" "$target"
  fi
}

ks_kubeconfigs_create() {
  local dir=$OUTPUT_PATH/kubeconfig
  install -d -m 0700 "$dir"
  ks_kubeconfig_generate "$dir/admin.kubeconfig" "https://$CONTROL_PLANE_ENDPOINT:$CONTROL_PLANE_PORT" kubernetes-admin "$PKI_PATH/kubernetes/admin/admin.pem" "$PKI_PATH/kubernetes/admin/admin-key.pem" "kubernetes-admin@$CLUSTER_NAME"
  ks_kubeconfig_generate "$dir/controller-manager.kubeconfig" "https://127.0.0.1:$CONTROL_PLANE_PORT" system:kube-controller-manager "$PKI_PATH/kubernetes/controller-manager/controller-manager.pem" "$PKI_PATH/kubernetes/controller-manager/controller-manager-key.pem" "system:kube-controller-manager@$CLUSTER_NAME"
  ks_kubeconfig_generate "$dir/scheduler.kubeconfig" "https://127.0.0.1:$CONTROL_PLANE_PORT" system:kube-scheduler "$PKI_PATH/kubernetes/scheduler/scheduler.pem" "$PKI_PATH/kubernetes/scheduler/scheduler-key.pem" "system:kube-scheduler@$CLUSTER_NAME"
  chmod 0600 "$dir/"*.kubeconfig
}

ks_deliver_kubeconfig() {
  local address=$1 user=$2 port=$3 source_file=$4 destination=$5 local_sha remote_sha remote_mode
  local_sha=$(ks_sha256_file "$source_file")
  if ks_ssh_root "$address" "$user" "$port" test -f "$destination"; then
    remote_sha=$(ks_ssh_root "$address" "$user" "$port" sha256sum "$destination" | awk '{print $1}')
    remote_mode=$(ks_ssh_root "$address" "$user" "$port" stat -c '%a' "$destination")
    [[ $remote_sha == "$local_sha" && $remote_mode == 600 ]] || { ks_log ERROR "Refusing to trust different or weakly protected remote kubeconfig: $address:$destination"; return 2; }
  else
    SSH_USER="$user" SSH_PORT="$port" ks_ssh_install_file "$address" "$source_file" "$destination" 0600
  fi
}

ks_control_plane_install() {
  local node role address user port name script_path script_sha remote_sha remote_path remote_file attempt
  local -a masters=()
  local script_source=$ROOT/scripts/remote/install-control-plane.sh
  local kubeconfig_dir=$OUTPUT_PATH/kubeconfig
  script_path=$CACHE_ROOT/ks-control-plane-install.sh
  ks_manifest_verify_cache "$ROOT/artifacts/manifest.tsv" "$CACHE_ROOT"
  for name in kube-apiserver kube-controller-manager kube-scheduler kubectl; do
    case $name in
      kube-apiserver) ks_verify_sha256 "$CACHE_ROOT/$kube_apiserver_FILE" "$kube_apiserver_SHA" ;;
      kube-controller-manager) ks_verify_sha256 "$CACHE_ROOT/$kube_controller_manager_FILE" "$kube_controller_manager_SHA" ;;
      kube-scheduler) ks_verify_sha256 "$CACHE_ROOT/$kube_scheduler_FILE" "$kube_scheduler_SHA" ;;
      kubectl) ks_verify_sha256 "$CACHE_ROOT/$kubectl_FILE" "$kubectl_SHA" ;;
    esac
  done
  [[ -r $SSH_KNOWN_HOSTS_FILE ]] || { ks_log ERROR "Known hosts file missing: $SSH_KNOWN_HOSTS_FILE"; return 2; }
  IFS=$' ,\t' read -r -a masters <<< "$MASTERS"
  cp -- "$script_source" "$script_path"
  chmod 0644 "$script_path"
  script_sha=$(ks_sha256_file "$script_path")
  curl --fail --silent --show-error --max-time 10 --output /dev/null "http://127.0.0.1:$ARTIFACT_HTTP_PORT/ks-control-plane-install.sh" || { rm -f -- "$script_path"; ks_log ERROR 'Caddy does not serve the control-plane installer script'; return 1; }
  for node in "${masters[@]}"; do
    IFS=$'\t' read -r role address user port < <(ks_node_lookup "$NODE_INVENTORY_FILE" "$node")
    [[ $role == master ]] || return 2
    for remote_file in "$KUBERNETES_CONFIG_DIR/pki/apiserver.crt" "$KUBERNETES_CONFIG_DIR/pki/apiserver.key" "$KUBERNETES_CONFIG_DIR/pki/ca-bundle.crt" "$KUBERNETES_CONFIG_DIR/pki/cluster-signer.key" "$KUBERNETES_CONFIG_DIR/pki/controller-manager.crt" "$KUBERNETES_CONFIG_DIR/pki/scheduler.crt" "$KUBERNETES_CONFIG_DIR/pki/etcd/ca.crt"; do
      ks_ssh_root "$address" "$user" "$port" test -r "$remote_file" || { ks_log ERROR "Required control-plane PKI file missing on $node: $remote_file"; return 2; }
    done
    remote_path=/var/tmp/ks-control-plane-install.sh
    SSH_USER="$user" SSH_PORT="$port" ks_ssh "$address" curl --fail --silent --show-error --location --proto '=http' --max-time 60 --output "$remote_path" "http://$INSTALL_NODE_ADVERTISE_ADDR:$ARTIFACT_HTTP_PORT/ks-control-plane-install.sh"
    remote_sha=$(SSH_USER="$user" SSH_PORT="$port" ks_ssh "$address" sha256sum "$remote_path" | awk '{print $1}')
    [[ $remote_sha == "$script_sha" ]] || { ks_log ERROR "Control-plane installer checksum mismatch on $node"; return 1; }
    SSH_USER="$user" SSH_PORT="$port" ks_ssh "$address" chmod 0700 "$remote_path"
    SSH_USER="$user" SSH_PORT="$port" ks_ssh "$address" bash "$remote_path" "$K8S_VERSION" "$kube_apiserver_FILE" "$kube_apiserver_SHA" "$kube_controller_manager_FILE" "$kube_controller_manager_SHA" "$kube_scheduler_FILE" "$kube_scheduler_SHA" "$kubectl_FILE" "$kubectl_SHA" "http://$INSTALL_NODE_ADVERTISE_ADDR:$ARTIFACT_HTTP_PORT" "$KUBERNETES_BIN_DIR" "$KUBERNETES_CONFIG_DIR" "$KUBERNETES_LOG_DIR" "$KUBERNETES_DATA_DIR" "$node" "$address" "$CONTROL_PLANE_PORT" "$CONTROLLER_MANAGER_PORT" "$SCHEDULER_PORT" "$SERVICE_CIDR" "$POD_CIDR" "$CLUSTER_DOMAIN" "$CLUSTER_NAME" "$ETCD_ENDPOINTS"
    ks_deliver_kubeconfig "$address" "$user" "$port" "$kubeconfig_dir/controller-manager.kubeconfig" "$KUBERNETES_CONFIG_DIR/controller-manager.kubeconfig"
    ks_deliver_kubeconfig "$address" "$user" "$port" "$kubeconfig_dir/scheduler.kubeconfig" "$KUBERNETES_CONFIG_DIR/scheduler.kubeconfig"
    ks_ssh_root "$address" "$user" "$port" systemctl enable --now kube-apiserver.service
    for ((attempt=1; attempt<=60; attempt++)); do
      if ks_ssh_root "$address" "$user" "$port" curl --fail --silent --show-error --proto '=https' --cacert "$KUBERNETES_CONFIG_DIR/pki/ca.crt" "https://127.0.0.1:$CONTROL_PLANE_PORT/readyz"; then break; fi
      ((attempt == 60)) && { ks_log ERROR "API Server did not become ready on $node"; return 1; }
      sleep 2
    done
    ks_ssh_root "$address" "$user" "$port" systemctl enable --now kube-controller-manager.service
    ks_ssh_root "$address" "$user" "$port" systemctl enable --now kube-scheduler.service
    ks_ssh_root "$address" "$user" "$port" systemctl is-active kube-apiserver.service kube-controller-manager.service kube-scheduler.service
    ks_log INFO "Control-plane components active on $node"
  done
  rm -f -- "$script_path"
  "$KUBECTL_BIN" --kubeconfig "$kubeconfig_dir/admin.kubeconfig" --request-timeout=15s get --raw=/readyz
}

ks_control_plane_apply() {
  ks_etcd_health
  ks_prepare_kubectl
  ks_kubeconfigs_create
  ks_control_plane_install
}

ks_control_plane_health() {
  local admin_kubeconfig=$OUTPUT_PATH/kubeconfig/admin.kubeconfig
  [[ -r $admin_kubeconfig ]] || { ks_log ERROR 'Admin kubeconfig is missing; deploy control plane first'; return 2; }
  [[ -x $OUTPUT_PATH/bin/kubectl ]] || { ks_log ERROR 'kubectl is missing from output/bin; deploy control plane first'; return 2; }
  "$OUTPUT_PATH/bin/kubectl" --kubeconfig "$admin_kubeconfig" --request-timeout=15s get --raw=/readyz
}

ks_manifest_get kube-apiserver
K8S_VERSION=$kube_apiserver_VERSION
ks_manifest_get kube-controller-manager
ks_manifest_get kube-scheduler
ks_manifest_get kubectl
[[ $K8S_VERSION == v1.37.2 ]] || { ks_log ERROR "Unsupported Kubernetes version: $K8S_VERSION"; exit 2; }
[[ $kube_controller_manager_VERSION == "$K8S_VERSION" && $kube_scheduler_VERSION == "$K8S_VERSION" && $kubectl_VERSION == "$K8S_VERSION" ]] || { ks_log ERROR 'Kubernetes component version skew in artifact manifest'; exit 2; }
ks_etcd_endpoint_list
ETCD_ENDPOINTS=$REPLY

case $COMMAND in
  deploy)
    if [[ $APPLY != true || ${KS_DRY_RUN:-true} == true ]]; then
      ks_log INFO "DRY-RUN: would deploy Kubernetes $K8S_VERSION API Server, Controller Manager and Scheduler on: $MASTERS"
      ks_log INFO "DRY-RUN: admin kubeconfig endpoint https://$CONTROL_PLANE_ENDPOINT:$CONTROL_PLANE_PORT"
      ks_log INFO 'DRY-RUN: controller/scheduler kubeconfigs are sent over SSH stdin; admin kubeconfig stays on the installation node'
      ks_manifest_verify_cache "$ROOT/artifacts/manifest.tsv" "$CACHE_ROOT"
      ks_validate_pki
    else
      ks_validate_pki
      ks_with_lock "$ROOT/state/control-plane-deploy.lock" ks_control_plane_apply
    fi
    ;;
  health)
    [[ $APPLY != true ]] || { ks_log ERROR '--apply is only valid for deploy'; exit 2; }
    [[ ${KS_DRY_RUN:-true} == false ]] || { ks_log INFO 'DRY-RUN: would query the Kubernetes API readiness endpoint'; exit 0; }
    ks_control_plane_health
    ;;
esac
