#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$ROOT/scripts/lib/common.sh"
source "$ROOT/scripts/lib/config.sh"
CONFIG="$ROOT/cluster.env"
STEP=
while (($#)); do
  case $1 in
    --config) CONFIG=$2; shift 2 ;;
    --dry-run) KS_DRY_RUN=true; KS_DRY_RUN_OVERRIDE=true; shift ;;
    *) [[ -z $STEP ]] || { echo 'Only one step accepted' >&2; exit 2; }; STEP=$1; shift ;;
  esac
done
[[ -n $STEP ]] || { echo 'Missing step' >&2; exit 2; }
ks_config_load "$CONFIG"
ks_config_validate
DRY_ARGS=()
[[ ${KS_DRY_RUN:-false} == true ]] && DRY_ARGS+=(--dry-run)
case $STEP in
  init-system) exec "$ROOT/scripts/01-init-system.sh" --config "$CONFIG" "${DRY_ARGS[@]}" ;;
  pki) exec "$ROOT/scripts/02-gen-ca-and-certs.sh" --config "$CONFIG" "${DRY_ARGS[@]}" ;;
  verify) exec "$ROOT/scripts/10-cluster-check.sh" --config "$CONFIG" "${DRY_ARGS[@]}" ;;
  etcd|runtime|control-plane|worker-proxy|kubelet-proxy|addons)
    ks_log ERROR "Stage '$STEP' is not implemented; refusing deployment"
    exit 78 ;;
  *) echo "Unknown step: $STEP" >&2; exit 2 ;;
esac
