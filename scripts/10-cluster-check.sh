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
source "$ROOT/scripts/lib/addons.sh"
source "$ROOT/scripts/lib/manifest.sh"
CONFIG="$ROOT/cluster.env"
REPORT_DIR=
E2E=false
while (($#)); do
  case $1 in
    --config) (($# >= 2)) || exit 2; CONFIG=$2; shift 2 ;;
    --report-dir) (($# >= 2)) || exit 2; REPORT_DIR=$2; shift 2 ;;
    --dry-run) KS_DRY_RUN=true; KS_DRY_RUN_OVERRIDE=true; shift ;;
    --e2e) E2E=true; shift ;;
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
for cmd in jq kubectl curl stat install mktemp realpath awk head sha256sum; do ks_require_cmd "$cmd"; done
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
E2E_NS="ks-verify-${TIMESTAMP,,}"
E2E_CREATED=false
cleanup() {
  if [[ $E2E_CREATED == true ]]; then "$KUBECTL" delete namespace "$E2E_NS" --wait=false >/dev/null 2>&1 || true; fi
  rm -rf -- "$WORK"
}
trap cleanup EXIT
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
  ks_report_add "$CHECKS" pod-network-e2e NOT_VERIFIED 'API credentials unavailable'
  ks_report_add "$CHECKS" dns-resolution-e2e NOT_VERIFIED 'API credentials unavailable'
  ks_report_add "$CHECKS" service-nodeport-e2e NOT_VERIFIED 'API credentials unavailable'
  ks_report_add "$CHECKS" network-policy-e2e NOT_VERIFIED 'API credentials unavailable'
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
  if [[ -f $ROOT/images.lock.tsv && ! -L $ROOT/images.lock.tsv ]]; then
    if ks_images_validate "$ROOT/images.lock.tsv"; then
      SANDBOX_REPOSITORY=$(ks_yaml_scalar "$ROOT/versions.yaml" sandbox_image repository)
      SANDBOX_TAG=$(ks_yaml_scalar "$ROOT/versions.yaml" sandbox_image tag)
      ks_images_require_ref "$ROOT/images.lock.tsv" sandbox-pause "$SANDBOX_REPOSITORY:$SANDBOX_TAG"
      [[ $ARTIFACT_HTTP_ROOT == /* ]] || ARTIFACT_HTTP_ROOT=$ROOT/$ARTIFACT_HTTP_ROOT
      CACHE_ROOT=$(realpath -m -- "$ARTIFACT_HTTP_ROOT")
      if ks_images_verify_archives "$ROOT/images.lock.tsv" "$CACHE_ROOT"; then
        image_unknown=0
        for namespace in tigera-operator calico-system kube-system; do
          "$KUBECTL" get pods -n "$namespace" -o json > "$WORK/images-$namespace.json" 2>/dev/null || continue
          while IFS= read -r image_ref; do
            [[ -n $image_ref ]] || continue
            image_ref=${image_ref%%@*}
            if ! awk -F '\\t' -v ref="$image_ref" 'NR>1 && $2==ref {found=1} END {exit !found}' "$ROOT/images.lock.tsv"; then
              ks_report_add "$CHECKS" "image-lock-$namespace" FAIL "running pod image missing from lock: $image_ref"
              image_unknown=1
            fi
          done < <(jq -r '.items[] | ((.spec.initContainers // []) + (.spec.containers // []) + (.spec.ephemeralContainers // []))[] | .image' "$WORK/images-$namespace.json")
        done
        if ((image_unknown == 0)); then ks_report_add "$CHECKS" addon-image-closure PASS 'all system namespace pod images are present in the digest/archive lock'; fi
      else
        ks_report_add "$CHECKS" addon-image-closure FAIL 'one or more locked image archives are missing or have a SHA256 mismatch'
      fi
    else
      ks_report_add "$CHECKS" addon-image-closure FAIL 'images.lock.tsv schema validation failed'
    fi
  else
    ks_report_add "$CHECKS" addon-image-closure NOT_VERIFIED 'images.lock.tsv is unavailable'
  fi
  if [[ $E2E == true ]]; then
    if [[ -f $ROOT/images.lock.tsv && ! -L $ROOT/images.lock.tsv ]]; then
      ks_images_validate "$ROOT/images.lock.tsv"
      ks_images_require_ref "$ROOT/images.lock.tsv" m9-test-busybox docker.io/library/busybox:1.37.0
      [[ $ARTIFACT_HTTP_ROOT == /* ]] || ARTIFACT_HTTP_ROOT=$ROOT/$ARTIFACT_HTTP_ROOT
      CACHE_ROOT=$(realpath -m -- "$ARTIFACT_HTTP_ROOT")
      ks_images_verify_archives "$ROOT/images.lock.tsv" "$CACHE_ROOT"
      E2E_IMAGE_DIGEST=$(awk -F '\\t' '$1=="m9-test-busybox" {print $3}' "$ROOT/images.lock.tsv")
      E2E_IMAGE="docker.io/library/busybox:1.37.0@$E2E_IMAGE_DIGEST"
      mapfile -t E2E_NODES < <(awk -F '\\t' 'NR>1 && $1!="" && $1 !~ /^#/ {print $1}' "$NODE_INVENTORY_FILE")
      if (("${#E2E_NODES[@]}" >= 2)); then
        "$KUBECTL" create namespace "$E2E_NS"
        E2E_CREATED=true
        cat > "$WORK/server.yaml" <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: ks-e2e-server
  namespace: "$E2E_NS"
  labels:
    app: ks-e2e-server
spec:
  nodeSelector:
    kubernetes.io/hostname: "${E2E_NODES[0]}"
  tolerations:
    - operator: Exists
  containers:
    - name: httpd
      image: "$E2E_IMAGE"
      imagePullPolicy: Never
      command: ["sh", "-c", "mkdir -p /www && printf ok >/www/index.html && httpd -f -p 8080 -h /www"]
      ports:
        - containerPort: 8080
YAML
        cat > "$WORK/client.yaml" <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: ks-e2e-client
  namespace: "$E2E_NS"
spec:
  nodeSelector:
    kubernetes.io/hostname: "${E2E_NODES[1]}"
  tolerations:
    - operator: Exists
  containers:
    - name: client
      image: "$E2E_IMAGE"
      imagePullPolicy: Never
      command: ["sh", "-c", "sleep 3600"]
YAML
        ks_run_check e2e-server-create "$KUBECTL" apply -f "$WORK/server.yaml"
        ks_run_check e2e-client-create "$KUBECTL" apply -f "$WORK/client.yaml"
        ks_run_check e2e-server-ready "$KUBECTL" wait --for=condition=Ready pod/ks-e2e-server -n "$E2E_NS" --timeout=180s
        ks_run_check e2e-client-ready "$KUBECTL" wait --for=condition=Ready pod/ks-e2e-client -n "$E2E_NS" --timeout=180s
        if "$KUBECTL" get pod ks-e2e-server -n "$E2E_NS" -o json > "$WORK/server.json" && "$KUBECTL" get pod ks-e2e-client -n "$E2E_NS" -o json > "$WORK/client.json"; then
          SERVER_IP=$(jq -r '.status.podIP' "$WORK/server.json")
          SERVER_NODE=$(jq -r '.spec.nodeName' "$WORK/server.json")
          [[ $SERVER_IP =~ ^[0-9.]+$ && $SERVER_NODE == "${E2E_NODES[0]}" ]] || { ks_report_add "$CHECKS" pod-network-e2e FAIL 'server pod did not schedule on selected node'; SERVER_IP=; }
          if [[ -n $SERVER_IP ]]; then
            ks_run_check pod-network-e2e "$KUBECTL" exec ks-e2e-client -n "$E2E_NS" -- wget -qO- "http://$SERVER_IP:8080/"
            ks_run_check dns-resolution-e2e "$KUBECTL" exec ks-e2e-client -n "$E2E_NS" -- nslookup "kubernetes.default.svc.$CLUSTER_DOMAIN"
            "$KUBECTL" expose pod ks-e2e-server -n "$E2E_NS" --name=ks-e2e-service --type=NodePort --port=8080 --target-port=8080
            "$KUBECTL" get service ks-e2e-service -n "$E2E_NS" -o json > "$WORK/service.json"
            SERVICE_IP=$(jq -r '.spec.clusterIP' "$WORK/service.json")
            NODE_PORT=$(jq -r '.spec.ports[0].nodePort' "$WORK/service.json")
            NODE_IP=$("$KUBECTL" get node "$SERVER_NODE" -o json | jq -r '.status.addresses[] | select(.type=="InternalIP") | .address' | head -n1)
            ks_run_check service-clusterip-e2e "$KUBECTL" exec ks-e2e-client -n "$E2E_NS" -- wget -qO- "http://$SERVICE_IP:8080/"
            ks_run_check service-dns-e2e "$KUBECTL" exec ks-e2e-client -n "$E2E_NS" -- wget -qO- "http://ks-e2e-service.$E2E_NS.svc.$CLUSTER_DOMAIN:8080/"
            ks_run_check service-nodeport-e2e "$KUBECTL" exec ks-e2e-client -n "$E2E_NS" -- wget -qO- "http://$NODE_IP:$NODE_PORT/"
            cat > "$WORK/deny-ingress.yaml" <<YAML
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ks-e2e-deny-ingress
  namespace: "$E2E_NS"
spec:
  podSelector:
    matchLabels:
      app: ks-e2e-server
  policyTypes:
    - Ingress
  ingress: []
YAML
            ks_run_check network-policy-create "$KUBECTL" apply -f "$WORK/deny-ingress.yaml"
            sleep 3
            ks_run_check network-policy-e2e "$KUBECTL" exec ks-e2e-client -n "$E2E_NS" -- sh -c 'if wget -q -T 3 -O - "$1"; then exit 1; else exit 0; fi' sh "http://$SERVER_IP:8080/"
            ks_run_check network-policy-delete "$KUBECTL" delete networkpolicy ks-e2e-deny-ingress -n "$E2E_NS" --ignore-not-found=true
            sleep 3
            ks_run_check network-policy-recovery-e2e "$KUBECTL" exec ks-e2e-client -n "$E2E_NS" -- wget -qO- "http://$SERVER_IP:8080/"
          fi
        else
          ks_report_add "$CHECKS" pod-network-e2e FAIL 'unable to retrieve E2E pod state'
          ks_report_add "$CHECKS" dns-resolution-e2e NOT_VERIFIED 'E2E client unavailable'
          ks_report_add "$CHECKS" service-nodeport-e2e NOT_VERIFIED 'E2E client unavailable'
        fi
      else
        ks_report_add "$CHECKS" pod-network-e2e NOT_VERIFIED 'two schedulable nodes are required for cross-node test'
        ks_report_add "$CHECKS" dns-resolution-e2e NOT_VERIFIED 'two schedulable nodes are required for E2E test'
        ks_report_add "$CHECKS" service-nodeport-e2e NOT_VERIFIED 'two schedulable nodes are required for E2E test'
        ks_report_add "$CHECKS" network-policy-e2e NOT_VERIFIED 'two schedulable nodes are required for E2E test'
      fi
    else
      ks_report_add "$CHECKS" pod-network-e2e FAIL 'images.lock.tsv missing; M9 E2E image must be pinned'
      ks_report_add "$CHECKS" dns-resolution-e2e NOT_VERIFIED 'E2E image lock unavailable'
      ks_report_add "$CHECKS" service-nodeport-e2e NOT_VERIFIED 'E2E image lock unavailable'
      ks_report_add "$CHECKS" network-policy-e2e NOT_VERIFIED 'E2E image lock unavailable'
    fi
  else
    ks_report_add "$CHECKS" pod-network-e2e NOT_VERIFIED 'run scripts/10-cluster-check.sh --e2e after pinning/importing the M9 test image'
    ks_report_add "$CHECKS" dns-resolution-e2e NOT_VERIFIED 'in-Pod DNS lookup requires explicit --e2e'
    ks_report_add "$CHECKS" service-nodeport-e2e NOT_VERIFIED 'ClusterIP and NodePort traffic requires explicit --e2e'
    ks_report_add "$CHECKS" network-policy-e2e NOT_VERIFIED 'NetworkPolicy enforcement requires explicit --e2e'
  fi
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
