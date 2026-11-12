#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$ROOT/scripts/lib/common.sh"
source "$ROOT/scripts/lib/config.sh"
CONFIG="$ROOT/cluster.env"
APPLY=false
while (($#)); do
  case $1 in
    --config) CONFIG=$2; shift 2 ;;
    --apply) APPLY=true; shift ;;
    --dry-run) KS_DRY_RUN=true; KS_DRY_RUN_OVERRIDE=true; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
ks_config_load "$CONFIG"
ks_config_validate
if [[ $APPLY != true || ${KS_DRY_RUN:-true} == true ]]; then
  ks_log INFO 'Preview only; no host settings changed'
  printf 'Would inspect Rocky Linux 9, x86_64, SELinux, kernel modules, sysctl, chronyd and firewall policy.\n'
  printf 'SELinux disable explicitly configured: %s\n' "$DISABLE_SELINUX"
  printf 'Firewall configuration enabled: %s\n' "$ENABLE_FIREWALL_CONFIG"
  exit 0
fi
ks_log ERROR 'Apply mode is intentionally blocked until role-specific firewall rules, rollback and Rocky Linux 9 integration tests are complete'
exit 78
