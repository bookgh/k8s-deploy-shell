#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$ROOT/scripts/lib/common.sh"
source "$ROOT/scripts/lib/config.sh"
source "$ROOT/scripts/lib/nodes.sh"
source "$ROOT/scripts/lib/ssh.sh"
source "$ROOT/scripts/lib/report.sh"
CONFIG="$ROOT/cluster.env"
REPORT_DIR=
while (($#)); do
  case $1 in
    --config) (($# >= 2)) || exit 2; CONFIG=$2; shift 2 ;;
    --report-dir) (($# >= 2)) || exit 2; REPORT_DIR=$2; shift 2 ;;
    --dry-run) KS_DRY_RUN=true; KS_DRY_RUN_OVERRIDE=true; shift ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
ks_config_load "$CONFIG"
ks_config_validate
ks_nodes_validate "$NODE_INVENTORY_FILE" "$MASTERS" "$WORKERS"
if ks_is_true "$KS_DRY_RUN"; then
  ks_log WARN 'NOT_VERIFIED: dry-run performs no API, SSH, filesystem or cluster checks'
  printf 'Would verify API livez/readyz, etcd quorum, expected Ready nodes, Calico, CoreDNS, NodeLocal DNSCache and every node localhost API endpoint.\n'
  exit 78
fi
for cmd in jq kubectl curl stat install mktemp; do ks_require_cmd "$cmd"; done
[[ $OUTPUT_ROOT == /* ]] || OUTPUT_ROOT=$ROOT/$OUTPUT_ROOT
OUTPUT_PATH=$(realpath -m -- "$OUTPUT_ROOT")
[[ -n $REPORT_DIR ]] || REPORT_DIR=$OUTPUT_PATH/reports
[[ $REPORT_DIR == /* ]] || REPORT_DIR=$ROOT/$REPORT_DIR
REPORT_DIR=$(realpath -m -- "$REPORT_DIR")
[[ $REPORT_DIR =~ ^/[A-Za-z0-9._/-]+$ && $REPORT_DIR != *'/../'* ]] || { ks_log ERROR 'Unsafe report directory'; exit 2; }
[[ $NODE_INVENTORY_FILE == /* ]] || NODE_INVENTORY_FILE=$ROOT/$NODE_INVENTORY_FILE
[[ $SSH_KNOWN_HOSTS_FILE == /* ]] || SSH_KNOWN_HOSTS_FILE=$ROOT/$SSH_KNOWN_HOSTS_FILE
export SSH_KNOWN_HOSTS_FILE
KUBECTL=$OUTPUT_PATH/bin/kubectl
KUBECONFIG=$OUTPUT_PATH/kubeconfig/admin.kubeconfig
TIMESTAMP=$(date -u '+%Y%m%dT%H%M%SZ')
WORK=$(mktemp -d "$ROOT/state/.cluster-check.XXXXXX")
trap 'rm -rf -- "$WORK"' EXIT
CHECKS=$WORK/checks.tsv
: > "$CHECKS"
ks_run_check() {
  local name=$1; shift
  local output rc
  if output=$("$@" 2>&1); then
    ks_report_add "$CHECKS" "$name" PASS "${output:-ok}"
  else
    rc=$?
    ks_report_add "$CHECKS" "$name" FAIL "exit=$rc ${output:-command failed}"
  fi
}
ks_file_check() {
  local name=$1 file=$2 mode=${3:-}
  if [[ -f $file && ! -L $file ]] && { [[ -z $mode ]] || [[ $(stat -c '%a' "$file") == "$mode" ]]; }; then
    ks_report_add "$CHECKS" "$name" PASS "$file"
    return 0
  fi
  ks_report_add "$CHECKS" "$name" FAIL "missing, unsafe or wrong mode: $file"
  return 1
}
ks_file_check kubectl-binary "$KUBECTL" || true
ks_file_check admin-kubeconfig "$KUBECONFIG" 600 || true
if [[ ! -x $KUBECTL || ! -f $KUBECONFIG ]]; then
  ks_report_add "$CHECKS" api-livez NOT_VERIFIED 'kubectl/admin kubeconfig unavailable'
  ks_report_add "$CHECKS" api-readyz NOT_VERIFIED 'kubectl/admin kubeconfig unavailable'
  ks_report_add "$CHECKS" etcd-quorum NOT_VERIFIED 'API credentials unavailable'
  ks_report_add "$CHECKS" node-readiness NOT_VERIFIED 'API credentials unavailable'
else
  export KUBECONFIG
  ks_run_check api-livez "$KUBECTL" get --raw=/livez
  ks_run_check api-readyz "$KUBECTL" get --raw=/readyz
  if "$KUBECTL" get nodes -o json > "$WORK/nodes.json" 2>"$WORK/nodes.err"; then
    ks_report_add "$CHECKS" node-api-list PASS 'Kubernetes API returned node inventory'
    while IFS=$'\t' read -r node role address user port || [[ -n ${node:-} ]]; do
      [[ -z ${node:-} || $node == node_id || $node == \#* ]] && continue
      if jq -e --arg name "$node" '.items[] | select(.metadata.name==$name) | .status.conditions[]? | select(.type=="Ready" and .status=="True")' "$WORK/nodes.json" >/dev/null; then
        ks_report_add "$CHECKS" "node-$node" PASS "$role $address Ready"
      else
        ks_report_add "$CHECKS" "node-$node" FAIL "$role $address missing or not Ready"
      fi
    done < "$NODE_INVENTORY_FILE"
  else
    ks_report_add "$CHECKS" node-api-list FAIL "$(cat "$WORK/nodes.err")"
  fi
  if "$KUBECTL" get tigerastatus calico -o json > "$WORK/calico.json" 2>/dev/null && jq -e 'any(.status.conditions[]?; .type=="Available" and .status=="True")' "$WORK/calico.json" >/dev/null; then
    ks_report_add "$CHECKS" calico-status PASS 'TigeraStatus calico Available'
  else
    ks_report_add "$CHECKS" calico-status FAIL 'TigeraStatus calico is not Available'
  fi
  ks_run_check coredns-rollout "$KUBECTL" rollout status deployment/coredns -n kube-system --timeout=60s
  ks_run_check nodelocaldns-rollout "$KUBECTL" rollout status daemonset/node-local-dns -n kube-system --timeout=60s
  if "$KUBECTL" get svc kube-dns -n kube-system -o json > "$WORK/dns-service.json" 2>/dev/null && jq -e --arg ip "$KUBERNETES_SERVICE_IP" '.spec.clusterIP==$ip' "$WORK/dns-service.json" >/dev/null; then
    ks_report_add "$CHECKS" coredns-service PASS "kube-dns ClusterIP=$KUBERNETES_SERVICE_IP"
  else
    ks_report_add "$CHECKS" coredns-service FAIL 'kube-dns service missing or ClusterIP mismatch'
  fi
  for namespace in tigera-operator calico-system kube-system; do
    if "$KUBECTL" get pods -n "$namespace" -o json > "$WORK/pods.json" 2>/dev/null &&
      jq -e '[.items[] | select(.status.phase!="Running" or any(.status.containerStatuses[]?; .ready!=true))] | length==0' "$WORK/pods.json" >/dev/null; then
      ks_report_add "$CHECKS" "pods-$namespace" PASS 'all namespace pods Running/Ready'
    else
      ks_report_add "$CHECKS" "pods-$namespace" FAIL 'one or more pods are not Running/Ready'
    fi
  done
  ks_report_add "$CHECKS" pod-network-e2e NOT_VERIFIED 'cross-node Pod-to-Pod and NetworkPolicy traffic requires a dedicated test workload'
  ks_report_add "$CHECKS" dns-resolution-e2e NOT_VERIFIED 'in-Pod DNS lookup requires a dedicated test image/workload'
  ks_report_add "$CHECKS" service-nodeport-e2e NOT_VERIFIED 'ClusterIP and NodePort traffic requires a dedicated test workload'
fi
if [[ -x $ROOT/scripts/04-deploy-etcd.sh ]]; then
  if "$ROOT/scripts/04-deploy-etcd.sh" --config "$CONFIG" health > "$WORK/etcd.out" 2>&1; then
    ks_report_add "$CHECKS" etcd-quorum PASS "$(tr '\n' ' ' < "$WORK/etcd.out")"
  else
    rc=$?
    ks_report_add "$CHECKS" etcd-quorum FAIL "exit=$rc $(tr '\n' ' ' < "$WORK/etcd.out")"
  fi
else
  ks_report_add "$CHECKS" etcd-quorum NOT_VERIFIED 'etcd health command unavailable'
fi
while IFS=$'\t' read -r node role address user port || [[ -n ${node:-} ]]; do
  [[ -z ${node:-} || $node == node_id || $node == \#* ]] && continue
  node_kubeconfig=$OUTPUT_PATH/node-config/$node/kubelet.kubeconfig
  if [[ -f $node_kubeconfig && ! -L $node_kubeconfig ]]; then
    endpoint=$("$KUBECTL" config view --kubeconfig "$node_kubeconfig" --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)
    if [[ $endpoint == "https://127.0.0.1:$CONTROL_PLANE_PORT" ]]; then
      ks_report_add "$CHECKS" "kubeconfig-$node" PASS "endpoint=$endpoint"
    else
      ks_report_add "$CHECKS" "kubeconfig-$node" FAIL "endpoint mismatch: ${endpoint:-unreadable}"
    fi
  else
    ks_report_add "$CHECKS" "kubeconfig-$node" FAIL "missing: $node_kubeconfig"
  fi
  if [[ -r $SSH_KNOWN_HOSTS_FILE ]]; then
    if SSH_USER=$user SSH_PORT=$port ks_ssh "$address" curl --fail --silent --show-error --cacert "$KUBERNETES_CONFIG_DIR/pki/ca.crt" --connect-timeout 3 --max-time 8 "https://127.0.0.1:$CONTROL_PLANE_PORT/readyz" >/dev/null 2>&1; then
      ks_report_add "$CHECKS" "localhost-api-$node" PASS 'TLS-verified loopback API endpoint'
    else
      ks_report_add "$CHECKS" "localhost-api-$node" FAIL 'loopback API endpoint failed TLS/readiness check'
    fi
  else
    ks_report_add "$CHECKS" "localhost-api-$node" NOT_VERIFIED 'known_hosts file unavailable'
  fi
done < "$NODE_INVENTORY_FILE"
ks_report_overall "$CHECKS"
OVERALL=$REPLY
install -d -m 0700 "$REPORT_DIR"
TEXT_REPORT=$REPORT_DIR/cluster-check-$TIMESTAMP.txt
JSON_REPORT=$REPORT_DIR/cluster-check-$TIMESTAMP.json
ks_report_render "$CHECKS" "$TEXT_REPORT" "$JSON_REPORT" "$CLUSTER_NAME" "$OVERALL" "$TIMESTAMP"
ks_log INFO "Cluster check overall=$OVERALL"
ks_log INFO "Text report: $TEXT_REPORT"
ks_log INFO "JSON report: $JSON_REPORT"
[[ $OVERALL == PASS ]] && exit 0
[[ $OVERALL == PARTIAL ]] && exit 78
exit 1
