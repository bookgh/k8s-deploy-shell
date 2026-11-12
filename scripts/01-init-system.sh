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
CHECK_SSH=false
while (($#)); do
  case $1 in
    --config) (($# >= 2)) || exit 2; CONFIG=$2; shift 2 ;;
    --apply) APPLY=true; shift ;;
    --check-ssh) CHECK_SSH=true; shift ;;
    --dry-run) KS_DRY_RUN=true; KS_DRY_RUN_OVERRIDE=true; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

ks_config_load "$CONFIG"
ks_config_validate
ks_nodes_validate "$NODE_INVENTORY_FILE" "$MASTERS" "$WORKERS"
if [[ $SSH_KNOWN_HOSTS_FILE != /* ]]; then SSH_KNOWN_HOSTS_FILE=$ROOT/$SSH_KNOWN_HOSTS_FILE; fi
export SSH_KNOWN_HOSTS_FILE

if [[ $CHECK_SSH == true ]]; then
  node_file=$NODE_INVENTORY_FILE
  [[ $node_file == /* ]] || node_file=$ROOT/$node_file
  if ks_is_true "$KS_DRY_RUN"; then
    while IFS=$'\t' read -r node role address user port || [[ -n ${node:-} ]]; do
      [[ -z ${node:-} || $node == node_id || $node == \#* ]] && continue
      SSH_USER="$user" SSH_PORT="$port" ks_ssh "$address" cat /etc/os-release
      SSH_USER="$user" SSH_PORT="$port" ks_ssh "$address" uname -m
      SSH_USER="$user" SSH_PORT="$port" ks_ssh "$address" id -u
    done < "$node_file"
    exit 0
  fi
  while IFS=$'\t' read -r node role address user port || [[ -n ${node:-} ]]; do
    [[ -z ${node:-} || $node == node_id || $node == \#* ]] && continue
    remote_os=$(SSH_USER="$user" SSH_PORT="$port" ks_ssh "$address" cat /etc/os-release)
    remote_arch=$(SSH_USER="$user" SSH_PORT="$port" ks_ssh "$address" uname -m)
    remote_uid=$(SSH_USER="$user" SSH_PORT="$port" ks_ssh "$address" id -u)
    if [[ $remote_uid != 0 ]]; then
      SSH_USER="$user" SSH_PORT="$port" ks_ssh "$address" sudo -n true
      remote_os=$(SSH_USER="$user" SSH_PORT="$port" ks_ssh "$address" sudo -n cat /etc/os-release)
    fi
    remote_id=$(sed -n 's/^ID=//p' <<< "$remote_os" | tr -d '"')
    remote_version=$(sed -n 's/^VERSION_ID=//p' <<< "$remote_os" | tr -d '"')
    [[ $remote_id == rocky && ${remote_version%%.*} == 9 && $remote_arch == x86_64 ]] || {
      ks_log ERROR "Target $node must be Rocky Linux 9 / x86_64; found $remote_id $remote_version / $remote_arch"
      exit 1
    }
    ks_log INFO "SSH and OS preflight passed: $node ($address)"
  done < "$node_file"
  exit 0
fi

if [[ $APPLY != true || ${KS_DRY_RUN:-true} == true ]]; then
  ks_log INFO 'Preview only; no host settings changed'
  printf 'Would inspect Rocky Linux 9, x86_64, SELinux, kernel modules, sysctl, chronyd and firewall policy.\n'
  printf 'SELinux disable explicitly configured: %s\n' "$DISABLE_SELINUX"
  printf 'Firewall configuration enabled: %s\n' "$ENABLE_FIREWALL_CONFIG"
  printf 'Node inventory: %s\n' "$NODE_INVENTORY_FILE"
  exit 0
fi
ks_log ERROR 'Apply mode is intentionally blocked until role-specific firewall rules, rollback and Rocky Linux 9 integration tests are complete'
exit 78
