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
source "$ROOT/scripts/lib/etcd.sh"
source "$ROOT/scripts/lib/etcd-restore.sh"

CONFIG="$ROOT/cluster.env"
COMMAND=
APPLY=false
RESTORE_SNAPSHOT=
RESTORE_MANIFEST=
while (($#)); do
  case $1 in
    --config) (($# >= 2)) || exit 2; CONFIG=$2; shift 2 ;;
    --apply) APPLY=true; shift ;;
    --dry-run) KS_DRY_RUN=true; KS_DRY_RUN_OVERRIDE=true; shift ;;
    --snapshot) (($# >= 2)) || exit 2; RESTORE_SNAPSHOT=$2; shift 2 ;;
    --manifest) (($# >= 2)) || exit 2; RESTORE_MANIFEST=$2; shift 2 ;;
    --help|-h) printf 'Usage: %s [--config FILE] [--dry-run] [--apply] deploy|health|member-list|snapshot|restore-preflight --snapshot FILE --manifest FILE\n' "$0"; exit 0 ;;
    deploy|health|member-list|snapshot|restore-preflight) [[ -z $COMMAND ]] || exit 2; COMMAND=$1; shift ;;
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
ks_etcd_cluster_string "$NODE_INVENTORY_FILE"
ETCD_CLUSTER=$REPLY
IFS=$'\t' read -r ETCD_FILE ETCD_SHA ETCD_VERSION ETCD_ARCH ETCD_URL < <(ks_manifest_lookup "$ROOT/artifacts/manifest.tsv" etcd)
[[ $ETCD_URL == "https://github.com/etcd-io/etcd/releases/download/v$ETCD_VERSION/$ETCD_FILE" ]] || { ks_log ERROR "Unexpected etcd artifact source: $ETCD_URL"; exit 2; }

ks_etcd_ssh_root() {
  local address=$1 user=$2 port=$3
  shift 3
  if [[ $user == root ]]; then
    SSH_USER="$user" SSH_PORT="$port" ks_ssh "$address" "$@"
  else
    SSH_USER="$user" SSH_PORT="$port" ks_ssh "$address" sudo -n "$@"
  fi
}

ks_etcd_deploy() {
  local node role address user port script_sha remote_sha remote_path remote_file
  local -a members=()
  local script_source=$ROOT/scripts/remote/install-etcd.sh
  local script_path=$CACHE_ROOT/ks-etcd-install-etcd.sh
  ks_manifest_verify_cache "$ROOT/artifacts/manifest.tsv" "$CACHE_ROOT"
  ks_verify_sha256 "$CACHE_ROOT/$ETCD_FILE" "$ETCD_SHA"
  ks_etcd_validate_pki "$PKI_PATH"
  [[ $ETCD_VERSION == 3.7.3 && $ETCD_ARCH == amd64 ]] || { ks_log ERROR "Unreviewed etcd artifact: $ETCD_VERSION/$ETCD_ARCH"; return 2; }
  if ! ks_is_true "$KS_DRY_RUN"; then
    [[ -r $SSH_KNOWN_HOSTS_FILE ]] || { ks_log ERROR "Known hosts file missing: $SSH_KNOWN_HOSTS_FILE"; return 2; }
  fi
  IFS=$' ,\t' read -r -a members <<< "$ETCD_NODES"
  if ks_is_true "$KS_DRY_RUN"; then
    ks_log INFO "DRY-RUN: etcd=$ETCD_VERSION archive=$ETCD_FILE sha256=$ETCD_SHA"
    ks_log INFO "DRY-RUN: initial cluster=$ETCD_CLUSTER"
  else
    cp -- "$script_source" "$script_path"
    chmod 0644 "$script_path"
    script_sha=$(ks_sha256_file "$script_path")
    curl --fail --silent --show-error --max-time 10 --output /dev/null "http://127.0.0.1:$ARTIFACT_HTTP_PORT/ks-etcd-install-etcd.sh" || { rm -f -- "$script_path"; ks_log ERROR 'Caddy does not serve the etcd installer script'; return 1; }
  fi
  for node in "${members[@]}"; do
    IFS=$'\t' read -r role address user port < <(ks_node_lookup "$NODE_INVENTORY_FILE" "$node")
    [[ $role == master ]] || return 2
    for remote_file in "$ETCD_CONFIG_DIR/pki/server.crt" "$ETCD_CONFIG_DIR/pki/server.key" "$ETCD_CONFIG_DIR/pki/peer.crt" "$ETCD_CONFIG_DIR/pki/peer.key" "$ETCD_CONFIG_DIR/pki/ca.crt"; do
      if [[ $user == root ]]; then
        SSH_USER="$user" SSH_PORT="$port" ks_ssh "$address" test -r "$remote_file" || { ks_log ERROR "Required remote PKI file missing on $node: $remote_file"; return 2; }
      else
        SSH_USER="$user" SSH_PORT="$port" ks_ssh "$address" sudo -n test -r "$remote_file" || { ks_log ERROR "Required remote PKI file missing on $node: $remote_file"; return 2; }
      fi
    done
    if ks_is_true "$KS_DRY_RUN"; then
      ks_log INFO "DRY-RUN: would install etcd on $node ($address) via Caddy and verify installer SHA256"
      continue
    fi
    remote_path=/var/tmp/ks-etcd-install-etcd.sh
    SSH_USER="$user" SSH_PORT="$port" ks_ssh "$address" curl --fail --silent --show-error --location --proto '=http' --max-time 60 --output "$remote_path" "http://$INSTALL_NODE_ADVERTISE_ADDR:$ARTIFACT_HTTP_PORT/ks-etcd-install-etcd.sh"
    remote_sha=$(SSH_USER="$user" SSH_PORT="$port" ks_ssh "$address" sha256sum "$remote_path" | awk '{print $1}')
    [[ $remote_sha == "$script_sha" ]] || { ks_log ERROR "Installer checksum mismatch on $node"; return 1; }
    SSH_USER="$user" SSH_PORT="$port" ks_ssh "$address" chmod 0700 "$remote_path"
    SSH_USER="$user" SSH_PORT="$port" ks_ssh "$address" bash "$remote_path" "$ETCD_VERSION" "$ETCD_FILE" "$ETCD_SHA" "http://$INSTALL_NODE_ADVERTISE_ADDR:$ARTIFACT_HTTP_PORT" "$ETCD_DATA_DIR" "$ETCD_CONFIG_DIR" "$ETCD_BACKUP_DIR" "$node" "$address" "$ETCD_CLUSTER" "$ETCD_CLIENT_PORT" "$ETCD_PEER_PORT" "$CLUSTER_NAME" "$ETCD_LOG_LEVEL" "$ETCD_AUTO_COMPACTION_RETENTION"
    ks_log INFO "etcd systemd active on $node"
  done
  if ! ks_is_true "$KS_DRY_RUN"; then rm -f -- "$script_path"; fi
}

ks_etcd_first_member() {
  local node role address user port
  local -a members=()
  IFS=$' ,\t' read -r -a members <<< "$ETCD_NODES"
  node=${members[0]}
  IFS=$'\t' read -r role address user port < <(ks_node_lookup "$NODE_INVENTORY_FILE" "$node")
  REPLY=$node
  ETCD_FIRST_ADDRESS=$address
  ETCD_FIRST_USER=$user
  ETCD_FIRST_PORT=$port
}

ks_etcd_cli() {
  local operation=$1 node role address user port endpoint_list='' member
  local -a members=()
  IFS=$' ,\t' read -r -a members <<< "$ETCD_NODES"
  for member in "${members[@]}"; do
    IFS=$'\t' read -r role address user port < <(ks_node_lookup "$NODE_INVENTORY_FILE" "$member")
    [[ -z $endpoint_list ]] || endpoint_list+=,
    endpoint_list+="https://$address:$ETCD_CLIENT_PORT"
  done
  ks_etcd_first_member
  node=$REPLY
  address=$ETCD_FIRST_ADDRESS
  user=$ETCD_FIRST_USER
  port=$ETCD_FIRST_PORT
  local -a cli=(env ETCDCTL_API=3 etcdctl "--endpoints=$endpoint_list" "--cacert=$ETCD_CONFIG_DIR/pki/ca.crt" "--cert=$ETCD_CONFIG_DIR/pki/healthcheck-client.crt" "--key=$ETCD_CONFIG_DIR/pki/healthcheck-client.key")
  case $operation in
    health) ks_etcd_ssh_root "$address" "$user" "$port" "${cli[@]}" endpoint health --cluster ;;
    member-list) ks_etcd_ssh_root "$address" "$user" "$port" "${cli[@]}" member list -w table ;;
    snapshot)
      local stamp snapshot
      local -a remote_lock=(flock -n /run/lock/ks-deploy-shell-node.lock flock -n /run/lock/ks-deploy-shell-etcd.lock)
      stamp=$(date -u '+%Y%m%dT%H%M%SZ')
      snapshot=$ETCD_BACKUP_DIR/$CLUSTER_NAME-$stamp.db
      ks_etcd_ssh_root "$address" "$user" "$port" "${remote_lock[@]}" install -d -o root -g root -m 0700 "$ETCD_BACKUP_DIR"
      ks_etcd_ssh_root "$address" "$user" "$port" "${remote_lock[@]}" env ETCDCTL_API=3 etcdctl "--endpoints=https://127.0.0.1:$ETCD_CLIENT_PORT" "--cacert=$ETCD_CONFIG_DIR/pki/ca.crt" "--cert=$ETCD_CONFIG_DIR/pki/healthcheck-client.crt" "--key=$ETCD_CONFIG_DIR/pki/healthcheck-client.key" snapshot save "$snapshot"
      ks_etcd_ssh_root "$address" "$user" "$port" "${remote_lock[@]}" etcdutl snapshot status "$snapshot" --write-out=table
      ks_etcd_ssh_root "$address" "$user" "$port" "${remote_lock[@]}" sha256sum "$snapshot"
      ks_log WARN "Snapshot retained on etcd member $node at $snapshot; copy it to independently managed encrypted backup storage"
      ;;
  esac
}

