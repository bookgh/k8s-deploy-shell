#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$ROOT/scripts/lib/common.sh"
source "$ROOT/scripts/lib/manifest.sh"
MANIFEST=${1:-$ROOT/artifacts/manifest.tsv}
ks_manifest_validate "$MANIFEST"
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT

fetch_component() {
  local name=$1 file sha version arch url target
  IFS=$'\t' read -r file sha version arch url < <(ks_manifest_lookup "$MANIFEST" "$name")
  [[ $version == v1.37.2 && $arch == amd64 && $url == "https://dl.k8s.io/release/$version/bin/linux/amd64/$name" ]] || { ks_log ERROR "Unexpected pinned artifact metadata: $name"; return 2; }
  target=$TMP/$name
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 --max-time 300 --output "$target" "$url"
  ks_verify_sha256 "$target" "$sha"
  chmod 0700 "$target"
  printf -v "${name//-/_}_BIN" '%s' "$target"
  printf -v "${name//-/_}_SHA" '%s' "$sha"
}

check_help_flags() {
  local binary=$1 label=$2 help_file=$TMP/$2.help flag
  shift 2
  "$binary" --help > "$help_file" 2>&1 || true
  [[ -s $help_file ]] || { ks_log ERROR "No help output from $label"; return 1; }
  for flag in "$@"; do
    grep -Fq -- "$flag" "$help_file" || { ks_log ERROR "$label does not support expected flag $flag"; return 1; }
  done
  ks_log INFO "$label flag validation passed"
}

fetch_component kube-apiserver
fetch_component kube-controller-manager
fetch_component kube-scheduler
fetch_component kubectl

"$kube_apiserver_BIN" --version 2>&1 | grep -Fq 'Kubernetes v1.37.2'
"$kube_controller_manager_BIN" --version 2>&1 | grep -Fq 'Kubernetes v1.37.2'
"$kube_scheduler_BIN" --version 2>&1 | grep -Fq 'Kubernetes v1.37.2'
"$kubectl_BIN" version --client --output=yaml | grep -Fq 'gitVersion: v1.37.2'

check_help_flags "$kube_apiserver_BIN" kube-apiserver \
  --advertise-address --bind-address --secure-port --service-cluster-ip-range \
  --etcd-servers --etcd-cafile --etcd-certfile --etcd-keyfile --etcd-prefix \
  --client-ca-file --tls-cert-file --tls-private-key-file \
  --kubelet-certificate-authority --kubelet-client-certificate --kubelet-client-key \
  --kubelet-preferred-address-types --service-account-key-file --service-account-signing-key-file \
  --service-account-issuer --api-audiences --service-account-lookup \
  --authorization-mode --enable-admission-plugins --anonymous-auth --allow-privileged \
  --requestheader-client-ca-file --proxy-client-cert-file --proxy-client-key-file \
  --requestheader-allowed-names --requestheader-extra-headers-prefix \
  --requestheader-group-headers --requestheader-username-headers --enable-aggregator-routing \
  --audit-policy-file --audit-log-path --audit-log-maxage --audit-log-maxbackup \
  --audit-log-maxsize --audit-log-format --audit-log-truncate-enabled \
  --tls-min-version --endpoint-reconciler-type --event-ttl --request-timeout \
  --max-requests-inflight --max-mutating-requests-inflight --profiling

check_help_flags "$kube_controller_manager_BIN" kube-controller-manager \
  --kubeconfig --authentication-kubeconfig --authorization-kubeconfig \
  --bind-address --secure-port --cluster-cidr --service-cluster-ip-range \
  --allocate-node-cidrs --cluster-name --cluster-signing-cert-file \
  --cluster-signing-key-file --cluster-signing-duration --root-ca-file \
  --service-account-private-key-file --use-service-account-credentials --leader-elect --profiling

check_help_flags "$kube_scheduler_BIN" kube-scheduler \
  --kubeconfig --authentication-kubeconfig --authorization-kubeconfig \
  --bind-address --secure-port --leader-elect --profiling
