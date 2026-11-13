#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
TEMP_FILES=()
SCRIPT_CREATED=false

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
[[ $RUNTIME == containerd ]] || { ks_log ERROR 'Kubelet deployment currently requires containerd'; exit 78; }
for command_name in curl realpath awk sha256sum openssl stat grep install mktemp cp chmod mv rm cat; do ks_require_cmd "$command_name"; done

[[ $PKI_ROOT == /* ]] || PKI_ROOT=$ROOT/$PKI_ROOT
[[ $OUTPUT_ROOT == /* ]] || OUTPUT_ROOT=$ROOT/$OUTPUT_ROOT
[[ $NODE_INVENTORY_FILE == /* ]] || NODE_INVENTORY_FILE=$ROOT/$NODE_INVENTORY_FILE
[[ $SSH_KNOWN_HOSTS_FILE == /* ]] || SSH_KNOWN_HOSTS_FILE=$ROOT/$SSH_KNOWN_HOSTS_FILE
PKI_PATH=$(realpath -m -- "$PKI_ROOT")
OUTPUT_PATH=$(realpath -m -- "$OUTPUT_ROOT")
export SSH_KNOWN_HOSTS_FILE
if [[ $ARTIFACT_HTTP_ROOT == /* ]]; then CACHE_ROOT=$(realpath -m -- "$ARTIFACT_HTTP_ROOT"); else CACHE_ROOT=$(realpath -m -- "$ROOT/$ARTIFACT_HTTP_ROOT"); fi

lookup_artifact() {
  local name=$1 expected_version=$2 expected_url=$3 file sha version arch url
  IFS=$'\t' read -r file sha version arch url < <(ks_manifest_lookup "$ROOT/artifacts/manifest.tsv" "$name")
  [[ $version == "$expected_version" && $arch == amd64 && $url == "$expected_url" && $sha =~ ^[a-fA-F0-9]{64}$ ]] || {
    ks_log ERROR "Unreviewed artifact metadata: $name"
    return 2
  }
  printf '%s\t%s\t%s\n' "$file" "$sha" "$version"
}
K8S_VERSION=$(ks_yaml_scalar "$ROOT/versions.yaml" kubernetes version)
IFS=$'\t' read -r KUBELET_FILE KUBELET_SHA _ < <(
  lookup_artifact kubelet "$K8S_VERSION" "https://dl.k8s.io/release/$K8S_VERSION/bin/linux/amd64/kubelet"
)
IFS=$'\t' read -r KUBE_PROXY_FILE KUBE_PROXY_SHA _ < <(
  lookup_artifact kube-proxy "$K8S_VERSION" "https://dl.k8s.io/release/$K8S_VERSION/bin/linux/amd64/kube-proxy"
)
IFS=$'\t' read -r _ KUBECTL_SHA _ < <(
  lookup_artifact kubectl "$K8S_VERSION" "https://dl.k8s.io/release/$K8S_VERSION/bin/linux/amd64/kubectl"
)

if [[ $APPLY != true || ${KS_DRY_RUN:-true} == true ]]; then
  ks_log INFO "DRY-RUN: install kubelet and kube-proxy $K8S_VERSION on all configured nodes"
  ks_log INFO "Both kubeconfigs will use https://127.0.0.1:$CONTROL_PLANE_PORT; Worker access depends on the local Nginx stream proxy"
  while IFS=$'\t' read -r node role address user port || [[ -n ${node:-} ]]; do
    [[ -z ${node:-} || $node == node_id || $node == \#* ]] && continue
    ks_log INFO "DRY-RUN: prepare kubelet identity for $node ($role/$address)"
  done < "$NODE_INVENTORY_FILE"
  exit 0
fi

for pair in "$KUBELET_FILE:$KUBELET_SHA" "$KUBE_PROXY_FILE:$KUBE_PROXY_SHA"; do
  file=${pair%%:*}; sha=${pair#*:}
  ks_verify_sha256 "$CACHE_ROOT/$file" "$sha"
done
KUBECTL_BIN=$OUTPUT_PATH/bin/kubectl
[[ -f $KUBECTL_BIN && -x $KUBECTL_BIN && ! -L $KUBECTL_BIN ]] || { ks_log ERROR 'Run M6 control-plane preparation first; output/bin/kubectl is missing'; exit 78; }
ks_verify_sha256 "$KUBECTL_BIN" "$KUBECTL_SHA"
"$KUBECTL_BIN" version --client --output=yaml | grep -Fq "gitVersion: $K8S_VERSION"
CA=$PKI_PATH/kubernetes/ca.pem
[[ -f $CA && ! -L $CA ]] || { ks_log ERROR "Kubernetes CA is missing or unsafe: $CA"; exit 2; }
KUBE_PROXY_CERT=$PKI_PATH/kubernetes/kube-proxy/kube-proxy.pem
KUBE_PROXY_KEY=$PKI_PATH/kubernetes/kube-proxy/kube-proxy-key.pem
for file in "$CA" "$KUBE_PROXY_CERT" "$KUBE_PROXY_KEY"; do [[ -f $file && ! -L $file ]] || { ks_log ERROR "Required local PKI file missing: $file"; exit 2; }; done

ks_verify_pair() {
  local cert=$1 key=$2 expected_cn=$3 expected_org=$4 subject cert_pub key_pub
  [[ -f $cert && -f $key && ! -L $cert && ! -L $key ]] || { ks_log ERROR "Missing or unsafe certificate pair: $cert"; return 2; }
  [[ $(stat -c '%a' "$key") == 600 ]] || { ks_log ERROR "Private key mode must be 0600: $key"; return 2; }
  openssl verify -CAfile "$CA" "$cert" >/dev/null
  subject=$(openssl x509 -in "$cert" -noout -subject -nameopt RFC2253)
  [[ $subject == *"CN=$expected_cn"* && $subject == *"O=$expected_org"* ]] || { ks_log ERROR "Certificate identity mismatch: $cert"; return 2; }
  cert_pub=$(openssl x509 -in "$cert" -noout -pubkey | openssl pkey -pubin -outform DER | sha256sum | awk '{print $1}')
  key_pub=$(openssl pkey -in "$key" -pubout -outform DER | sha256sum | awk '{print $1}')
  [[ $cert_pub == "$key_pub" ]] || { ks_log ERROR "Certificate/key mismatch: $cert"; return 2; }
}

ks_write_managed() {
  local target=$1 mode=$2 dir tmp
  dir=$(dirname -- "$target")
  install -d -m 0700 "$dir"
  tmp=$(mktemp "$dir/.managed.XXXXXX")
  cat > "$tmp"
  chmod "$mode" "$tmp"
  if [[ -e $target ]]; then
    [[ -f $target && ! -L $target ]] || { rm -f -- "$tmp"; ks_log ERROR "Unsafe existing generated file: $target"; return 2; }
    cmp -s "$tmp" "$target" || { rm -f -- "$tmp"; ks_log ERROR "Refusing to overwrite changed generated file: $target"; return 73; }
    rm -f -- "$tmp"
  else
    mv -f -- "$tmp" "$target"
  fi
}

ks_kubeconfig_generate() {
  local target=$1 username=$2 cert=$3 key=$4 context=$5 temp
  temp=$(mktemp "$(dirname -- "$target")/.kubeconfig.XXXXXX")
  TEMP_FILES+=("$temp")
  "$KUBECTL_BIN" config set-cluster "$CLUSTER_NAME" --certificate-authority="$CA" --embed-certs=true --server="https://127.0.0.1:$CONTROL_PLANE_PORT" --kubeconfig="$temp" >/dev/null
  "$KUBECTL_BIN" config set-credentials "$username" --client-certificate="$cert" --client-key="$key" --embed-certs=true --kubeconfig="$temp" >/dev/null
  "$KUBECTL_BIN" config set-context "$context" --cluster="$CLUSTER_NAME" --user="$username" --kubeconfig="$temp" >/dev/null
  "$KUBECTL_BIN" config use-context "$context" --kubeconfig="$temp" >/dev/null
  chmod 0600 "$temp"
  if [[ -e $target ]]; then
    [[ -f $target && ! -L $target ]] || { rm -f -- "$temp"; ks_log ERROR "Unsafe existing kubeconfig: $target"; return 2; }
    cmp -s "$temp" "$target" || { rm -f -- "$temp"; ks_log ERROR "Refusing to overwrite different kubeconfig: $target"; return 73; }
    rm -f -- "$temp"
  else
    mv -f -- "$temp" "$target"
  fi
}

ks_render_kube_proxy_config() {
  local target=$1 node=$2 address=$3 temp normalized
  temp=$(mktemp "$OUTPUT_PATH/node-config/.kube-proxy-config.XXXXXX")
  normalized=$(mktemp "$OUTPUT_PATH/node-config/.kube-proxy-normalized.XXXXXX")
  TEMP_FILES+=("$temp" "$normalized")
  awk -v kubeconfig="$KUBERNETES_CONFIG_DIR/kube-proxy.kubeconfig" -v node="$node" -v address="$address" \
    -v healthz="127.0.0.1:$KUBE_PROXY_HEALTHZ_PORT" -v metrics="127.0.0.1:$KUBE_PROXY_METRICS_PORT" \
    -v cidr="$POD_CIDR" -v mode="$KUBE_PROXY_MODE" '
    function quote(value) {
      gsub(/\\/, "\\\\", value)
      gsub(/"/, "\\\"", value)
      return "\"" value "\""
    }
    {
      if (skip_nodeport) {
        if ($0 ~ /^[[:space:]]/) next
        skip_nodeport = 0
      }
      if ($0 ~ /^nodePortAddresses:/) {
        print "nodePortAddresses: [\"primary\"]"
        found["nodePortAddresses"]++
        skip_nodeport = 1
        next
      }
      if (in_client && $0 !~ /^[[:space:]]/) {
        if (client_kubeconfig == 0) {
          print "  kubeconfig: " quote(kubeconfig)
          client_kubeconfig++
        }
        in_client = 0
      }
      if ($0 ~ /^clientConnection:[[:space:]]*$/) {
        client_section++
        in_client = 1
        print
        next
      }
      if (in_client && $0 ~ /^  kubeconfig:/) {
        print "  kubeconfig: " quote(kubeconfig)
        client_kubeconfig++
        next
      }
      if ($0 ~ /^hostnameOverride:/) { print "hostnameOverride: " quote(node); found["hostnameOverride"]++; next }
      if ($0 ~ /^bindAddress:/) { print "bindAddress: " quote(address); found["bindAddress"]++; next }
      if ($0 ~ /^healthzBindAddress:/) { print "healthzBindAddress: " quote(healthz); found["healthzBindAddress"]++; next }
      if ($0 ~ /^metricsBindAddress:/) { print "metricsBindAddress: " quote(metrics); found["metricsBindAddress"]++; next }
      if ($0 ~ /^clusterCIDR:/) { print "clusterCIDR: " quote(cidr); found["clusterCIDR"]++; next }
      if ($0 ~ /^mode:/) { print "mode: " quote(mode); found["mode"]++; next }
      if ($0 ~ /^enableProfiling:/) { print "enableProfiling: false"; found["enableProfiling"]++; next }
      print
    }
    END {
      if (in_client && client_kubeconfig == 0) { print "  kubeconfig: " quote(kubeconfig); client_kubeconfig++ }
      if (found["nodePortAddresses"] == 0) { print "nodePortAddresses: [\"primary\"]"; found["nodePortAddresses"]++ }
      if (client_section != 1 || client_kubeconfig != 1 || found["nodePortAddresses"] != 1) exit 2
      required["hostnameOverride"] = 1
      required["bindAddress"] = 1
      required["healthzBindAddress"] = 1
      required["metricsBindAddress"] = 1
      required["clusterCIDR"] = 1
      required["mode"] = 1
      required["enableProfiling"] = 1
      for (key in required) if (found[key] != 1) exit 2
    }
  ' "$KUBE_PROXY_DEFAULT_CONFIG" > "$temp"
  "$KUBE_PROXY_TOOL" --config="$temp" --write-config-to="$normalized" >/dev/null
  ks_write_managed "$target" 0600 < "$normalized"
  rm -f -- "$temp" "$normalized"
}

ks_generate_node_files() {
  local node=$1 node_dir client_cert client_key serving_cert serving_key proxy_cfg
  node_dir=$OUTPUT_PATH/node-config/$node
  client_cert=$PKI_PATH/kubernetes/kubelet/$node/node-client.pem
  client_key=$PKI_PATH/kubernetes/kubelet/$node/node-client-key.pem
  serving_cert=$PKI_PATH/kubernetes/kubelet/$node/node-serving.pem
  serving_key=$PKI_PATH/kubernetes/kubelet/$node/node-serving-key.pem
  ks_verify_pair "$client_cert" "$client_key" "system:node:$node" system:nodes
  ks_verify_pair "$serving_cert" "$serving_key" "$node" system:nodes
  openssl x509 -in "$serving_cert" -noout -ext subjectAltName | grep -Fq "IP Address:$NODE_ADDRESS" || { ks_log ERROR "Kubelet serving certificate lacks $NODE_ADDRESS SAN for $node"; return 2; }
  ks_verify_pair "$KUBE_PROXY_CERT" "$KUBE_PROXY_KEY" system:kube-proxy system:node-proxier
  [[ ! -L $node_dir ]] || { ks_log ERROR "Node output directory is a symlink: $node_dir"; return 2; }
  install -d -m 0700 "$node_dir"
  ks_kubeconfig_generate "$node_dir/kubelet.kubeconfig" "system:node:$node" "$client_cert" "$client_key" "system:node:$node@$CLUSTER_NAME"
  ks_kubeconfig_generate "$node_dir/kube-proxy.kubeconfig" system:kube-proxy "$KUBE_PROXY_CERT" "$KUBE_PROXY_KEY" "kube-proxy@$CLUSTER_NAME"
  ks_write_managed "$node_dir/kubelet-config.yaml" 0600 <<YAML
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
address: "$KUBELET_BIND_ADDRESS"
port: $KUBELET_PORT
readOnlyPort: 0
enableServer: true
cgroupDriver: systemd
containerRuntimeEndpoint: "unix://$CONTAINERD_STATE_DIR/containerd.sock"
rootDir: "$KUBELET_DATA_DIR"
certDirectory: "$KUBELET_DATA_DIR/pki"
clusterDNS:
  - "$NODELOCAL_DNS_IP"
clusterDomain: "$CLUSTER_DOMAIN"
staticPodPath: "$KUBERNETES_CONFIG_DIR/manifests"
resolvConf: /etc/resolv.conf
maxPods: $KUBELET_MAX_PODS
podPidsLimit: $KUBELET_POD_PIDS_LIMIT
reservedSystemCPUs: ""
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
  x509:
    clientCAFile: "$KUBERNETES_CONFIG_DIR/pki/ca.crt"
authorization:
  mode: Webhook
rotateCertificates: false
serverTLSBootstrap: false
tlsCertFile: "$KUBELET_DATA_DIR/pki/kubelet-serving.crt"
tlsPrivateKeyFile: "$KUBELET_DATA_DIR/pki/kubelet-serving.key"
failSwapOn: true
failCgroupV1: true
serializeImagePulls: false
logging:
  format: text
enableSystemLogHandler: false
enableSystemLogQuery: false
enableProfilingHandler: false
shutdownGracePeriod: 30s
shutdownGracePeriodCriticalPods: 10s
YAML
  proxy_cfg=$node_dir/kube-proxy-config.yaml
  ks_render_kube_proxy_config "$proxy_cfg" "$node" "$NODE_ADDRESS"
}

ks_deliver_file() {
  local address=$1 user=$2 port=$3 source_file=$4 destination=$5 mode=$6 local_sha remote_sha
  local_sha=$(ks_sha256_file "$source_file")
  if SSH_USER=$user SSH_PORT=$port ks_ssh "$address" readlink "$destination" >/dev/null 2>&1; then
    ks_log ERROR "Refusing symlink destination: $destination"
    return 2
  fi
  if SSH_USER=$user SSH_PORT=$port ks_ssh "$address" test -f "$destination"; then
    remote_sha=$(SSH_USER=$user SSH_PORT=$port ks_ssh "$address" sha256sum "$destination" | awk '{print $1}')
    [[ $remote_sha == "$local_sha" ]] || { ks_log ERROR "Remote managed file differs: $destination"; return 73; }
  else
    SSH_USER=$user SSH_PORT=$port ks_ssh_install_file "$address" "$source_file" "$destination" "$mode"
  fi
}

script_source=$ROOT/scripts/remote/install-kubelet-kubeproxy.sh
script_path=$CACHE_ROOT/ks-kubelet-proxy-install.sh
script_tmp=
cleanup() {
  local temporary
  for temporary in "${TEMP_FILES[@]}"; do [[ ! -e $temporary ]] || rm -f -- "$temporary"; done
  [[ -z $script_tmp || ! -e $script_tmp ]] || rm -f -- "$script_tmp"
  [[ $SCRIPT_CREATED != true || -z $script_path || ! -e $script_path ]] || rm -f -- "$script_path"
}
trap cleanup EXIT

[[ -f $script_source && ! -L $script_source ]] || { ks_log ERROR 'Remote kubelet/proxy installer is missing or unsafe'; exit 2; }
if [[ $APPLY != true || ${KS_DRY_RUN:-true} == true ]]; then
  ks_log INFO "DRY-RUN: kubelet/kube-proxy $K8S_VERSION; kubeconfigs target https://127.0.0.1:$CONTROL_PLANE_PORT"
  while IFS=$'\t' read -r node role address user port || [[ -n ${node:-} ]]; do
    [[ -z ${node:-} || $node == node_id || $node == \#* ]] && continue
    ks_log INFO "DRY-RUN: would install binaries/units and deliver node credentials to $node ($role/$address)"
  done < "$NODE_INVENTORY_FILE"
  exit 0
fi
for pair in "$KUBELET_FILE:$KUBELET_SHA" "$KUBE_PROXY_FILE:$KUBE_PROXY_SHA"; do
  file=${pair%%:*}; sha=${pair#*:}
  ks_verify_sha256 "$CACHE_ROOT/$file" "$sha"
done
[[ -r $SSH_KNOWN_HOSTS_FILE ]] || { ks_log ERROR "Known hosts file missing: $SSH_KNOWN_HOSTS_FILE"; exit 2; }
[[ ! -L $OUTPUT_PATH/node-config && ! -L $OUTPUT_PATH/bin ]] || { ks_log ERROR "Output directories must not be symlinks"; exit 2; }
install -d -m 0700 "$OUTPUT_PATH/node-config" "$OUTPUT_PATH/bin"
KUBECTL_BIN=$OUTPUT_PATH/bin/kubectl
[[ -f $KUBECTL_BIN && -x $KUBECTL_BIN && ! -L $KUBECTL_BIN ]] || { ks_log ERROR 'Run M6 control-plane preparation first; output/bin/kubectl is missing'; exit 78; }
ks_verify_sha256 "$KUBECTL_BIN" "$KUBECTL_SHA"
"$KUBECTL_BIN" version --client --output=yaml | grep -Fq "gitVersion: $K8S_VERSION"
KUBE_PROXY_TOOL=$OUTPUT_PATH/bin/kube-proxy
if [[ -e $KUBE_PROXY_TOOL ]]; then
  [[ -f $KUBE_PROXY_TOOL && ! -L $KUBE_PROXY_TOOL ]] || exit 2
  cmp -s "$CACHE_ROOT/$KUBE_PROXY_FILE" "$KUBE_PROXY_TOOL" || { ks_log ERROR 'Existing local kube-proxy tool differs'; exit 73; }
else
  install -m 0755 "$CACHE_ROOT/$KUBE_PROXY_FILE" "$KUBE_PROXY_TOOL"
fi
chmod 0755 "$KUBE_PROXY_TOOL"
KUBE_PROXY_DEFAULT_CONFIG=$OUTPUT_PATH/node-config/.kube-proxy-default.yaml
rm -f -- "$KUBE_PROXY_DEFAULT_CONFIG"
"$KUBE_PROXY_TOOL" --write-config-to="$KUBE_PROXY_DEFAULT_CONFIG" >/dev/null
chmod 0600 "$KUBE_PROXY_DEFAULT_CONFIG"
CA=$PKI_PATH/kubernetes/ca.pem
KUBE_PROXY_CERT=$PKI_PATH/kubernetes/kube-proxy/kube-proxy.pem
KUBE_PROXY_KEY=$PKI_PATH/kubernetes/kube-proxy/kube-proxy-key.pem
for file in "$CA" "$KUBE_PROXY_CERT" "$KUBE_PROXY_KEY"; do [[ -f $file && ! -L $file ]] || { ks_log ERROR "Required local PKI file missing: $file"; exit 2; }; done

[[ ! -L $script_path ]] || { ks_log ERROR 'Refusing symlink at public installer path'; exit 2; }
script_tmp=$(mktemp "$CACHE_ROOT/.ks-kubelet-proxy.XXXXXX")
cp -- "$script_source" "$script_tmp"
chmod 0644 "$script_tmp"
mv -f -- "$script_tmp" "$script_path"
SCRIPT_CREATED=true
script_tmp=
script_sha=$(ks_sha256_file "$script_path")
curl --fail --silent --show-error --max-time 10 --output /dev/null "http://127.0.0.1:$ARTIFACT_HTTP_PORT/ks-kubelet-proxy-install.sh" || { ks_log ERROR 'Caddy does not serve the kubelet/proxy installer'; exit 1; }

while IFS=$'\t' read -r node role address user port || [[ -n ${node:-} ]]; do
  [[ -z ${node:-} || $node == node_id || $node == \#* ]] && continue
  IFS=$'\t' read -r _ NODE_ADDRESS _ _ < <(ks_node_lookup "$NODE_INVENTORY_FILE" "$node")
  ks_generate_node_files "$node"
  remote_path=/var/tmp/ks-kubelet-proxy-install.sh
  SSH_USER=$user SSH_PORT=$port ks_ssh "$address" curl --fail --silent --show-error --location --proto '=http' --proto-redir '=http' --max-time 60 --output "$remote_path" "http://$INSTALL_NODE_ADVERTISE_ADDR:$ARTIFACT_HTTP_PORT/ks-kubelet-proxy-install.sh"
  remote_sha=$(SSH_USER=$user SSH_PORT=$port ks_ssh "$address" sha256sum "$remote_path" | awk '{print $1}')
  [[ $remote_sha == "$script_sha" ]] || { ks_log ERROR "Kubelet/proxy installer checksum mismatch on $node"; exit 1; }
  SSH_USER=$user SSH_PORT=$port ks_ssh "$address" chmod 0700 "$remote_path"
  SSH_USER=$user SSH_PORT=$port ks_ssh "$address" bash "$remote_path" \
    "$K8S_VERSION" "$KUBELET_FILE" "$KUBELET_SHA" "$KUBE_PROXY_FILE" "$KUBE_PROXY_SHA" \
    "http://$INSTALL_NODE_ADVERTISE_ADDR:$ARTIFACT_HTTP_PORT" \
    "$KUBERNETES_BIN_DIR" "$KUBERNETES_CONFIG_DIR" "$KUBELET_DATA_DIR" "$CONTAINERD_STATE_DIR" "$node" "$address"
  SSH_USER=$user SSH_PORT=$port ks_ssh "$address" rm -f "$remote_path"
  node_dir=$OUTPUT_PATH/node-config/$node
  ks_deliver_file "$address" "$user" "$port" "$node_dir/kubelet-config.yaml" "$KUBERNETES_CONFIG_DIR/kubelet-config.yaml" 0600
  ks_deliver_file "$address" "$user" "$port" "$node_dir/kubelet.kubeconfig" "$KUBERNETES_CONFIG_DIR/kubelet.kubeconfig" 0600
  ks_deliver_file "$address" "$user" "$port" "$node_dir/kube-proxy-config.yaml" "$KUBERNETES_CONFIG_DIR/kube-proxy-config.yaml" 0600
  ks_deliver_file "$address" "$user" "$port" "$node_dir/kube-proxy.kubeconfig" "$KUBERNETES_CONFIG_DIR/kube-proxy.kubeconfig" 0600
  ks_log INFO "Kubelet and kube-proxy installed but remain disabled on $node"
done < "$NODE_INVENTORY_FILE"
