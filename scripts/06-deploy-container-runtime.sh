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
[[ $RUNTIME == containerd ]] || { ks_log ERROR 'Only containerd is implemented; cri-dockerd is not silently substituted'; exit 78; }
for command_name in curl realpath awk sha256sum; do ks_require_cmd "$command_name"; done

[[ $SSH_KNOWN_HOSTS_FILE == /* ]] || SSH_KNOWN_HOSTS_FILE=$ROOT/$SSH_KNOWN_HOSTS_FILE
export SSH_KNOWN_HOSTS_FILE
[[ $NODE_INVENTORY_FILE == /* ]] || NODE_INVENTORY_FILE=$ROOT/$NODE_INVENTORY_FILE
if [[ $ARTIFACT_HTTP_ROOT == /* ]]; then
  CACHE_ROOT=$(realpath -m -- "$ARTIFACT_HTTP_ROOT")
else
  CACHE_ROOT=$(realpath -m -- "$ROOT/$ARTIFACT_HTTP_ROOT")
fi

lookup_artifact() {
  local name=$1 expected_version=$2 expected_url=$3
  local file sha version arch url
  IFS=$'\t' read -r file sha version arch url < <(ks_manifest_lookup "$ROOT/artifacts/manifest.tsv" "$name")
  [[ $version == "$expected_version" && $arch == amd64 && $url == "$expected_url" && $sha =~ ^[a-fA-F0-9]{64}$ ]] || {
    ks_log ERROR "Unreviewed artifact metadata: $name"
    return 2
  }
  printf '%s\t%s\t%s\n' "$file" "$sha" "$version"
}

CONTAINERD_VERSION=$(ks_yaml_scalar "$ROOT/versions.yaml" containerd version)
RUNC_VERSION=$(ks_yaml_scalar "$ROOT/versions.yaml" runc version)
CNI_VERSION=$(ks_yaml_scalar "$ROOT/versions.yaml" cni_plugins version)
SANDBOX_REPOSITORY=$(ks_yaml_scalar "$ROOT/versions.yaml" sandbox_image repository)
SANDBOX_TAG=$(ks_yaml_scalar "$ROOT/versions.yaml" sandbox_image tag)
SANDBOX_IMAGE=$SANDBOX_REPOSITORY:$SANDBOX_TAG
[[ $SANDBOX_IMAGE =~ ^[A-Za-z0-9.-]+/[A-Za-z0-9._/-]+:[A-Za-z0-9._-]+$ ]] || { ks_log ERROR 'Invalid sandbox image reference in versions.yaml'; exit 2; }

IFS=$'\t' read -r CONTAINERD_FILE CONTAINERD_SHA _ < <(
  lookup_artifact containerd-static "$CONTAINERD_VERSION" "https://github.com/containerd/containerd/releases/download/v$CONTAINERD_VERSION/containerd-static-$CONTAINERD_VERSION-linux-amd64.tar.gz"
)
IFS=$'\t' read -r RUNC_FILE RUNC_SHA _ < <(
  lookup_artifact runc "$RUNC_VERSION" "https://github.com/opencontainers/runc/releases/download/v$RUNC_VERSION/runc.amd64"
)
IFS=$'\t' read -r CNI_FILE CNI_SHA _ < <(
  lookup_artifact cni-plugins "$CNI_VERSION" "https://github.com/containernetworking/plugins/releases/download/v$CNI_VERSION/cni-plugins-linux-amd64-v$CNI_VERSION.tgz"
)

script_source=$ROOT/scripts/remote/install-container-runtime.sh
script_path=$CACHE_ROOT/ks-container-runtime-install.sh
script_tmp=
cleanup() {
  [[ -z $script_tmp || ! -e $script_tmp ]] || rm -f -- "$script_tmp"
  [[ -z $script_path || ! -e $script_path ]] || rm -f -- "$script_path"
}
trap cleanup EXIT

if [[ $APPLY != true || ${KS_DRY_RUN:-true} == true ]]; then
  ks_log INFO "DRY-RUN: containerd $CONTAINERD_VERSION / runc $RUNC_VERSION / CNI $CNI_VERSION on all configured nodes"
  while IFS=$'\t' read -r node role address user port || [[ -n ${node:-} ]]; do
    [[ -z ${node:-} || $node == node_id || $node == \#* ]] && continue
    ks_log INFO "DRY-RUN: would install containerd $CONTAINERD_VERSION, runc $RUNC_VERSION and CNI $CNI_VERSION on $node ($role/$address)"
  done < "$NODE_INVENTORY_FILE"
  exit 0
fi

for pair in "$CONTAINERD_FILE:$CONTAINERD_SHA" "$RUNC_FILE:$RUNC_SHA" "$CNI_FILE:$CNI_SHA"; do
  file=${pair%%:*}
  sha=${pair#*:}
  ks_verify_sha256 "$CACHE_ROOT/$file" "$sha"
done
[[ -r $SSH_KNOWN_HOSTS_FILE ]] || { ks_log ERROR "Known hosts file missing: $SSH_KNOWN_HOSTS_FILE"; exit 2; }
[[ -f $script_source && ! -L $script_source ]] || { ks_log ERROR 'Remote runtime installer is missing or unsafe'; exit 2; }
[[ ! -L $script_path ]] || { ks_log ERROR 'Refusing symlink at public installer path'; exit 2; }

script_tmp=$(mktemp "$CACHE_ROOT/.ks-runtime-install.XXXXXX")
cp -- "$script_source" "$script_tmp"
chmod 0644 "$script_tmp"
mv -f -- "$script_tmp" "$script_path"
script_tmp=
script_sha=$(ks_sha256_file "$script_path")
curl --fail --silent --show-error --max-time 10 --output /dev/null "http://127.0.0.1:$ARTIFACT_HTTP_PORT/ks-container-runtime-install.sh" || {
  ks_log ERROR 'Caddy does not serve the container runtime installer'
  exit 1
}

while IFS=$'\t' read -r node role address user port || [[ -n ${node:-} ]]; do
  [[ -z ${node:-} || $node == node_id || $node == \#* ]] && continue
  remote_path=/var/tmp/ks-container-runtime-install.sh
  SSH_USER=$user SSH_PORT=$port ks_ssh "$address" curl --fail --silent --show-error --location --proto '=http' --max-time 60 --output "$remote_path" "http://$INSTALL_NODE_ADVERTISE_ADDR:$ARTIFACT_HTTP_PORT/ks-container-runtime-install.sh"
  remote_sha=$(SSH_USER=$user SSH_PORT=$port ks_ssh "$address" sha256sum "$remote_path" | awk '{print $1}')
  [[ $remote_sha == "$script_sha" ]] || { ks_log ERROR "Runtime installer checksum mismatch on $node"; exit 1; }
  SSH_USER=$user SSH_PORT=$port ks_ssh "$address" chmod 0700 "$remote_path"
  SSH_USER=$user SSH_PORT=$port ks_ssh "$address" bash "$remote_path" \
    "$CONTAINERD_VERSION" "$CONTAINERD_FILE" "$CONTAINERD_SHA" \
    "$RUNC_VERSION" "$RUNC_FILE" "$RUNC_SHA" \
    "$CNI_VERSION" "$CNI_FILE" "$CNI_SHA" \
    "http://$INSTALL_NODE_ADVERTISE_ADDR:$ARTIFACT_HTTP_PORT" \
    "$CONTAINERD_CONFIG_DIR" "$CONTAINERD_ROOT_DIR" "$CONTAINERD_STATE_DIR" \
    "$CONTAINERD_BIN_DIR" "$CNI_BIN_DIR" "$CNI_CONF_DIR" "$SANDBOX_IMAGE"
  SSH_USER=$user SSH_PORT=$port ks_ssh "$address" rm -f "$remote_path"
  ks_log INFO "containerd CRI installed and verified on $node"
done < "$NODE_INVENTORY_FILE"
