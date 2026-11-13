#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
(($# == 24)) || { echo 'Expected 24 deployment arguments' >&2; exit 2; }
K8S_VERSION=$1
APISERVER_FILE=$2; APISERVER_SHA=$3
CONTROLLER_FILE=$4; CONTROLLER_SHA=$5
SCHEDULER_FILE=$6; SCHEDULER_SHA=$7
KUBECTL_FILE=$8; KUBECTL_SHA=$9
HTTP_URL=${10}; BIN_DIR=${11}; CONFIG_DIR=${12}; LOG_DIR=${13}; DATA_DIR=${14}
NODE_NAME=${15}; NODE_ADDRESS=${16}; CONTROL_PORT=${17}; CONTROLLER_MANAGER_PORT=${18}; SCHEDULER_PORT=${19}; SERVICE_CIDR=${20}; POD_CIDR=${21}
CLUSTER_DOMAIN=${22}; CLUSTER_NAME=${23}; ETCD_ENDPOINTS=${24}
[[ $EUID -eq 0 ]] || exec sudo -n bash "$0" "$@"
install -d -o root -g root -m 0755 /run/lock
exec 9>/run/lock/ks-deploy-shell-control-plane.lock
flock -n 9 || { echo 'Another control-plane operation is already running on this node' >&2; exit 75; }
for cmd in curl sha256sum systemctl install find cmp stat mv cp mktemp date grep sed tr bash openssl flock; do command -v "$cmd" >/dev/null 2>&1 || { echo "Missing remote command: $cmd" >&2; exit 127; }; done
[[ -r /etc/os-release ]] || exit 2
remote_os=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')
remote_version=$(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '"')
[[ $remote_os == rocky && ${remote_version%%.*} == 9 && $(uname -m) == x86_64 ]] || { echo 'Target must be Rocky Linux 9 / x86_64' >&2; exit 2; }
[[ $K8S_VERSION == v1.37.2 ]] || { echo 'Unreviewed Kubernetes version' >&2; exit 2; }
[[ $APISERVER_FILE == kube-apiserver-$K8S_VERSION-linux-amd64 && $CONTROLLER_FILE == kube-controller-manager-$K8S_VERSION-linux-amd64 && $SCHEDULER_FILE == kube-scheduler-$K8S_VERSION-linux-amd64 && $KUBECTL_FILE == kubectl-$K8S_VERSION-linux-amd64 ]] || exit 2
for digest in "$APISERVER_SHA" "$CONTROLLER_SHA" "$SCHEDULER_SHA" "$KUBECTL_SHA"; do [[ $digest =~ ^[a-fA-F0-9]{64}$ ]] || exit 2; done
[[ $HTTP_URL =~ ^http://[A-Za-z0-9.-]+:[0-9]{1,5}$ ]] || exit 2
for path in "$BIN_DIR" "$CONFIG_DIR" "$LOG_DIR" "$DATA_DIR" "$CONFIG_DIR/pki/etcd"; do [[ $path =~ ^/[A-Za-z0-9._/-]+$ && $path != *'/../'* && $path != */.. && $path != / ]] || exit 2; done
[[ $NODE_NAME =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && $NODE_ADDRESS =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || exit 2
[[ $CONTROL_PORT =~ ^[0-9]{1,5}$ ]] && ((10#$CONTROL_PORT > 0 && 10#$CONTROL_PORT < 65536)) || exit 2
[[ $CONTROLLER_MANAGER_PORT =~ ^[0-9]{1,5}$ && $SCHEDULER_PORT =~ ^[0-9]{1,5}$ ]] || exit 2
((10#$CONTROLLER_MANAGER_PORT > 0 && 10#$CONTROLLER_MANAGER_PORT < 65536 && 10#$SCHEDULER_PORT > 0 && 10#$SCHEDULER_PORT < 65536)) || exit 2
[[ $CONTROL_PORT != "$CONTROLLER_MANAGER_PORT" && $CONTROL_PORT != "$SCHEDULER_PORT" && $CONTROLLER_MANAGER_PORT != "$SCHEDULER_PORT" ]] || exit 2
[[ $SERVICE_CIDR =~ ^[0-9.]+/[0-9]{1,2}$ && $POD_CIDR =~ ^[0-9.]+/[0-9]{1,2}$ ]] || exit 2
[[ $CLUSTER_DOMAIN =~ ^[A-Za-z0-9.-]+$ && $CLUSTER_NAME =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]] || exit 2
[[ $ETCD_ENDPOINTS =~ ^https://[0-9.]+:[0-9]{1,5}(,https://[0-9.]+:[0-9]{1,5})*$ ]] || exit 2

required_files=(
  "$CONFIG_DIR/pki/ca.crt" "$CONFIG_DIR/pki/ca-bundle.crt"
  "$CONFIG_DIR/pki/apiserver.crt" "$CONFIG_DIR/pki/apiserver.key"
  "$CONFIG_DIR/pki/apiserver-kubelet-client.crt" "$CONFIG_DIR/pki/apiserver-kubelet-client.key"
  "$CONFIG_DIR/pki/cluster-signer.crt" "$CONFIG_DIR/pki/cluster-signer.key"
  "$CONFIG_DIR/pki/controller-manager.crt" "$CONFIG_DIR/pki/controller-manager.key"
  "$CONFIG_DIR/pki/scheduler.crt" "$CONFIG_DIR/pki/scheduler.key"
  "$CONFIG_DIR/pki/front-proxy-ca.crt" "$CONFIG_DIR/pki/front-proxy-client.crt" "$CONFIG_DIR/pki/front-proxy-client.key"
  "$CONFIG_DIR/pki/apiserver-etcd-client.crt" "$CONFIG_DIR/pki/apiserver-etcd-client.key"
  "$CONFIG_DIR/pki/sa.key" "$CONFIG_DIR/pki/sa.pub"
  "$CONFIG_DIR/pki/etcd/ca.crt"
)
for file in "${required_files[@]}"; do [[ -f $file && ! -L $file ]] || { echo "Missing PKI file: $file" >&2; exit 2; }; done
for key in "$CONFIG_DIR/pki/apiserver.key" "$CONFIG_DIR/pki/apiserver-kubelet-client.key" "$CONFIG_DIR/pki/cluster-signer.key" "$CONFIG_DIR/pki/controller-manager.key" "$CONFIG_DIR/pki/scheduler.key" "$CONFIG_DIR/pki/front-proxy-client.key" "$CONFIG_DIR/pki/apiserver-etcd-client.key" "$CONFIG_DIR/pki/sa.key"; do
  [[ $(stat -c '%a' "$key") == 600 ]] || { echo "Private key mode must be 0600: $key" >&2; exit 2; }
done
openssl verify -CAfile "$CONFIG_DIR/pki/ca-bundle.crt" "$CONFIG_DIR/pki/apiserver.crt" >/dev/null
openssl verify -CAfile "$CONFIG_DIR/pki/ca-bundle.crt" "$CONFIG_DIR/pki/apiserver-kubelet-client.crt" >/dev/null
openssl verify -CAfile "$CONFIG_DIR/pki/front-proxy-ca.crt" "$CONFIG_DIR/pki/front-proxy-client.crt" >/dev/null
openssl verify -CAfile "$CONFIG_DIR/pki/etcd/ca.crt" "$CONFIG_DIR/pki/apiserver-etcd-client.crt" >/dev/null

REMOTE_TMP=$(mktemp -d /var/tmp/ks-control-plane.XXXXXX)
cleanup() { rm -rf -- "$REMOTE_TMP"; }
trap cleanup EXIT
fetch_binary() {
  local name=$1 digest=$2 target=$REMOTE_TMP/$1
  curl --fail --silent --show-error --location --proto '=http' --max-time 300 --output "$target" "$HTTP_URL/$name"
  printf '%s  %s\n' "$digest" "$target" | sha256sum -c -
  chmod 0700 "$target"
  if [[ $name == "$KUBECTL_FILE" ]]; then
    "$target" version --client --output=yaml | grep -Fq "gitVersion: $K8S_VERSION" || { echo "Unexpected kubectl version" >&2; exit 2; }
  else
    "$target" --version 2>&1 | grep -Fq "Kubernetes $K8S_VERSION" || { echo "Unexpected binary version: $name" >&2; exit 2; }
  fi
}
fetch_binary "$APISERVER_FILE" "$APISERVER_SHA"
fetch_binary "$CONTROLLER_FILE" "$CONTROLLER_SHA"
fetch_binary "$SCHEDULER_FILE" "$SCHEDULER_SHA"
fetch_binary "$KUBECTL_FILE" "$KUBECTL_SHA"

for path in "$CONFIG_DIR" "$CONFIG_DIR/pki" "$LOG_DIR" "$DATA_DIR" "$BIN_DIR" "$CONFIG_DIR/pki/etcd"; do [[ ! -L $path ]] || { echo "Symlinked Kubernetes path rejected: $path" >&2; exit 2; }; done
install -d -o root -g root -m 0700 "$CONFIG_DIR" "$CONFIG_DIR/pki" "$DATA_DIR"
install -d -o root -g root -m 0750 "$LOG_DIR"
install -d -o root -g root -m 0755 "$BIN_DIR"

cat > "$REMOTE_TMP/audit-policy.yaml" <<'AUDIT'
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages:
  - RequestReceived
rules:
  - level: None
    users:
      - system:kube-proxy
    verbs:
      - watch
    resources:
      - group: ""
        resources:
          - endpoints
          - services
  - level: Metadata
    resources:
      - group: ""
        resources:
          - secrets
          - configmaps
  - level: RequestResponse
    verbs:
      - create
      - update
      - patch
      - delete
    resources:
      - group: ""
        resources:
          - pods
          - deployments
          - services
          - namespaces
          - nodes
  - level: Metadata
AUDIT

cat > "$REMOTE_TMP/kube-apiserver.service" <<UNIT
[Unit]
Description=Kubernetes API Server
Documentation=https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN_DIR/kube-apiserver \\
  --advertise-address=$NODE_ADDRESS \\
  --bind-address=0.0.0.0 \\
  --secure-port=$CONTROL_PORT \\
  --service-cluster-ip-range=$SERVICE_CIDR \\
  --etcd-servers=$ETCD_ENDPOINTS \\
  --etcd-cafile=$CONFIG_DIR/pki/etcd/ca.crt \\
  --etcd-certfile=$CONFIG_DIR/pki/apiserver-etcd-client.crt \\
  --etcd-keyfile=$CONFIG_DIR/pki/apiserver-etcd-client.key \\
  --etcd-prefix=/registry \\
  --client-ca-file=$CONFIG_DIR/pki/ca-bundle.crt \\
  --tls-cert-file=$CONFIG_DIR/pki/apiserver.crt \\
  --tls-private-key-file=$CONFIG_DIR/pki/apiserver.key \\
  --kubelet-certificate-authority=$CONFIG_DIR/pki/ca-bundle.crt \\
  --kubelet-client-certificate=$CONFIG_DIR/pki/apiserver-kubelet-client.crt \\
  --kubelet-client-key=$CONFIG_DIR/pki/apiserver-kubelet-client.key \\
  --kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname \\
  --service-account-key-file=$CONFIG_DIR/pki/sa.pub \\
  --service-account-signing-key-file=$CONFIG_DIR/pki/sa.key \\
  --service-account-issuer=https://kubernetes.default.svc.$CLUSTER_DOMAIN \\
  --api-audiences=https://kubernetes.default.svc.$CLUSTER_DOMAIN \\
  --service-account-lookup=true \\
  --authorization-mode=Node,RBAC \\
  --enable-admission-plugins=NodeRestriction \\
  --anonymous-auth=false \\
  --allow-privileged=true \\
  --requestheader-client-ca-file=$CONFIG_DIR/pki/front-proxy-ca.crt \\
  --proxy-client-cert-file=$CONFIG_DIR/pki/front-proxy-client.crt \\
  --proxy-client-key-file=$CONFIG_DIR/pki/front-proxy-client.key \\
  --requestheader-allowed-names=front-proxy-client \\
  --requestheader-extra-headers-prefix=X-Remote-Extra- \\
  --requestheader-group-headers=X-Remote-Group \\
  --requestheader-username-headers=X-Remote-User \\
  --enable-aggregator-routing=true \\
  --audit-policy-file=$CONFIG_DIR/audit-policy.yaml \\
  --audit-log-path=$LOG_DIR/audit.log \\
  --audit-log-maxage=30 \\
  --audit-log-maxbackup=10 \\
  --audit-log-maxsize=100 \\
  --audit-log-format=json \\
  --audit-log-truncate-enabled=true \\
  --tls-min-version=VersionTLS12 \\
  --endpoint-reconciler-type=lease \\
  --event-ttl=1h \\
  --request-timeout=1m \\
  --max-requests-inflight=400 \\
  --max-mutating-requests-inflight=200 \\
  --profiling=false
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536
LimitCORE=infinity
TasksMax=infinity
OOMScoreAdjust=-999
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=$LOG_DIR $DATA_DIR

[Install]
WantedBy=multi-user.target
UNIT

cat > "$REMOTE_TMP/kube-controller-manager.service" <<UNIT
[Unit]
Description=Kubernetes Controller Manager
Documentation=https://kubernetes.io/docs/reference/command-line-tools-reference/kube-controller-manager/
After=network-online.target kube-apiserver.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN_DIR/kube-controller-manager \\
  --kubeconfig=$CONFIG_DIR/controller-manager.kubeconfig \\
  --authentication-kubeconfig=$CONFIG_DIR/controller-manager.kubeconfig \\
  --authorization-kubeconfig=$CONFIG_DIR/controller-manager.kubeconfig \\
  --bind-address=127.0.0.1 \\
  --secure-port=$CONTROLLER_MANAGER_PORT \\
  --cluster-cidr=$POD_CIDR \\
  --service-cluster-ip-range=$SERVICE_CIDR \\
  --allocate-node-cidrs=true \\
  --cluster-name=$CLUSTER_NAME \\
  --cluster-signing-cert-file=$CONFIG_DIR/pki/cluster-signer.crt \\
  --cluster-signing-key-file=$CONFIG_DIR/pki/cluster-signer.key \\
  --cluster-signing-duration=8760h \\
  --root-ca-file=$CONFIG_DIR/pki/ca.crt \\
  --service-account-private-key-file=$CONFIG_DIR/pki/sa.key \\
  --use-service-account-credentials=true \\
  --leader-elect=true \\
  --profiling=false
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536
OOMScoreAdjust=-999
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=$DATA_DIR

[Install]
WantedBy=multi-user.target
UNIT

cat > "$REMOTE_TMP/kube-scheduler.service" <<UNIT
[Unit]
Description=Kubernetes Scheduler
Documentation=https://kubernetes.io/docs/reference/command-line-tools-reference/kube-scheduler/
After=network-online.target kube-apiserver.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN_DIR/kube-scheduler \\
  --kubeconfig=$CONFIG_DIR/scheduler.kubeconfig \\
  --authentication-kubeconfig=$CONFIG_DIR/scheduler.kubeconfig \\
  --authorization-kubeconfig=$CONFIG_DIR/scheduler.kubeconfig \\
  --bind-address=127.0.0.1 \\
  --secure-port=$SCHEDULER_PORT \\
  --leader-elect=true \\
  --profiling=false
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536
OOMScoreAdjust=-999
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=$DATA_DIR

[Install]
WantedBy=multi-user.target
UNIT

unit_files=("$REMOTE_TMP/kube-apiserver.service" "$REMOTE_TMP/kube-controller-manager.service" "$REMOTE_TMP/kube-scheduler.service")
unit_targets=(/etc/systemd/system/kube-apiserver.service /etc/systemd/system/kube-controller-manager.service /etc/systemd/system/kube-scheduler.service)
binary_files=("$APISERVER_FILE" "$CONTROLLER_FILE" "$SCHEDULER_FILE" "$KUBECTL_FILE")
binary_targets=("$BIN_DIR/kube-apiserver" "$BIN_DIR/kube-controller-manager" "$BIN_DIR/kube-scheduler" "$BIN_DIR/kubectl")
binary_digests=("$APISERVER_SHA" "$CONTROLLER_SHA" "$SCHEDULER_SHA" "$KUBECTL_SHA")
services=(kube-apiserver.service kube-controller-manager.service kube-scheduler.service)
active_count=0
for service in "${services[@]}"; do if systemctl is-active --quiet "$service"; then ((active_count+=1)); fi; done
for target in "${binary_targets[@]}" "${unit_targets[@]}" "$CONFIG_DIR/audit-policy.yaml"; do [[ ! -L $target ]] || { echo "Symlinked control-plane target rejected: $target" >&2; exit 2; }; done

if ((active_count > 0)); then
  for i in "${!binary_targets[@]}"; do
    [[ -f ${binary_targets[$i]} && ! -L ${binary_targets[$i]} ]] || { echo 'Active control plane has a missing/unsafe binary' >&2; exit 73; }
    printf '%s  %s\n' "${binary_digests[$i]}" "${binary_targets[$i]}" | sha256sum -c -
  done
  for i in "${!unit_targets[@]}"; do
    [[ -f ${unit_targets[$i]} && ! -L ${unit_targets[$i]} ]] && cmp -s "${unit_files[$i]}" "${unit_targets[$i]}" || { echo 'Active control-plane configuration differs; refusing replacement' >&2; exit 73; }
  done
  cmp -s "$REMOTE_TMP/audit-policy.yaml" "$CONFIG_DIR/audit-policy.yaml" || { echo 'Active audit policy differs; refusing replacement' >&2; exit 73; }
  "$BIN_DIR/kubectl" version --client --output=yaml | grep -Fq "gitVersion: $K8S_VERSION"
  systemctl enable "${services[@]}"
  echo 'Existing active control-plane components match pinned checksums and configuration; no replacement performed'
  rm -f -- "$0"
  exit 0
fi

declare -A enabled_state=()
for service in "${services[@]}"; do enabled_state[$service]=$(systemctl is-enabled "$service" 2>/dev/null || true); done
install -d -o root -g root -m 0700 "$DATA_DIR/.ks-deploy-shell"
backup_dir=$(mktemp -d "$DATA_DIR/.ks-deploy-shell/control-plane.XXXXXX")
chmod 0700 "$backup_dir"
for target in "${binary_targets[@]}" "${unit_targets[@]}" "$CONFIG_DIR/audit-policy.yaml"; do
  [[ ! -e $target ]] || cp -a -- "$target" "$backup_dir/"
done
for i in "${!binary_files[@]}"; do
  install -m 0755 "$REMOTE_TMP/${binary_files[$i]}" "$BIN_DIR/.${binary_targets[$i]##*/}.new"
  mv -f -- "$BIN_DIR/.${binary_targets[$i]##*/}.new" "${binary_targets[$i]}"
done
install -o root -g root -m 0644 "$REMOTE_TMP/audit-policy.yaml" "$CONFIG_DIR/audit-policy.yaml.new"
mv -f -- "$CONFIG_DIR/audit-policy.yaml.new" "$CONFIG_DIR/audit-policy.yaml"
for i in "${!unit_files[@]}"; do
  install -o root -g root -m 0644 "${unit_files[$i]}" "${unit_targets[$i]}.new"
  mv -f -- "${unit_targets[$i]}.new" "${unit_targets[$i]}"
done
systemctl daemon-reload
if ! systemctl enable "${services[@]}"; then
  systemctl disable "${services[@]}" >/dev/null 2>&1 || true
  for target in "${binary_targets[@]}" "${unit_targets[@]}" "$CONFIG_DIR/audit-policy.yaml"; do
    if [[ -f $backup_dir/${target##*/} ]]; then cp -a "$backup_dir/${target##*/}" "$target"; else rm -f "$target"; fi
  done
  for service in "${services[@]}"; do
    if [[ ${enabled_state[$service]} == enabled || ${enabled_state[$service]} == enabled-runtime ]]; then systemctl enable "$service" >/dev/null 2>&1 || true; fi
  done
  systemctl daemon-reload
  echo 'Control-plane installation failed; previous binaries and unit files restored' >&2
  exit 1
fi
echo "Kubernetes $K8S_VERSION binaries and Systemd units installed; services are enabled but not started"
rm -f -- "$0"