case $COMMAND in
  deploy)
    if [[ $APPLY != true || ${KS_DRY_RUN:-true} == true ]]; then
      ks_log INFO 'etcd deployment preview; no remote changes will occur'
      ks_etcd_deploy
    else
      ks_with_lock "$ROOT/state/etcd-deploy.lock" ks_etcd_deploy
      ks_etcd_cli health
      ks_etcd_cli member-list
    fi
    ;;
  restore-preflight)
    [[ $APPLY != true ]] || { ks_log ERROR '--apply is not valid for restore-preflight'; exit 2; }
    [[ -n $RESTORE_SNAPSHOT && -n $RESTORE_MANIFEST ]] || { ks_log ERROR 'restore-preflight requires --snapshot and --manifest'; exit 2; }
    ks_etcd_restore_manifest_validate "$RESTORE_MANIFEST" "$RESTORE_SNAPSHOT" "$CLUSTER_NAME" "$ETCD_VERSION" "$ETCD_CLUSTER"
    ;;
  health|member-list)
    [[ $APPLY != true ]] || { ks_log ERROR '--apply is only valid for deploy'; exit 2; }
    [[ ${KS_DRY_RUN:-true} == false ]] || { ks_log INFO "DRY-RUN: would execute etcd $COMMAND"; exit 0; }
    ks_etcd_cli "$COMMAND"
    ;;
  snapshot)
    if [[ $APPLY != true ]]; then
      if ks_is_true "${KS_DRY_RUN:-true}"; then
        ks_log INFO 'DRY-RUN: would create an etcd snapshot; explicit --apply is required to execute'
        exit 0
      fi
      ks_log ERROR 'etcd snapshot creation requires explicit --apply'
      exit 78
    fi
    if ks_is_true "${KS_DRY_RUN:-true}"; then
      ks_log INFO 'DRY-RUN: would create an etcd snapshot'
      exit 0
    fi
    ks_with_lock "$ROOT/state/etcd-deploy.lock" ks_etcd_cli snapshot
    ;;
esac
