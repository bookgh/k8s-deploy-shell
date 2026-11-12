#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$ROOT/scripts/lib/common.sh"
source "$ROOT/scripts/lib/config.sh"
source "$ROOT/scripts/lib/manifest.sh"
usage() { printf 'Usage: bin/install.sh [--config FILE] [--dry-run] COMMAND\nCommands: validate preflight plan prepare status\n'; }
CONFIG="$ROOT/cluster.env"; COMMAND=
while (($#)); do
  case $1 in
    --config) (($# >= 2)) || { usage >&2; exit 2; }; CONFIG=$2; shift 2 ;;
    --dry-run) KS_DRY_RUN=true; KS_DRY_RUN_OVERRIDE=true; shift ;;
    --help|-h) usage; exit 0 ;;
    validate|preflight|plan|prepare|status) [[ -z $COMMAND ]] || { usage >&2; exit 2; }; COMMAND=$1; shift ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ -n $COMMAND ]] || { usage >&2; exit 2; }
load_config() { ks_config_load "$CONFIG"; ks_config_validate; }
case $COMMAND in
  validate) load_config; ks_log INFO "Configuration valid: $CONFIG" ;;
  preflight)
    load_config
    for cmd in bash curl tar sha256sum awk ssh flock systemctl; do ks_require_cmd "$cmd"; done
    [[ $(uname -m) == x86_64 ]] || { ks_log ERROR 'Expected x86_64'; exit 1; }
    df -Pk "$ROOT" | awk 'NR==2 { if ($4 < 1048576) exit 1 }' || { ks_log ERROR 'Less than 1 GiB free'; exit 1; }
    ks_log INFO 'Local preflight passed; target nodes are not checked'
    ;;
  plan)
    load_config
    printf 'Cluster: %s\nMasters: %s\nWorkers: %s\nEtcd: %s\nRuntime: %s\nProxy: %s\nImage mode: %s\nDry-run: %s\n' "$CLUSTER_NAME" "$MASTERS" "$WORKERS" "$ETCD_NODES" "$RUNTIME" "$KUBE_PROXY_MODE" "$IMAGE_MODE" "$KS_DRY_RUN"
    printf 'Order: preflight -> system-init -> PKI -> etcd -> runtime -> control-plane -> worker-proxy -> kubelet/proxy -> addons -> verify\n'
    printf 'Read-only plan; no cluster changes performed.\n'
    ;;
  prepare)
    load_config
    [[ -f $ROOT/artifacts/manifest.tsv ]] || { ks_log ERROR 'Missing artifacts/manifest.tsv'; exit 2; }
    ks_manifest_fetch "$ROOT/artifacts/manifest.tsv" "$ROOT/artifacts/cache"
    ;;
  status) printf 'Project root: %s\nConfig: %s\nDry-run: %s\n' "$ROOT" "$CONFIG" "$KS_DRY_RUN" ;;
esac
