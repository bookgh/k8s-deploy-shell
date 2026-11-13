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
source "$ROOT/scripts/lib/addons.sh"
CONFIG="$ROOT/cluster.env"
COMMAND=deploy
APPLY=false
while (($#)); do
  case $1 in
    --config) (($# >= 2)) || exit 2; CONFIG=$2; shift 2 ;;
    --apply) APPLY=true; shift ;;
    --dry-run) KS_DRY_RUN=true; KS_DRY_RUN_OVERRIDE=true; shift ;;
    deploy|verify) COMMAND=$1; shift ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
ks_config_load "$CONFIG"
ks_config_validate
ks_nodes_validate "$NODE_INVENTORY_FILE" "$MASTERS" "$WORKERS"
[[ $NODE_INVENTORY_FILE == /* ]] || NODE_INVENTORY_FILE=$ROOT/$NODE_INVENTORY_FILE
[[ $SSH_KNOWN_HOSTS_FILE == /* ]] || SSH_KNOWN_HOSTS_FILE=$ROOT/$SSH_KNOWN_HOSTS_FILE
export SSH_KNOWN_HOSTS_FILE
[[ $OUTPUT_ROOT == /* ]] || OUTPUT_ROOT=$ROOT/$OUTPUT_ROOT
OUTPUT_PATH=$(realpath -m -- "$OUTPUT_ROOT")
[[ $ARTIFACT_HTTP_ROOT == /* ]] || ARTIFACT_HTTP_ROOT=$ROOT/$ARTIFACT_HTTP_ROOT
CACHE_ROOT=$(realpath -m -- "$ARTIFACT_HTTP_ROOT")
[[ $IMAGE_MODE == local-import ]] || { ks_log ERROR 'M8 currently supports only local-import; Harbor/online image modes remain blocked'; exit 78; }
if [[ ! -f $ROOT/images.lock.tsv || -L $ROOT/images.lock.tsv ]]; then
  if [[ $APPLY != true || ${KS_DRY_RUN:-true} == true ]]; then
    ks_log WARN 'DRY-RUN only: images.lock.tsv is not present; apply remains blocked until all chart/operator images are pinned and archived'
    exit 0
  fi
  ks_log ERROR 'Create images.lock.tsv from images.lock.tsv.example after a complete rendered-image audit'
  exit 78
fi
ks_images_validate "$ROOT/images.lock.tsv"
ks_images_require_ref "$ROOT/images.lock.tsv" calico-operator quay.io/tigera/operator:v1.44.0
ks_images_require_ref "$ROOT/images.lock.tsv" calico quay.io/calico/calico:v3.33.0
ks_images_require_ref "$ROOT/images.lock.tsv" coredns registry.k8s.io/coredns/coredns:1.14.7
ks_images_require_ref "$ROOT/images.lock.tsv" node-local-dns registry.k8s.io/dns/k8s-dns-node-cache:1.26.8
ks_images_require_ref "$ROOT/images.lock.tsv" m9-test-busybox docker.io/library/busybox:1.37.0
ks_addon_artifact helm "$(ks_yaml_scalar "$ROOT/versions.yaml" helm version)" "https://get.helm.sh/helm-v3.22.1-linux-amd64.tar.gz"
HELM_ARCHIVE=$REPLY; HELM_SHA=$KS_ADDON_SHA
ks_addon_artifact calico-operator-chart "$(ks_yaml_scalar "$ROOT/charts.yaml" calico version)" "https://github.com/projectcalico/calico/releases/download/v3.33.0/tigera-operator-v3.33.0.tgz"
CALICO_CHART=$REPLY; CALICO_CHART_SHA=$KS_ADDON_SHA
ks_addon_artifact calico-crds-chart "$(ks_yaml_scalar "$ROOT/charts.yaml" calico crd_version)" "https://github.com/projectcalico/calico/releases/download/v3.33.0/projectcalico.org.v3-v3.33.0.tgz"
CALICO_CRD_CHART=$REPLY; CALICO_CRD_SHA=$KS_ADDON_SHA
ks_addon_artifact coredns-chart "$(ks_yaml_scalar "$ROOT/charts.yaml" coredns version)" "https://github.com/coredns/helm/releases/download/coredns-1.48.2/coredns-1.48.2.tgz"
COREDNS_CHART=$REPLY; COREDNS_CHART_SHA=$KS_ADDON_SHA
K8S_VERSION=$(ks_yaml_scalar "$ROOT/versions.yaml" kubernetes version)
COREDNS_IMAGE_VERSION=$(ks_yaml_scalar "$ROOT/charts.yaml" coredns app_version)
NODELOCAL_IMAGE_VERSION=$(ks_yaml_scalar "$ROOT/charts.yaml" nodelocaldns app_version)
[[ $COREDNS_IMAGE_VERSION == 1.14.7 && $NODELOCAL_IMAGE_VERSION == 1.26.8 && $K8S_VERSION == v1.37.2 ]] || { ks_log ERROR 'Addon image/chart compatibility pins changed without review'; exit 2; }
for pair in "$HELM_ARCHIVE:$HELM_SHA" "$CALICO_CHART:$CALICO_CHART_SHA" "$CALICO_CRD_CHART:$CALICO_CRD_SHA" "$COREDNS_CHART:$COREDNS_CHART_SHA"; do
  file=${pair%%:*}; sha=${pair#*:}
  ks_verify_sha256 "$CACHE_ROOT/$file" "$sha"
done
if [[ $COMMAND == verify ]]; then
  ks_images_verify_archives "$ROOT/images.lock.tsv" "$CACHE_ROOT"
  ks_log INFO 'Addon chart and image archives verified; cluster resources were not changed'
  exit 0
fi
if [[ $APPLY != true || ${KS_DRY_RUN:-true} == true ]]; then
  ks_log INFO "DRY-RUN: Calico 3.33.0, CoreDNS chart 1.48.2 / app 1.14.7, NodeLocal DNSCache 1.26.8"
  ks_log INFO "DRY-RUN: cluster DNS=$CLUSTER_DNS, node-local DNS=$NODELOCAL_DNS_IP, kube-proxy=$KUBE_PROXY_MODE"
  ks_log INFO 'DRY-RUN: all locked image archives must be imported to every node before Helm installation'
  ks_log INFO 'DRY-RUN: NodeLocal DNS chart is maintained locally from the Kubernetes v1.37.2 upstream manifest'
  exit 0
fi
[[ ${KS_DRY_RUN:-true} == false ]] || { ks_log ERROR 'Set DRY_RUN=false before --apply'; exit 2; }
[[ -r $SSH_KNOWN_HOSTS_FILE ]] || { ks_log ERROR "Known hosts file missing: $SSH_KNOWN_HOSTS_FILE"; exit 2; }
ks_images_verify_archives "$ROOT/images.lock.tsv" "$CACHE_ROOT"
for cmd in curl flock tar grep awk stat install cp chmod rm mktemp realpath sha256sum; do ks_require_cmd "$cmd"; done
[[ -f $OUTPUT_PATH/kubeconfig/admin.kubeconfig && ! -L $OUTPUT_PATH/kubeconfig/admin.kubeconfig ]] || { ks_log ERROR 'M6 admin kubeconfig missing'; exit 78; }
[[ $(stat -c '%a' "$OUTPUT_PATH/kubeconfig/admin.kubeconfig") == 600 ]] || { ks_log ERROR 'Admin kubeconfig must be mode 0600'; exit 2; }
KUBECTL=$OUTPUT_PATH/bin/kubectl
[[ -x $KUBECTL && ! -L $KUBECTL ]] || { ks_log ERROR 'Pinned kubectl missing from output/bin'; exit 78; }
HELM=$OUTPUT_PATH/bin/helm
if [[ -e $HELM ]]; then
  [[ -f $HELM && -x $HELM && ! -L $HELM ]] || { ks_log ERROR 'Unsafe existing Helm path'; exit 2; }
  "$HELM" version --short | grep -Fq 'v3.22.1' || { ks_log ERROR 'Existing Helm is not v3.22.1'; exit 2; }
else
  WORK=$(mktemp -d "$ROOT/state/.helm-install.XXXXXX")
  trap 'rm -rf -- "$WORK"' EXIT
  tar -tzf "$CACHE_ROOT/$HELM_ARCHIVE" | grep -Fxq linux-amd64/helm || { ks_log ERROR 'Helm archive layout mismatch'; exit 2; }
  tar -xOzf "$CACHE_ROOT/$HELM_ARCHIVE" linux-amd64/helm > "$WORK/helm"
  chmod 0755 "$WORK/helm"
  "$WORK/helm" version --short | grep -Fq 'v3.22.1' || { ks_log ERROR 'Helm archive version mismatch'; exit 2; }
  install -d -m 0755 "$OUTPUT_PATH/bin"
  install -m 0755 "$WORK/helm" "$HELM"
  rm -rf -- "$WORK"
  trap - EXIT
fi
"$HELM" lint "$ROOT/charts/nodelocaldns"
"$HELM" lint "$CACHE_ROOT/$CALICO_CHART"
"$HELM" lint "$CACHE_ROOT/$COREDNS_CHART"
install -d -m 0700 "$ROOT/state"
exec 9>"$ROOT/state/addons.lock"
flock -n 9 || { ks_log ERROR 'Addon operation already in progress'; exit 75; }
SCRIPT_SOURCE=$ROOT/scripts/remote/import-image.sh
SCRIPT_PUBLIC=$CACHE_ROOT/ks-import-image.sh
SCRIPT_CREATED=false
cleanup() { [[ $SCRIPT_CREATED != true || ! -e $SCRIPT_PUBLIC ]] || rm -f -- "$SCRIPT_PUBLIC"; }
trap cleanup EXIT
[[ -f $SCRIPT_SOURCE && ! -L $SCRIPT_SOURCE && ! -L $SCRIPT_PUBLIC ]] || { ks_log ERROR 'Image import helper missing or public path is symlinked'; exit 2; }
cp -- "$SCRIPT_SOURCE" "$SCRIPT_PUBLIC"; chmod 0644 "$SCRIPT_PUBLIC"; SCRIPT_CREATED=true
SCRIPT_SHA=$(ks_sha256_file "$SCRIPT_PUBLIC")
while IFS=$'\t' read -r name reference digest archive archive_sha platform || [[ -n ${name:-} ]]; do
  [[ -z ${name:-} || $name == name || $name == \#* ]] && continue
  while IFS=$'\t' read -r node role address user port || [[ -n ${node:-} ]]; do
    [[ -z ${node:-} || $node == node_id || $node == \#* ]] && continue
    SSH_USER=$user SSH_PORT=$port ks_ssh "$address" curl --fail --silent --show-error --location --proto '=http' --output /var/tmp/ks-import-image.sh "http://$INSTALL_NODE_ADVERTISE_ADDR:$ARTIFACT_HTTP_PORT/ks-import-image.sh"
    remote_sha=$(SSH_USER=$user SSH_PORT=$port ks_ssh "$address" sha256sum /var/tmp/ks-import-image.sh | awk '{print $1}')
    [[ $remote_sha == "$SCRIPT_SHA" ]] || { ks_log ERROR "Image import helper checksum mismatch on $node"; exit 1; }
    SSH_USER=$user SSH_PORT=$port ks_ssh "$address" chmod 0700 /var/tmp/ks-import-image.sh
    SSH_USER=$user SSH_PORT=$port ks_ssh "$address" bash /var/tmp/ks-import-image.sh "http://$INSTALL_NODE_ADVERTISE_ADDR:$ARTIFACT_HTTP_PORT" "$archive" "$archive_sha" "$reference" "$digest" "$CONTAINERD_BIN_DIR/ctr"
  done < "$NODE_INVENTORY_FILE"
done < "$ROOT/images.lock.tsv"
rm -f -- "$SCRIPT_PUBLIC"; SCRIPT_CREATED=false
# Bootstrap kubelet first; host-network Calico components can then install the CNI.
while IFS=$'\t' read -r node role address user port || [[ -n ${node:-} ]]; do
  [[ -z ${node:-} || $node == node_id || $node == \#* ]] && continue
  SSH_USER=$user SSH_PORT=$port ks_ssh "$address" systemctl enable --now kubelet.service
done < "$NODE_INVENTORY_FILE"
KUBECONFIG=$OUTPUT_PATH/kubeconfig/admin.kubeconfig
"$KUBECTL" --kubeconfig "$KUBECONFIG" get --raw=/readyz >/dev/null
"$HELM" template calico-crds "$CACHE_ROOT/$CALICO_CRD_CHART" --namespace tigera-operator --api-versions admissionregistration.k8s.io/v1/MutatingAdmissionPolicy | "$KUBECTL" --kubeconfig "$KUBECONFIG" apply --server-side --force-conflicts -f -
"$KUBECTL" --kubeconfig "$KUBECONFIG" wait --for=condition=Established --timeout=180s crd --all
cat > "$ROOT/state/calico-values.yaml" <<YAML
installation:
  calicoNetwork:
    bgp: Disabled
    ipPools:
      - cidr: "$POD_CIDR"
        encapsulation: VXLAN
        natOutgoing: Enabled
        nodeSelector: all()
YAML
"$HELM" upgrade --install calico "$CACHE_ROOT/$CALICO_CHART" --namespace tigera-operator --create-namespace --values "$ROOT/state/calico-values.yaml" --wait --timeout 10m
"$KUBECTL" --kubeconfig "$KUBECONFIG" wait --for=condition=Available --timeout=15m tigerastatus/calico
while IFS=$'\t' read -r node role address user port || [[ -n ${node:-} ]]; do
  [[ -z ${node:-} || $node == node_id || $node == \#* ]] && continue
  SSH_USER=$user SSH_PORT=$port ks_ssh "$address" systemctl enable --now kube-proxy.service
done < "$NODE_INVENTORY_FILE"
"$KUBECTL" --kubeconfig "$KUBECONFIG" wait --for=condition=Ready --timeout=15m nodes --all
COREDNS_DIGEST=$(awk -F '\t' '$1=="coredns" {sub(/^sha256:/,"",$3); print $3}' "$ROOT/images.lock.tsv")
NODELOCAL_DIGEST=$(awk -F '\t' '$1=="node-local-dns" {sub(/^sha256:/,"",$3); print $3}' "$ROOT/images.lock.tsv")
[[ $COREDNS_DIGEST =~ ^[a-fA-F0-9]{64}$ && $NODELOCAL_DIGEST =~ ^[a-fA-F0-9]{64}$ ]] || { ks_log ERROR 'CoreDNS/NodeLocal image digest missing'; exit 2; }
cat > "$ROOT/state/coredns-values.yaml" <<YAML
image:
  repository: registry.k8s.io/coredns/coredns
  tag: "$COREDNS_IMAGE_VERSION@sha256:$COREDNS_DIGEST"
replicaCount: 2
service:
  name: kube-dns
  clusterIP: "$KUBERNETES_SERVICE_IP"
servers:
  - zones:
      - zone: .
        use_tcp: true
    port: 53
    plugins:
      - name: errors
      - name: health
        configBlock: |-
          lameduck 10s
      - name: ready
      - name: kubernetes
        parameters: "$CLUSTER_DOMAIN in-addr.arpa ip6.arpa"
        configBlock: |-
          pods insecure
          fallthrough in-addr.arpa ip6.arpa
          ttl 30
      - name: prometheus
        parameters: 0.0.0.0:9153
      - name: forward
        parameters: . /etc/resolv.conf
      - name: cache
        parameters: 30
      - name: loop
      - name: reload
      - name: loadbalance
YAML
"$HELM" upgrade --install coredns "$CACHE_ROOT/$COREDNS_CHART" --namespace kube-system --values "$ROOT/state/coredns-values.yaml" --wait --timeout 10m
"$HELM" upgrade --install node-local-dns "$ROOT/charts/nodelocaldns" --namespace kube-system --set-string clusterDomain="$CLUSTER_DOMAIN" --set-string clusterDNS="$KUBERNETES_SERVICE_IP" --set-string localIP="$NODELOCAL_DNS_IP" --set-string kubeProxyMode="$KUBE_PROXY_MODE" --set-string image.digest="sha256:$NODELOCAL_DIGEST" --wait --timeout 10m
"$KUBECTL" --kubeconfig "$KUBECONFIG" rollout status --timeout=10m daemonset/node-local-dns -n kube-system
"$KUBECTL" --kubeconfig "$KUBECONFIG" rollout status --timeout=10m deployment/coredns -n kube-system
ks_log INFO 'M8 addon installation commands completed; run M9 live acceptance before declaring the cluster ready'
