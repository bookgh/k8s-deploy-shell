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
PKI_ROOT=${PKI_ROOT:-$ROOT/pki}
if [[ $APPLY != true || ${KS_DRY_RUN:-true} == true ]]; then
  ks_log INFO "Preview only; no key material created. PKI root: $PKI_ROOT"
  printf 'Required trust domains: Kubernetes Root CA, ETCD CA, Front Proxy CA, independent ServiceAccount signing key.\n'
  printf 'Existing PKI must be inspected and must never be overwritten.\n'
  exit 0
fi
ks_log ERROR 'Certificate issuance is blocked until component profiles, SAN inventory, rotation and recovery tests are implemented'
exit 78
