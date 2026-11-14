#!/usr/bin/env bash
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
    --help|-h) printf 'Usage: %s [--config FILE] [--dry-run] [--apply] deploy\n' "$0"; exit 0 ;;
    deploy) [[ -z $COMMAND ]] || exit 2; COMMAND=$1; shift ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
[[ $COMMAND == deploy ]] || { ks_log ERROR 'Command required: deploy'; exit 2; }
ks_config_load "$CONFIG"
ks_config_validate
ks_nodes_validate "$NODE_INVENTORY_FILE" "$MASTERS" "$WORKERS"
for command_name in curl realpath awk sha256sum install cp chmod mv rm mktemp; do ks_require_cmd "$command_name"; done
[[ $NODE_INVENTORY_FILE == /* ]] || NODE_INVENTORY_FILE=$ROOT/$NODE_INVENTORY_FILE
[[ $SSH_KNOWN_HOSTS_FILE == /* ]] || SSH_KNOWN_HOSTS_FILE=$ROOT/$SSH_KNOWN_HOSTS_FILE
export SSH_KNOWN_HOSTS_FILE
if [[ $ARTIFACT_HTTP_ROOT == /* ]]; then CACHE_ROOT=$(realpath -m -- "$ARTIFACT_HTTP_ROOT"); else CACHE_ROOT=$(realpath -m -- "$ROOT/$ARTIFACT_HTTP_ROOT"); fi
NGINX_VERSION=$(ks_yaml_scalar "$ROOT/versions.yaml" nginx version)
IFS=$'\t' read -r _ SOURCE_SHA _ SOURCE_ARCH SOURCE_URL < <(ks_manifest_lookup "$ROOT/artifacts/manifest.tsv" nginx-source)
[[ $SOURCE_ARCH == noarch && $SOURCE_URL == "https://nginx.org/download/nginx-$NGINX_VERSION.tar.gz" ]] || { ks_log ERROR 'Nginx source manifest mismatch'; exit 2; }
MASTER_ADDRS=
IFS=',' read -r -a master_nodes <<< "$MASTERS"
for master in "${master_nodes[@]}"; do
  IFS=$'\t' read -r role master_address _ _ < <(ks_node_lookup "$NODE_INVENTORY_FILE" "$master")
  [[ $role == master ]] || { ks_log ERROR "Node $master is not a master"; exit 2; }
  [[ -z $MASTER_ADDRS ]] && MASTER_ADDRS=$master_address || MASTER_ADDRS+=",$master_address"
done
if [[ $APPLY != true || ${KS_DRY_RUN:-true} == true ]]; then
  ks_log INFO "DRY-RUN: deploy Nginx $NGINX_VERSION stream proxy to Worker nodes"
  ks_log INFO "Loopback listener: 127.0.0.1:$CONTROL_PLANE_PORT; upstream Masters: $MASTER_ADDRS"
  ks_log INFO 'Nginx uses passive TCP failure handling only; no commercial active health-check directive is assumed'
  while IFS=$'\t' read -r node role address user port || [[ -n ${node:-} ]]; do
    [[ -z ${node:-} || $node == node_id || $node == \#* ]] && continue
    [[ $role == worker ]] && ks_log INFO "DRY-RUN: configure local API proxy on $node ($address)"
  done < "$NODE_INVENTORY_FILE"
  exit 0
fi
STATE_FILE=$ROOT/state/generated-artifacts.tsv
[[ -f $STATE_FILE && ! -L $STATE_FILE ]] || { ks_log ERROR 'Missing generated-artifacts state; build Nginx first'; exit 78; }
artifact_row=$(awk -F '\t' -v name=nginx-stream -v version="$NGINX_VERSION" 'NR > 1 && $1 == name && $2 == version { print; count++ } END { if (count != 1) exit 2 }' "$STATE_FILE") || {
  ks_log ERROR 'No unique generated Nginx artifact record; run build-nginx first'
  exit 78
}
IFS=$'\t' read -r artifact_name artifact_version artifact_arch ARCHIVE_NAME ARCHIVE_SHA ARCHIVE_SOURCE_SHA <<< "$artifact_row"
[[ $artifact_name == nginx-stream && $artifact_version == "$NGINX_VERSION" && $artifact_arch == amd64 && $ARCHIVE_NAME == "nginx-stream-$NGINX_VERSION-linux-amd64.tar.gz" && $ARCHIVE_SHA =~ ^[a-fA-F0-9]{64}$ && $ARCHIVE_SOURCE_SHA == "$SOURCE_SHA" ]] || {
  ks_log ERROR 'Generated Nginx artifact record does not match pinned source/version'
  exit 2
}
ARCHIVE_PATH=$CACHE_ROOT/$ARCHIVE_NAME
[[ -f $ARCHIVE_PATH && ! -L $ARCHIVE_PATH ]] || { ks_log ERROR "Nginx archive missing or unsafe: $ARCHIVE_PATH"; exit 2; }
ks_verify_sha256 "$ARCHIVE_PATH" "$ARCHIVE_SHA"
[[ -r $SSH_KNOWN_HOSTS_FILE ]] || { ks_log ERROR "Known hosts file missing: $SSH_KNOWN_HOSTS_FILE"; exit 2; }

script_source=$ROOT/scripts/remote/install-worker-proxy.sh
script_path=$CACHE_ROOT/ks-worker-proxy-install.sh
script_tmp=
SCRIPT_CREATED=false
cleanup() {
  [[ -z $script_tmp || ! -e $script_tmp ]] || rm -f -- "$script_tmp"
  [[ $SCRIPT_CREATED != true || ! -e $script_path ]] || rm -f -- "$script_path"
}
trap cleanup EXIT
[[ -f $script_source && ! -L $script_source ]] || { ks_log ERROR 'Remote Worker proxy installer is missing or unsafe'; exit 2; }
[[ ! -L $script_path ]] || { ks_log ERROR 'Refusing symlink at public installer path'; exit 2; }
script_tmp=$(mktemp "$CACHE_ROOT/.ks-worker-proxy.XXXXXX")
cp -- "$script_source" "$script_tmp"
chmod 0644 "$script_tmp"
mv -f -- "$script_tmp" "$script_path"
SCRIPT_CREATED=true
script_tmp=
script_sha=$(ks_sha256_file "$script_path")
curl --fail --silent --show-error --max-time 10 --output /dev/null "http://127.0.0.1:$ARTIFACT_HTTP_PORT/ks-worker-proxy-install.sh" || { ks_log ERROR 'Caddy does not serve the Worker proxy installer'; exit 1; }
curl --fail --silent --show-error --max-time 30 --output /dev/null "http://127.0.0.1:$ARTIFACT_HTTP_PORT/$ARCHIVE_NAME" || { ks_log ERROR 'Caddy does not serve the generated Nginx archive'; exit 1; }

while IFS=$'\t' read -r node role address user port || [[ -n ${node:-} ]]; do
  [[ -z ${node:-} || $node == node_id || $node == \#* ]] && continue
  [[ $role == worker ]] || continue
  remote_path=/var/tmp/ks-worker-proxy-install.sh
  SSH_USER=$user SSH_PORT=$port ks_ssh "$address" curl --fail --silent --show-error --location --proto '=http' --proto-redir '=http' --max-time 60 --output "$remote_path" "http://$INSTALL_NODE_ADVERTISE_ADDR:$ARTIFACT_HTTP_PORT/ks-worker-proxy-install.sh"
  remote_sha=$(SSH_USER=$user SSH_PORT=$port ks_ssh "$address" sha256sum "$remote_path" | awk '{print $1}')
  [[ $remote_sha == "$script_sha" ]] || { ks_log ERROR "Worker proxy installer checksum mismatch on $node"; exit 1; }
  SSH_USER=$user SSH_PORT=$port ks_ssh "$address" chmod 0700 "$remote_path"
  SSH_USER=$user SSH_PORT=$port ks_ssh "$address" bash "$remote_path" \
    "$NGINX_VERSION" "$ARCHIVE_NAME" "$ARCHIVE_SHA" \
    "http://$INSTALL_NODE_ADVERTISE_ADDR:$ARTIFACT_HTTP_PORT" \
    "$NGINX_BIN" "$NGINX_CONFIG_DIR" "$NGINX_LOG_DIR" "$NGINX_PID_FILE" \
    "$CONTROL_PLANE_PORT" "$MASTER_ADDRS" "$NGINX_WORKER_CONNECTIONS" \
    "$NGINX_PROXY_CONNECT_TIMEOUT" "$NGINX_PROXY_TIMEOUT" "$NGINX_UPSTREAM_MAX_FAILS" \
    "$NGINX_UPSTREAM_FAIL_TIMEOUT" "$NGINX_NEXT_UPSTREAM_TRIES" "$NGINX_NEXT_UPSTREAM_TIMEOUT" "$node"
  SSH_USER=$user SSH_PORT=$port ks_ssh "$address" rm -f "$remote_path"
  ks_log INFO "Worker API proxy active on $node at 127.0.0.1:$CONTROL_PLANE_PORT"
done < "$NODE_INVENTORY_FILE"
