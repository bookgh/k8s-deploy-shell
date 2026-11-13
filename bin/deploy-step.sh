#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$ROOT/scripts/lib/common.sh"
source "$ROOT/scripts/lib/config.sh"
source "$ROOT/scripts/lib/nodes.sh"
CONFIG="$ROOT/cluster.env"
APPLY=false
STEP=
while (($#)); do
  case $1 in
    --config) CONFIG=$2; shift 2 ;;
    --dry-run) KS_DRY_RUN=true; KS_DRY_RUN_OVERRIDE=true; shift ;;
    --apply) APPLY=true; shift ;;
    *) [[ -z $STEP ]] || { echo 'Only one step accepted' >&2; exit 2; }; STEP=$1; shift ;;
  esac
done
[[ -n $STEP ]] || { echo 'Missing step' >&2; exit 2; }
ks_config_load "$CONFIG"
ks_config_validate
ks_nodes_validate "$NODE_INVENTORY_FILE" "$MASTERS" "$WORKERS"
DRY_ARGS=()
APPLY_ARGS=()
[[ ${KS_DRY_RUN:-false} == true ]] && DRY_ARGS+=(--dry-run)
[[ $APPLY == true ]] && APPLY_ARGS+=(--apply)
case $STEP in
  init-system) exec "$ROOT/scripts/01-init-system.sh" --config "$CONFIG" "${DRY_ARGS[@]}" "${APPLY_ARGS[@]}" ;;
  pki) exec "$ROOT/scripts/02-gen-ca-and-certs.sh" --config "$CONFIG" "${DRY_ARGS[@]}" "${APPLY_ARGS[@]}" ;;
  distribute-pki) exec "$ROOT/scripts/03-distribute-pki.sh" --config "$CONFIG" "${DRY_ARGS[@]}" "${APPLY_ARGS[@]}" ;;
  etcd|etcd-health|etcd-members|etcd-snapshot)
    COMMAND=deploy
    [[ $STEP == etcd-health ]] && COMMAND=health
    [[ $STEP == etcd-members ]] && COMMAND=member-list
    [[ $STEP == etcd-snapshot ]] && COMMAND=snapshot
    exec "$ROOT/scripts/04-deploy-etcd.sh" --config "$CONFIG" "${DRY_ARGS[@]}" "${APPLY_ARGS[@]}" "$COMMAND" ;;
  control-plane) exec "$ROOT/scripts/05-deploy-control-plane.sh" --config "$CONFIG" "${DRY_ARGS[@]}" "${APPLY_ARGS[@]}" deploy ;;
  control-plane-health) exec "$ROOT/scripts/05-deploy-control-plane.sh" --config "$CONFIG" "${DRY_ARGS[@]}" "${APPLY_ARGS[@]}" health ;;
  verify) exec "$ROOT/scripts/10-cluster-check.sh" --config "$CONFIG" "${DRY_ARGS[@]}" ;;
  runtime) exec "$ROOT/scripts/06-deploy-container-runtime.sh" --config "$CONFIG" "${DRY_ARGS[@]}" "${APPLY_ARGS[@]}" deploy ;;
  kubelet-proxy) exec "$ROOT/scripts/07-deploy-kubelet-kubeproxy.sh" --config "$CONFIG" "${DRY_ARGS[@]}" "${APPLY_ARGS[@]}" deploy ;;
  build-nginx) exec "$ROOT/scripts/08-build-nginx-stream.sh" --config "$CONFIG" "${DRY_ARGS[@]}" "${APPLY_ARGS[@]}" build ;;
  worker-proxy) exec "$ROOT/scripts/09-deploy-worker-proxy.sh" --config "$CONFIG" "${DRY_ARGS[@]}" "${APPLY_ARGS[@]}" deploy ;;
  addons)
    ks_log ERROR "Stage '$STEP' is not implemented; refusing deployment"
    exit 78 ;;
  *) echo "Unknown step: $STEP" >&2; exit 2 ;;
esac
