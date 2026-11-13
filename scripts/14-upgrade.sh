#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$ROOT/scripts/lib/common.sh"
source "$ROOT/scripts/lib/config.sh"
source "$ROOT/scripts/lib/nodes.sh"
source "$ROOT/scripts/lib/manifest.sh"
CONFIG="$ROOT/cluster.env"
TARGET_VERSION=
APPLY=false
while (($#)); do
  case $1 in
    --config) CONFIG=$2; shift 2 ;;
    --target-version) (($# >= 2)) || exit 2; TARGET_VERSION=$2; shift 2 ;;
    --apply) APPLY=true; shift ;;
    --dry-run) KS_DRY_RUN=true; KS_DRY_RUN_OVERRIDE=true; shift ;;
    plan) shift ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
ks_config_load "$CONFIG"
ks_config_validate
ks_nodes_validate "$NODE_INVENTORY_FILE" "$MASTERS" "$WORKERS"
[[ -n $TARGET_VERSION ]] || TARGET_VERSION=$(ks_yaml_scalar "$ROOT/versions.yaml" kubernetes version)
[[ $TARGET_VERSION =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { ks_log ERROR 'Target Kubernetes version must be vMAJOR.MINOR.PATCH'; exit 2; }
if [[ $APPLY == true ]]; then
  ks_log ERROR 'Upgrade apply is blocked until etcd restore, HA rolling upgrade, kubelet skew and rollback are integration-tested on Rocky Linux 9'
  exit 78
fi
if ks_is_true "$KS_DRY_RUN"; then
  printf 'Upgrade plan (read-only): target=%s\n' "$TARGET_VERSION"
  printf '1. Verify current API and component versions; target must advance by at most one minor release.\n'
  printf '2. Take an etcd snapshot, verify it with etcdutl and copy it to independent encrypted storage.\n'
  printf '3. Upgrade HA control-plane nodes one at a time; verify API /readyz and etcd quorum after each node.\n'
  printf '4. Upgrade kubelet/kube-proxy one node at a time; cordon/drain Workers and uncordon after Ready.\n'
  printf '5. Re-run M9 checks; binary rollback does not roll back etcd/API data.\n'
  printf 'No cluster state was queried or changed.\n'
  exit 78
fi
for cmd in jq kubectl stat realpath; do ks_require_cmd "$cmd"; done
[[ $OUTPUT_ROOT == /* ]] || OUTPUT_ROOT=$ROOT/$OUTPUT_ROOT
OUTPUT_PATH=$(realpath -m -- "$OUTPUT_ROOT")
KUBECTL=$OUTPUT_PATH/bin/kubectl
KUBECONFIG=$OUTPUT_PATH/kubeconfig/admin.kubeconfig
[[ -x $KUBECTL && -f $KUBECONFIG && $(stat -c '%a' "$KUBECONFIG") == 600 ]] || { ks_log ERROR 'Pinned kubectl/admin kubeconfig missing or unsafe'; exit 78; }
current=$("$KUBECTL" --kubeconfig "$KUBECONFIG" get --raw=/version | jq -r '.gitVersion')
[[ $current =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || { ks_log ERROR "Cannot parse current Kubernetes version: $current"; exit 2; }
current_major=${BASH_REMATCH[1]}; current_minor=${BASH_REMATCH[2]}; current_patch=${BASH_REMATCH[3]}
[[ $TARGET_VERSION =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]
target_major=${BASH_REMATCH[1]}; target_minor=${BASH_REMATCH[2]}; target_patch=${BASH_REMATCH[3]}
((target_major == current_major && target_minor >= current_minor && target_minor <= current_minor + 1)) || {
  ks_log ERROR "Unsupported upgrade path $current -> $TARGET_VERSION; only same minor patch or one minor step is allowed"
  exit 2
}
if ((target_minor == current_minor && target_patch < current_patch)); then
  ks_log ERROR 'Downgrades are not supported'
  exit 2
fi
printf 'Current: %s\nTarget: %s\nMasters: %s\nWorkers: %s\n' "$current" "$TARGET_VERSION" "$MASTERS" "$WORKERS"
printf 'Allowed path: one minor step maximum. This script does not execute the upgrade.\n'
printf 'Required gates: verified etcd snapshot, API skew check, HA quorum check, per-node drain/uncordon and post-upgrade M9 report.\n'
exit 78
